# Watch whether a ghostty pane raises a desktop notification, with the
# profile's compatibility.allowOSC777 on and off.
#
# A notification that is suppressed looks exactly like one that was never
# raised, so the observable is GhosttyControlCore's trace on the debugger
# channel rather than the toast: it says the action reached WT, which is the
# only part of the chain this fork owns. Everything after it - the toast, the
# rate limit, the focus rule - is TerminalPage's, shared with cascadia.
param(
    # The unpacked portable build to drive: the folder holding
    # WindowsTerminal.exe, as produced by package-portable.ps1.
    [Parameter(Mandatory = $true)][string] $PortableRoot,
    # The value to write into the profile's compatibility.allowOSC777. Run it
    # both ways: "it did not notify" is only evidence next to "it did".
    [Parameter(Mandatory = $true)][bool] $Allow,
    [int] $Seconds = 14
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $PortableRoot).Path
$exe = Join-Path $root 'WindowsTerminal.exe'
if (-not (Test-Path $exe)) { throw "no WindowsTerminal.exe under $root" }
$settingsDir = Join-Path $root 'settings'
$sp = $settingsDir

Add-Type @'
using System;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class DbWin2 : IDisposable
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

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class N {
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(
        IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out UIntPtr res);
    public const uint WM_CLOSE = 0x0010;
}
'@

# The pane's whole job: one OSC 777 with a title and a body of known lengths,
# then idle so the window is still there to close.
$emit = Join-Path $sp 'osc777.ps1'
$lines = @(
    '$e = [char]27'
    '[Console]::Write("$e]777;notify;NotifyTitle;NotifyBodyText$e\")'
    'Start-Sleep -Seconds 600'
)
Set-Content -Path $emit -Value $lines -Encoding ascii

$allowJson = if ($Allow) { 'true' } else { 'false' }
$settings = @"
{
    "`$schema": "https://aka.ms/terminal-profiles-schema",
    "initialCols": 100,
    "initialRows": 25,
    "defaultProfile": "{b1a2c3d4-0000-4000-8000-00000000cafe}",
    "profiles": {
        "defaults": { "engine": "ghostty" },
        "list": [
            {
                "guid": "{b1a2c3d4-0000-4000-8000-00000000cafe}",
                "name": "notify probe",
                "compatibility.allowOSC777": $allowJson,
                "commandline": "powershell.exe -NoLogo -NoProfile -File \"$($emit -replace '\\','\\\\')\""
            }
        ]
    }
}
"@
New-Item -ItemType Directory -Force $settingsDir | Out-Null
Set-Content -Path (Join-Path $settingsDir 'settings.json') -Value $settings -Encoding utf8

$w = New-Object DbWin2
if (-not $w.Open()) { throw 'another process owns the DBWIN buffer - close DebugView and retry' }

$hits = @()
$sawGhostty = $false
$proc = $null
try {
    $before = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | ForEach-Object Id)
    Start-Process $exe
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $line = $w.Read(500)
        if (-not $line) { continue }
        if ($line -notmatch '\[ghostty\]') { continue }
        $sawGhostty = $true
        if ($line -match 'notification title=') { $hits += $line.Trim() }
    }
    $proc = Get-Process WindowsTerminal | Where-Object { $before -notcontains $_.Id -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
finally {
    $w.Dispose()
}

if ($proc) {
    $res = [UIntPtr]::Zero
    [void][N]::SendMessageTimeout($proc.MainWindowHandle, [N]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero, 0, 8000, [ref]$res)
    $proc.WaitForExit(15000) | Out-Null
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
}

"allowOSC777=$allowJson  ghostty traces seen: $sawGhostty  notification traces: $($hits.Count)"
$hits | ForEach-Object { "  $_" }
if (-not $sawGhostty) { "INCONCLUSIVE - no [ghostty] traces at all, so nothing was observed"; exit 2 }
if ($Allow) {
    if ($hits.Count -ge 1) { 'PASS - the pane raised the notification' } else { 'FAIL - allowed, but nothing was raised'; exit 1 }
}
else {
    if ($hits.Count -eq 0) { 'PASS - the profile refused it and nothing was raised' } else { 'FAIL - refused, but it was raised anyway'; exit 1 }
}
