<#
.SYNOPSIS
    Print what a ghostty pane was handed for each key, while someone types.

.DESCRIPTION
    KD-25. Two attempts to infer this from outside were wrong: the pane's
    behaviour is consistent with several different events, and only the pane
    can say which one arrived. A remote desktop client may deliver a character
    as a VK_PACKET whose scan code is the code point rather than as a key
    press, and the two are indistinguishable from the bytes the child receives.

    Launches a portable build with GHOSTTY_TRACE_KEYS set - the trace is
    compiled in but off without it, since it costs a debugger round trip per
    keystroke - and prints every `[ghostty] key ...` line for as long as asked.

    The window stays open so a human (or a phone, over Remote Desktop) can type
    into it. Close it yourself when the run is over.

    Only one process on the machine may own the DBWIN buffer, so this fails
    rather than half-works if DebugView or another probe has it.

.EXAMPLE
    .\probe-key-trace.ps1 -PortableRoot C:\tmp\wtfix\terminal-0.1.0.0 -Seconds 300
#>
[CmdletBinding()]
param(
    # The directory holding WindowsTerminal.exe.
    [Parameter(Mandatory)][string]$PortableRoot,
    [int]$Seconds = 300,
    # Profile to open. Anything works - this reads keys, not output.
    [string]$Profile = 'gh'
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path $PortableRoot).Path
$exe = Join-Path $root 'WindowsTerminal.exe'
if (-not (Test-Path $exe)) { throw "no WindowsTerminal.exe under $root" }

Add-Type @'
using System;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class DbWinKeys : IDisposable
{
    private EventWaitHandle _bufferReady;
    private EventWaitHandle _dataReady;
    private MemoryMappedFile _mmf;
    private MemoryMappedViewAccessor _view;

    public bool Open()
    {
        bool created;
        _bufferReady = new EventWaitHandle(false, EventResetMode.AutoReset, "DBWIN_BUFFER_READY", out created);
        if (!created) { return false; }
        _dataReady = new EventWaitHandle(false, EventResetMode.AutoReset, "DBWIN_DATA_READY", out created);
        _mmf = MemoryMappedFile.CreateOrOpen("DBWIN_BUFFER", 4096);
        _view = _mmf.CreateViewAccessor();
        _bufferReady.Set();
        return true;
    }

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

$w = New-Object DbWinKeys
if (-not $w.Open()) { throw 'another process owns the DBWIN buffer - close DebugView or the other probe and retry' }

try
{
    $env:GHOSTTY_TRACE_KEYS = '1'
    Start-Process $exe -ArgumentList @('-w', 'new', '-p', "`"$Profile`"") | Out-Null
    Write-Host "window opening; tracing keys for $Seconds s - type into it now" -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline)
    {
        $line = $w.Read(500)
        if (-not $line) { continue }
        if ($line -notmatch '\[ghostty\] key ') { continue }
        Write-Host $line.Trim()
    }
}
finally
{
    # Leaking the listener costs every writer on the machine ten seconds a call.
    $w.Dispose()
    Remove-Item Env:\GHOSTTY_TRACE_KEYS -ErrorAction SilentlyContinue
}
