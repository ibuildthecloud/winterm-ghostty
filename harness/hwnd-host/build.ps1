<#
.SYNOPSIS
    Build and optionally run the hwnd-host harness against libghostty.

.DESCRIPTION
    Phase 1's demonstrable deliverable: a minimal Win32 host that drives
    libghostty's embedded C API to put a D3D11-rendered surface on screen.

    The ghostty build emits `ghostty-internal.dll` but **no import library**
    for it (only libghostty-vt gets one), so this script synthesizes one from
    the DLL's export table via dumpbin -> .def -> lib. That keeps the harness
    free of LoadLibrary/GetProcAddress boilerplate without patching upstream's
    build just to serve a test host.

.EXAMPLE
    .\harness\hwnd-host\build.ps1              # build + run on hardware
    .\harness\hwnd-host\build.ps1 -Warp        # build + run forcing WARP
    .\harness\hwnd-host\build.ps1 -NoRun
#>
[CmdletBinding()]
param(
    [switch] $NoRun,
    # Force the software rasterizer, for the forced-WARP exit criterion.
    [switch] $Warp
)

$ErrorActionPreference = 'Stop'

$here        = $PSScriptRoot
$RepoRoot    = Split-Path -Parent (Split-Path -Parent $here)
$GhosttyOut  = Join-Path $RepoRoot 'ghostty\zig-out'
$dll         = Join-Path $GhosttyOut 'lib\ghostty-internal.dll'
$include     = Join-Path $GhosttyOut 'include'

if (-not (Test-Path $dll)) {
    throw "libghostty not built. Run .\scripts\build-ghostty.ps1 first (looked for $dll)."
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot  = & $vswhere -latest -prerelease -products * -property installationPath
$vcvars  = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found at $vcvars" }

# --- Synthesize the import library -------------------------------------------
# Only redo this when the DLL is newer than the .lib; dumpbin over a 43 MB DLL
# is not free.
$implib = Join-Path $here 'ghostty.lib'
$def    = Join-Path $here 'ghostty.def'
$needsImplib =
    -not (Test-Path $implib) -or
    ((Get-Item $dll).LastWriteTime -gt (Get-Item $implib).LastWriteTime)

if ($needsImplib) {
    Write-Host "generating import library from $(Split-Path -Leaf $dll)" -ForegroundColor Cyan
    $exports = cmd /c "`"$vcvars`" >nul 2>&1 && dumpbin /EXPORTS `"$dll`""
    $names = $exports |
        Select-String -Pattern '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Where-Object { $_ -like 'ghostty_*' } |
        Sort-Object -Unique

    if (-not $names) { throw "no ghostty_* exports found in $dll" }

    # The LIBRARY line is load-bearing: without it `lib` names the import
    # after the .def file, so the exe would search for "ghostty.dll" and die
    # at load with STATUS_DLL_NOT_FOUND (0xC0000135) rather than a link error.
    $content = @("LIBRARY $(Split-Path -Leaf $dll)", 'EXPORTS') +
               ($names | ForEach-Object { "    $_" })
    Set-Content -Path $def -Value $content -Encoding ascii
    Write-Host "  $($names.Count) exports" -ForegroundColor DarkGray

    cmd /c "`"$vcvars`" >nul 2>&1 && lib /NOLOGO /DEF:`"$def`" /OUT:`"$implib`" /MACHINE:X64"
    if ($LASTEXITCODE -ne 0) { throw "lib /DEF failed ($LASTEXITCODE)" }
}

# --- Compile ------------------------------------------------------------------
$exe = Join-Path $here 'hwnd-host.exe'
Write-Host 'cl main.c' -ForegroundColor Cyan
# Run from $here with plain relative names. Passing absolute /Fo and /Fd paths
# through two layers of quoting (PowerShell then cmd) is where this previously
# went wrong, and cl reports that as a bare exit 1 with no diagnostic.
# /STACK:16MB - a Debug-optimized Zig libghostty has very large stack frames,
# and ghostty_init alone overflows MSVC's default 1 MB main-thread stack
# (STATUS_STACK_OVERFLOW, 0xC00000FD). The reserve is virtual address space,
# not committed memory, so this costs nothing at runtime.
cmd /c "`"$vcvars`" >nul 2>&1 && cd /d `"$here`" && cl /nologo /W4 /Zi /I`"$include`" /Fe:hwnd-host.exe main.c /link /STACK:16777216 ghostty.lib user32.lib shcore.lib"
if ($LASTEXITCODE -ne 0) { throw "compile failed ($LASTEXITCODE)" }

# The DLL has to sit next to the exe (or on PATH) at load time.
Copy-Item $dll (Join-Path $here 'ghostty-internal.dll') -Force

Write-Host "built $exe" -ForegroundColor Green
if ($NoRun) { return }

if ($Warp) {
    $env:GHOSTTY_D3D11_DRIVER = 'warp'
    Write-Host 'GHOSTTY_D3D11_DRIVER=warp' -ForegroundColor Yellow
}
& $exe
