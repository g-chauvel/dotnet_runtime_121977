# Reproduction of dotnet/runtime#121977

MulticoreJIT (ProfileOptimization) startup-profile cache corruption under concurrent writers.

## Root cause

The startup profile is written at a **fixed path shared by every process that uses the
same profile root** (for example pwsh's `~/.cache/powershell/StartupProfileData-NonInteractive`,
shared by every pwsh session under one `$HOME`). `MulticoreJitRecorder::WriteOutput`
writes that final file **in place**: `fopen("wb")` (truncate), then a sequence of
fragmented buffered writes, with **no inter-process lock**.

When several processes shut down at about the same time, their writes tear each other's
output. A process starting concurrently reads the half-written file; the player validates
only the **header**, so a torn body drives the JIT into unbounded recursion and the process
dies at startup with an uncatchable `Stack overflow.`/SIGABRT or a segfault, before
producing any output.

## Platform difference (important)

| | Linux | Windows |
|---|---|---|
| In-place write share mode | plain `fopen` → no sharing semantics | deny-share (`_wfopen_s`) |
| What a concurrent reader sees | **torn / incomplete profile** → JIT crash | **`ERROR_SHARING_VIOLATION`** (refused) |
| When the profile is written | shutdown only (timer is `#ifndef TARGET_UNIX`) | shutdown + delayed-write timer |

So the **corruption itself is a Unix manifestation**. On Windows the deny-share open
prevents torn reads, but turns every in-place write window into a sharing violation for
readers (and silently drops a second concurrent writer's update). The fix — write to a
private temp file, publish with an atomic rename / `MoveFileExW` — removes both: the final
path is never opened for write, so Linux readers never see a torn profile and Windows
readers are never refused.

This is why the two harnesses measure different things:
- **Linux** reproduces the actual defect (torn/incomplete reads) deterministically.
- **Windows** demonstrates the reader contention (sharing violations) and that the fix
  eliminates it. It does **not** reproduce a crash — Windows is immune to the torn read.

## The method (~40s per run)

Waiting for the downstream JIT crash is lossy and flaky (reporters see "1 to 300 tries").
Instead we measure the defect **at its source** — the fix's contract is *"a reader never
observes a non-atomic intermediate state"*:

- **`linux/mcj_delay.c`** — an `LD_PRELOAD` shim that widens the torn-write window: it
  `usleep`s after the truncating `fopen` and after each `fwrite` **of the final profile
  path only** (basename contains the target name and does **not** end in `.tmp`). It
  interposes the CRT **stdio** entry points (`fopen`/`fopen64`/`fwrite`), which is the
  layer the runtime actually writes through — glibc's stdio reaches its internal
  `open`/`write` via libc-internal aliases that bypass `LD_PRELOAD`, so hooking the raw
  syscall wrappers would silently never fire. The `fwrite` delays stretch the gaps
  between the stdio buffer's flushes to disk, where the torn states live. The in-place
  rewrite tears without the shim too (truncate + buffered ~4 KiB flushes of a tens-of-KB
  body); the shim just makes the windows wide enough to be sampled reliably.
- **`detector/Detector.cs`** — one C# reader loop, shared by both OSes, that opens the
  shared profile in a tight loop and counts `INCOMPLETE` / `TORN` (and, on Windows,
  `SHARING_VIOLATION`) observations. Exits `2` if it ever sees one, `0` if every read
  was complete and valid, `3` if it never got a single valid read (a harness error —
  "nothing happened" must not pass as "atomic").

A runtime that writes to a private `*.tmp` file and publishes via an **atomic rename**
never touches the final path mid-write, so it **evades the shim by construction** — and
the driver prints the proof: each writer reports its shim hit counts (`shim: final-path
fopen hits=N, delayed fwrites=M`), nonzero on an unpatched runtime, `0` on a fixed one,
while the detector verdict flips from `NON-ATOMIC` to `ATOMIC` on the same workload.

`Program.cs` reproduces what pwsh does: every process calls
`ProfileOptimization.StartProfile` on the same file. Two *identical* writers don't corrupt
(interleaving identical bytes yields a valid file), so workers deliberately write profiles
of **different sizes** (even = tiny, odd = large) to maximize the torn-merge window.

## Layout

```
app/      Program.cs, mcjrepro.csproj    the repro app (one StartProfile per process), portable
detector/ Detector.cs, detector.csproj   the reader-side detector, shared by both OSes
linux/    mcj_delay.c, run.sh            LD_PRELOAD shim (C) + driver
windows/  run.ps1                        driver
```

Both the app and the detector are portable C#; only the `LD_PRELOAD` shim (which must
interpose the CRT `fopen`/`fwrite` calls at the loader level) is native C, so `gcc` is
needed on Linux for that one file. Windows needs no native compiler — just a .NET SDK.

