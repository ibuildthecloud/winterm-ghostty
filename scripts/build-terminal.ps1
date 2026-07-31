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
      3. MSBuild's default `/m` (one node per core) exhausts commit charge on
         the C++/WinRT + XAML translation units: cl.exe dies with
         "C1076: compiler limit: internal heap limit reached" and the underlying
         "the system returned code 1455: The paging file is too small". Hence
         -MaxCpuCount 4 / CL_MPCount 2 by default. Raise at your own risk.
      4. If a build dies that way, the XAML/cppwinrt codegen is left half
         written and MSBuild then considers it up to date, so the next build
         fails with a wall of "Cannot open include file: 'Xxx.g.h'". Use
         -CleanCodegen to delete the stale "Generated Files" + obj dirs.
      5. The unpackaged bin\x64\Debug\WindowsTerminal\WindowsTerminal.exe
         calls abort() on launch. The supported run-from-source path is
         -Project package followed by -Deploy (DeployAppRecipe), which
         registers WindowsTerminalDev_8wekyb3d8bbwe!App.

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

    # Parallel MSBuild nodes. Defaults to 4 deliberately - see note 3 above.
    [int] $MaxCpuCount = 4,

    # Delete the XAML/cppwinrt generated output before building, to recover
    # from a half-written codegen left by an out-of-memory build (note 4).
    [switch] $CleanCodegen,

    # After building, deploy the loose layout via DeployAppRecipe and print
    # the AUMID. Only meaningful with -Project package.
    [switch] $Deploy,

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

# --- Recover from a half-written codegen ----------------------------------
if ($CleanCodegen) {
    foreach ($proj in 'TerminalSettingsEditor', 'TerminalApp', 'TerminalControl', 'TerminalSettingsModel') {
        $gen = Join-Path $TerminalRoot "src\cascadia\$proj\Generated Files"
        if (Test-Path $gen) {
            Write-Host "  removing $gen" -ForegroundColor DarkYellow
            Remove-Item -Recurse -Force $gen
        }
    }
    $obj = Join-Path $TerminalRoot "obj\$Platform\$Configuration"
    if (Test-Path $obj) {
        Get-ChildItem $obj -Directory | Where-Object Name -match 'Terminal' | ForEach-Object {
            Write-Host "  removing $($_.FullName)" -ForegroundColor DarkYellow
            Remove-Item -Recurse -Force $_.FullName
        }
    }
}

# --- Build ----------------------------------------------------------------
$msbuildArgs = @(
    $projectFull
    "/p:SolutionDir=$TerminalRoot\"
    "/p:Configuration=$Configuration"
    "/p:Platform=$Platform"
    '/v:m'
    '/nologo'
    "/m:$MaxCpuCount"
    '/p:CL_MPCount=2'
)
if ($Rest) { $msbuildArgs += $Rest }

Write-Host "msbuild $projectPath ($Configuration|$Platform, /m:$MaxCpuCount)" -ForegroundColor Cyan
& $msbuild @msbuildArgs
if ($LASTEXITCODE -ne 0) { throw "msbuild failed with exit code $LASTEXITCODE" }

$binDir = Join-Path $TerminalRoot "bin\$Platform\$Configuration"
if (Test-Path $binDir) {
    Write-Host "`nOutput in $binDir" -ForegroundColor Green
    Get-ChildItem $binDir -Filter *.exe | ForEach-Object { '  {0}' -f $_.Name }
}

# --- Deploy ---------------------------------------------------------------
if ($Deploy) {
    $recipe = Join-Path $TerminalRoot `
        "src\cascadia\CascadiaPackage\bin\$Platform\$Configuration\CascadiaPackage.build.appxrecipe"
    if (-not (Test-Path $recipe)) {
        throw "appxrecipe not found at $recipe - build with -Project package first."
    }
    $vsRoot  = & $vswhere -latest -prerelease -products * -property installationPath
    $deployer = Join-Path $vsRoot 'Common7\IDE\DeployAppRecipe.exe'
    if (-not (Test-Path $deployer)) { throw "DeployAppRecipe.exe not found at $deployer" }

    Write-Host "`nDeployAppRecipe $recipe" -ForegroundColor Cyan
    & $deployer $recipe
    if ($LASTEXITCODE -ne 0) { throw "DeployAppRecipe failed with exit code $LASTEXITCODE" }

    Write-Host "`nLaunch with:" -ForegroundColor Green
    Write-Host '  Start-Process "shell:appsFolder\WindowsTerminalDev_8wekyb3d8bbwe!App"'
}
