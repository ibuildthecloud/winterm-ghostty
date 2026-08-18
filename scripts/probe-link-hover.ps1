# Hover a URL in a pane with ctrl held, capture it, and optionally ctrl+click it.
#
# KD-20's question, and it takes a real window: the link a ghostty pane
# highlights has to be the one under the *pointer*, and a ctrl+click on it has
# to reach Windows Terminal's own opener. Neither is observable from a unit
# test - the first is drawn by libghostty's renderer, the second ends in a
# dialog or a browser.
#
# Aim it at a URL with a scheme WT refuses to launch (ftp://, which ghostty's
# regex still matches) and the click's evidence is a dialog inside the window
# rather than a browser stealing the desktop.
param(
    [Parameter(Mandatory = $true)][int] $Hwnd,
    [Parameter(Mandatory = $true)][string] $OutPrefix,

    # The cell to point at, from the top-left of the window's client text area.
    [int] $Row = 1,
    [int] $Col = 5,

    # Measured on this machine's dev window; see probe-drag-select.ps1, which
    # these match.
    [int] $CellW = 13,
    [int] $CellH = 26,
    [int] $PaneTop = 78,
    [int] $PaneLeft = 14,

    # Send the click as well as the hover.
    [switch] $Click
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Hover {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    // Logical vs physical pixels: without this every coordinate is off by the
    // display scale and the pointer lands nowhere near the row it was aimed at.
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public static readonly IntPtr PER_MONITOR_V2 = new IntPtr(-4);
    public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
    public const uint KEYUP = 0x0002;
    // VK_LCONTROL, not VK_CONTROL. TermControl reads the modifier state with
    // CoreWindow::GetKeyState(VirtualKey::LeftControl / RightControl), and an
    // injected *generic* VK_CONTROL sets neither - so the pane sees no ctrl at
    // all, no link highlights, and the probe reports a fix that works as
    // broken. Cost an hour the first time.
    public const byte VK_LCONTROL = 0xA2;
    public const byte SCAN_LCONTROL = 0x1D;
}
'@

[void][Hover]::SetProcessDpiAwarenessContext([Hover]::PER_MONITOR_V2)

$r = New-Object Hover+RECT
[void][Hover]::GetWindowRect([IntPtr]$Hwnd, [ref]$r)

# SetForegroundWindow is refused unless the calling thread shares input state
# with the current foreground thread.
$fg = [Hover]::GetForegroundWindow()
$fgThread = [Hover]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
$me = [Hover]::GetCurrentThreadId()
[void][Hover]::AttachThreadInput($me, $fgThread, $true)
[void][Hover]::SetForegroundWindow([IntPtr]$Hwnd)
[void][Hover]::AttachThreadInput($me, $fgThread, $false)
Start-Sleep -Milliseconds 400
$now = [Hover]::GetForegroundWindow()
"foreground: $now (wanted $Hwnd)"
if ($now -ne [IntPtr]$Hwnd) { throw "could not take the foreground - the user is probably at the keyboard" }

$x = $r.L + $PaneLeft + ($Col * $CellW) + [int]($CellW / 2)
$y = $r.T + $PaneTop + ($Row * $CellH) + [int]($CellH / 2)
"pointing at x=$x y=$y (window $($r.L),$($r.T))"

# Away first, so the move onto the link is a real pointer move: WT reports
# hover per move, and a pointer already parked on the cell sends none.
[void][Hover]::SetCursorPos($r.L + 400, $r.B - 20)
Start-Sleep -Milliseconds 150
[void][Hover]::SetCursorPos($x, $y)
Start-Sleep -Milliseconds 150

[Hover]::keybd_event([Hover]::VK_LCONTROL, [Hover]::SCAN_LCONTROL, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 200
# One more move with ctrl already down, a pixel over: the modifiers ghostty
# knows come from key events, but the position comes from a move.
[void][Hover]::SetCursorPos($x + 1, $y)
Start-Sleep -Milliseconds 400

& "E:\src\winterm-ghostty\harness\wgc-shot\wgc-shot.exe" "hwnd:$Hwnd" "$OutPrefix-hover.png"

if ($Click) {
    [Hover]::mouse_event([Hover]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Hover]::mouse_event([Hover]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1200
    & "E:\src\winterm-ghostty\harness\wgc-shot\wgc-shot.exe" "hwnd:$Hwnd" "$OutPrefix-click.png"
}

[Hover]::keybd_event([Hover]::VK_LCONTROL, [Hover]::SCAN_LCONTROL, [Hover]::KEYUP, [UIntPtr]::Zero)
# Park the pointer off the window: it is composited into any later capture.
[void][Hover]::SetCursorPos(10, 10)
