#!/usr/bin/env bash
# Deterministic reproduction of dotnet/runtime#121977 against ONE runtime (Linux).
#
# Builds the repro app + an LD_PRELOAD write-delay shim + a torn-read detector, then
# runs N concurrent writers (under the shim) against ONE shared profile while the
# detector samples it.
#
#   exit 2  -> INCOMPLETE/TORN/MISSING observed = bug present (an UNPATCHED runtime)
#   exit 0  -> profile always complete+valid = atomic (a FIXED runtime)
#   other   -> harness error (no profile seeded, no valid observation, detector died):
#              NOT a pass; "nothing happened" must never report as "atomic".
#
# The app is BUILT with a full SDK and RUN on the runtime under test:
#   DOTNET_SDK   full SDK used to build the app   (default: `dotnet` from PATH)
#   DOTNET_ROOT  runtime layout to test           (default: the SDK's own runtime)
#
# Usage:
#   ./run.sh                                      # build+run with the SDK on PATH
#                                                 # (a stock SDK -> reproduces the bug)
#   DOTNET_ROOT=/path/to/built-runtime ./run.sh   # run on your locally built coreclr
#   DUR_MS=15000 WRITERS=12 ./run.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPPROJ="$HERE/../app/mcjrepro.csproj"
DETPROJ="$HERE/../detector/detector.csproj"
DUR_MS="${DUR_MS:-15000}"
WRITERS="${WRITERS:-12}"
TARGET="StartupProfileData-Repro"

SDK="${DOTNET_SDK:-$(command -v dotnet)}"
[ -x "$SDK" ] || { echo "no SDK (set DOTNET_SDK or put dotnet on PATH)"; exit 1; }
if [ -n "${DOTNET_ROOT:-}" ]; then RUN="$DOTNET_ROOT/dotnet"; else RUN="$SDK"; fi
[ -x "$RUN" ] || { echo "runtime host not found: $RUN"; exit 1; }
# Preserve paths relative to the caller before the build changes directory for global.json.
SDK="$(cd "$(dirname "$SDK")" && pwd)/$(basename "$SDK")"
RUN="$(cd "$(dirname "$RUN")" && pwd)/$(basename "$RUN")"
command -v gcc >/dev/null || { echo "gcc required"; exit 1; }

WORK="$(mktemp -d)"
# Left in place on purpose (a throwaway dir under $TMPDIR); delete it yourself when done.
trap 'echo "work dir left at: $WORK"' EXIT
export MCJ_PROFILE_ROOT="$WORK/cache"
PROFILE="$MCJ_PROFILE_ROOT/$TARGET"
export DOTNET_MULTILEVEL_LOOKUP=0 DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-Major}"

echo "== building repro app + detector (SDK: $SDK) =="
( unset DOTNET_ROOT
  # SDK selection searches from cwd, not from the absolute project path.
  # The subshell restores the caller's directory and DOTNET_ROOT on every exit.
  cd "$HERE/.." || exit 1
  "$SDK" --version || exit 1
  "$SDK" build -c Release "$APPPROJ" -o "$WORK/app" >/dev/null || exit 1
  "$SDK" build -c Release "$DETPROJ" -o "$WORK/det" >/dev/null || exit 1
) || { echo "build failed"; exit 1; }
APP="$WORK/app/mcjrepro.dll"
DET="$WORK/det/detector.dll"
echo "== building LD_PRELOAD shim (gcc) =="
gcc -O2 -shared -fPIC "$HERE/mcj_delay.c" -o "$WORK/mcj_delay.so" -ldl || exit 1

echo "== runtime under test: $RUN =="
echo "== seeding a valid profile (no shim) =="
WORKER_IDX=1 SLEEP_MS=5 "$RUN" "$APP" >/dev/null 2>&1 || { echo "seed run failed"; exit 1; }
SEED_SIZE=$(stat -c%s "$PROFILE" 2>/dev/null || echo 0)
echo "seeded: $SEED_SIZE bytes"
# A profile smaller than its 64-byte header means MulticoreJIT never wrote one (e.g. it
# silently disables itself below 2 CPUs). Without a profile the live phase would observe
# nothing and "ATOMIC" would be vacuous.
[ "$SEED_SIZE" -ge 64 ] || { echo "ERROR: no profile was seeded -- nothing to measure"; exit 1; }
SEED_STATE=$(stat -c '%i:%s:%y' "$PROFILE")

echo "== sanity: detector on the static (no-writer) profile, must report 0 =="
"$RUN" "$DET" "$PROFILE" 800

echo "== live: detector + $WRITERS concurrent delayed writers for ${DUR_MS}ms =="
export MCJ_DELAY_REPORT="$WORK/shim_report"
READY="$WORK/det.ready"
"$RUN" "$DET" "$PROFILE" "$DUR_MS" "$READY" > "$WORK/det.out" 2>&1 &
det=$!
for ((attempt=0; attempt<1000; attempt++)); do
    [ -e "$READY" ] && break
    kill -0 "$det" 2>/dev/null || break
    sleep 0.01
done
if [ ! -e "$READY" ]; then
    wait "$det" 2>/dev/null || true
    cat "$WORK/det.out"
    echo "ERROR: detector did not become ready -- no verdict"
    exit 1
