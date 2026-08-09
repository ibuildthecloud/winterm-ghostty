<#
.SYNOPSIS
    Exercise a built portable distribution the way a person would, and fail if
    it dies.

.DESCRIPTION
    This exists because v0.2.0 shipped broken. The pre-publish check at the time
    was "does it launch", the artifact launched, and it crashed on the first
    font-size change a user made (KD-07). Launching is not using.

    So this drives the actual artifact: focus it, type a command, zoom in and
    out, split a pane, and confirm the process is still alive and responding at
    the end. Every step is a thing that killed or could have killed a build.

    It is deliberately dumb about *what* it sees - there is no assertion on
    pixels here - because the failure being guarded against is a crash, and a
    crash needs no interpretation.

.EXAMPLE
    .\scripts\smoke-release.ps1 -Layout .\dist\extracted\terminal-0.2.1.0
    .\scripts\smoke-release.ps1 -Zip .\dist\winterm-ghostty-0.2.1.0-x64-portable.zip
#>
[CmdletBinding()]
param(
    # An extracted portable layout (the folder containing WindowsTerminal.exe).
    [string] $Layout,

    # Or the zip; it is extracted beside itself.
    [string] $Zip,

    # Force a ghostty pane. Without this the smoke test exercises the stock
    # engine and proves nothing about the thing this fork adds - which is
    # exactly how v0.2.0's crash was missed on the first two repro attempts.
    [switch] $NoGhostty,

    [string] $ShotDir
)

$ErrorActionPreference = 'Stop'

if (-not $Layout) {
    if (-not $Zip) { throw 'give -Layout or -Zip' }
    $dest = Join-Path (Split-Path -Parent (Resolve-Path $Zip)) 'smoke-extract'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive $Zip -DestinationPath $dest
    $Layout = (Get-ChildItem $dest -Directory | Select-Object -First 1).FullName
}
$exe = Join-Path $Layout 'WindowsTerminal.exe'
if (-not (Test-Path $exe)) { throw "WindowsTerminal.exe not found in $Layout" }

# Downloaded artifacts carry Mark-of-the-Web, which puts a security prompt in
# front of every launch and would hang an unattended run.
Get-ChildItem $Layout -Recurse -File | Unblock-File

if (-not $NoGhostty) {
    $sdir = Join-Path $Layout 'settings'
    New-Item -ItemType Directory -Force $sdir | Out-Null
    # Portable settings live in settings\, NOT beside the exe. A settings.json
    # dropped at the top level is silently ignored and the pane comes up
    # cascadia.
    #
    # The font is not incidental. A first version of this gate set only the
    # engine, so the pane came up on WT's default font and PASSED against a
    # build that had crashed minutes earlier under Cascadia Code - a ligature
    # font, which shapes down a different path. A smoke test that exercises the
    # safe path is worse than none, because it certifies.
    $cfg = @{
        profiles = @{
            defaults = @{
                engine      = 'ghostty'
                cursorShape = 'filledBox'
                font        = @{ face = 'Cascadia Code'; size = 11 }
            }
        }
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $sdir 'settings.json') -Encoding utf8
}

Add-Type @'
using System;using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public int pad0; public int pad1; }
public static class Smoke {
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int cb);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
  const uint KEYUP = 0x0002, UNICODE_FLAG = 0x0004;
  static void K(ushort vk, ushort sc, uint f){ INPUT[] a=new INPUT[1]; a[0].type=1; a[0].ki.wVk=vk; a[0].ki.wScan=sc; a[0].ki.dwFlags=f; SendInput(1,a,Marshal.SizeOf(typeof(INPUT))); }
  public static void Ch(char c){ INPUT[] a=new INPUT[1]; a[0].type=1; a[0].ki.wScan=(ushort)c; a[0].ki.dwFlags=UNICODE_FLAG; SendInput(1,a,Marshal.SizeOf(typeof(INPUT)));
                                 a[0].ki.dwFlags=UNICODE_FLAG|KEYUP; SendInput(1,a,Marshal.SizeOf(typeof(INPUT))); }
  public static void Enter(){ K(0x0D,0x1C,0); K(0x0D,0x1C,KEYUP); }
  public static void CtrlKey(ushort vk, ushort sc){ K(0x11,0x1D,0); K(vk,sc,0); K(vk,sc,KEYUP); K(0x11,0x1D,KEYUP); }
  public static void ZoomIn(){ CtrlKey(0xBB,0x0D); }   // ctrl + '='
  public static void ZoomOut(){ CtrlKey(0xBD,0x0C); }  // ctrl + '-'
  // ctrl+shift+d : split pane
  public static void SplitPane(){ K(0x11,0x1D,0); K(0x10,0x2A,0); K(0x44,0x20,0); K(0x44,0x20,KEYUP); K(0x10,0x2A,KEYUP); K(0x11,0x1D,KEYUP); }
}
'@

