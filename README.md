# Startup-profile cache corruption (dotnet/runtime#121977)

MulticoreJIT (ProfileOptimization) startup-profile cache corruption under concurrent writers.

This reproduction and its analysis were prepared with AI assistance.

## Root cause

The startup profile is written at a **fixed path shared by every process that uses the
same profile root** (for example pwsh's `~/.cache/powershell/StartupProfileData-NonInteractive`,
shared by every pwsh session under one `$HOME`). `MulticoreJitRecorder::WriteOutput`
writes that final file **in place**: `fopen("wb")` (truncate), then a sequence of
fragmented buffered writes, with **no inter-process lock**.

On Linux, overlapping writes can tear each other's output, and a process starting
concurrently can read an incomplete or mixed profile. The player's header validation
does not establish the validity of the complete body. Corrupt replay data can contribute
to the reported startup `Stack overflow.`/SIGABRT or segfault failures. This harness
measures the file-publication defect; its detector does not demonstrate a downstream JIT
crash or prove that every structurally invalid sample would cause one.

## Platform difference (important)

| | Linux | Windows |
|---|---|---|
| In-place write share mode | plain `fopen` → no sharing semantics | deny-share (`_wfopen_s`) |
| What a concurrent reader sees | **torn / incomplete profile** (replay can crash) | **`ERROR_SHARING_VIOLATION`** (refused) |
| When the profile is written | shutdown only (timer is `#ifndef TARGET_UNIX`) | shutdown + delayed-write timer |

On Windows, deny-share opens prevent the original overlapping in-place read/write case,
but can refuse readers and silently drop a competing writer's update. A complete
publication fix writes a private temporary file in the same directory and replaces the
final path after completing the file. Linux uses `rename(2)` for atomic namespace
replacement; this is a visibility guarantee, not a crash-durability guarantee.

The revised Windows implementation uses
`SetFileInformationByHandle(FileRenameInfoEx)` with
`FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS`.
The [Windows FILE_RENAME_INFO documentation](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info)
describes the flags layout used with `FileRenameInfoEx`.
It must support publication while runtime readers retain handles opened with read and
delete sharing, but without write sharing. `MoveFileExW(MOVEFILE_REPLACE_EXISTING)`
alone is insufficient: replacement can fail under such a reader even though it permits
deletion. Avoiding a write-open of the final path does not prove that publication will
succeed. The Windows driver tests actual replacement and the retained reader's snapshot;
it makes no general claim about `MoveFileExW` atomicity. Filesystem/API support and
readers that deny delete sharing remain relevant constraints.

The format changes from version 102 to 103. Version checks reject an intact profile from
the other format, including old version-102 caches, but do not isolate writers: both
versions still use the same final filename. An unpatched writer can overwrite or truncate
a version-103 file. A mixed cohort therefore has no general safe-publication guarantee;
upgrade every writer sharing the root, or use separate profile roots.

The drivers exercise these contracts:

- **Linux** samples incomplete/torn reads while a shim widens the original write windows.
- **Windows** samples reader contention and snapshot integrity, then requires successful
  publication while a runtime-style reader keeps its old profile handle open.

Neither driver establishes the absence of all startup crashes on either platform.

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
Expected on a stock runtime — exit 2, `RESULT: CONTENTION`: live sampling may observe
`SHARING_VIOLATION`, and the held-reader phase reports no replacement. A clean run must
also print `HELD_READER: publication observed; old handle unchanged`; zero sharing
violations alone are insufficient.

For targeted checks of the held-reader detector and Windows APIs, run
`.\test-held-reader.ps1` from this directory. It requires rejection of no publication and
legacy `MoveFileExW` replacement under an open reader, then success with `FileRenameInfoEx`
POSIX replacement. These controlled publisher checks validate the detector; they do not
substitute for running the driver against a patched runtime.

Both Windows drivers register each child as soon as it starts. On normal completion or
an exception, they stop remaining children, wait for exit and dispose their process
handles. Completed writer batches are disposed immediately, keeping process tracking
bounded. Cleanup operates only on children registered by that invocation; logs and
profiles remain in the printed work directory.

Run `.\test-process-cleanup.ps1` to inject failures at live-detector readiness, midway
through writer startup, at held-reader readiness, and in the controlled publisher test.
It invokes the real drivers and requires independently retained process handles to be
exited before the failed driver returns. It runs on PowerShell 5.1 and 7+ and uses the
pinned SDK; it does not build CoreCLR or validate a runtime publication fix.

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
$env:DOTNET_ROOT = "C:\path\to\a-runtime"; .\run.ps1                # exit 0: valid snapshots and successful held-reader publication
```

### Reproducible Windows ARM64 build record

`windows/build-runtime-arm64.ps1` is for the dedicated Windows ARM64 build host,
not a desktop witness machine. It builds only `clr.runtime+clr.jit+clr.corelib` and
records the selected SDK, source SHA, complete build output, and the native exit code.
It rejects a repository-local `.dotnet` bootstrap because `global.json` would select it
ahead of the explicitly supplied SDK:

```powershell
.\build-runtime-arm64.ps1 -RuntimeRepo C:\src\runtime `
  -DotnetSdk C:\Tools\dotnet-sdk-11.0.100-rc.1.26420.103\dotnet.exe `
  -Artifacts C:\temp\mcj-arm64-build `
  -ExpectedCommit <runtime-commit>
```

The resulting runtime still needs to be assembled into an isolated `DOTNET_ROOT` layout
before `run.ps1` tests it; the script never overwrites an installed SDK.

## How it works

