<#
.SYNOPSIS
    Measure what a ghostty pane costs while its window is in the background.

.DESCRIPTION
    KD-04 asked whether an idle pane stops presenting when its window is not
    the active one. Answering it needs three things that are easy to get wrong,
    which is why this is a script rather than a recipe:

      1. **Proof of the engine.** With `profiles.defaults.engine = ghostty`,
         `ghostty-internal.dll` is loaded even for a cascadia pane, so the
         loaded-module check lies. `GhosttyControlCore::_trace` writes
         "[ghostty] ..." through OutputDebugString in every configuration, so a
         line on the DBWIN channel *from this pid* is the fact.

      2. **libghostty's own counters** (`GHOSTTY_RENDER_DIAG=1`,
         `renderer/render_diag.zig`): notify / wakeup / update / present. They
         are reported from the **cursor blink timer**, so their silence is
         itself a measurement - a stopped blink takes the report with it. The
         totals in the first line after the window comes back carry whatever
         accumulated meanwhile, which is how a silent period is read.

      3. **What state the window was actually in.** A synthetic
         SetForegroundWindow loses to a human at the keyboard: the foreground
         goes back to them and the terminal under test is never activated at
         all. That is not a broken probe - it is the interesting case, because
         a surface is born believing it is focused - but it has to be *known*
         rather than assumed, so the foreground window is read at every step
         and reported.

    Read the verdict against the phase the run actually achieved:

      - Window never activated: a fixed build shows a near-flat present count
        (only the handful from startup). ~2/sec is KD-04 - the pane believes it
        is focused, blinks, and pays a rebuild and a full-surface present for
        each blink.
      - Window activated, then deactivated: the blink must stop within a blink
        interval of losing activation. XAML does raise LostFocus for a control
        that had focus, so this half worked even before the fix.

.EXAMPLE
    .\scripts\probe-idle-focus.ps1
    .\scripts\probe-idle-focus.ps1 -ProfileName 'Command Prompt' -IdleSeconds 20
#>
[CmdletBinding()]
param(
    # A profile whose engine is ghostty. Explicit "engine" on the profile, not
    # inherited from profiles.defaults, or the run proves nothing about which
    # engine was measured.
    [string] $ProfileName = 'PowerShell',

    # How long to hold the window in the background.
    [int] $IdleSeconds = 15,

    # Seconds of settling before measuring; the shell has to reach a prompt.
    [int] $SettleSeconds = 8,

    # Blink reports per second above which the run is reported as KD-04. A
    # 600 ms blink reports 1.67/sec; a pane that is not blinking reports ~0.
    [double] $FailRatePerSecond = 0.5
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace Probe -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr res);
'@

# The DBWIN channel. Same shape as scripts\smoke-release.ps1 - the pid is not
# optional, because DBWIN is machine-global and every other Windows Terminal on
# the box writes to it too.
Add-Type @'
using System;using System.Threading;using System.Runtime.InteropServices;
using System.IO.MemoryMappedFiles;
public class IdleDbwin : IDisposable {
  MemoryMappedFile _mmf; MemoryMappedViewAccessor _view;
  EventWaitHandle _ready, _data; Thread _t; volatile bool _stop;
  public System.Collections.Concurrent.ConcurrentQueue<Tuple<long,uint,string>> Lines =
      new System.Collections.Concurrent.ConcurrentQueue<Tuple<long,uint,string>>();
  public bool Started;
  public IdleDbwin() {
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
      Lines.Enqueue(Tuple.Create(DateTime.UtcNow.Ticks, pid,
          System.Text.Encoding.Default.GetString(buf, 4, end - 4).TrimEnd('\r','\n')));
    }
  }
  public void Dispose() { _stop = true; try { _t.Join(800); } catch {} }
}
'@

function Get-MainHwnd([int]$procId) {
    $p = Get-Process -Id $procId
    for ($i = 0; $i -lt 40; $i++) {
        $p.Refresh()
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { return $p.MainWindowHandle }
        Start-Sleep -Milliseconds 250
    }
    throw "no main window for pid $procId"
}

