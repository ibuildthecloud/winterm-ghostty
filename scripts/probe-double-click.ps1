<#
.SYNOPSIS
    Double-click a word in a pane and report exactly what got selected.

.DESCRIPTION
    A double click selects a word, and "the highlight looks too wide" is not a
    measurement - `foo` and `foo ` differ by one blank cell on screen and by one
    byte in the answer. So the pane is opened with `copyOnSelect`, which puts the
    selection on the clipboard the moment it is made, and the clipboard is what
    this reports - delimited, so a trailing space is visible.

    Run it against a ghostty profile and a cascadia profile with the same text
    on screen: that pair is the whole diagnosis, because both panes get the same
    input through the same code above the engine seam.

    Needs the foreground, since a double click is real mouse input. It refuses
    rather than typing into whatever the user is looking at.

.EXAMPLE
    .\probe-double-click.ps1 -Root C:\tmp\wt\terminal-0.1.0.0 -Profile gh -Col 8
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Profile,
    # Which cell to click, in character cells from the pane's top-left.
    [int]$Row = 0,
    [int]$Col = 8,
    # Cell metrics and the first text row's offset inside the window. Defaults
    # measured on this machine at 150% scale; a screenshot is saved so a click
    # that landed on the wrong word is visible rather than silently believed.
    [int]$CellW = 13,
    [int]$CellH = 26,
    [int]$PaneTop = 78,
    [int]$PaneLeft = 6,
    [string]$Shot
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DblClick {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    // Without this, GetWindowRect and SetCursorPos speak *logical* pixels while
    // the window is laid out in physical ones, and every coordinate is off by
    // the display scale - 150% here, so the click lands nowhere near the cell.
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern uint GetDoubleClickTime();
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
    public static readonly IntPtr PER_MONITOR_V2 = new IntPtr(-4);
    public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
}
'@

[void][DblClick]::SetProcessDpiAwarenessContext([DblClick]::PER_MONITOR_V2)

$before = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Start-Process (Join-Path $Root 'WindowsTerminal.exe') -ArgumentList @('-w', 'new', '-p', "`"$Profile`"") | Out-Null
Start-Sleep -Seconds 7

$mine = Get-Process WindowsTerminal | Where-Object { $_.Id -notin $before -and $_.MainWindowHandle -ne 0 }
if (-not $mine) { throw 'no new terminal process appeared - another instance of this build took the window' }
$proc = $mine[0]
$hwnd = [IntPtr]$proc.MainWindowHandle

for ($i = 0; $i -lt 10; $i++) {
    if ([DblClick]::GetForegroundWindow() -eq $hwnd) { break }
    $fg = [DblClick]::GetForegroundWindow()
    $fgt = [DblClick]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
    $me = [DblClick]::GetCurrentThreadId()
    [void][DblClick]::AttachThreadInput($me, $fgt, $true)
    [void][DblClick]::SetForegroundWindow($hwnd)
    [void][DblClick]::AttachThreadInput($me, $fgt, $false)
    Start-Sleep -Milliseconds 300
}
if ([DblClick]::GetForegroundWindow() -ne $hwnd) { throw 'the window will not stay in front - a user has the keyboard' }

$r = New-Object DblClick+RECT
[void][DblClick]::GetWindowRect($hwnd, [ref]$r)
$x = $r.L + $PaneLeft + ($Col * $CellW) + [int]($CellW / 2)
$y = $r.T + $PaneTop + ($Row * $CellH) + [int]($CellH / 2)
Write-Host "window ($($r.L),$($r.T)) -> clicking cell ($Col,$Row) at ($x,$y)"

Set-Clipboard -Value 'PROBE-CLIPBOARD-UNSET'

[void][DblClick]::SetCursorPos($x, $y)
Start-Sleep -Milliseconds 300
# Two presses inside the system double-click time, at the same point.
[DblClick]::mouse_event([DblClick]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
[DblClick]::mouse_event([DblClick]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds ([Math]::Min(80, [DblClick]::GetDoubleClickTime() / 4))
[DblClick]::mouse_event([DblClick]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
[DblClick]::mouse_event([DblClick]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 700

# The pointer composes into a capture, so park it off the window first.
[void][DblClick]::SetCursorPos($r.L + 5, $r.T + 5)
Start-Sleep -Milliseconds 200

if ($Shot) {
    & (Join-Path (Split-Path -Parent $PSScriptRoot) 'harness\wgc-shot\wgc-shot.exe') "hwnd:$([int64]$hwnd)" $Shot | Out-Null
    Write-Host "shot: $Shot"
}

$clip = Get-Clipboard -Raw
Write-Host "selected: [$clip]"
Write-Host "length:   $($clip.Length)"

$res = [IntPtr]::Zero
[void][DblClick]::SendMessageTimeoutW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero, 2, 5000, [ref]$res)
