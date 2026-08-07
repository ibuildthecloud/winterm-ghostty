<#
.SYNOPSIS
    Export the forks' `windows` branches as patch series into <fork>-patches/.

.DESCRIPTION
    ADR 0004: a fork is an ordered, rebasable patch series, and this repo tracks the
    exported patches rather than the clone. The clones are gitignored, so these files are
    the durable, reviewable form of the forks - each must always be reconstructable from
    *recorded upstream pin + these patches*.

    Both forks, by default. Exporting only ghostty was the original shape, and it meant
    that for months the Windows Terminal side - the `engine` setting, the IControlCore
    seam, GhosttyControlCore, every fix found by hand - existed nowhere but one developer's
    disk. A published repo that cannot build the thing it documents is worse than no
    published repo.

    The base commit is derived, not hardcoded: it is the merge-base of `windows` and the
    upstream branch, so this keeps working after a rebase onto a new pin.

    Stale patch files are removed first, otherwise a renamed or dropped patch would linger
    and the directory would stop matching the branch.

.EXAMPLE
    .\scripts\export-patches.ps1
    .\scripts\export-patches.ps1 -Fork terminal
    .\scripts\export-patches.ps1 -Check      # verify the exports are current; non-zero if not
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'ghostty', 'terminal')]
    [string] $Fork = 'all',

    [string] $Branch = 'windows',
    [string] $Upstream = 'main',

    # Do not write anything; fail if any <fork>-patches/ is out of date with its branch.
    # Intended for a pre-commit or CI check.
    [switch] $Check
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$forks = @(
    @{ Name = 'ghostty'; Clone = Join-Path $RepoRoot 'ghostty'; Out = Join-Path $RepoRoot 'ghostty-patches' }
    @{ Name = 'terminal'; Clone = Join-Path $RepoRoot 'terminal'; Out = Join-Path $RepoRoot 'terminal-patches' }
) | Where-Object { $Fork -eq 'all' -or $_.Name -eq $Fork }

$stale = @()

foreach ($f in $forks) {
    if (-not (Test-Path $f.Clone)) {
        # A missing clone is not a failure when exporting everything: a machine may only
        # have one of the two. Asking for it by name and not having it is.
        if ($Fork -eq 'all') {
            Write-Host "$($f.Name)/ not present - skipping" -ForegroundColor DarkYellow
            continue
        }
        throw "$($f.Name)/ clone not found at $($f.Clone)"
    }

    $base = (& git -C $f.Clone merge-base $Upstream $Branch).Trim()
    if (-not $base) { throw "could not determine merge-base of $Upstream and $Branch in $($f.Name)/" }

    $count = [int](& git -C $f.Clone rev-list --count "$base..$Branch").Trim()
    Write-Host "$($f.Name): base $base, $count patch$(if ($count -ne 1) {'es'})" -ForegroundColor DarkGray

    # Export to a temp dir first so -Check never mutates the tracked directory, and so a
    # failed export cannot leave the patch directory half-written.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gp-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        # --zero-commit and --no-signature keep the output stable across re-exports, so an
        # unchanged branch produces a byte-identical directory and -Check is meaningful.
        & git -C $f.Clone format-patch --no-numbered --zero-commit --no-signature `
            -o $tmp "$base..$Branch" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git format-patch failed for $($f.Name) ($LASTEXITCODE)" }

        $new = Get-ChildItem $tmp -Filter *.patch | Sort-Object Name
        $old = if (Test-Path $f.Out) { Get-ChildItem $f.Out -Filter *.patch | Sort-Object Name } else { @() }

        $identical =
            ($new.Count -eq $old.Count) -and
            -not (Compare-Object $new.Name $old.Name) -and
            -not ($new | Where-Object {
                $o = Join-Path $f.Out $_.Name
                (-not (Test-Path $o)) -or
                ((Get-FileHash $_.FullName).Hash -ne (Get-FileHash $o).Hash)
            })

        if ($Check) {
            if ($identical) {
                Write-Host "  $(Split-Path $f.Out -Leaf)/ is up to date" -ForegroundColor Green
            }
            else {
                Write-Host "  $(Split-Path $f.Out -Leaf)/ is STALE" -ForegroundColor Red
                $stale += $f.Name
            }
            continue
        }

        if ($identical) {
            Write-Host "  $(Split-Path $f.Out -Leaf)/ already up to date" -ForegroundColor Green
            continue
        }

        New-Item -ItemType Directory -Force $f.Out | Out-Null
        Get-ChildItem $f.Out -Filter *.patch | Remove-Item -Force   # drop stale/renamed patches
        Copy-Item (Join-Path $tmp '*.patch') $f.Out

        Write-Host "  exported $($new.Count) to $(Split-Path $f.Out -Leaf)/" -ForegroundColor Green
    }
    finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

if ($Check -and $stale.Count -gt 0) {
    Write-Host "`nrun .\scripts\export-patches.ps1 - stale: $($stale -join ', ')" -ForegroundColor Red
    exit 1
}