function Get-Counters($lines, [uint32]$procId, [long]$notAfter = [long]::MaxValue) {
    $last = $lines | Where-Object {
        $_.Item2 -eq $procId -and $_.Item3 -match '\[ghostty-diag\]' -and $_.Item1 -le $notAfter
    } | Select-Object -Last 1
    if (-not $last) { return $null }
    if ($last.Item3 -notmatch 'notify=(\d+) wakeup=(\d+) update=(\d+) present=(\d+)') { return $null }
    [pscustomobject]@{
        T = $last.Item1; Notify = [int]$Matches[1]; Wakeup = [int]$Matches[2]
        Update = [int]$Matches[3]; Present = [int]$Matches[4]; Text = $last.Item3
    }
}

$dbwin = New-Object IdleDbwin
if (-not $dbwin.Started) { throw 'could not open the DBWIN channel; nothing can be measured' }

$env:GHOSTTY_RENDER_DIAG = '1'
try {
    $before = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    Start-Process wtgd.exe -ArgumentList @('-w', '-1', '-p', "`"$ProfileName`"")

    $newPid = $null
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        $now = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        $d = $now | Where-Object { $before -notcontains $_ }
        if ($d) { $newPid = $d[0]; break }
    }
    if (-not $newPid) { throw 'the fork did not start a new WindowsTerminal process' }
    $hwnd = Get-MainHwnd $newPid
    Write-Host "pid=$newPid hwnd=$([int64]$hwnd) profile='$ProfileName'" -ForegroundColor Cyan

    # Watch the foreground while the shell settles, so the phase this run
    # achieved is a record rather than an assumption.
    $everForeground = $false
    for ($i = 0; $i -lt ($SettleSeconds * 4); $i++) {
        if ([Probe.Win]::GetForegroundWindow() -eq $hwnd) { $everForeground = $true }
        Start-Sleep -Milliseconds 250
    }

    if ($everForeground) {
        # It was activated, so measure the deactivation half: put it behind
        # another window. mspaint deliberately - a packaged app's top-level
        # window does not belong to the launched pid.
        $paint = Start-Process mspaint.exe -PassThru
        $paintHwnd = Get-MainHwnd $paint.Id
        $fg = [Probe.Win]::GetForegroundWindow()
        $fgPid = [uint32]0
        $other = [Probe.Win]::GetWindowThreadProcessId($fg, [ref]$fgPid)
        [void][Probe.Win]::AttachThreadInput([Probe.Win]::GetCurrentThreadId(), $other, $true)
        [void][Probe.Win]::SetForegroundWindow($paintHwnd)
        [void][Probe.Win]::AttachThreadInput([Probe.Win]::GetCurrentThreadId(), $other, $false)
        Start-Sleep -Milliseconds 500
        $phase = 'activated, then put behind another window'
    } else {
        $paint = $null
        $phase = 'never activated (the foreground never came here)'
    }

    Start-Sleep -Milliseconds 1200
    $lines = @($dbwin.Lines.ToArray())
    $start = Get-Counters $lines $newPid
    $tStart = [DateTime]::UtcNow.Ticks

    Start-Sleep -Seconds $IdleSeconds
    $tIdleEnd = [DateTime]::UtcNow.Ticks

    # Bring it back: the counters ride home on the first blink report after
    # re-activation, which is the only way to read a period that was silent.
    $fg = [Probe.Win]::GetForegroundWindow()
    $fgPid = [uint32]0
    $other = [Probe.Win]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    [void][Probe.Win]::AttachThreadInput([Probe.Win]::GetCurrentThreadId(), $other, $true)
    [void][Probe.Win]::SetForegroundWindow($hwnd)
    [void][Probe.Win]::AttachThreadInput([Probe.Win]::GetCurrentThreadId(), $other, $false)
    $tEnd = [DateTime]::UtcNow.Ticks
    Start-Sleep -Seconds 3

    $lines = @($dbwin.Lines.ToArray())
    $end = Get-Counters $lines $newPid
    $traces = @($lines | Where-Object { $_.Item2 -eq $newPid -and $_.Item3 -match '\[ghostty\]' })

    if ($paint) { Stop-Process -Id $paint.Id -Force -ErrorAction SilentlyContinue }
    [IntPtr]$res = 0
    [void][Probe.Win]::SendMessageTimeoutW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 3000, [ref]$res)

    Write-Host ''
    if ($traces.Count -eq 0) {
        throw "no [ghostty] trace from pid $newPid - this window is NOT running the ghostty engine, so the run proves nothing. Give '$ProfileName' an explicit `"engine`": `"ghostty`"."
    }
    Write-Host "engine proven ghostty ($($traces.Count) trace lines from pid $newPid)" -ForegroundColor DarkGray
    Write-Host "phase: $phase"

    # The verdict comes from the reports that arrived *while the window was in
    # the background*, not from a before/after difference in the totals. Each
    # line is one tick of the cursor blink - the thing that wakes the renderer -
    # so counting them measures the defect directly, and it does not depend on
    # getting the window back in front at the end, which a synthetic
    # SetForegroundWindow cannot promise. An earlier version differenced the
    # totals and, when no line arrived after re-activation, "measured" 0 over
    # 0.0s and called it a pass.
    $all = @($lines | Where-Object { $_.Item2 -eq $newPid -and $_.Item3 -match '\[ghostty-diag\]' })
    $during = @($all | Where-Object { $_.Item1 -ge $tStart -and $_.Item1 -le $tIdleEnd })
    $before = @($all | Where-Object { $_.Item1 -lt $tStart })
    $after  = @($all | Where-Object { $_.Item1 -gt $tIdleEnd })
    $idleSpan = [TimeSpan]::FromTicks($tIdleEnd - $tStart).TotalSeconds
    $rate = if ($idleSpan -gt 0) { $during.Count / $idleSpan } else { 0 }

    Write-Host ("  blink reports:  {0} before  |  {1} during {2:N1}s in the background ({3:N2}/sec)  |  {4} after coming back" -f
                $before.Count, $during.Count, $idleSpan, $rate, $after.Count)
    if ($start) { Write-Host ("  last line before: {0}" -f $start.Text) }
    if ($end -and $after.Count -gt 0) {
        Write-Host ("  first line after : {0}" -f $end.Text)
        if ($start) {
            Write-Host ("  totals across the background period: +{0} present, +{1} wakeup, +{2} notify" -f
                        ($end.Present - $start.Present), ($end.Wakeup - $start.Wakeup), ($end.Notify - $start.Notify))
        }
    }
    Write-Host ''

    if ($rate -gt $FailRatePerSecond) {
        Write-Host ("KD-04: a background pane is still blinking and presenting ({0:N2}/sec)." -f $rate) -ForegroundColor Red
        exit 1
    }

    # Silence during the background period is the result we want, and it is also
    # what a diagnostic that never worked looks like. They are told apart by a
    # period where the pane *was* in front and did report - before backgrounding,
    # or after coming back. Without one of those this run proves nothing, and
    # says so rather than certifying. (A fixed build in a window the foreground
    # never reached blinks at no point in the run, so this is a real outcome, not
    # a corner case: it happens whenever a person is using the machine.)
    if ($before.Count -eq 0 -and $after.Count -eq 0) {
        Write-Host 'INCONCLUSIVE: the pane never blinked at any point in this run, so a silent' -ForegroundColor Yellow
        Write-Host 'background period cannot be distinguished from a diagnostic that never ran.' -ForegroundColor Yellow
        Write-Host 'The window has to be in front at some point. Re-run with nobody at the' -ForegroundColor Yellow
        Write-Host 'keyboard, or click the window yourself and use item 8 of docs\manual-validation.md.' -ForegroundColor Yellow
        exit 2
    }
    Write-Host ("ok: a background pane is idle - {0} blink reports in {1:N1}s, against {2} while in front." -f
                $during.Count, $idleSpan, ($before.Count + $after.Count)) -ForegroundColor Green
} finally {
    $dbwin.Dispose()
    Remove-Item Env:GHOSTTY_RENDER_DIAG -ErrorAction SilentlyContinue
}
