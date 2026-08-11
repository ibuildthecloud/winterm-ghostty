# Build the raw-input probe.
#
# Plain Win32 console API - no WinRT, no NuGet, so this only needs the SDK that
# comes with Visual Studio.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
if (-not $vs) { throw "Visual Studio not found" }

$cl = 'cl /nologo /EHsc /std:c++20 /W3 /Fe:rawin.exe main.cpp'
cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul 2>&1 && $cl"
if ($LASTEXITCODE -ne 0) { throw "compile failed with exit code $LASTEXITCODE" }

Write-Host "built $PSScriptRoot\rawin.exe"
