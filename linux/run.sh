#!/usr/bin/env bash
# Deterministic reproduction of dotnet/runtime#121977 against ONE runtime (Linux).
#
# Builds the repro app + an LD_PRELOAD write-delay shim + a torn-read detector, then
# runs N concurrent writers (under the shim) against ONE shared profile while the
# detector samples it.
#
#   exit 2  -> INCOMPLETE/TORN observed = bug present (an UNPATCHED runtime)
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
command -v gcc >/dev/null || { echo "gcc required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export MCJ_PROFILE_ROOT="$WORK/cache"
PROFILE="$MCJ_PROFILE_ROOT/$TARGET"
export DOTNET_MULTILEVEL_LOOKUP=0 DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-Major}"

echo "== building repro app + detector (SDK: $SDK) =="
( unset DOTNET_ROOT
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
SEED_MTIME=$(stat -c%Y "$PROFILE")

echo "== sanity: detector on the static (no-writer) profile, must report 0 =="
"$RUN" "$DET" "$PROFILE" 800

echo "== live: detector + $WRITERS concurrent delayed writers for ${DUR_MS}ms =="
export MCJ_DELAY_REPORT="$WORK/shim_report"
"$RUN" "$DET" "$PROFILE" "$DUR_MS" > "$WORK/det.out" 2>&1 &
det=$!
end=$(( $(date +%s%3N) + DUR_MS ))
while (( $(date +%s%3N) < end )); do
    pids=()
    for ((i=0; i<WRITERS; i++)); do
        LD_PRELOAD="$WORK/mcj_delay.so" MCJ_TARGET="$TARGET" WORKER_IDX=$i SLEEP_MS=20 \
            "$RUN" "$APP" >/dev/null 2>&1 & pids+=($!)
    done
    # A writer may crash on the unpatched runtime (it replays a torn profile); that is
    # an expected outcome here, not a script error, so do not let it trip 'set -e'.
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
done
# The detector exits 2 when it observes torn/incomplete (the control case): capture that
# code instead of letting 'set -e' abort on it.
rc=0; wait "$det" || rc=$?
cat "$WORK/det.out"

# Shim proof: on an unpatched runtime the writers' final-path fopen/fwrite hooks must have
# fired; a fixed runtime writes only "*.tmp" paths and reports 0 hits (evaded by design).
if [ -s "$MCJ_DELAY_REPORT" ]; then
    awk -F'[= ]' '{o+=$2; w+=$4} END{printf "shim: final-path fopen hits=%d, delayed fwrites=%d (0 = the runtime never wrote the final path in place)\n", o, w}' "$MCJ_DELAY_REPORT"
else
    echo "shim: no report (no writer reached the shim)"
fi

# The live phase must actually have republished the profile, whatever the runtime: an
# unchanged file means no writes were measured and the verdict would be vacuous.
if [ "$(stat -c%Y "$PROFILE" 2>/dev/null || echo 0)" -eq "$SEED_MTIME" ] && \
   [ "$(stat -c%s "$PROFILE" 2>/dev/null || echo 0)" -eq "$SEED_SIZE" ]; then
    echo "ERROR: the profile never changed during the live phase -- nothing was measured"
    exit 1
fi

case "$rc" in
    0) echo "RESULT: ATOMIC -- reader never observed a non-atomic profile (fixed)." ;;
    2) echo "RESULT: NON-ATOMIC -- reader observed an incomplete/torn profile (bug present)." ;;
    3) echo "ERROR: detector never managed a single valid read -- no verdict." ;;
    *) echo "ERROR: detector failed (exit $rc) -- no verdict." ;;
esac
exit "$rc"
