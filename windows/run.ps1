# Windows reproduction driver for dotnet/runtime#121977.
#
# On Windows the torn-read corruption does NOT occur: the in-place write opens the final
# path deny-share, so a concurrent reader is refused with ERROR_SHARING_VIOLATION instead
# of reading torn bytes. This driver runs N concurrent writers against one shared profile
# while a reader (Detector.cs) samples it, and counts what the reader observes.
#
#   exit 2  -> reader saw SHARING_VIOLATION (or torn/incomplete) and the profile is still the
#              seeded file = contention present (UNPATCHED)
#   exit 0  -> reader was never blocked by an in-place writer and always read a complete
#              profile, every writer succeeded, and the profile at the end is a different
#              file than the seeded one (published by rename, not rewritten in place)
#              = FIXED (a rare ACCESS_DENIED while a rename replaces the file is reported,
#              not counted: it is the fix's own transient)
#   other   -> harness error (no profile seeded, no valid observation, no publication
#              while the detector ran, detector died, a process did not exit):
#              NOT a pass; "nothing happened" must never report as "fixed".
#
# Once its parameters are bound, the driver sets the exit code the same way whether it runs
# as `pwsh -File run.ps1` or in the current session as `.\run.ps1` (then read $LASTEXITCODE).
# The environment variables the driver sets are restored on exit.
#
# The app + detector are BUILT with a full SDK and the app is RUN on the runtime under test:
#   $env:DOTNET_SDK    full SDK used to build      (default: `dotnet` from PATH)
#   $env:DOTNET_ROOT   runtime layout to test      (default: the SDK's own runtime)
#
# Usage:
#   .\run.ps1                                   # build+run with `dotnet` on PATH
#                                               # (a stock SDK -> shows sharing violations)
#   $env:DOTNET_ROOT="C:\path\to\runtime"; .\run.ps1   # run on your locally built runtime
#   .\run.ps1 -DurationMs 15000 -Writers 12
param([int]$DurationMs = 15000, [int]$Writers = 12)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

