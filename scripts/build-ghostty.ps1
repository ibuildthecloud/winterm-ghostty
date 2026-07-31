<#
.SYNOPSIS
    Build libghostty from the ghostty/ clone with the pinned Zig toolchain.

.DESCRIPTION
    Wraps `zig build -Dapp-runtime=none`, which per build.zig emits libghostty
    (DLL + static) rather than an application executable.

.EXAMPLE
    .\scripts\build-ghostty.ps1                    # Debug libghostty for x64
    .\scripts\build-ghostty.ps1 -Optimize ReleaseFast
    .\scripts\build-ghostty.ps1 -Test              # zig build test
    .\scripts\build-ghostty.ps1 -Target aarch64-windows-msvc   # ARM64 cross-build
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string] $Optimize = 'Debug',

    # Zig target triple; empty means the host.
    [string] $Target = '',

    # Run `zig build test` instead of building the library.
    [switch] $Test,

    # Extra arguments passed straight through to `zig build`.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$GhosttyRoot = Join-Path $RepoRoot 'ghostty'

if (-not (Test-Path $GhosttyRoot)) {
    throw "ghostty/ clone not found at $GhosttyRoot. See PLAN.md Phase 0."
}

. (Join-Path $PSScriptRoot 'zigenv.ps1')

$zigArgs = @('build') + @(if ($Test) { 'test' })
$zigArgs += "-Doptimize=$Optimize"
if (-not $Test) { $zigArgs += '-Dapp-runtime=none' }
if ($Target)    { $zigArgs += "-Dtarget=$Target" }
if ($Rest)      { $zigArgs += $Rest }

Push-Location $GhosttyRoot
try {
    Write-Host "zig $($zigArgs -join ' ')" -ForegroundColor Cyan
    & zig @zigArgs
    if ($LASTEXITCODE -ne 0) { throw "zig build failed with exit code $LASTEXITCODE" }
}
finally { Pop-Location }

if (-not $Test) {
    $out = Join-Path $GhosttyRoot 'zig-out'
    Write-Host "`nArtifacts in $out :" -ForegroundColor Green
    Get-ChildItem $out -Recurse -Include *.dll, *.lib, *.pdb, ghostty.h -ErrorAction SilentlyContinue |
        ForEach-Object { '  {0}  ({1:N0} bytes)' -f $_.FullName.Substring($out.Length + 1), $_.Length }
}