function Assert-Alive([System.Diagnostics.Process] $p, [string] $stage) {
    $q = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if (-not $q) {
        $p.WaitForExit()
        throw ("SMOKE FAILED at '{0}': process exited 0x{1:X8}{2}" -f $stage, $p.ExitCode,
               $(if ($p.ExitCode -eq -1073741571) { ' (STATUS_STACK_OVERFLOW)' } else { '' }))
    }
    Write-Host ("  ok  {0}" -f $stage) -ForegroundColor DarkGray
}

[void][Smoke]::AllowSetForegroundWindow(-1)
Write-Host "smoking $Layout" -ForegroundColor Cyan
$p = Start-Process $exe -PassThru
Start-Sleep -Seconds 12
Assert-Alive $p 'launch'

$hwnd = (Get-Process -Id $p.Id).MainWindowHandle
[void][Smoke]::ShowWindow($hwnd, 9)
for ($i = 0; $i -lt 12 -and [Smoke]::GetForegroundWindow() -ne $hwnd; $i++) {
    $o = [uint32]0
    $ft = [Smoke]::GetWindowThreadProcessId([Smoke]::GetForegroundWindow(), [ref]$o)
    [void][Smoke]::AttachThreadInput($ft, [Smoke]::GetCurrentThreadId(), $true)
    [void][Smoke]::BringWindowToTop($hwnd); [void][Smoke]::SetForegroundWindow($hwnd)
    [void][Smoke]::AttachThreadInput($ft, [Smoke]::GetCurrentThreadId(), $false)
    Start-Sleep -Milliseconds 300
}
if ([Smoke]::GetForegroundWindow() -ne $hwnd) { Stop-Process -Id $p.Id -Force; throw 'SMOKE FAILED: could not focus the window' }
Start-Sleep -Milliseconds 800

try {
    foreach ($c in 'echo smoke'.ToCharArray()) { [Smoke]::Ch($c); Start-Sleep -Milliseconds 60 }
    [Smoke]::Enter(); Start-Sleep -Milliseconds 800
    Assert-Alive $p 'typing'

    # The step that found KD-07. Zoom hard, not once.
    # 20, not a token few. KD-07 scales with the glyph size reached, so a
    # shallow zoom passes on the very build it is meant to reject: 12 presses
    # survived a binary that died on the 11th under a slightly different pane
    # size. Zoom until it is silly, then come back.
    for ($i = 0; $i -lt 20; $i++) { [Smoke]::ZoomIn(); Start-Sleep -Milliseconds 250; Assert-Alive $p "zoom in $($i+1)" }
    for ($i = 0; $i -lt 20; $i++) { [Smoke]::ZoomOut(); Start-Sleep -Milliseconds 250; Assert-Alive $p "zoom out $($i+1)" }

    [Smoke]::SplitPane(); Start-Sleep -Seconds 2
    Assert-Alive $p 'split pane'

    Start-Sleep -Seconds 2
    $q = Get-Process -Id $p.Id
    if (-not $q.Responding) { throw 'SMOKE FAILED: window stopped responding' }

    if ($ShotDir) {
        New-Item -ItemType Directory -Force $ShotDir | Out-Null
        $shot = Join-Path (Split-Path -Parent $PSScriptRoot) 'harness\wgc-shot\wgc-shot.exe'
        if (Test-Path $shot) { & $shot "hwnd:$([int64]$hwnd)" (Join-Path $ShotDir 'smoke.png') | Out-Null }
    }
    Write-Host 'SMOKE PASSED' -ForegroundColor Green
}
finally {
    $q = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if ($q) { Stop-Process -Id $q.Id -Force }
}
