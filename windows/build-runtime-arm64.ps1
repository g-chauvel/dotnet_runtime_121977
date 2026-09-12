# Build the minimum CoreCLR payload used by this harness on an ARM64 Windows build host.
#
# This is deliberately separate from run.ps1: the harness never builds CoreCLR on the
# machine where it is merely validating a runtime. The script records the selected SDK,
# exact source revision, full build output, and native exit code for a reproducible build.
param(
    [Parameter(Mandatory = $true)]
    [string]$RuntimeRepo,
    [Parameter(Mandatory = $true)]
    [string]$DotnetSdk,
    [Parameter(Mandatory = $true)]
    [string]$Artifacts,
    [string]$ExpectedCommit
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

function Require-Path([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description was not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

$repo = Require-Path $RuntimeRepo "Runtime repository"
$sdk = Require-Path $DotnetSdk "SDK executable"
$artifactRoot = [System.IO.Path]::GetFullPath($Artifacts)
New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null

$buildCmd = Require-Path (Join-Path $repo "build.cmd") "Runtime build command"
$globalJson = Get-Content -Raw -LiteralPath (Join-Path $repo "global.json") | ConvertFrom-Json
$requiredSdk = $globalJson.sdk.version
$sdkRoot = Split-Path -Parent $sdk

# A local bootstrap directory takes precedence over the requested SDK through global.json.
# Refuse it rather than silently changing the compiler identity that this script records.
if (Test-Path -LiteralPath (Join-Path $repo ".dotnet")) {
    throw "Refusing to build with $repo\.dotnet present; remove or relocate that bootstrap before selecting $sdk."
}

Push-Location -LiteralPath $repo
$savedInstallDir = $env:DOTNET_INSTALL_DIR
$savedRoot = $env:DOTNET_ROOT
$savedLookup = $env:DOTNET_MULTILEVEL_LOOKUP
$savedPath = $env:PATH
try {
    $env:DOTNET_INSTALL_DIR = $sdkRoot
    $env:DOTNET_ROOT = $sdkRoot
    $env:DOTNET_MULTILEVEL_LOOKUP = "0"
    $env:PATH = "$sdkRoot;$savedPath"

    $selectedSdk = (& $sdk --version).Trim()
    if ($LASTEXITCODE -ne 0) { throw "SDK selection failed (exit $LASTEXITCODE)" }
    if ($selectedSdk -ne $requiredSdk) {
        throw "global.json requires SDK $requiredSdk, but $sdk selected $selectedSdk"
    }

    $head = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not determine the runtime revision" }
    if ($ExpectedCommit -and $head -ne $ExpectedCommit) {
        throw "Runtime revision is $head, expected $ExpectedCommit"
    }

    $metadataPath = Join-Path $artifactRoot "build-arm64-metadata.txt"
    @(
        "runtime_repo=$repo"
        "runtime_commit=$head"
        "sdk=$sdk"
        "sdk_version=$selectedSdk"
        "command=$buildCmd clr.runtime+clr.jit+clr.corelib -arch arm64 -configuration Release -binaryLog"
    ) | Set-Content -LiteralPath $metadataPath -Encoding utf8

    $buildLog = Join-Path $artifactRoot "build-arm64.log"
    & $buildCmd clr.runtime+clr.jit+clr.corelib -arch arm64 -configuration Release -binaryLog *> $buildLog
    $buildExitCode = $LASTEXITCODE
    "build_exit_code=$buildExitCode" | Set-Content -LiteralPath (Join-Path $artifactRoot "build-arm64-exit.txt") -Encoding ascii

    if ($buildExitCode -ne 0) {
        throw "ARM64 CoreCLR subset build failed (exit $buildExitCode); see $buildLog"
    }
}
finally {
    $env:DOTNET_INSTALL_DIR = $savedInstallDir
    $env:DOTNET_ROOT = $savedRoot
    $env:DOTNET_MULTILEVEL_LOOKUP = $savedLookup
    $env:PATH = $savedPath
    Pop-Location
}
