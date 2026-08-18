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

    # Zig target triple. Pinned, NOT the host, and that is the point.
    #
    # ghostty's build.zig calls b.standardTargetOptions(), so with no -Dtarget
    # Zig resolves the *build machine's* native CPU - upstream's own comment
    # beside it notes it returns something specific like `apple_a15` rather than
    # a generic model. Every build was therefore tuned to whatever hardware
    # produced it, which makes the artifact unreproducible across machines and
    # can emit instructions a downloader's CPU does not have.
    #
    # It stopped being theoretical in v0.2.0: the CI-built libghostty crashed
    # with STATUS_STACK_OVERFLOW on a font-size change, while a local build of
    # the identical commit did not. Same source, same flags, different machine
    # (KD-07).
    [string] $Target = 'x86_64-windows-msvc',

    # CPU feature baseline. `baseline` is the conservative x86_64 floor - it
    # runs anywhere, which is what a public download has to do.
    #
    # Raising this to x86_64_v2/v3 would buy codegen at the cost of excluding
    # older machines. Do not raise it without re-running the Phase 7 throughput
    # measurements: those numbers were taken on native-CPU builds and do not
    # transfer.
    [string] $Cpu = 'baseline',

    # The font backend, which decides discovery *and* rasterization (ADR 0005).
    #
    # This is a parameter with a default rather than something the caller
    # remembers to pass, because for months it was the latter and the two
    # builds silently disagreed: release.yml passed
    # -Dfont-backend=directwrite_harfbuzz while this script passed nothing, so
    # `zig build` fell through to ghostty's own Windows default,
    # `freetype_windows`. Every local build - and so every dev package, every
    # capture, every by-hand check - ran FreeType rasterization and a
    # C:\Windows\Fonts directory scan, while what shipped ran DirectWrite and
    # the system fallback chain. Two different font stacks, one of them never
    # exercised by the person testing it.
    #
    # Pass '' to build ghostty's default instead, which is the only way to
    # reproduce that older behaviour deliberately.
    [string] $FontBackend = 'directwrite_harfbuzz',

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
if ($Cpu)       { $zigArgs += "-Dcpu=$Cpu" }
if ($FontBackend) { $zigArgs += "-Dfont-backend=$FontBackend" }
if ($Rest)      { $zigArgs += $Rest }

Push-Location $GhosttyRoot
try {
    Write-Host "zig $($zigArgs -join ' ')" -ForegroundColor Cyan
    & zig @zigArgs
    if ($LASTEXITCODE -ne 0) { throw "zig build failed with exit code $LASTEXITCODE" }
}
finally { Pop-Location }

# --- Import library -----------------------------------------------------------
# Zig emits ghostty-internal.dll but no import library for it (only libghostty-vt
# gets one), so anything that links against it has to synthesize one from the
# export table. Doing that here rather than in each consumer means the harness
# and the Windows Terminal fork share one artifact and cannot drift.
#
# The LIBRARY line is load-bearing: without it `lib` names the import after the
# .def file, and consumers would search for "ghostty.def.dll" at load time and
# die with STATUS_DLL_NOT_FOUND rather than a link error.
if (-not $Test) {
    $libDir = Join-Path $GhosttyRoot 'zig-out\lib'
    $dll    = Join-Path $libDir 'ghostty-internal.dll'
    $implib = Join-Path $libDir 'ghostty.lib'
    $def    = Join-Path $libDir 'ghostty.def'

    if (Test-Path $dll) {
        $stale = -not (Test-Path $implib) -or
                 ((Get-Item $dll).LastWriteTime -gt (Get-Item $implib).LastWriteTime)
        if ($stale) {
            $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
            $vsRoot  = & $vswhere -latest -prerelease -products * -property installationPath
            $vcvars  = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
            if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found at $vcvars" }

            Write-Host "`ngenerating import library ghostty.lib" -ForegroundColor Cyan
            $exports = cmd /c "`"$vcvars`" >nul 2>&1 && dumpbin /EXPORTS `"$dll`""
            $names = $exports |
                Select-String -Pattern '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)' |
                ForEach-Object { $_.Matches[0].Groups[1].Value } |
                Where-Object { $_ -like 'ghostty_*' } |
                Sort-Object -Unique
            if (-not $names) { throw "no ghostty_* exports found in $dll" }

            Set-Content -Path $def -Encoding ascii -Value (
                @("LIBRARY $(Split-Path -Leaf $dll)", 'EXPORTS') +
                ($names | ForEach-Object { "    $_" }))

            cmd /c "`"$vcvars`" >nul 2>&1 && lib /NOLOGO /DEF:`"$def`" /OUT:`"$implib`" /MACHINE:X64"
            if ($LASTEXITCODE -ne 0) { throw "lib /DEF failed ($LASTEXITCODE)" }
            Write-Host "  $($names.Count) exports" -ForegroundColor DarkGray
        }
    }
}

if (-not $Test) {
    $out = Join-Path $GhosttyRoot 'zig-out'
    Write-Host "`nArtifacts in $out :" -ForegroundColor Green
    Get-ChildItem $out -Recurse -Include *.dll, *.lib, *.pdb, ghostty.h -ErrorAction SilentlyContinue |
        ForEach-Object { '  {0}  ({1:N0} bytes)' -f $_.FullName.Substring($out.Length + 1), $_.Length }
}
