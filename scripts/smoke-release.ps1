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

    # Test at the window's natural size instead of maximized. Maximized is the
    # default because it is the worst case for anything that scales with the
    # pane.
    [switch] $NoMaximize,

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

# A disconnected session has no interactive desktop. SetForegroundWindow cannot
# succeed there, and DWM stops compositing so captures come back blank - but the
# symptom is "could not focus the window", which reads as a product failure and
# has sent this investigation the wrong way twice. Check first and say so.
$current = @(qwinsta 2>$null | Where-Object { $_ -match '^\s*>' })
if ($current.Count -gt 0 -and $current[0] -notmatch 'Active') {
    throw ("SMOKE SKIPPED: this session is not connected - '{0}'. " -f $current[0].Trim()) +
          'The gate drives a real window, so it needs an interactive desktop. Reconnect and re-run; nothing is wrong with the build.'
}

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
    # An explicit profile, made the default - NOT just profiles.defaults.
    #
    # Setting only profiles.defaults.engine was measured NOT to take: the pane
    # came up cascadia and the whole gate silently tested the wrong engine.
    # Naming a profile and pointing defaultProfile at it removes any dependence
    # on how defaults layer onto dynamically generated profiles.
    #
    # cmd.exe on purpose: always present, and it keeps the gate off WSL, which
    # a CI runner will not have.
    $cfg = @{
        '$schema'      = 'https://aka.ms/terminal-profiles-schema'
        defaultProfile = '{f6d2a1c4-7b3e-4a55-9c21-000000000001}'
        profiles       = @{
            defaults = @{ engine = 'ghostty' }
            list     = @(
                @{
                    guid        = '{f6d2a1c4-7b3e-4a55-9c21-000000000001}'
                    name        = 'smoke'
                    commandline = 'cmd.exe'
                    engine      = 'ghostty'
                    cursorShape = 'filledBox'
                    font        = @{ face = 'Cascadia Code'; size = 11 }
                }
            )
        }
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $sdir 'settings.json') -Encoding utf8
}

Add-Type @'
using System;using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public int pad0; public int pad1; }
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
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
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  const uint KEYUP = 0x0002, UNICODE_FLAG = 0x0004;
  static void K(ushort vk, ushort sc, uint f){ INPUT[] a=new INPUT[1]; a[0].type=1; a[0].ki.wVk=vk; a[0].ki.wScan=sc; a[0].ki.dwFlags=f; SendInput(1,a,Marshal.SizeOf(typeof(INPUT))); }
  public static void Ch(char c){ INPUT[] a=new INPUT[1]; a[0].type=1; a[0].ki.wScan=(ushort)c; a[0].ki.dwFlags=UNICODE_FLAG; SendInput(1,a,Marshal.SizeOf(typeof(INPUT)));
                                 a[0].ki.dwFlags=UNICODE_FLAG|KEYUP; SendInput(1,a,Marshal.SizeOf(typeof(INPUT))); }
  public static void Enter(){ K(0x0D,0x1C,0); K(0x0D,0x1C,KEYUP); }
  public static void CtrlKey(ushort vk, ushort sc){ K(0x11,0x1D,0); K(vk,sc,0); K(vk,sc,KEYUP); K(0x11,0x1D,KEYUP); }
  // A synthetic ALT tap releases Windows' foreground lock, which otherwise
  // refuses SetForegroundWindow while someone is using the machine. Without it
  // this gate can only run on an idle desktop.
  public static void AltTap(){ K(0x12,0x38,0); K(0x12,0x38,KEYUP); }
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
        # What was the engine doing when it died? These are the last calls it
        # traced, which is the difference between "it crashed somewhere" and a
        # place to look.
        if ($script:dbwin -and $script:dbwin.Started) {
            $tail = @($script:dbwin.Lines.ToArray() | Where-Object { $_.Item1 -eq $p.Id } |
                      Select-Object -Last 16 | ForEach-Object { $_.Item2.Trim() } |
                      Where-Object { $_ -and $_ -ne '[ghostty]' })
            if ($tail.Count) {
                Write-Host '  last engine activity before the crash:' -ForegroundColor Yellow
                $tail | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
            }
        }
        throw ("SMOKE FAILED at '{0}': process exited 0x{1:X8}{2}" -f $stage, $p.ExitCode,
               $(if ($p.ExitCode -eq -1073741571) { ' (STATUS_STACK_OVERFLOW)' } else { '' }))
    }
    Write-Host ("  ok  {0}" -f $stage) -ForegroundColor DarkGray
}


