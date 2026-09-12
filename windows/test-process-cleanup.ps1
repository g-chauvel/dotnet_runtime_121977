# Inject failures into the real drivers and independently observe their process handles.
# Each case runs in a fresh host (Add-Type publisher names and script exit are isolated).
param([ValidateSet('all', 'live-ready', 'partial-writers', 'held-ready', 'publisher-ready')]
      [string]$Case = 'all')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if ($Case -eq 'all') {
    $hostExe = (Get-Process -Id $PID).MainModule.FileName
    foreach ($item in @('live-ready', 'partial-writers', 'held-ready', 'publisher-ready')) {
        & $hostExe -NoProfile -File $PSCommandPath -Case $item
        if ($LASTEXITCODE -ne 0) { throw "$item cleanup regression failed (exit $LASTEXITCODE)" }
    }
    return
}
. (Join-Path $PSScriptRoot 'process-cleanup.ps1')
$previousState = Get-Variable -Name McjCleanupTestState -Scope Global -ErrorAction SilentlyContinue
# Driver functions execute in the caller's script scope. An explicit, restored
# global state keeps the injections independent of driver-local variable names.
$global:McjCleanupTestState = [pscustomobject]@{ Case = $Case; Observed = [System.Collections.Generic.List[System.Diagnostics.Process]]::new(); Injected = $false; HeldStarted = $false }
function Start-Process {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$FilePath, [string[]]$ArgumentList,
          [switch]$PassThru, [switch]$NoNewWindow, [string]$RedirectStandardOutput)
    if ($global:McjCleanupTestState.Case -eq 'partial-writers' -and $global:McjCleanupTestState.Observed.Count -eq 2) {
        $global:McjCleanupTestState.Injected = $true
        throw 'Injected partial writer batch failure'
    }
    $process = Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
    # Retain a separate kernel process handle before the driver disposes its object.
    $observer = [Diagnostics.Process]::GetProcessById($process.Id)
    $null = $observer.Handle
    $global:McjCleanupTestState.Observed.Add($observer)
    if (($ArgumentList -join ' ') -match '--hold-reader') { $global:McjCleanupTestState.HeldStarted = $true }
    return $process
}
function Test-Path {
    [CmdletBinding()]
    param([Parameter(Position=0)][string[]]$Path, [string[]]$LiteralPath)
    $readyCheck = (($Path -join ' ') -like '*.ready')
    if ($readyCheck -and $global:McjCleanupTestState.Observed.Count -gt 0 -and
        (($global:McjCleanupTestState.Case -eq 'live-ready') -or ($global:McjCleanupTestState.Case -eq 'publisher-ready') -or
         ($global:McjCleanupTestState.Case -eq 'held-ready' -and $global:McjCleanupTestState.HeldStarted))) {
        $global:McjCleanupTestState.Injected = $true
        throw 'Injected detector readiness failure'
    }
    return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
try {
    $caught = $null
    try {
        if ($Case -eq 'publisher-ready') {
            & (Join-Path $PSScriptRoot 'test-held-reader.ps1')
        } else {
            & (Join-Path $PSScriptRoot 'run.ps1') -DurationMs 2000 -Writers 2
        }
    }
    catch { $caught = $_ }
    if (-not $global:McjCleanupTestState.Injected -or $null -eq $caught -or $caught.Exception.Message -notlike 'Injected*') {
        throw "Expected injected $Case failure; got $caught"
    }
    if ($global:McjCleanupTestState.Observed.Count -eq 0) { throw 'No process was launched; cleanup was not exercised' }
    foreach ($observer in $global:McjCleanupTestState.Observed) {
        # Cleanup must finish before the driver returns. Waiting here would hide
        # an orphan detector that happens to exit naturally a few seconds later.
        if (-not $observer.HasExited) { throw "Orphan process $($observer.Id) after $Case failure" }
    }
    Write-Host "PASS: $Case ($($global:McjCleanupTestState.Observed.Count) independently observed process exits)"
}
finally {
    # A failing regression must itself stop the leaked children it observed.
    try { Stop-HarnessProcesses $global:McjCleanupTestState.Observed }
    finally {
        if ($null -eq $previousState) { Remove-Variable -Name McjCleanupTestState -Scope Global }
        else { Set-Variable -Name McjCleanupTestState -Scope Global -Value $previousState.Value }
    }
}