Each live sampling window defaults to 15 seconds. Total elapsed time also includes builds,
seeding, sanity checks, waiting for writers to shut down, and up to 5 seconds for the
Windows held-reader phase. Writer delays can make a run substantially longer.

Waiting for the downstream JIT crash is probabilistic.
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
  shared profile in a tight loop and validates the complete record stream: record types,
  sizes, alignment, module indexes, header counts, and exact end of file. It accepts
  version 102 from the stock runtime and version 103 from the atomic-publication fix.
  It counts `INCOMPLETE` / `TORN` / `MISSING` (and, on Windows, `SHARING_VIOLATION`)
  observations. Unexpected I/O errors return `1`; otherwise any observed anomaly returns
  `2`. With no anomalies it returns `0` only after a valid read, or `3` when no valid read
  occurred. An anomaly takes precedence over the no-valid-read check. The drivers wait
  for an explicit detector-ready signal before starting writers and accept a clean
  verdict only when a publication completed while the detector was alive.
- **Windows held-reader phase** — keeps a valid profile open with
  `FileShare.Read | FileShare.Delete`, records its file identity and complete bytes, and
  starts another writer workload. Success requires a different file identity at the
  final path, a structurally valid replacement, and identical bytes through the original
  still-open handle. This detects publication failures that rapid read/write/delete
  sampling could miss. It excludes `FileShare.Write`, matching the runtime reader
  contract. No replacement or a changed/invalid snapshot returns `2`; setup/I/O failures
  are harness errors.

A runtime that writes to a private `*.tmp` file and publishes it with a rename
never touches the final path mid-write, so it **evades the shim by construction**. Each
writer reports its shim hit counts (`shim: final-path fopen hits=N, delayed fwrites=M`):
they are nonzero on an unpatched runtime and `0` on a fixed one. The Linux driver accepts
`RESULT: ATOMIC` only if it receives a valid report and both aggregate counters are zero,
in addition to the detector and publication-overlap checks; a missing, malformed, or
nonzero report is a harness error rather than a clean verdict. A clean Linux verdict
also requires every writer to exit successfully and exactly one report per launched
writer. A crash can bypass the shim's `atexit` handler, so a partial collection of zero
reports cannot establish that all writers avoided the final path. An observed detector
anomaly still returns `2`, even when a writer failed or reports are incomplete.

Run `bash linux/test-writer-reports.sh` for synthetic driver-guard checks using a fake
SDK/detector/writer host and the real shim. These check rejection of lost/extra/malformed
reports and failed writers, and preservation of anomaly exit `2`; they do not build or
test a .NET runtime.

`app/Program.cs` reproduces what pwsh does: every process calls
`ProfileOptimization.StartProfile` on the same file. Even writers producing identical bytes
can expose incomplete profiles on Linux: an in-place writer truncates the file before
repopulating it, and readers can observe that intermediate state. Workers deliberately
write profiles of **different sizes** (even = tiny, odd = large) to amplify mismatched
record streams; workload diversity is not a prerequisite for the publication defect.

## Files

```
app/      Program.cs, mcjrepro.csproj    the repro app (one StartProfile per process), portable
detector/ Detector.cs, detector.csproj   the reader-side detector, shared by both OSes
linux/    mcj_delay.c, run.sh            LD_PRELOAD shim (C) + driver
windows/  run.ps1, test-held-reader.ps1, build-runtime-arm64.ps1
          driver, controlled publication checks, and reproducible ARM64 build record
```

The app and the default detector sampling mode are portable C#. The held-reader mode
and its controlled publication checks are Windows-only. The `LD_PRELOAD` shim (which must interpose
the CRT `fopen`/`fwrite` calls at the loader level) is native C, so `gcc` is needed on
Linux for that one file. Windows needs no native compiler — just a .NET SDK.

## What this measures (and what it does not)

The harness measures publication under the tested workload and filesystem. A clean run
means the sampled profiles were structurally valid, a publication completed during
sampling, and on Windows replacement also succeeded with an old reader held open.
It is evidence for these contracts in that run, not proof that every concurrency schedule
is safe or that all startup crashes are fixed.

- The detector validates record grammar, lengths, indexes and counts, but not semantic
  signature/metadata validity. A structurally valid corruption can escape it.
- The drivers suppress writer output and do not classify player crashes. Windows ignores
  writer exit codes; Linux rejects failed writers when the detector would otherwise report
  clean, while preserving an observed anomaly verdict. Even though writers can replay a
  shared profile, that replay is not independently checked by the harness.
- Each run uses **one runtime cohort**. The format bump rejects incompatible complete
  profiles but leaves the filename shared. Mixed patched/unpatched writers can still
  overwrite one another; this harness does not verify mixed-cohort safety.
- The Linux shim deliberately amplifies final-path in-place writes and excludes `*.tmp`
  paths. A clean Linux result requires its valid zero-hit report, but that report alone
  does not establish publication success. The independent detector/publication checks
  are also required.
- Windows replacement is tested with delete-sharing readers on the local test filesystem.
  Readers denying deletion, unsupported filesystems/APIs, and machine-crash durability
  are outside this test.

## The actual startup crash (Linux, for the original symptom)

The original symptom is a probabilistic startup failure when processes share a profile
root. A separate crash experiment must preserve writer/player output and exit statuses
and identify the runtime and resource limits used. `Stack overflow.`/SIGABRT or a segfault
must be observed directly before reporting that the startup crash was reproduced.

CPU-throttled workloads can widen scheduling windows, but this harness does not establish
a reliable time-to-crash distribution or guarantee that a particular cgroup limit will
reproduce the failure. Its `INCOMPLETE`/`TORN` counts demonstrate invalid published bytes;
they are not themselves a JIT-crash measurement.
