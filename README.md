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
output. A process starting concurrently reads the half-written file. The player validates
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
readers (and silently drops a second concurrent writer's update). The fix writes to a
private temp file and publishes it with `rename(2)` (atomic by POSIX contract) on Linux and
`MoveFileExW(MOVEFILE_REPLACE_EXISTING)` on Windows. That removes both: the final path is
never opened for write, so Linux readers never see a torn profile and Windows readers are
no longer refused by an in-place writer (a reader can still, rarely, be refused while a
rename replaces the file). The move is same-directory with no `MOVEFILE_COPY_ALLOWED`, so it
cannot silently degrade to copy+delete. The Windows benefit rests on the final path never
being write-opened, not on documented `MoveFileExW` atomicity.

Atomic publication alone does not repair a profile that is already torn: a process that
crashes while replaying it exits before it records a new one, so the file stays and every
start crashes. The fix therefore also bumps the profile format to version 103, whose header
carries a checksum of the records. The player rejects a version 102 profile (possibly torn
by an earlier runtime) and any profile whose records do not match the checksum, starts
without replaying it, and the recorder replaces it at exit.

This is why the two drivers measure different things:
- **Linux** reproduces the actual defect (torn/incomplete reads) reliably.
- **Windows** demonstrates the reader contention (sharing violations). It does **not**
  reproduce a crash: Windows is immune to the torn read.

On both OSes a run in which the detector misses every window exits `1`, never `0`.

## Reproduce it

To reproduce, you need a **.NET SDK that can target `net11.0`** (a .NET 11 preview SDK,
the app's target framework), with `dotnet` on `PATH`. On Linux you also need `gcc` (for
the single native shim file), glibc and GNU coreutils or uutils (Ubuntu, Debian, Fedora,
not Alpine/BusyBox). Windows needs no native compiler. Clone the repository and run the
driver for your OS.

**Linux**

```sh
cd linux
chmod +x run.sh
./run.sh
```
Expected: the bug reproduces (exit 2, the counts below come from one run and vary from run to run):
```
DETECTOR path=.../cache/StartupProfileData-Repro dur=15000ms samples=1382337 OK=152091 (version 102=152091, 103=0) INCOMPLETE=102555 TORN=1127691 SHARING_VIOLATION=0 MISSING=0 ACCESS_DENIED=0 IO_ERROR=0
writers: started=24, failed=0
shim: final-path fopen hits=24, delayed fwrites=49054 (0 = the runtime never wrote the final path in place)
shim: *.tmp opens=0, writers without one=24
profile inode: seeded=474390, final=474390 (unchanged = rewritten in place)
RESULT: NON-ATOMIC -- reader observed an incomplete/torn profile (bug present).
```

**Windows** (PowerShell 5.1 or 7+)

```powershell
cd windows
.\run.ps1
```
Expected: reader contention (exit 2, also in `$LASTEXITCODE` when run as `.\run.ps1`),
`SHARING_VIOLATION` > 0, `RESULT: CONTENTION`. Windows does not show torn reads (the
deny-share open refuses the concurrent reader instead), see "Platform difference" above.
On a fixed runtime a few `ACCESS_DENIED` can appear (a reader opening the file while a
rename replaces it). They are reported but do not fail the run.

Tunables: `DUR_MS`/`WRITERS` (Linux env vars), `-DurationMs`/`-Writers` (Windows params).
The app targets `net11.0`, the runtime whose profile write path is the CRT `fopen`/`fwrite`
the shim hooks. On an older SDK you can lower `<TargetFramework>` in `app/mcjrepro.csproj`
(net10/9/8): the in-place corruption still reproduces (INCOMPLETE/TORN from the natural
window), but the `shim:` hit counts stay 0, because pre-net11 runtimes write the profile
through a different path. Without the shim the window is narrow: a run that misses it exits
`1`, not `0`.

Any exit code other than `2` (bug) or `0` (clean) is a harness error, never a verdict: no
profile written, detector never got a valid read, no publication completed while the
detector ran, a process that did not exit, or observations that contradict each other. The
seed run prints the runtime that actually ran (`runtime: .NET ... from ...`): check it when
`DOTNET_ROOT` is set.

### Optional: compare against a fixed runtime

To see the same workload come back clean, point `DOTNET_ROOT` at any runtime *layout* (a
`dotnet` host plus `shared/Microsoft.NETCore.App/<version>/`), for example a locally built
coreclr assembled per
[using-your-build-with-installed-sdk.md](https://github.com/dotnet/runtime/blob/main/docs/workflow/testing/using-your-build-with-installed-sdk.md):

```sh
DOTNET_ROOT=/path/to/a-runtime ./run.sh                             # exit 0: 0 torn reads, 0 final-path shim hits, new inode
```
```powershell
$env:DOTNET_ROOT = "C:\path\to\a-runtime"; .\run.ps1                # exit 0: 0 sharing violations, new file identity
```

## How it works (~40s per run)

Waiting for the downstream JIT crash is lossy and flaky (reporters see "1 to 300 tries").
Instead we measure the defect **at its source**. The fix's contract is *"a reader never
observes a non-atomic intermediate state"*:

- **`linux/mcj_delay.c`**: an `LD_PRELOAD` shim that widens the torn-write window. It
  `usleep`s after the truncating `fopen` and after each `fwrite` **of the final profile
  path only** (basename contains the target name and does **not** end in `.tmp`). It
  interposes the CRT **stdio** entry points (`fopen`/`fopen64`/`fwrite`), which is the
  layer the runtime actually writes through: glibc's stdio reaches its internal
  `open`/`write` via libc-internal aliases that bypass `LD_PRELOAD`, so hooking the raw
  syscall wrappers would silently never fire. The `fwrite` delays stretch the gaps
  between the stdio buffer's flushes to disk, where the torn states live. The in-place
  rewrite tears without the shim too (truncate + buffered ~4 KiB flushes of a tens-of-KB
  body). The shim just makes the windows wide enough to be sampled reliably. It also
  counts, without delaying them, the write-mode opens of the target's `*.tmp` files.
- **`detector/Detector.cs`**: one C# reader loop, shared by both OSes, that opens the
  shared profile in a tight loop, reads it whole and validates the complete record stream
  (record types and sizes, module indexes, header counts, exact end of file, and for
  version 103 the checksum of the records, as the player does). It counts
  `INCOMPLETE` / `TORN` / `MISSING` (and, on Windows, `SHARING_VIOLATION` /
  `ACCESS_DENIED`) observations. `TORN` (a valid header over records that do not match it)
  is the state that crashes the player. `INCOMPLETE` (shorter than the header) is rejected
  by the player, but it still shows the in-place rewrite. `ACCESS_DENIED` is the
  rename's own transient on Windows and is only reported.
  Exits `2` if it ever sees one of the others, `0` if every read was complete and valid, `3` if it never
  got a single valid read, `1` on an unexpected I/O error (harness errors: "nothing
  happened" must not pass as "atomic"). The drivers start the writers only once the
  detector is ready.

A runtime that writes to a private `*.tmp` file and publishes it with a rename
never touches the final path mid-write, so it **evades the shim by construction**, and
the driver prints the proof: each writer reports its shim hit counts (`shim: final-path
fopen hits=N, delayed fwrites=M`), nonzero on an unpatched runtime, `0` on a fixed one,
while the detector verdict flips from `NON-ATOMIC` to `ATOMIC` on the same workload. The
Linux driver reports `ATOMIC` only if every writer exited successfully and left a
zero-hit report in which the shim saw its `*.tmp` open (`shim: *.tmp opens=N, writers
without one=0`): zero hits from a shim that sees nothing are not a proof. Both drivers also
compare the file at the end with the seeded one (its inode on Linux, its file index on
Windows): a rename installs a new file, an in-place write keeps the old one. The clean
verdict requires a new file and the bug verdict the seeded one. The Linux driver keeps the
seeded file open until the verdict, so that the file system cannot give its inode number to
a later file. On Windows, where no shim runs, the new file and every writer exiting `0` are
what separate a clean run from a run in which the detector happened to miss the writes.

`app/Program.cs` reproduces what pwsh does: every process calls
`ProfileOptimization.StartProfile` on the same file. Even *identical* writers expose an
incomplete profile (the in-place write truncates before it rewrites), and workers
deliberately write profiles of **different sizes** (even = tiny, odd = large) so that a
torn merge also leaves a mismatched record stream.

## Files

```
app/      Program.cs, mcjrepro.csproj    the repro app (one StartProfile per process), portable
detector/ Detector.cs, detector.csproj   the reader-side detector, shared by both OSes
linux/    mcj_delay.c, run.sh            LD_PRELOAD shim (C) + driver
windows/  run.ps1, process-cleanup.ps1   driver + cleanup of the driver's child processes
```

The app and the detector are portable C#. Only the `LD_PRELOAD` shim (which must interpose
the CRT `fopen`/`fwrite` calls at the loader level) is native C, so `gcc` is needed on
Linux for that one file. Windows needs no native compiler, just a .NET SDK.

## What this measures (and what it does not)

The harness demonstrates **writer-side atomicity**: with the fix, a reader can never observe a
truncated or torn profile *being produced*. Two deliberate limits:

- The detector validates the **record structure**, which is stricter than an unpatched
  player (it checks the header only, and that blindness is part of the bug). It does not
  check semantic validity (method tokens, signatures), and it does not exercise the
  player's replay path.
- Each run tests **one runtime cohort**. In a mixed fleet (an unpatched writer next to
  patched processes sharing the same profile root), the unpatched writer still tears the
  shared file in place. A patched reader rejects what it writes (version 102), and the
  checksum rejects the remaining case: a version 103 profile truncated and rewritten by the
  unpatched writer while a patched reader is reading it. The cost is that the two cohorts
  stop replaying each other's profile while they share the path.

## The actual startup crash (Linux, for the original symptom)

This is the heavy-tailed, non-deterministic path that the harness above deliberately replaces
with a fast atomicity measurement. It is shown only to connect the repro to the originally
reported symptom. To get the crash from the issue rather than the atomicity measurement: run many of these
processes sharing one `$HOME` under a CPU-throttled cgroup (`--cpus=2` / `CPUQuota=200%`)
on an otherwise idle host. The brief CFS freeze widens the torn-write window enough that a
starting process replays a corrupt profile and dies with `Stack overflow.` (exit 134) or a
segfault (139). It is probabilistic (median a few minutes, heavy-tailed), which is exactly
the flaky-CI signature reporters describe.
