# Clean up only Process objects registered by this harness invocation.
# Keep this compatible with Windows PowerShell 5.1 (no Kill(entireProcessTree)).
function Stop-HarnessProcesses {
    param([System.Collections.Generic.List[System.Diagnostics.Process]]$Processes)

    $failures = [System.Collections.Generic.List[string]]::new()
    $stopErrors = @{}
    # Stop the entire active batch before waiting, so one slow exit cannot leave
    # the other writers running against a retained detector handle.
    foreach ($process in $Processes) {
        try {
            if (-not $process.HasExited) { $process.Kill() }
        }
        catch {
            # The process can exit between HasExited and Kill. Judge cleanup by
            # its eventual exit, rather than turning that race into a failure.
            $stopErrors[$process] = $_.Exception.Message
        }
    }
    foreach ($process in $Processes) {
        try {
            if (-not $process.WaitForExit(5000)) {
                throw "process $($process.Id) did not exit; stop error: $($stopErrors[$process])"
            }
        }
        catch {
            $failures.Add("waiting for process: $($_.Exception.Message)")
        }
        finally {
            $process.Dispose()
        }
    }
    $Processes.Clear()
    if ($failures.Count -ne 0) {
        throw ("Harness process cleanup failed: " + ($failures -join '; '))
    }
}
