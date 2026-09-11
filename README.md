# Startup-profile cache corruption (dotnet/runtime#121977)

MulticoreJIT (ProfileOptimization) startup-profile cache corruption under concurrent writers.

This reproduction and its analysis were prepared with AI assistance.

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
private temp file, publish it with `rename(2)` (atomic by POSIX contract) on Linux and
`MoveFileExW(MOVEFILE_REPLACE_EXISTING)` on Windows — removes both: the final path is
never opened for write, so Linux readers never see a torn profile and Windows readers are
never refused. (The move is same-directory with no `MOVEFILE_COPY_ALLOWED`, so it cannot
silently degrade to copy+delete; the Windows benefit rests on the final path never being
write-opened, not on documented `MoveFileExW` atomicity.)

This is why the two drivers measure different things:
- **Linux** reproduces the actual defect (torn/incomplete reads) deterministically.
- **Windows** demonstrates the reader contention (sharing violations). It does **not**
  reproduce a crash — Windows is immune to the torn read.

## Reproduce it

The repository's `global.json` pins **.NET SDK 11.0.100-rc.1.26420.103**, which can
target the app's `net11.0` framework. Make that SDK available to the `dotnet` muxer on
`PATH`, or set `DOTNET_SDK` to the exact `dotnet` executable when SDKs are installed
side by side in separate roots. On Linux you also need `gcc` for the single native shim
file; Windows needs no native compiler. Clone the repository and run the driver for your OS.

**Linux**

```sh
cd linux
chmod +x run.sh
./run.sh
```
Expected — the bug reproduces (exit 2; counts below are illustrative, they vary run to run):
```
DETECTOR ... samples=2752648 OK=2600664 INCOMPLETE=151984 TORN=0 SHARING_VIOLATION=0 missing=0
shim: final-path fopen hits=12, delayed fwrites=44852 (0 = the runtime never wrote the final path in place)
RESULT: NON-ATOMIC -- reader observed an incomplete/torn profile (bug present).
```

**Windows** (PowerShell 5.1 or 7+)

```powershell
cd windows
.\run.ps1
```
Expected — reader contention (exit 2): `SHARING_VIOLATION` > 0, `RESULT: CONTENTION`. Windows
does not show torn reads (deny-share open refuses the concurrent reader instead) — see
"Platform difference" above.

Tunables: `DUR_MS`/`WRITERS` (Linux env vars), `-DurationMs`/`-Writers` (Windows params).
The app targets `net11.0` — the runtime whose profile write path is the CRT `fopen`/`fwrite`
the shim hooks. On an older SDK you can lower `<TargetFramework>` in `app/mcjrepro.csproj`
(net10/9/8): the in-place corruption still reproduces (INCOMPLETE/TORN from the natural
window), but the `shim:` hit counts stay 0, because pre-net11 runtimes write the profile
through a different path.

Any exit code other than `2` (bug) or `0` (clean) is a harness error — no profile written,
detector never got a valid read — never a verdict.

### Optional: compare against a fixed runtime

To see the same workload come back clean, point `DOTNET_ROOT` at any runtime *layout* (a
`dotnet` host plus `shared/Microsoft.NETCore.App/<version>/`) — e.g. a locally built coreclr
assembled per
[using-your-build-with-installed-sdk.md](https://github.com/dotnet/runtime/blob/main/docs/workflow/testing/using-your-build-with-installed-sdk.md):

```sh
DOTNET_ROOT=/path/to/a-runtime ./run.sh                             # exit 0: 0 torn reads, 0 shim hits
```
```powershell
$env:DOTNET_ROOT = "C:\path\to\a-runtime"; .\run.ps1                # exit 0: 0 sharing violations
```

## How it works (~40s per run)

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
  shared profile in a tight loop and counts `INCOMPLETE` / `TORN` / `MISSING` (and, on
  Windows, `SHARING_VIOLATION`) observations. Exits `2` if it ever sees one, `0` if every
  read was complete and valid, `1` for an unexpected I/O error, and `3` if it never got
  a single valid read (a harness error — "nothing happened" must not pass as "atomic").
  The drivers wait for an explicit detector-ready signal before starting writers and
  accept a clean verdict only when a publication completed while the detector was alive.

A runtime that writes to a private `*.tmp` file and publishes it with a rename
never touches the final path mid-write, so it **evades the shim by construction** — and
the driver prints the proof: each writer reports its shim hit counts (`shim: final-path
fopen hits=N, delayed fwrites=M`), nonzero on an unpatched runtime, `0` on a fixed one,
while the detector verdict flips from `NON-ATOMIC` to `ATOMIC` on the same workload.

`app/Program.cs` reproduces what pwsh does: every process calls
`ProfileOptimization.StartProfile` on the same file. Two *identical* writers don't corrupt
(interleaving identical bytes yields a valid file), so workers deliberately write profiles
of **different sizes** (even = tiny, odd = large) to maximize the torn-merge window.

## Files

```
app/      Program.cs, mcjrepro.csproj    the repro app (one StartProfile per process), portable
detector/ Detector.cs, detector.csproj   the reader-side detector, shared by both OSes
linux/    mcj_delay.c, run.sh            LD_PRELOAD shim (C) + driver
windows/  run.ps1                        driver
```

The app and the detector are portable C#; only the `LD_PRELOAD` shim (which must interpose
the CRT `fopen`/`fwrite` calls at the loader level) is native C, so `gcc` is needed on
Linux for that one file. Windows needs no native compiler — just a .NET SDK.

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

## The actual startup crash (Linux, for the original symptom)

This is the heavy-tailed, non-deterministic path that the harness above deliberately replaces
with a fast atomicity measurement; it is shown only to connect the repro to the originally
reported symptom. To get the crash from the issue rather than the atomicity measurement: run many of these
processes sharing one `$HOME` under a CPU-throttled cgroup (`--cpus=2` / `CPUQuota=200%`)
on an otherwise idle host. The brief CFS freeze widens the torn-write window enough that a
starting process replays a corrupt profile and dies with `Stack overflow.` (exit 134) or a
segfault (139). It is probabilistic — median a few minutes, heavy-tailed — which is exactly
the flaky-CI signature reporters describe.