## What this measures (and what it does not)

The harness proves **writer-side atomicity**: with the fix, a reader can never observe a
truncated or torn profile *being produced*. Two deliberate limits:

- The detector validates the **header only — exactly like the runtime's player** (that
  blindness is part of the bug). It does not prove that a reader survives a profile with
  a valid header and a torn body, and it does not exercise the player's replay path.
- Each run tests **one runtime cohort**. A mixed fleet (one unpatched writer next to
  patched processes sharing the same profile root) still tears the shared file, and a
  patched reader will still replay it — writer atomicity protects a machine only once
  every writer on it is patched. That is the argument for servicing backports, not
  against the fix.

## Run — Linux

Prerequisites: `gcc`, and a .NET SDK (`dotnet` on `PATH`, or set `DOTNET_ROOT` to a
specific runtime layout such as a locally built coreclr).

```sh
cd linux
chmod +x run.sh

# Against a stock runtime -> reproduces the bug (exit 2):
DOTNET_ROOT=/path/to/stock-runtime ./run.sh

# Against a runtime built with the fix -> atomic (exit 0):
DOTNET_ROOT=/path/to/fixed-runtime ./run.sh
```

Expected — unpatched (12 s, 12 writers):
```
DETECTOR ... samples=2752648 OK=2600664 INCOMPLETE=151984 TORN=0 SHARING_VIOLATION=0 missing=0
shim: final-path fopen hits=12, delayed fwrites=44852 (0 = the runtime never wrote the final path in place)
RESULT: NON-ATOMIC -- reader observed an incomplete/torn profile (bug present).
```
Fixed:
```
DETECTOR ... samples=2223943 OK=2223943 INCOMPLETE=0 TORN=0 SHARING_VIOLATION=0 missing=0
shim: final-path fopen hits=0, delayed fwrites=0 (0 = the runtime never wrote the final path in place)
RESULT: ATOMIC -- reader never observed a non-atomic profile (fixed).
```
Any other exit code is a harness error (no profile seeded, detector never got a valid
read), never a verdict.

## Run — Windows

Prerequisites: a .NET SDK only (the detector is C#, no native compiler needed). PowerShell
5.1 or 7+.

```powershell
cd windows

# Against a stock runtime -> shows sharing violations (exit 2):
.\run.ps1

# Against a runtime built with the fix -> no contention (exit 0):
$env:DOTNET_ROOT = "C:\path\to\fixed-runtime"; .\run.ps1
```

Expected — unpatched: `SHARING_VIOLATION` > 0, `RESULT: CONTENTION`.
Fixed: `SHARING_VIOLATION=0 INCOMPLETE=0 TORN=0`, `RESULT: CLEAN`.

Tunables: `DUR_MS`/`WRITERS` (Linux env vars), `-DurationMs`/`-Writers` (Windows params).
The app targets `net11.0`; to test net10/net9 change `<TargetFramework>` in `app/mcjrepro.csproj`
(the host rolls forward via `DOTNET_ROLL_FORWARD=Major`).

## The actual startup crash (Linux, for the original symptom)

To get the crash from the issue rather than the atomicity measurement: run many of these
processes sharing one `$HOME` under a CPU-throttled cgroup (`--cpus=2` / `CPUQuota=200%`)
on an otherwise idle host. The brief CFS freeze widens the torn-write window enough that a
starting process replays a corrupt profile and dies with `Stack overflow.` (exit 134) or a
segfault (139). It is probabilistic — median a few minutes, heavy-tailed — which is exactly
the flaky-CI signature reporters describe.
