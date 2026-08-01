<#
.SYNOPSIS
    Export the ghostty fork's `windows` branch as a patch series into ghostty-patches/.

.DESCRIPTION
    ADR 0004: the fork is an ordered, rebasable patch series, and this repo tracks the
    exported patches rather than the clone. The clone is gitignored, so these files are
    the durable, reviewable form of the fork - it must always be reconstructable from
    *recorded upstream pin + these patches*.

    The base commit is derived, not hardcoded: it is the merge-base of `windows` and the
    upstream branch, so this keeps working after a rebase onto a new pin.

    Stale patch files are removed first, otherwise a renamed or dropped patch would linger
    and the directory would stop matching the branch.

.EXAMPLE
    .\scripts\export-patches.ps1
    .\scripts\export-patches.ps1 -Check      # verify the export is current; non-zero if not
#>
[CmdletBinding()]
param(
    [string] $Branch = 'windows',
    [string] $Upstream = 'main',

    # Do not write anything; fail if ghostty-patches/ is out of date with the branch.
    # Intended for a pre-commit or CI check.
    [switch] $Check
)

$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$GhosttyRoot = Join-Path $RepoRoot 'ghostty'
$OutDir      = Join-Path $RepoRoot 'ghostty-patches'

if (-not (Test-Path $GhosttyRoot)) { throw "ghostty/ clone not found at $GhosttyRoot" }

$base = (& git -C $GhosttyRoot merge-base $Upstream $Branch).Trim()
if (-not $base) { throw "could not determine merge-base of $Upstream and $Branch" }

$count = [int](& git -C $GhosttyRoot rev-list --count "$base..$Branch").Trim()
Write-Host "base   $base" -ForegroundColor DarkGray
Write-Host "branch $Branch ($count patch$(if ($count -ne 1) {'es'}))" -ForegroundColor DarkGray

# Export to a temp dir first so -Check never mutates the tracked directory, and so a
# failed export cannot leave ghostty-patches/ half-written.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("gp-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    # --zero-commit and --no-signature keep the output stable across re-exports, so an
    # unchanged branch produces a byte-identical directory and the -Check below is meaningful.
    & git -C $GhosttyRoot format-patch --no-numbered --zero-commit --no-signature `
        -o $tmp "$base..$Branch" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git format-patch failed ($LASTEXITCODE)" }

    $new = Get-ChildItem $tmp -Filter *.patch | Sort-Object Name
    $old = if (Test-Path $OutDir) { Get-ChildItem $OutDir -Filter *.patch | Sort-Object Name } else { @() }

    $identical =
        ($new.Count -eq $old.Count) -and
        -not (Compare-Object $new.Name $old.Name) -and
        -not ($new | Where-Object {
            $o = Join-Path $OutDir $_.Name
            (-not (Test-Path $o)) -or
            ((Get-FileHash $_.FullName).Hash -ne (Get-FileHash $o).Hash)
        })

    if ($Check) {
        if ($identical) { Write-Host "ghostty-patches/ is up to date" -ForegroundColor Green; exit 0 }
        Write-Host "ghostty-patches/ is STALE - run .\scripts\export-patches.ps1" -ForegroundColor Red
        exit 1
    }

    if ($identical) {
        Write-Host "ghostty-patches/ already up to date" -ForegroundColor Green
        return
    }

    New-Item -ItemType Directory -Force $OutDir | Out-Null
    Get-ChildItem $OutDir -Filter *.patch | Remove-Item -Force   # drop stale/renamed patches
    Copy-Item (Join-Path $tmp '*.patch') $OutDir

    Write-Host "`nExported to ghostty-patches/:" -ForegroundColor Green
    Get-ChildItem $OutDir -Filter *.patch | ForEach-Object { '  {0}  ({1:N0} bytes)' -f $_.Name, $_.Length }
}
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
