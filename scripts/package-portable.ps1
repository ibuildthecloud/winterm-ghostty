<#
.SYNOPSIS
    Stage the portable (unpackaged) ZIP into dist/.

.DESCRIPTION
    The no-certificate answer. Unzip it anywhere and run WindowsTerminal.exe:
    no install, no signature, no Developer Mode, nothing registered. The
    `.portable` marker next to the exe makes settings live beside it rather
    than in %LOCALAPPDATA%\Packages, so it leaves no trace behind either.

    This is a thin wrapper over upstream's own
    build\scripts\New-UnpackagedTerminalDistribution.ps1 rather than a
    reimplementation, because the layout is not just "the bin directory":

      - Microsoft.UI.Xaml.dll and its resources have to be copied in from the
        WinUI framework package, since an unpackaged app has no framework
        dependency to resolve against.
      - resources.pri has to be MERGED with XAML's, or resource lookups fail.
      - The appx-specific files have to be stripped.

    Copying bin\ and dropping a .portable marker next to it produces something
    that launches and immediately dies with 0xC0000409 (__fastfail). Measured,
    not guessed - that was the first attempt.

.EXAMPLE
    .\scripts\package-portable.ps1
#>
[CmdletBinding()]
param(
    # The .msix to unpack. Defaults to the newest one msbuild produced.
    # Signed or unsigned makes no difference: this only reads the contents.
    [string] $Msix,

    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PkgProj  = Join-Path $RepoRoot 'terminal\src\cascadia\CascadiaPackage'
$DistDir  = Join-Path $RepoRoot 'dist'
$Upstream = Join-Path $RepoRoot 'terminal\build\scripts\New-UnpackagedTerminalDistribution.ps1'

if (-not (Test-Path $Upstream)) { throw "upstream packaging script not found at $Upstream" }

# --- Inputs -------------------------------------------------------------------
if (-not $Msix) {
    $found = Get-ChildItem (Join-Path $PkgProj 'AppPackages') -Recurse -Filter *.msix -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $found) { throw "no .msix under $PkgProj\AppPackages - build the package project first" }
    $Msix = $found.FullName
}

# The XAML framework package ships beside the app package as a build
# dependency. It is an input here rather than a shipped asset: the portable
# layout needs its DLL and resources copied *in*, which is a different thing
# from asking the installing machine to have the framework.
$xaml = Get-ChildItem (Join-Path $PkgProj 'AppPackages') -Recurse -Filter 'Microsoft.UI.Xaml.*.appx' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'x64' } | Select-Object -First 1
if (-not $xaml) { throw 'Microsoft.UI.Xaml.*.appx (x64) not found under AppPackages - run a NuGet restore' }

$sdkBin = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory -ErrorAction SilentlyContinue |
    Where-Object Name -match '^10\.' | Sort-Object Name -Descending | Select-Object -First 1
$makeappx = Join-Path $sdkBin.FullName 'x64\makeappx.exe'
if (-not (Test-Path $makeappx)) { throw "makeappx.exe not found at $makeappx" }

Write-Host "terminal  $(Split-Path -Leaf $Msix)" -ForegroundColor Cyan
Write-Host "xaml      $($xaml.Name)" -ForegroundColor Cyan

# --- Build --------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

# -PortableMode is explicit on purpose: in the AppX parameter set the upstream
# script defaults it to false, so without this the zip is an unpackaged build
# that still keeps its settings in %LOCALAPPDATA%, which is not what is wanted
# from something called portable.
$zip = & $Upstream -TerminalAppX $Msix -XamlAppX $xaml.FullName `
    -MakeAppxPath $makeappx -PortableMode -Destination $DistDir 6>$null

if (-not $zip) { throw 'upstream script produced no zip' }

# Rename to match the msix asset rather than upstream's
# <PackageName>_<version>_<arch> convention, so a release page reads as one set
# of files.
$manifestVersion = [regex]::Match($zip.Name, '_(\d+\.\d+\.\d+\.\d+)_').Groups[1].Value
$final = Join-Path $DistDir "winterm-ghostty-$manifestVersion-x64-portable.zip"
Move-Item $zip.FullName $final -Force

Write-Host ''
Write-Host ('  {0,-46} {1,12:N0} bytes' -f (Split-Path -Leaf $final), (Get-Item $final).Length) -ForegroundColor Green
