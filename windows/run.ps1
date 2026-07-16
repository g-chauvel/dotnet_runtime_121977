# Windows reproduction driver for dotnet/runtime#121977.
#
# On Windows the torn-read corruption does NOT occur: the in-place write opens the final
# path deny-share, so a concurrent reader is refused with ERROR_SHARING_VIOLATION instead
# of reading torn bytes. This driver runs N concurrent writers against one shared profile
# while a reader (Detector.cs) samples it, and counts what the reader observes.
#
#   exit 2  -> reader saw SHARING_VIOLATION (or torn/incomplete) = contention present (UNPATCHED)
#   exit 0  -> reader was never blocked and always read a complete profile = FIXED
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
$appProj = Join-Path $here "..\app\mcjrepro.csproj"
$detProj = Join-Path $here "..\detector\detector.csproj"
$target = "StartupProfileData-Repro"

$sdk = if ($env:DOTNET_SDK) { $env:DOTNET_SDK } else { (Get-Command dotnet).Source }
if (-not (Test-Path $sdk)) { Write-Error "no SDK (set DOTNET_SDK or put dotnet on PATH)"; exit 1 }
$run = if ($env:DOTNET_ROOT) { Join-Path $env:DOTNET_ROOT "dotnet.exe" } else { $sdk }
if (-not (Test-Path $run)) { Write-Error "runtime host not found: $run"; exit 1 }

$work = Join-Path $env:TEMP ("mcjrepro_" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $env:MCJ_PROFILE_ROOT = Join-Path $work "cache"
    $profilePath = Join-Path $env:MCJ_PROFILE_ROOT $target
    $env:DOTNET_MULTILEVEL_LOOKUP = "0"; $env:DOTNET_NOLOGO = "1"; $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
    if (-not $env:DOTNET_ROLL_FORWARD) { $env:DOTNET_ROLL_FORWARD = "Major" }

    Write-Host "== building repro app + detector (SDK: $sdk) =="
    $savedRoot = $env:DOTNET_ROOT
    $env:DOTNET_ROOT = $null
    & $sdk build -c Release $appProj -o (Join-Path $work "app") | Out-Null
    Assert-ExitOk "app build"
    & $sdk build -c Release $detProj -o (Join-Path $work "det") | Out-Null
    Assert-ExitOk "detector build"
    $env:DOTNET_ROOT = $savedRoot
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
    $detArgs = '"{0}" "{1}" {2}' -f $det, $profilePath, $DurationMs
    $detProc = Start-Process -FilePath $run -ArgumentList $detArgs -PassThru -NoNewWindow -RedirectStandardOutput $detOut
    # Stopwatch rather than [Environment]::TickCount64, which Windows PowerShell 5.1
    # (.NET Framework) does not have.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $DurationMs) {
        $procs = @()
        for ($i = 0; $i -lt $Writers; $i++) {
            $wArgs = '"{0}" {1}' -f $app, $i
            $procs += Start-Process -FilePath $run -ArgumentList $wArgs -PassThru -NoNewWindow
        }
        $procs | ForEach-Object { $_.WaitForExit() }
    }
    $detProc.WaitForExit()
    Get-Content $detOut

    # The live phase must actually have republished the profile, whatever the runtime: an
    # unchanged file means no writes were measured and the verdict would be vacuous.
    $after = Get-Item $profilePath -ErrorAction SilentlyContinue
    if ($null -ne $after -and $after.LastWriteTimeUtc -eq $seedStamp -and $after.Length -eq $seeded) {
        throw "the profile never changed during the live phase -- nothing was measured"
    }

    $rc = $detProc.ExitCode
    switch ($rc) {
        0       { Write-Host "RESULT: CLEAN -- reader never blocked, always read a complete profile (fixed)." }
        2       { Write-Host "RESULT: CONTENTION -- reader observed sharing violations / torn profile (unpatched)." }
        3       { Write-Host "ERROR: detector never managed a single valid read -- no verdict." }
        default { Write-Host "ERROR: detector failed (exit $rc) -- no verdict." }
    }
    exit $rc
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