# $ErrorActionPreference does not apply to native executables (dotnet, ...): a non-zero
# exit is not a PowerShell error. Check $LASTEXITCODE explicitly after each external command
# whose success is required. (The writers' exit codes are checked only for the clean
# verdict -- a writer may fail on an unpatched runtime, which is an expected outcome.)
function Assert-ExitOk([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

# Build output goes to a log, shown only when the build fails.
function Invoke-Build([string]$What, [string]$Project, [string]$Out, [string]$Log) {
    # No MSBuild node or compiler server left running after the harness.
    & $sdk build -c Release --disable-build-servers $Project -o $Out *> $Log
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $Log -Tail 30 | Write-Host
        throw "$What failed (exit $LASTEXITCODE), full log: $Log"
    }
}

$here = $PSScriptRoot
$ownedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$appProj = Join-Path $here "..\app\mcjrepro.csproj"
$detProj = Join-Path $here "..\detector\detector.csproj"
$target = "StartupProfileData-Repro"

$savedEnv = @{}
foreach ($name in 'MCJ_PROFILE_ROOT', 'MCJ_PRINT_RUNTIME', 'SLEEP_MS', 'DOTNET_ROOT', 'DOTNET_MULTILEVEL_LOOKUP',
                  'DOTNET_NOLOGO', 'DOTNET_CLI_TELEMETRY_OPTOUT', 'DOTNET_ROLL_FORWARD') {
    $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
}

$rc = 1
$work = $null
try {
    . (Join-Path $here 'process-cleanup.ps1')

    # The identity of the file behind a path (volume serial + file index): an in-place write
    # keeps it, a rename installs the identity of the renamed file.
    if (-not ('McjFileIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class McjFileIdentity
{
    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow, CreationTimeHigh;
        public uint LastAccessTimeLow, LastAccessTimeHigh;
        public uint LastWriteTimeLow, LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh, FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandleFileInformation information);

    public static string Get(string path)
    {
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out information))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return string.Format("{0:x8}:{1:x8}{2:x8}", information.VolumeSerialNumber, information.FileIndexHigh, information.FileIndexLow);
        }
    }
}
'@
    }

    $dotnetOnPath = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $sdk = if ($env:DOTNET_SDK) { $env:DOTNET_SDK } elseif ($dotnetOnPath) { $dotnetOnPath.Source } else { $null }
    if (-not $sdk -or -not (Test-Path -LiteralPath $sdk)) { throw "no SDK (set DOTNET_SDK or put dotnet on PATH)" }
    $run = if ($env:DOTNET_ROOT) { Join-Path $env:DOTNET_ROOT "dotnet.exe" } else { $sdk }
    if (-not (Test-Path -LiteralPath $run)) { throw "runtime host not found: $run" }
    # Preserve paths relative to the caller before the build changes directory for global.json.
    $sdk = (Resolve-Path -LiteralPath $sdk).ProviderPath
    $run = (Resolve-Path -LiteralPath $run).ProviderPath

    $work = Join-Path $env:TEMP ("mcjrepro_" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $env:MCJ_PROFILE_ROOT = Join-Path $work "cache"
    $profilePath = Join-Path $env:MCJ_PROFILE_ROOT $target
    $env:DOTNET_MULTILEVEL_LOOKUP = "0"; $env:DOTNET_NOLOGO = "1"; $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
    if (-not $env:DOTNET_ROLL_FORWARD) { $env:DOTNET_ROLL_FORWARD = "Major" }

    Write-Host "== building repro app + detector (SDK: $sdk) =="
    $runtimeRoot = $env:DOTNET_ROOT
    Push-Location -LiteralPath (Join-Path $here '..')
    try {
        # SDK selection searches from cwd, not from the absolute project path.
        $env:DOTNET_ROOT = $null
        & $sdk --version
        Assert-ExitOk "SDK selection (global.json)"
        Invoke-Build "app build" $appProj (Join-Path $work "app") (Join-Path $work "build-app.log")
        Invoke-Build "detector build" $detProj (Join-Path $work "det") (Join-Path $work "build-det.log")
    }
    finally {
        $env:DOTNET_ROOT = $runtimeRoot
        Pop-Location
    }
    $app = Join-Path $work "app\mcjrepro.dll"
    $det = Join-Path $work "det\detector.dll"

    Write-Host "== runtime under test: $run =="
    Write-Host "== seeding a valid profile =="
    $env:SLEEP_MS = "5"
    $env:MCJ_PRINT_RUNTIME = "1"
    $seedOutput = & $run $app "1"
    Assert-ExitOk "seed run"
    $env:MCJ_PRINT_RUNTIME = $null
    $seedOutput | Write-Host
    $seeded = if (Test-Path -LiteralPath $profilePath) { (Get-Item -LiteralPath $profilePath).Length } else { 0 }
    Write-Host ("seeded: {0} bytes" -f $seeded)
    # A profile smaller than its 64-byte header means MulticoreJIT never wrote one (e.g. it
    # silently disables itself below 2 CPUs); the live phase would then measure nothing and
    # "CLEAN" would be vacuous.
    if ($seeded -lt 64) { throw "no profile was seeded -- nothing to measure" }
    $seedStamp = (Get-Item -LiteralPath $profilePath).LastWriteTimeUtc
    $seedIdentity = [McjFileIdentity]::Get($profilePath)

    Write-Host "== sanity: detector on the static (no-writer) profile, must report 0 =="
    & $run $det $profilePath 800
    Assert-ExitOk "sanity detector (static profile must read clean)"

    Write-Host "== live: detector + $Writers concurrent writers for ${DurationMs}ms =="
    # A process still running this long after the sampling window is stuck: no verdict.
    $deadlineMs = $DurationMs + 60000
    $env:SLEEP_MS = "20"
    $detOut = Join-Path $work "det.out"
    $detReady = Join-Path $work "det.ready"
    $detArgs = '"{0}" "{1}" {2} "{3}"' -f $det, $profilePath, $DurationMs, $detReady
    $detProc = Start-Process -FilePath $run -ArgumentList $detArgs -PassThru -NoNewWindow -RedirectStandardOutput $detOut
    $ownedProcesses.Add($detProc)
    # Windows PowerShell 5.1 must retain the handle before HasExited closes it;
    # otherwise ExitCode can remain null even after WaitForExit.
    $null = $detProc.Handle
    $readyWait = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $detReady) -and -not $detProc.HasExited -and $readyWait.ElapsedMilliseconds -lt 10000) {
        Start-Sleep -Milliseconds 10
    }
    if (-not (Test-Path -LiteralPath $detReady)) {
        if ($detProc.HasExited) { Get-Content -LiteralPath $detOut }
        throw "detector did not become ready -- no verdict"
    }

    # Stopwatch rather than [Environment]::TickCount64, which Windows PowerShell 5.1
    # (.NET Framework) does not have.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $overlapObserved = $false
    $writersStarted = 0
    $writersFailed = 0
    $changesObserved = 0
    $lastState = "{0}:{1}" -f $seedStamp.Ticks, $seeded
    while ($sw.ElapsedMilliseconds -lt $DurationMs -and -not $detProc.HasExited) {
        $procs = @()
        for ($i = 0; $i -lt $Writers; $i++) {
            $wArgs = '"{0}" {1}' -f $app, $i
            $writer = Start-Process -FilePath $run -ArgumentList $wArgs -PassThru -NoNewWindow
            $ownedProcesses.Add($writer)
            $null = $writer.Handle
            $procs += $writer
            $writersStarted++
        }
        foreach ($writer in $procs) {
            $remainingMs = [int][Math]::Max(0, $deadlineMs - $sw.ElapsedMilliseconds)
            if (-not $writer.WaitForExit($remainingMs)) { throw "writer $($writer.Id) did not exit -- no verdict" }
            if ($writer.ExitCode -ne 0) { $writersFailed++ }
            $null = $ownedProcesses.Remove($writer)
            $writer.Dispose()
        }
        if (-not $detProc.HasExited) {
            $during = Get-Item -LiteralPath $profilePath -ErrorAction SilentlyContinue
            if ($null -ne $during) {
                $state = "{0}:{1}" -f $during.LastWriteTimeUtc.Ticks, $during.Length
                if ($state -ne $lastState) { $changesObserved++; $lastState = $state }
                if ($during.LastWriteTimeUtc -ne $seedStamp -or $during.Length -ne $seeded) {
                    $overlapObserved = $true
                }
            }
        }
    }
    $remainingMs = [int][Math]::Max(0, $deadlineMs - $sw.ElapsedMilliseconds)
    if (-not $detProc.WaitForExit($remainingMs)) { throw "detector did not exit -- no verdict" }
    Get-Content -LiteralPath $detOut
    Write-Host "writers: started=$writersStarted, failed=$writersFailed"
    # Each change counts once per batch: a margin of a few changes means the detector left
    # little room for publications.
    Write-Host "profile changes seen between writer batches while the detector ran: $changesObserved"

    # The live phase must actually have republished the profile, whatever the runtime: a
    # missing or unchanged file means no successful atomic publication was measured.
    $after = Get-Item -LiteralPath $profilePath -ErrorAction SilentlyContinue
    if ($null -eq $after) {
        throw "the profile disappeared during the live phase -- no verdict"
    }
    if ($after.LastWriteTimeUtc -eq $seedStamp -and $after.Length -eq $seeded) {
        throw "the profile never changed during the live phase -- nothing was measured"
    }
    $finalIdentity = [McjFileIdentity]::Get($profilePath)
    Write-Host "profile file identity: seeded=$seedIdentity, final=$finalIdentity (unchanged = rewritten in place)"

    $rc = $detProc.ExitCode
    if ($null -eq $rc) { throw "detector exit code unavailable -- no verdict" }
    if ($rc -eq 0) {
        # A clean detector only means no sample hit a write: the clean verdict also needs
        # independent proof that the profile was published by rename while it ran.
        if ($writersFailed -ne 0) { throw "$writersFailed writer(s) failed -- no clean verdict" }
        if (-not $overlapObserved) { throw "no profile publication completed while the detector was running -- no verdict" }
        if ($finalIdentity -eq $seedIdentity) { throw "the profile is still the seeded file, rewritten in place -- no clean verdict" }
    }
    # An unpatched runtime rewrites the seeded file: a new file contradicts the observation,
    # for example a sharing violation caused by another process holding the profile.
    if ($rc -eq 2 -and $finalIdentity -ne $seedIdentity) {
        throw "contention observed, but the profile was published by rename -- no verdict"
    }
    switch ($rc) {
        0       { Write-Host "RESULT: CLEAN -- reader never blocked by an in-place writer, always read a complete profile (fixed)." }
        2       { Write-Host "RESULT: CONTENTION -- reader observed sharing violations / torn profile (unpatched)." }
        3       { Write-Host "ERROR: detector never managed a single valid read -- no verdict." }
        default { Write-Host "ERROR: detector failed (exit $rc) -- no verdict." }
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    $rc = 1
}
finally {
    # Absent only when process-cleanup.ps1 failed to load, before any process was started.
    try { if (Get-Command Stop-HarnessProcesses -ErrorAction SilentlyContinue) { Stop-HarnessProcesses $ownedProcesses } }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        $rc = 1
    }
    foreach ($name in $savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnv[$name])
    }
    # Left in place on purpose (a throwaway dir under %TEMP%); delete it yourself when done.
    if ($work) { Write-Host "work dir left at: $work" }
}
exit $rc