# --- Proof that a ghostty pane is actually under test ------------------------
#
# Without this the gate is worthless and worse than worthless, because it
# certifies. GhosttyControlCore::AdjustFontSize is a NO-OP, so zooming a real
# ghostty pane changes nothing and "20 zooms survived" is exactly what a
# cascadia pane looks like too. An earlier version of this script passed three
# builds in a row that way, one of which had crashed minutes before.
#
# GhosttyControlCore::_trace writes "[ghostty] ..." through OutputDebugString
# unconditionally, in every configuration. Listening on the DBWIN channel turns
# "is this the engine I think it is" into a fact.
Add-Type @'
using System;using System.Threading;using System.Runtime.InteropServices;
using System.IO.MemoryMappedFiles;
public class Dbwin : IDisposable {
  MemoryMappedFile _mmf; MemoryMappedViewAccessor _view;
  EventWaitHandle _ready, _data; Thread _t; volatile bool _stop;
  // (pid, text). The PID is NOT optional: DBWIN is a machine-global channel,
  // so without it this picks up every OutputDebugString on the box - including
  // any other Windows Terminal the developer happens to have running, which is
  // exactly how an earlier version of this gate "proved" the engine using
  // traces emitted by a different process.
  public System.Collections.Concurrent.ConcurrentQueue<Tuple<uint,string>> Lines =
      new System.Collections.Concurrent.ConcurrentQueue<Tuple<uint,string>>();
  public bool Started;
  public Dbwin() {
    try {
      _mmf = MemoryMappedFile.CreateOrOpen("DBWIN_BUFFER", 4096);
      _view = _mmf.CreateViewAccessor(0, 4096);
      bool created;
      _ready = new EventWaitHandle(false, EventResetMode.AutoReset, "DBWIN_BUFFER_READY", out created);
      _data  = new EventWaitHandle(false, EventResetMode.AutoReset, "DBWIN_DATA_READY", out created);
      _t = new Thread(Loop); _t.IsBackground = true; _t.Start();
      Started = true;
    } catch { Started = false; }
  }
  void Loop() {
    byte[] buf = new byte[4096];
    while (!_stop) {
      _ready.Set();
      if (!_data.WaitOne(500)) continue;
      _view.ReadArray(0, buf, 0, buf.Length);
      uint pid = BitConverter.ToUInt32(buf, 0);
      int end = 4; while (end < buf.Length && buf[end] != 0) end++;
      Lines.Enqueue(Tuple.Create(pid, System.Text.Encoding.Default.GetString(buf, 4, end - 4)));
    }
  }
  public void Dispose() { _stop = true; try { _t.Join(800); } catch {} }
}
'@
$dbwin = New-Object Dbwin
$script:dbwin = $dbwin
if (-not $dbwin.Started) { Write-Host '  WARNING: could not open the DBWIN channel; engine cannot be proven' -ForegroundColor Yellow }

[void][Smoke]::AllowSetForegroundWindow(-1)
Write-Host "smoking $Layout" -ForegroundColor Cyan
$p = Start-Process $exe -PassThru
Start-Sleep -Seconds 12
Assert-Alive $p 'launch'