fi

# Keep the unit explicit. GNU date truncates %3N to milliseconds, while the
# uutils date shipped by Ubuntu 26.04 currently emits all nine nanosecond
# digits for %3N. Comparing epoch nanoseconds works with both implementations.
end_ns=$(( $(date +%s%N) + DUR_MS * 1000000 ))
overlap_observed=0
writers_started=0
writers_failed=0
while (( $(date +%s%N) < end_ns )) && kill -0 "$det" 2>/dev/null; do
    pids=()
    for ((i=0; i<WRITERS; i++)); do
        LD_PRELOAD="$WORK/mcj_delay.so" MCJ_TARGET="$TARGET" WORKER_IDX=$i SLEEP_MS=20 \
            "$RUN" "$APP" >/dev/null 2>&1 & pids+=($!)
        writers_started=$((writers_started + 1))
    done
    # Observe publication while writers are active: one slow writer must not hide a
    # faster writer's publication until after the detector's sampling window closes.
    while kill -0 "$det" 2>/dev/null; do
        writers_running=0
        for p in "${pids[@]}"; do
            if kill -0 "$p" 2>/dev/null; then writers_running=1; break; fi
        done
        current_state=$(stat -c '%i:%s:%y' "$PROFILE" 2>/dev/null || true)
        # Check the detector on both sides of stat so a late publication does not count.
        if [ -n "$current_state" ] && [ "$current_state" != "$SEED_STATE" ] && \
           kill -0 "$det" 2>/dev/null; then
            overlap_observed=1
        fi
        [ "$writers_running" -eq 1 ] || break
        sleep 0.01
    done
    # A crash can lose the shim's atexit report. Preserve an observed anomaly verdict,
    # but never accept clean when a writer failed or its report may be missing.
    for p in "${pids[@]}"; do
        if ! wait "$p" 2>/dev/null; then
            writers_failed=$((writers_failed + 1))
        fi
    done
done
# The detector exits 2 when it observes torn/incomplete (the control case): capture that
# code instead of letting 'set -e' abort on it.
rc=0; wait "$det" || rc=$?
cat "$WORK/det.out"
echo "writers: started=$writers_started, failed=$writers_failed"

# Shim proof: on an unpatched runtime the writers' final-path fopen/fwrite hooks must have
# fired; a fixed runtime writes only "*.tmp" paths and reports 0 hits (evaded by design).
# A clean verdict must have this proof: otherwise a final-path writer that happened not to
# be sampled could be misclassified as atomic.
shim_report_valid=0
shim_open_hits=""
shim_write_hits=""
if [ -s "$MCJ_DELAY_REPORT" ]; then
    if shim_counts=$(awk -v expected="$writers_started" '
        /^open=[0-9]+ write=[0-9]+$/ {
            split($1, open, "="); split($2, write, "=")
            opens += open[2]; writes += write[2]; records++
            next
        }
        { malformed = 1 }
        END {
            if (records == 0 || records != expected || malformed) exit 1
            printf "%.0f %.0f\n", opens, writes
        }
    ' "$MCJ_DELAY_REPORT"); then
        read -r shim_open_hits shim_write_hits <<<"$shim_counts"
        shim_report_valid=1
        echo "shim: final-path fopen hits=$shim_open_hits, delayed fwrites=$shim_write_hits (0 = the runtime never wrote the final path in place)"
    else
        echo "shim: invalid or incomplete reports (expected $writers_started) -- no clean verdict"
    fi
else
    echo "shim: no report (no writer reached the shim) -- no clean verdict"
fi

# The live phase must actually have republished the profile, whatever the runtime: a
# missing or unchanged file means no successful atomic publication was measured.
[ -f "$PROFILE" ] || { echo "ERROR: the profile disappeared during the live phase -- no verdict"; exit 1; }
if [ "$(stat -c '%i:%s:%y' "$PROFILE")" = "$SEED_STATE" ]; then
    echo "ERROR: the profile never changed during the live phase -- nothing was measured"
    exit 1
fi

case "$rc" in
    0)
        if [ "$writers_failed" -ne 0 ]; then
            echo "ERROR: $writers_failed writer(s) failed -- no clean verdict"
            exit 1
        fi
        if [ "$overlap_observed" -ne 1 ]; then
            echo "ERROR: no profile publication completed while the detector was running -- no verdict"
            exit 1
        fi
        if [ "$shim_report_valid" -ne 1 ]; then
            echo "ERROR: no valid shim report -- no clean verdict"
            exit 1
        fi
        if [ "$shim_open_hits" -ne 0 ] || [ "$shim_write_hits" -ne 0 ]; then
            echo "ERROR: shim observed final-path writes -- no clean verdict"
            exit 1
        fi
        echo "RESULT: ATOMIC -- reader never observed a non-atomic profile (fixed)."
        ;;
    2) echo "RESULT: NON-ATOMIC -- reader observed an incomplete/torn profile (bug present)." ;;
    3) echo "ERROR: detector never managed a single valid read -- no verdict." ;;
    *) echo "ERROR: detector failed (exit $rc) -- no verdict." ;;
esac
exit "$rc"
