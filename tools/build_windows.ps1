param([switch]$CreateArchive)

# Run from Windows 11 with the Flutter Windows/VS C++ workload installed.
# Regenerates FRB from the real Rust API; never packages a stale debug DLL.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$previousLocation = Get-Location
$oldIncremental = $env:CARGO_INCREMENTAL
$oldJobs = $env:CARGO_BUILD_JOBS
function Invoke-BuildStep {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE)" }
}
function Copy-VisualCppRuntime {
    param([string]$Bundle)
    # App-local redistributable DLLs let the ZIP run without a VS installation.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'vswhere is missing; install the Visual Studio C++ desktop workload.' }
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'MSVC x64 tools installation was not found.' }
    $versions = Get-ChildItem -LiteralPath (Join-Path $installation 'VC/Redist/MSVC') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
        Sort-Object { [Version]$_.Name } -Descending
    if (-not $versions) { throw 'MSVC redistributable files are missing; install the VC++ redistributable component.' }
    $crt = Get-ChildItem -LiteralPath (Join-Path $versions[0].FullName 'x64') -Directory -Filter '*.CRT' | Select-Object -First 1
    if (-not $crt) { throw 'MSVC x64 CRT redistributable directory was not found.' }
    Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' -File | Copy-Item -Destination $Bundle -Force
    foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Bundle $name))) { throw "MSVC runtime was not packaged: $name" }
    }
    Write-Output "Packaged MSVC runtime from: $($crt.FullName)"
}
try {
    Set-Location $repoRoot
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
        throw 'This script currently packages Windows x64 only; do not mix an ARM64 Flutter bundle with the x64 Rust DLL.'
    }
    foreach ($tool in @('cargo', 'flutter', 'flutter_rust_bridge_codegen', 'python')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Missing $tool. Install the documented toolchain before building."
        }
    }
    $generatorVersion = & flutter_rust_bridge_codegen --version
    if ($LASTEXITCODE -ne 0 -or $generatorVersion -notmatch '(?<!\d)2\.13\.0(?![\d.])') {
        throw 'This repository requires flutter_rust_bridge_codegen 2.13.0.'
    }
    $env:CARGO_INCREMENTAL = '0'
    $env:CARGO_BUILD_JOBS = '2'
    Invoke-BuildStep -Command 'python' -Arguments @((Join-Path $repoRoot 'tools/prepare_native_extensions.py'))
    Set-Location (Join-Path $repoRoot 'ui_flutter')
    Invoke-BuildStep -Command 'flutter' -Arguments @('pub', 'get')
    Set-Location $repoRoot
    Invoke-BuildStep -Command 'flutter_rust_bridge_codegen' -Arguments @('generate')
    # Explicit target avoids silently inheriting a Linux/Android default target.
    Invoke-BuildStep -Command 'cargo' -Arguments @('build', '-p', 'hspterm-frb-bridge', '--release', '--locked', '--target', 'x86_64-pc-windows-msvc', '--target-dir', (Join-Path $repoRoot 'target'))
    Set-Location (Join-Path $repoRoot 'ui_flutter')
    Invoke-BuildStep -Command 'flutter' -Arguments @('build', 'windows', '--release', '--target', 'lib/workbench_main.dart')
    $bundle = Join-Path $repoRoot 'ui_flutter/build/windows/x64/runner/Release'
    $nativeDll = Join-Path $repoRoot 'target/x86_64-pc-windows-msvc/release/hspterm_frb_bridge.dll'
    if (-not (Test-Path -LiteralPath (Join-Path $bundle 'hspterm.exe'))) {
        throw "Flutter bundle not found at $bundle"
    }
    if (-not (Test-Path -LiteralPath $nativeDll)) { throw 'Matching release Rust DLL was not produced.' }
    if (-not (Test-Path -LiteralPath (Join-Path $bundle 'flutter_local_notifications_windows.dll'))) {
        throw 'Windows notification plugin DLL is missing from the Flutter bundle; check the VS C++ ATL/WinRT components and plugin build.'
    }
    Copy-Item -LiteralPath $nativeDll -Destination (Join-Path $bundle 'hspterm_frb_bridge.dll') -Force
    $sourceHash = (Get-FileHash -LiteralPath $nativeDll -Algorithm SHA256).Hash
    $packagedHash = (Get-FileHash -LiteralPath (Join-Path $bundle 'hspterm_frb_bridge.dll') -Algorithm SHA256).Hash
    if ($sourceHash -ne $packagedHash) { throw 'Packaged DLL hash does not match the build.' }
    Copy-VisualCppRuntime -Bundle $bundle
    Write-Output "Release bundle: $bundle"
    Write-Output "Rust DLL SHA256: $packagedHash"
    if ($CreateArchive) {
        $archive = Join-Path $repoRoot 'ui_flutter/build/windows/HSPTerm-windows-x64.zip'
        if (Test-Path -LiteralPath $archive) { throw "Archive already exists; preserve or remove it explicitly: $archive" }
        Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive
        Write-Output "Archive: $archive"
    }
} finally {
    $env:CARGO_INCREMENTAL = $oldIncremental
    $env:CARGO_BUILD_JOBS = $oldJobs
    Set-Location $previousLocation
}
