# Targeted contract checks for Detector --hold-reader, using the SDK runtime.
# This validates the detector and Windows rename APIs; it is not a patched-runtime test.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'process-cleanup.ps1')
$ownedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$sdk = if ($env:DOTNET_SDK) { $env:DOTNET_SDK } else { (Get-Command dotnet).Source }
# Resolve relative SDK paths before entering the directory containing global.json.
$sdk = (Resolve-Path -LiteralPath $sdk).ProviderPath
$work = Join-Path $env:TEMP ("mcj_held_checks_" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work | Out-Null
$savedRoot = $env:DOTNET_ROOT
try {
Push-Location -LiteralPath (Join-Path $PSScriptRoot '..')
try {
    # SDK selection searches from cwd, not from the absolute project path.
    $env:DOTNET_ROOT = $null
    & $sdk --version
    if ($LASTEXITCODE -ne 0) { throw "SDK selection (global.json) failed" }
    & $sdk build -c Release (Join-Path $PSScriptRoot '../app/mcjrepro.csproj') -o (Join-Path $work 'app') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "app build failed" }
    & $sdk build -c Release (Join-Path $PSScriptRoot '../detector/detector.csproj') -o (Join-Path $work 'det') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "detector build failed" }
}
finally {
    Pop-Location
}
$env:MCJ_PROFILE_ROOT = Join-Path $work 'seed'
$env:SLEEP_MS = '5'
& $sdk (Join-Path $work 'app/mcjrepro.dll') 1
if ($LASTEXITCODE -ne 0) { throw "seed run failed" }
$seed = Join-Path $env:MCJ_PROFILE_ROOT 'StartupProfileData-Repro'
if (-not (Test-Path $seed)) { throw "no seed profile" }
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class HeldReaderPublisher {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool MoveFileExW(string existing, string replacement, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint creation, uint attributes, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass,
        IntPtr buffer, uint size);
    public static int Legacy(string temporary, string target) {
        return MoveFileExW(temporary, target, 1) ? 0 : Marshal.GetLastWin32Error();
    }
    public static void Posix(string temporary, string target) {
        using (SafeFileHandle handle = CreateFileW(temporary, 0x10000, 7,
            IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] name = Encoding.Unicode.GetBytes(target);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = rootOffset + IntPtr.Size;
            int nameOffset = lengthOffset + 4;
            // FileNameLength excludes the terminator, but provide and initialize one:
            // FileRenameInfoEx otherwise consumed uninitialized bytes in this probe on
            // Windows and could create a malformed target name.
            int bufferBytes = checked(nameOffset + name.Length + sizeof(char));
            IntPtr buffer = Marshal.AllocHGlobal(bufferBytes);
            try {
                Marshal.WriteInt32(buffer, 0, 3); // REPLACE_IF_EXISTS | POSIX_SEMANTICS
                Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
                Marshal.WriteInt32(buffer, lengthOffset, name.Length);
                Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
                Marshal.WriteInt16(buffer, nameOffset + name.Length, 0);
                if (!SetFileInformationByHandle(handle, 22, buffer, (uint)bufferBytes))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { Marshal.FreeHGlobal(buffer); }
        }
    }
}
"@
foreach ($case in @('none', 'legacy', 'posix')) {
    $target = Join-Path $work "$case.profile"
    $temporary = Join-Path $work "$case.tmp"
    Copy-Item $seed $target
    # Identical bytes deliberately require file-identity proof, rather than content/mtime.
    Copy-Item $seed $temporary
    $ready = Join-Path $work "$case.ready"
    $output = Join-Path $work "$case.out"
    $arguments = '"{0}" --hold-reader "{1}" 2000 "{2}"' -f (Join-Path $work 'det/detector.dll'), $target, $ready
    $process = Start-Process $sdk -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput $output
    $ownedProcesses.Add($process)
    $null = $process.Handle
    $wait = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $ready) -and -not $process.HasExited -and $wait.ElapsedMilliseconds -lt 10000) {
        Start-Sleep -Milliseconds 10
    }
    if (-not (Test-Path $ready)) { throw "$case detector did not become ready" }
    if ($case -eq 'legacy') {
        $errorCode = [HeldReaderPublisher]::Legacy($temporary, $target)
        if ($errorCode -ne 5 -and $errorCode -ne 32) { throw "legacy rename expected an access/sharing failure, got $errorCode" }
        Write-Host "legacy rename: expected access/sharing failure ($errorCode)"
    }
    if ($case -eq 'posix') { [HeldReaderPublisher]::Posix($temporary, $target) }
    $process.WaitForExit()
    Get-Content $output
    $expected = if ($case -eq 'posix') { 0 } else { 2 }
    if ($null -eq $process.ExitCode -or $process.ExitCode -ne $expected) {
        throw "$case detector expected $expected, got $($process.ExitCode)"
    }
    Write-Host "PASS: $case (exit $expected)"
}
Write-Host "work dir left at: $work"
}
finally {
    try { Stop-HarnessProcesses $ownedProcesses }
    finally { $env:DOTNET_ROOT = $savedRoot }
}
