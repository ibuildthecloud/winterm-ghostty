<#
.SYNOPSIS
    Re-stack the ghostty `windows` patch series onto a new upstream pin.

.DESCRIPTION
    ADR 0004 keeps the fork as an ordered, rebasable series against upstream `main`, and
    requires that **each patch leaves the tree building and passing `zig build test` on
    Windows**. A rebase that silently breaks patch 3 of 7 is the failure mode this script
    exists to catch, so -Verify replays the series one commit at a time and builds each.

    Safety:
      * refuses to run with a dirty working tree
      * tags the pre-rebase tip (`rebase-backup/<timestamp>`) so the old series is
        always recoverable - a rebase is destructive to branch history
      * never pushes anything (the fork is local-only per the Phase 0 retro)

    After a successful rebase, re-export with scripts\export-patches.ps1 and update the
    pin recorded in DESIGN.md. Per AGENTS.md, only advance a pin during a readiness or
    retro step.

.EXAMPLE
    .\scripts\rebase-upstream.ps1 -Pin origin/main -Verify
    .\scripts\rebase-upstream.ps1 -Pin 1a2b3c4 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Commit-ish to rebase onto. Fetched first if it looks like a remote ref.
    [Parameter(Mandatory = $true)]
    [string] $Pin,

    [string] $Branch = 'windows',

    # Build + test at every commit in the series, not just the tip.
    [switch] $Verify
)

$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$GhosttyRoot = Join-Path $RepoRoot 'ghostty'
if (-not (Test-Path $GhosttyRoot)) { throw "ghostty/ clone not found at $GhosttyRoot" }

function Git { & git -C $GhosttyRoot @args }

if (Git status --porcelain) { throw "ghostty/ working tree is dirty - commit or stash first." }

Git fetch origin --tags
if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }

$target = (Git rev-parse --verify "$Pin^{commit}").Trim()
$oldTip = (Git rev-parse --verify $Branch).Trim()
$oldBase = (Git merge-base $oldTip $target).Trim()

$patches = (Git rev-list --count "$oldBase..$Branch").Trim()
Write-Host "branch     $Branch @ $oldTip"
Write-Host "new pin    $target"
Write-Host "replaying  $patches patch(es)"

if (-not $PSCmdlet.ShouldProcess("$Branch", "rebase onto $target")) { return }

$backup = "rebase-backup/$(Git rev-parse --short $oldTip)"
Git tag -f $backup $oldTip | Out-Null
Write-Host "backup tag $backup" -ForegroundColor DarkGray

Git checkout $Branch
Git rebase --onto $target $oldBase $Branch
if ($LASTEXITCODE -ne 0) {
    Write-Host @"

Rebase stopped with conflicts. Resolve them, then:
    git -C ghostty rebase --continue      # or --abort to bail out
The pre-rebase tip is preserved at tag $backup.
"@ -ForegroundColor Yellow
    exit 1
}

Write-Host "`nrebased $Branch onto $target" -ForegroundColor Green

if ($Verify) {
    $commits = Git rev-list --reverse "$target..$Branch"
    $i = 0
    foreach ($c in $commits) {
        $i++
        $subject = Git log -1 --format='%s' $c
        Write-Host "`n[$i/$($commits.Count)] $($c.Substring(0,9))  $subject" -ForegroundColor Cyan
        Git checkout --detach $c | Out-Null
        & (Join-Path $PSScriptRoot 'build-ghostty.ps1')
        if ($LASTEXITCODE -ne 0) { Git checkout $Branch | Out-Null; throw "patch $i does not build - ADR 0004 violated" }
        & (Join-Path $PSScriptRoot 'build-ghostty.ps1') -Test
        if ($LASTEXITCODE -ne 0) { Git checkout $Branch | Out-Null; throw "patch $i fails zig build test - ADR 0004 violated" }
    }
    Git checkout $Branch | Out-Null
    Write-Host "`nall $($commits.Count) patch(es) build and pass tests" -ForegroundColor Green
}

Write-Host @"

Next:
  .\scripts\export-patches.ps1     # refresh the tracked series
  update the pin in DESIGN.md      # readiness/retro step only (AGENTS.md)
"@ -ForegroundColor DarkGray
