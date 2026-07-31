# Dot-source this to put the pinned Zig toolchain on PATH for the current shell.
#   . .\scripts\zigenv.ps1
#
# The Zig version is pinned by ghostty's build.zig.zon (.minimum_zig_version) and
# flake.nix; see docs/sessions/0001-phase-0.md. Do not advance it outside a
# readiness/retro step (AGENTS.md).

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ZigVersion = '0.16.0'
$ZigDir     = Join-Path $RepoRoot "tools\zig-x86_64-windows-$ZigVersion"

if (-not (Test-Path (Join-Path $ZigDir 'zig.exe'))) {
    Write-Host "Zig $ZigVersion not found at $ZigDir - downloading..." -ForegroundColor Yellow
    $tools = Join-Path $RepoRoot 'tools'
    New-Item -ItemType Directory -Force $tools | Out-Null
    $zip = Join-Path $tools "zig-x86_64-windows-$ZigVersion.zip"
    Invoke-WebRequest -UseBasicParsing `
        -Uri "https://ziglang.org/download/$ZigVersion/zig-x86_64-windows-$ZigVersion.zip" `
        -OutFile $zip
    Expand-Archive $zip -DestinationPath $tools -Force
    Remove-Item $zip
}

if ($env:PATH -notlike "*$ZigDir*") { $env:PATH = "$ZigDir;$env:PATH" }

$script:GhosttyZigVersion = $ZigVersion
Write-Host "zig $(& zig version) from $ZigDir" -ForegroundColor Green
