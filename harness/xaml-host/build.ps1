<#
.SYNOPSIS
    Build and run the XAML SwapChainPanel harness.

.DESCRIPTION
    Phase 2's deliverable: binds libghostty's DirectComposition surface handle
    into a system-XAML SwapChainPanel, the same way Windows Terminal does in
    TermControl::_AttachDxgiSwapChainToXaml.

    Needs only the Windows SDK - its cppwinrt headers cover system XAML and
    XAML Islands, so there are no NuGet packages to restore. Reuses the import
    library produced by the hwnd-host build, since ghostty's build emits none.

.EXAMPLE
    .\harness\xaml-host\build.ps1
    .\harness\xaml-host\build.ps1 -Warp
    .\harness\xaml-host\build.ps1 -NoRun
#>
[CmdletBinding()]
param(
    [switch] $NoRun,
    [switch] $Warp
)

$ErrorActionPreference = 'Stop'

$here       = $PSScriptRoot
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $here)
$GhosttyOut = Join-Path $RepoRoot 'ghostty\zig-out'
$dll        = Join-Path $GhosttyOut 'lib\ghostty-internal.dll'
$include    = Join-Path $GhosttyOut 'include'
$hwndHost   = Join-Path $RepoRoot 'harness\hwnd-host'
$implib     = Join-Path $hwndHost 'ghostty.lib'

if (-not (Test-Path $dll)) {
    throw "libghostty not built. Run .\scripts\build-ghostty.ps1 first."
}

# The import library is synthesized by the hwnd-host build (ghostty emits none).
# Regenerate it there rather than duplicating the dumpbin/lib dance.
if (-not (Test-Path $implib) -or
    ((Get-Item $dll).LastWriteTime -gt (Get-Item $implib).LastWriteTime)) {
    Write-Host 'refreshing import library via hwnd-host build' -ForegroundColor DarkGray
    & (Join-Path $hwndHost 'build.ps1') -NoRun | Out-Null
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot  = & $vswhere -latest -prerelease -products * -property installationPath
$vcvars  = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'

# /std:c++20 and /await are what C++/WinRT wants; /EHsc for winrt exceptions.
# /STACK matches hwnd-host - see the note there on Zig's stack expectations.
# The embedded manifest is not optional: XAML Islands refuses to initialize
# without a <maxversiontested> declaration (E_UNEXPECTED with a message saying
# so). See xaml-host.manifest.
$cl = "cl /nologo /std:c++20 /EHsc /W3 /Zi " +
      "/I`"$include`" /Fe:xaml-host.exe main.cpp " +
      "/link /STACK:16777216 /MANIFEST:EMBED /MANIFESTINPUT:xaml-host.manifest " +
      "`"$implib`" user32.lib shcore.lib windowsapp.lib"

Write-Host 'cl main.cpp' -ForegroundColor Cyan
cmd /c "`"$vcvars`" >nul 2>&1 && cd /d `"$here`" && $cl"
if ($LASTEXITCODE -ne 0) { throw "compile failed ($LASTEXITCODE)" }

Copy-Item $dll (Join-Path $here 'ghostty-internal.dll') -Force
Write-Host "built $here\xaml-host.exe" -ForegroundColor Green
if ($NoRun) { return }

if ($Warp) {
    $env:GHOSTTY_D3D11_DRIVER = 'warp'
    Write-Host 'GHOSTTY_D3D11_DRIVER=warp' -ForegroundColor Yellow
}
& (Join-Path $here 'xaml-host.exe')