# The engine assertion. A ghostty pane traces on construction and on every
# size push; a cascadia pane cannot produce these lines at all.
# Always assert, including when -NoGhostty left the layout's own settings in
# place. -NoGhostty means "do not rewrite the config", never "do not check";
# a gate that skips its own proof is the failure this whole exercise was about.
if ($dbwin.Started) {
    $seen = @($dbwin.Lines.ToArray())
    # Only this process. GhosttyControlCore::_trace is the sole emitter of
    # "[ghostty]", so a line from OUR pid means a ghostty core was constructed
    # for a pane in the window under test - and a line from any other pid means
    # nothing at all.
    $mine = @($seen | Where-Object { $_.Item1 -eq $p.Id -and $_.Item2 -match '\[ghostty\]' })
    $others = @($seen | Where-Object { $_.Item1 -ne $p.Id -and $_.Item2 -match '\[ghostty\]' })
    if ($others.Count -gt 0) {
        Write-Host ("  note: ignored {0} [ghostty] lines from other processes (pids {1})" -f
                    $others.Count, (($others | ForEach-Object { $_.Item1 } | Sort-Object -Unique) -join ',')) -ForegroundColor DarkYellow
    }
    if ($mine.Count -eq 0) {
        Stop-Process -Id $p.Id -Force
        $dbwin.Dispose()
        throw "SMOKE FAILED: no [ghostty] trace from pid $($p.Id) - this window is NOT running the ghostty engine, so the run proves nothing. Cross-check by hand: open the search box (ctrl+shift+f); on a ghostty pane the regex and case-sensitivity toggles are disabled."
    }
    Write-Host ("  ok  engine is ghostty ({0} trace lines from pid {1})" -f $mine.Count, $p.Id) -ForegroundColor DarkGray
}

# Wait for a window to exist before trying to focus it. MainWindowHandle is 0
# until the window is created, and reading it once - immediately - yields 0 on a
# cold layout, after which every focus attempt compares against 0 and "fails"
# for a reason that has nothing to do with the build.
$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 40; $i++) {
    $proc = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if (-not $proc) { break }
    $proc.Refresh()
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { $hwnd = $proc.MainWindowHandle; break }
    Start-Sleep -Milliseconds 500
}
if ($hwnd -eq [IntPtr]::Zero) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    throw 'SMOKE FAILED: the process never created a main window'
}
[void][Smoke]::ShowWindow($hwnd, 9)
# Patient on purpose: taking the foreground competes with whoever is using
# the machine, and losing that race is not a product failure. 30 x 500ms.
for ($i = 0; $i -lt 30 -and [Smoke]::GetForegroundWindow() -ne $hwnd; $i++) {
    $o = [uint32]0
    $ft = [Smoke]::GetWindowThreadProcessId([Smoke]::GetForegroundWindow(), [ref]$o)
    [void][Smoke]::AttachThreadInput($ft, [Smoke]::GetCurrentThreadId(), $true)
    [Smoke]::AltTap()
    [void][Smoke]::BringWindowToTop($hwnd); [void][Smoke]::SetForegroundWindow($hwnd)
    [void][Smoke]::AttachThreadInput($ft, [Smoke]::GetCurrentThreadId(), $false)
    Start-Sleep -Milliseconds 500
}
if ([Smoke]::GetForegroundWindow() -ne $hwnd) { Stop-Process -Id $p.Id -Force; throw 'SMOKE FAILED: could not focus the window' }
Start-Sleep -Milliseconds 800

# Maximize before zooming, and say how big that is.
#
# Window size is a variable, not a detail: KD-07 arrived at press 2 in one run,
# zoom 11 in another and never in a third, and the runs differed in pane size.
# A gate that tests whatever size the window happened to open at is measuring
# something different each time. Maximized is the worst case and the one a
# person is most likely to be in.
if (-not $NoMaximize) {
    [void][Smoke]::ShowWindow($hwnd, 3)   # SW_MAXIMIZE
    Start-Sleep -Milliseconds 1200
}
$rect = New-Object RECT
[void][Smoke]::GetWindowRect($hwnd, [ref]$rect)
Write-Host ("  window {0}x{1}{2}" -f ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top),
            $(if ($NoMaximize) { '' } else { ' (maximized)' })) -ForegroundColor DarkGray

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
    if ($dbwin) { $dbwin.Dispose() }
}
