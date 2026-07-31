<#
.SYNOPSIS
    Build Windows Terminal from the terminal/ clone.

.DESCRIPTION
    Wraps NuGet restore + MSBuild for microsoft/terminal, encoding the two
    non-obvious steps found in Phase 0 (see docs/sessions/0001-phase-0.md):

      1. The bundled dep\nuget\nuget.exe predates `.slnx` and rejects
         `nuget restore OpenConsole.slnx`. Restoring
         dep\nuget\packages.config alone pulls the centralized package set
         (WIL, CppWinRT, Microsoft.UI.Xaml, TAEF, ...), which is what the
         native projects actually consume.
      2. Building an individual .vcxproj requires -SolutionDir, because the
         projects import `$(SolutionDir)common.openconsole.props`.

    MSBuild is located through vswhere, so this follows whichever Visual
    Studio is installed (VS 2026 / v145 on the Phase 0 machine; WT's
    src\common.build.pre.props selects v145 when VisualStudioVersion >= 18.0).

.EXAMPLE
    .\scripts\build-terminal.ps1                       # WindowsTerminal.exe, Debug x64
    .\scripts\build-terminal.ps1 -Project conhost      # OpenConsole (conhost) only
    .\scripts\build-terminal.ps1 -Configuration Release -Platform ARM64
    .\scripts\build-terminal.ps1 -RestoreOnly
#>
[CmdletBinding()]
param(
    # Named shortcut, or a path to a .vcxproj/.slnx relative to terminal/.
    [string] $Project = 'terminal',

    [ValidateSet('Debug', 'Release', 'AuditMode')]
    [string] $Configuration = 'Debug',

    [ValidateSet('x64', 'x86', 'ARM64')]
    [string] $Platform = 'x64',

    [switch] $RestoreOnly,

    # Skip the NuGet restore (it is idempotent but not free).
    [switch] $NoRestore,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'

$RepoRoot     = Split-Path -Parent $PSScriptRoot
$TerminalRoot = Join-Path $RepoRoot 'terminal'

if (-not (Test-Path $TerminalRoot)) {
    throw "terminal/ clone not found at $TerminalRoot. See PLAN.md Phase 0."
}

# Named shortcuts for the projects this project cares about.
$known = @{
    'terminal' = 'src\cascadia\WindowsTerminal\WindowsTerminal.vcxproj'
    'conhost'  = 'src\host\exe\Host.EXE.vcxproj'
    'package'  = 'src\cascadia\CascadiaPackage\CascadiaPackage.wapproj'
    'solution' = 'OpenConsole.slnx'
}
$projectPath = if ($known.ContainsKey($Project)) { $known[$Project] } else { $Project }
$projectFull = Join-Path $TerminalRoot $projectPath
if (-not (Test-Path $projectFull)) { throw "Project not found: $projectFull" }

# --- Locate MSBuild -------------------------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found; is Visual Studio installed?" }

$msbuild = & $vswhere -latest -prerelease -products * `
    -requires Microsoft.Component.MSBuild `
    -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1

if (-not $msbuild) {
    # VS 2026 Community without the standalone MSBuild component still ships MSBuild.
    $vsRoot  = & $vswhere -latest -prerelease -products * -property installationPath
    $msbuild = Join-Path $vsRoot 'MSBuild\Current\Bin\MSBuild.exe'
}
if (-not (Test-Path $msbuild)) { throw "MSBuild.exe not found." }

Write-Host "MSBuild: $msbuild" -ForegroundColor DarkGray

# --- Restore --------------------------------------------------------------
if (-not $NoRestore) {
    $nuget = Join-Path $TerminalRoot 'dep\nuget\nuget.exe'
    Write-Host 'nuget restore dep\nuget\packages.config' -ForegroundColor Cyan
    & $nuget restore (Join-Path $TerminalRoot 'dep\nuget\packages.config') -Verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw "nuget restore failed ($LASTEXITCODE)" }
}
if ($RestoreOnly) { return }

# --- Build ----------------------------------------------------------------
$msbuildArgs = @(
    $projectFull
    "/p:SolutionDir=$TerminalRoot\"
    "/p:Configuration=$Configuration"
    "/p:Platform=$Platform"
    '/v:m'
    '/nologo'
    '/m'
)
if ($Rest) { $msbuildArgs += $Rest }

Write-Host "msbuild $projectPath ($Configuration|$Platform)" -ForegroundColor Cyan
& $msbuild @msbuildArgs
if ($LASTEXITCODE -ne 0) { throw "msbuild failed with exit code $LASTEXITCODE" }

$binDir = Join-Path $TerminalRoot "bin\$Platform\$Configuration"
if (Test-Path $binDir) {
    Write-Host "`nOutput in $binDir" -ForegroundColor Green
    Get-ChildItem $binDir -Filter *.exe | ForEach-Object { '  {0}' -f $_.Name }
}
