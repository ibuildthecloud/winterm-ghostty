<#
.SYNOPSIS
    Build and run the D3D11 / WARP device probe.

.DESCRIPTION
    Answers the Phase 1 escalation trigger in PLAN.md ("WARP device creation
    fails on this machine") and re-checks ADR 0002's degradation ladder on any
    machine or session. Run it over RDP to validate the remote/driverless path,
    which is the only second configuration this project has.

    Exit code is the number of failures, so it works as a gate in CI or a
    session smoke test.

.EXAMPLE
    .\harness\warp-probe\build.ps1            # build + run
    .\harness\warp-probe\build.ps1 -NoRun     # build only
#>
[CmdletBinding()]
param([switch] $NoRun)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$exe  = Join-Path $here 'warp-probe.exe'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot  = & $vswhere -latest -prerelease -products * -property installationPath
$vcvars  = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found at $vcvars" }

Write-Host "cl warp-probe.cpp" -ForegroundColor Cyan
cmd /c "`"$vcvars`" >nul 2>&1 && cd /d `"$here`" && cl /nologo /EHsc /W3 /Fe:warp-probe.exe warp-probe.cpp"
if ($LASTEXITCODE -ne 0) { throw "compile failed ($LASTEXITCODE)" }

if (-not $NoRun) {
    Write-Host ''
    & $exe
    $failures = $LASTEXITCODE
    if ($failures -ne 0) {
        Write-Host "`nprobe reported $failures failure(s)" -ForegroundColor Red
    }
    exit $failures
}
