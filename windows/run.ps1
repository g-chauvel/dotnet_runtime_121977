# Windows reproduction driver for dotnet/runtime#121977.
#
# On Windows the torn-read corruption does NOT occur: the in-place write opens the final
# path deny-share, so a concurrent reader is refused with ERROR_SHARING_VIOLATION instead
# of reading torn bytes. This driver runs N concurrent writers against one shared profile
# while a reader (Detector.cs) samples it, and counts what the reader observes.
#
#   exit 2  -> invalid/blocked read, or publication failed with a reader open
#   exit 0  -> valid snapshots and replacement succeeded while an old reader stayed open
#   other   -> harness error (no profile seeded, no valid observation, detector died):
#              NOT a pass; "nothing happened" must never report as "fixed".
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
# whose success is required. (The writers below are intentionally NOT checked -- a writer
# may crash on an unpatched runtime, which is an expected outcome, not a script failure.)
function Assert-ExitOk([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

$here = $PSScriptRoot
. (Join-Path $here 'process-cleanup.ps1')
$ownedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$appProj = Join-Path $here "..\app\mcjrepro.csproj"
$detProj = Join-Path $here "..\detector\detector.csproj"
$target = "StartupProfileData-Repro"

$sdk = if ($env:DOTNET_SDK) { $env:DOTNET_SDK } else { (Get-Command dotnet).Source }
if (-not (Test-Path $sdk)) { Write-Error "no SDK (set DOTNET_SDK or put dotnet on PATH)"; exit 1 }
$run = if ($env:DOTNET_ROOT) { Join-Path $env:DOTNET_ROOT "dotnet.exe" } else { $sdk }
if (-not (Test-Path $run)) { Write-Error "runtime host not found: $run"; exit 1 }
# Preserve paths relative to the caller before the build changes directory for global.json.
$sdk = (Resolve-Path -LiteralPath $sdk).ProviderPath
$run = (Resolve-Path -LiteralPath $run).ProviderPath

$work = Join-Path $env:TEMP ("mcjrepro_" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $env:MCJ_PROFILE_ROOT = Join-Path $work "cache"
    $profilePath = Join-Path $env:MCJ_PROFILE_ROOT $target
    $env:DOTNET_MULTILEVEL_LOOKUP = "0"; $env:DOTNET_NOLOGO = "1"; $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
    if (-not $env:DOTNET_ROLL_FORWARD) { $env:DOTNET_ROLL_FORWARD = "Major" }

    Write-Host "== building repro app + detector (SDK: $sdk) =="
    $savedRoot = $env:DOTNET_ROOT
    Push-Location -LiteralPath (Join-Path $here '..')
    try {
        # SDK selection searches from cwd, not from the absolute project path.
        $env:DOTNET_ROOT = $null
        & $sdk --version
        Assert-ExitOk "SDK selection (global.json)"
        & $sdk build -c Release $appProj -o (Join-Path $work "app") | Out-Null
        Assert-ExitOk "app build"
        & $sdk build -c Release $detProj -o (Join-Path $work "det") | Out-Null
        Assert-ExitOk "detector build"
    }
    finally {
        $env:DOTNET_ROOT = $savedRoot
        Pop-Location
    }
    $app = Join-Path $work "app\mcjrepro.dll"
    $det = Join-Path $work "det\detector.dll"

    Write-Host "== runtime under test: $run =="
    Write-Host "== seeding a valid profile =="
    $env:SLEEP_MS = "5"
    & $run $app "1" | Out-Null
    Assert-ExitOk "seed run"
    $seeded = (Get-Item $profilePath).Length
    Write-Host ("seeded: {0} bytes" -f $seeded)
    # A profile smaller than its 64-byte header means MulticoreJIT never wrote one (e.g. it
    # silently disables itself below 2 CPUs); the live phase would then measure nothing and
    # "CLEAN" would be vacuous.
    if ($seeded -lt 64) { throw "no profile was seeded -- nothing to measure" }
    $seedStamp = (Get-Item $profilePath).LastWriteTimeUtc

    Write-Host "== sanity: detector on the static (no-writer) profile, must report 0 =="
    & $run $det $profilePath 800
    Assert-ExitOk "sanity detector (static profile must read clean)"

    Write-Host "== live: detector + $Writers concurrent writers for ${DurationMs}ms =="
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
    while (-not (Test-Path $detReady) -and -not $detProc.HasExited -and $readyWait.ElapsedMilliseconds -lt 10000) {
        Start-Sleep -Milliseconds 10
    }
    if (-not (Test-Path $detReady)) {
        if ($detProc.HasExited) { Get-Content $detOut }
        throw "detector did not become ready -- no verdict"
    }

    # Stopwatch rather than [Environment]::TickCount64, which Windows PowerShell 5.1
    # (.NET Framework) does not have.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $overlapObserved = $false
    while ($sw.ElapsedMilliseconds -lt $DurationMs -and -not $detProc.HasExited) {
        $procs = @()
        for ($i = 0; $i -lt $Writers; $i++) {
            $wArgs = '"{0}" {1}' -f $app, $i
            $writer = Start-Process -FilePath $run -ArgumentList $wArgs -PassThru -NoNewWindow
            $ownedProcesses.Add($writer)
            $procs += $writer
        }
        foreach ($writer in $procs) {
            $writer.WaitForExit()
            $null = $ownedProcesses.Remove($writer)
            $writer.Dispose()
        }
        if (-not $detProc.HasExited) {
            $during = Get-Item $profilePath -ErrorAction SilentlyContinue
            if ($null -ne $during -and ($during.LastWriteTimeUtc -ne $seedStamp -or $during.Length -ne $seeded)) {
                $overlapObserved = $true
            }
        }
    }
    $detProc.WaitForExit()
    Get-Content $detOut

    # The live phase must actually have republished the profile, whatever the runtime: a
    # missing or unchanged file means no successful atomic publication was measured.
    $after = Get-Item $profilePath -ErrorAction SilentlyContinue
    if ($null -eq $after) {
        throw "the profile disappeared during the live phase -- no verdict"
    }
    if ($after.LastWriteTimeUtc -eq $seedStamp -and $after.Length -eq $seeded) {
        throw "the profile never changed during the live phase -- nothing was measured"
    }

    $rc = $detProc.ExitCode
    if ($null -eq $rc) { throw "detector exit code unavailable -- no verdict" }
    # A failing detector observed contention directly. A clean detector needs an
    # independent proof that a publication completed before its sampling window ended.
    if ($rc -eq 0 -and -not $overlapObserved) {
        throw "no profile publication completed while the detector was running -- no verdict"
    }
    Write-Host "== publication while a FileShare.Read|Delete reader stays open =="
    $heldDuration = [Math]::Min($DurationMs, 5000)
    $heldOut = Join-Path $work "held.out"
    $heldReady = Join-Path $work "held.ready"
    $heldArgs = '"{0}" --hold-reader "{1}" {2} "{3}"' -f $det, $profilePath, $heldDuration, $heldReady
    $heldProc = Start-Process -FilePath $run -ArgumentList $heldArgs -PassThru -NoNewWindow -RedirectStandardOutput $heldOut
    $ownedProcesses.Add($heldProc)
    $null = $heldProc.Handle
    $heldWait = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $heldReady) -and -not $heldProc.HasExited -and $heldWait.ElapsedMilliseconds -lt 10000) {
        Start-Sleep -Milliseconds 10
    }
    if (-not (Test-Path $heldReady)) {
        if ($heldProc.HasExited) { Get-Content $heldOut }
        throw "held reader did not become ready -- no verdict"
    }
    while (-not $heldProc.HasExited) {
        $procs = @()
        for ($i = 0; $i -lt $Writers; $i++) {
            $wArgs = '"{0}" {1}' -f $app, $i
            $writer = Start-Process -FilePath $run -ArgumentList $wArgs -PassThru -NoNewWindow
            $ownedProcesses.Add($writer)
            $procs += $writer
        }
        foreach ($writer in $procs) {
            $writer.WaitForExit()
            $null = $ownedProcesses.Remove($writer)
            $writer.Dispose()
        }
    }
    $heldProc.WaitForExit()
    Get-Content $heldOut
    $heldRc = $heldProc.ExitCode
    if ($null -eq $heldRc) { throw "held-reader exit code unavailable -- no verdict" }
    if ($heldRc -ne 0 -and $heldRc -ne 2) { throw "held-reader test failed (exit $heldRc) -- no verdict" }
    if ($rc -eq 0 -and $heldRc -eq 2) { $rc = 2 }

    switch ($rc) {
        0       { Write-Host "RESULT: CLEAN -- reader snapshots valid; publication succeeded with the old handle unchanged." }
        2       { Write-Host "RESULT: CONTENTION -- reader observed an invalid/blocked read or publication failed with a reader open." }
        3       { Write-Host "ERROR: detector never managed a single valid read -- no verdict." }
        default { Write-Host "ERROR: detector failed (exit $rc) -- no verdict." }
    }
    exit $rc
}
finally {
    try { Stop-HarnessProcesses $ownedProcesses }
    finally {
        # Preserve logs and profiles even when a detector or writer must be stopped.
        Write-Host "work dir left at: $work"
    }
}
