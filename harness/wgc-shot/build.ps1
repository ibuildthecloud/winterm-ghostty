# Build the Windows Graphics Capture screenshot tool.
#
# C++/WinRT headers ship with the Windows SDK, so this needs no vcpkg or NuGet.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
if (-not $vs) { throw "Visual Studio not found" }

# C++20, not 17: under /std:c++17 C++/WinRT pulls in <experimental/coroutine>,
# which this MSVC hard-errors on as removed. C++20 has real <coroutine>.
$cl = 'cl /nologo /EHsc /std:c++20 /W3 /D_UNICODE /DUNICODE /Fe:wgc-shot.exe main.cpp'
cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul 2>&1 && $cl"
if ($LASTEXITCODE -ne 0) { throw "compile failed with exit code $LASTEXITCODE" }

Write-Host "built $PSScriptRoot\wgc-shot.exe"
