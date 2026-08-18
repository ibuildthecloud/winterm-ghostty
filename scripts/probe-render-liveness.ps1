<#
.SYNOPSIS
    Watch libghostty's render stage counters and report a stall.

.DESCRIPTION
    The liveness property this answers is "after something changes, pixels
    follow" - the thing KD-19's fix has to preserve now that the UI thread no
    longer forces a frame itself.

    `render_diag` counts four stages, and reports them **from the cursor blink
    timer** rather than from the render path, which is the whole point: a report
    emitted by rendering goes quiet exactly when rendering stops. So a freeze
    shows up as `notify` climbing while `present` stands still.

        notify   Surface.queueRender      someone asked for a render
        wakeup   Thread.wakeupCallback    the render thread woke
        update   Thread.renderCallback    terminal state was sampled
        present  D3D11.present            pixels reached the swap chain

    The lines go to OutputDebugString, because a packaged Windows Terminal has
    no stdout. This reads them straight out of the DBWIN shared buffer and
    prints per-second deltas, so `notify +3 present +0` is visible as a stall
    without staring at running totals.

    Only one process may own the DBWIN buffer, so close DebugView first.

    Two things will make this say nothing at all, and it says so rather than
    reporting a clean run: the variable is read once and cached, so the terminal
    must have been *started* with it set; and the report is emitted from the
    cursor blink timer, which only runs while a surface is focused. Watch a pane
    you are actually using.

.EXAMPLE
    .\scripts\probe-render-liveness.ps1 -Launch -Profile Ubuntu
    # then drive the pane by hand and watch the deltas

.EXAMPLE
    .\scripts\probe-render-liveness.ps1 -Seconds 30
    # attach to a terminal already started with GHOSTTY_RENDER_DIAG=1
#>
[CmdletBinding()]
param(
    # Start the dev package with the diagnostic enabled. Without this, the
    # terminal must already have been started with GHOSTTY_RENDER_DIAG=1 -
    # the variable is read once, on first use, and cached.
    [switch] $Launch,

    [string] $ProfileName = 'Ubuntu',

    [int] $Seconds = 60
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class DbWin : IDisposable
{
    // The classic OutputDebugString transport: a 4KB shared section whose first
    // DWORD is the writing process id, followed by the ANSI string, with two
    // events for handshaking.
    private EventWaitHandle _bufferReady;
    private EventWaitHandle _dataReady;
    private MemoryMappedFile _mmf;
    private MemoryMappedViewAccessor _view;

    public bool Open()
    {
        bool created;
        _bufferReady = new EventWaitHandle(false, EventResetMode.AutoReset, "DBWIN_BUFFER_READY", out created);
        if (!created) { return false; }   // someone else owns it - DebugView?
        _dataReady = new EventWaitHandle(false, EventResetMode.AutoReset, "DBWIN_DATA_READY", out created);
        _mmf = MemoryMappedFile.CreateOrOpen("DBWIN_BUFFER", 4096);
        _view = _mmf.CreateViewAccessor();
        _bufferReady.Set();
        return true;
    }

    // Returns null on timeout.
    public string Read(int timeoutMs)
    {
        if (!_dataReady.WaitOne(timeoutMs)) { return null; }
        var bytes = new byte[4096 - 4];
        _view.ReadArray(4, bytes, 0, bytes.Length);
        int len = Array.IndexOf(bytes, (byte)0);
        if (len < 0) { len = bytes.Length; }
        string s = Encoding.Default.GetString(bytes, 0, len);
        _bufferReady.Set();
        return s;
    }

    public void Dispose()
    {
        if (_view != null) { _view.Dispose(); }
        if (_mmf != null) { _mmf.Dispose(); }
        if (_dataReady != null) { _dataReady.Dispose(); }
        if (_bufferReady != null) { _bufferReady.Dispose(); }
    }
}
'@ -ReferencedAssemblies System.IO.MemoryMappedFiles, System.Threading, System.Runtime.InteropServices

if ($Launch) {
    $env:GHOSTTY_RENDER_DIAG = '1'
    Start-Process wtgd.exe -ArgumentList "-w -1 new-tab -p `"$ProfileName`""
    Start-Sleep -Seconds 6
}

$w = New-Object DbWin
if (-not $w.Open()) {
    throw "another process owns the DBWIN buffer - close DebugView and retry"
}

Write-Host "watching for $Seconds s. Drive the pane; deltas are per report." -ForegroundColor Cyan
Write-Host "a stall is notify climbing while present does not.`n" -ForegroundColor DarkGray

$prev = @{ notify = 0; wakeup = 0; update = 0; present = 0 }
$deadline = (Get-Date).AddSeconds($Seconds)
$stalls = 0
$reports = 0

try {
    while ((Get-Date) -lt $deadline) {
        $line = $w.Read(1000)
        if (-not $line) { continue }
        if ($line -notmatch '\[ghostty-diag\]') { continue }
        $reports++

        $cur = @{}
        foreach ($m in [regex]::Matches($line, '(\w+)=(\d+)')) {
            $cur[$m.Groups[1].Value] = [int]$m.Groups[2].Value
        }
        $d = @{}
        foreach ($k in 'notify', 'wakeup', 'update', 'present') { $d[$k] = $cur[$k] - $prev[$k] }
        $prev = $cur

        # Nothing asked for a render: nothing to conclude, and saying so every
        # second would bury the interesting lines.
        if ($d.notify -eq 0 -and $d.present -eq 0) { continue }

        $stalled = ($d.notify -gt 0 -and $d.present -eq 0)
        if ($stalled) { $stalls++ }
        $colour = if ($stalled) { 'Red' } else { 'Green' }
        Write-Host ("{0:HH:mm:ss}  notify +{1,-4} wakeup +{2,-4} update +{3,-4} present +{4,-4} {5}" -f `
                (Get-Date), $d.notify, $d.wakeup, $d.update, $d.present, $(if ($stalled) { '<-- STALL' } else { '' })) `
            -ForegroundColor $colour
    }
}
finally {
    $w.Dispose()
    if ($Launch) { Remove-Item Env:\GHOSTTY_RENDER_DIAG -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($reports -eq 0) {
    Write-Host "no diagnostic lines arrived at all, so this run proves nothing." -ForegroundColor Yellow
    Write-Host "  - was the terminal started with GHOSTTY_RENDER_DIAG=1? it is read once and cached" -ForegroundColor DarkGray
    Write-Host "  - is the pane focused? the report rides the cursor blink timer" -ForegroundColor DarkGray
    Write-Host "  - is DebugView holding the DBWIN buffer?" -ForegroundColor DarkGray
    exit 2
}
Write-Host "$reports report(s) seen." -ForegroundColor DarkGray
if ($stalls -gt 0) {
    Write-Host "$stalls report(s) where a render was asked for and no frame was presented." -ForegroundColor Red
    exit 1
}
Write-Host "no stalls: every second that asked for a render also presented one." -ForegroundColor Green
