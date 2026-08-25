<#
.SYNOPSIS
    Build OpenConsole.exe (the ConPTY host) at an upstream commit and drop it
    into a portable install for testing.

.DESCRIPTION
    KD-26: a large escape-dense frame is corrupted by the ConPTY host we build
    and not by the one the 1.24 store terminal ships. Swapping only
    OpenConsole.exe between two otherwise identical installs moves the fault,
    so the culprit is a commit on upstream `main` after the 1.24 branch point
    (ad48162f0, 2025-08-25) and at or before our pin.

    None of our patches touch conhost - the only one in that area changes a
    CLSID - so each step builds *unpatched upstream* in a detached worktree.
    That keeps the fork's branch untouched, and it means what is measured is
    upstream's code rather than ours.

    The worktree shares the main clone's NuGet packages through a junction, so
    only the first build pays for a restore.

.EXAMPLE
    .\bisect-conhost.ps1 -Commit ca7996296 -Into 'C:\Users\darre\Downloads\winterm-ghostty-BISECT\terminal-0.2.11.0'
#>
[CmdletBinding()]
param(
    # Omit when git bisect is driving: it has already checked out the commit to
    # test, and checking out again here would fight its bookkeeping.
    [string]$Commit,
    # The portable install whose OpenConsole.exe gets replaced.
    [Parameter(Mandatory)][string]$Into,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    # Where the detached worktree lives. Off the repo's drive by default is a
    # deliberate choice: a conhost build wants several GB of intermediates, and
    # E: had ten megabytes free the first time this ran.
    [string]$Worktree,
    [int]$MaxCpuCount = 4,
    [string]$SdkVersion = '10.0.26100.0',
    [string]$Toolset = 'v145'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Main = Join-Path $RepoRoot 'terminal'
$Work = if ($Worktree) { $Worktree } else { Join-Path $RepoRoot 'terminal-bisect' }

if (-not (Test-Path $Main)) { throw "terminal/ clone not found at $Main" }

# --- The worktree ---------------------------------------------------------
if (-not (Test-Path $Work)) {
    if (-not $Commit) { throw "the worktree does not exist yet, so -Commit is needed to create it" }
    Write-Host "creating worktree at $Work" -ForegroundColor Cyan
    git -C $Main worktree add --detach $Work $Commit
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed" }
}
elseif (-not $Commit) {
    # git bisect has us where it wants us; just build what is checked out.
    git -C $Work clean -xfd -e packages -e bin -e obj -e bisect-relax.props 2>&1 | Out-Null
}
else {
    git -C $Work checkout --detach --force $Commit 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git checkout $Commit failed in the worktree" }
    # A stale object file from another commit is worse than a slow build.
    git -C $Work clean -xfd -e packages -e bin -e obj -e bisect-relax.props 2>&1 | Out-Null
}

$sha = (git -C $Work rev-parse --short HEAD).Trim()
$subject = (git -C $Work log -1 --format='%s').Trim()
Write-Host "at $sha  $subject" -ForegroundColor Green

# --- Packages, shared with the main clone ---------------------------------
$pkgMain = Join-Path $Main 'packages'
$pkgWork = Join-Path $Work 'packages'
if ((Test-Path $pkgMain) -and -not (Test-Path $pkgWork)) {
    Write-Host "linking packages" -ForegroundColor DarkGray
    cmd /c mklink /J "`"$pkgWork`"" "`"$pkgMain`"" | Out-Null
}
if (-not (Test-Path $pkgWork)) {
    $nuget = Join-Path $Work 'dep\nuget\nuget.exe'
    & $nuget restore (Join-Path $Work 'dep\nuget\packages.config') `
        -PackagesDirectory $pkgWork -ConfigFile (Join-Path $Work 'NuGet.Config') -Verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw "nuget restore failed" }
}

# --- Build conhost --------------------------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$msbuild = & $vswhere -latest -prerelease -products * -requires Microsoft.Component.MSBuild `
    -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) {
    $vsRoot = & $vswhere -latest -prerelease -products * -property installationPath
    $msbuild = Join-Path $vsRoot 'MSBuild\Current\Bin\MSBuild.exe'
}

$proj = Join-Path $Work 'src\host\exe\Host.EXE.vcxproj'
Write-Host "msbuild Host.EXE.vcxproj ($Configuration|x64)" -ForegroundColor Cyan
# The toolchain is held constant across every step on purpose. Commits from
# 2025 target Windows SDK 10.0.22621.0 and toolset v143; this machine has only
# 10.0.26100.0, and the calibrated bad build used v145 against it. Letting each
# commit pick its own would mean a "clean" verdict could be the compiler rather
# than the source - the one confound a bisect cannot survive.
# Old source, new compiler, new vcpkg headers: warnings that did not exist in
# 2025 are errors in 2026, and WT builds warnings-as-errors. The props file
# turns that off for the build only - see the comment inside it.
$relax = Join-Path $Work 'bisect-relax.props'
if (-not (Test-Path $relax)) { throw "missing $relax" }

& $msbuild $proj "/p:SolutionDir=$Work\" "/p:Configuration=$Configuration" '/p:Platform=x64' `
    "/p:WindowsTargetPlatformVersion=$SdkVersion" "/p:PlatformToolset=$Toolset" `
    "/p:ForceImportBeforeCppTargets=$relax" `
    '/v:m' '/nologo' "/m:$MaxCpuCount" '/p:CL_MPCount=2'
if ($LASTEXITCODE -ne 0) { throw "msbuild failed ($LASTEXITCODE)" }

$built = Join-Path $Work "bin\x64\$Configuration\OpenConsole.exe"
if (-not (Test-Path $built)) { throw "no OpenConsole.exe at $built" }

# --- Install --------------------------------------------------------------
if (-not (Test-Path $Into)) { throw "target install not found: $Into" }

# A window still open from the previous round holds OpenConsole.exe open, and
# the copy fails. Only windows running *from this install* are closed - matched
# by path, never by process name, since the name is shared with whatever the
# user is working in.
$running = Get-Process WindowsTerminal -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Into, [StringComparison]::OrdinalIgnoreCase) }
foreach ($p in $running)
{
    Write-Host "closing the previous round's window (pid $($p.Id))" -ForegroundColor DarkYellow
    $null = $p.CloseMainWindow()
}
if ($running) { Start-Sleep -Seconds 4 }

Copy-Item $built (Join-Path $Into 'OpenConsole.exe') -Force
$info = Get-Item (Join-Path $Into 'OpenConsole.exe')

Write-Host ""
Write-Host "installed $sha -> $($info.FullName)" -ForegroundColor Green
Write-Host "  $($info.Length) bytes, built $($info.LastWriteTime)"
Write-Host "  $subject"
