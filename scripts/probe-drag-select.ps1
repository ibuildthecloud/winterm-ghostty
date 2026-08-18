# Drive a real left-button drag across a window and capture the frame that
# follows it, with no other input in between.
#
# The point is KD-19's regression question: with the forced render gone, a
# selection has to appear from the render thread's own wakeup. If the wake were
# lost, the capture taken right after the drag would show no highlight.
param(
    [Parameter(Mandatory = $true)][int] $Hwnd,
    [Parameter(Mandatory = $true)][string] $Out,
    [int] $Row = 3,        # which text row to drag along, from the pane top
    [int] $StartCol = 2,
    [int] $EndCol = 40,
    [int] $CellW = 13,
    [int] $CellH = 26,
    [int] $PaneTop = 78    # first text row's y, inside the window
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Drag {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    // Without this, GetWindowRect and SetCursorPos speak *logical* pixels while
    // wgc-shot captures physical ones, and every coordinate is off by the
    // display scale - which on this box is 150%, so a drag lands nowhere near
    // the row it was aimed at.
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public static readonly IntPtr PER_MONITOR_V2 = new IntPtr(-4);
    public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
}
'@

[void][Drag]::SetProcessDpiAwarenessContext([Drag]::PER_MONITOR_V2)

$r = New-Object Drag+RECT
[void][Drag]::GetWindowRect([IntPtr]$Hwnd, [ref]$r)

# SetForegroundWindow is refused unless the calling thread shares input state
# with the current foreground thread - see the headless-driving notes.
$fg = [Drag]::GetForegroundWindow()
$fgThread = [Drag]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
$me = [Drag]::GetCurrentThreadId()
[void][Drag]::AttachThreadInput($me, $fgThread, $true)
[void][Drag]::SetForegroundWindow([IntPtr]$Hwnd)
[void][Drag]::AttachThreadInput($me, $fgThread, $false)
Start-Sleep -Milliseconds 400
$now = [Drag]::GetForegroundWindow()
"foreground: $now (wanted $Hwnd)" 
if ($now -ne [IntPtr]$Hwnd) { throw "could not take the foreground - the user is probably at the keyboard" }

$y = $r.T + $PaneTop + ($Row * $CellH) + [int]($CellH / 2)
$x1 = $r.L + 14 + ($StartCol * $CellW)
$x2 = $r.L + 14 + ($EndCol * $CellW)

"drag y=$y from x=$x1 to x=$x2 (window $($r.L),$($r.T))"

[void][Drag]::SetCursorPos($x1, $y)
Start-Sleep -Milliseconds 120
[Drag]::mouse_event([Drag]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
[Drag]::mouse_event([Drag]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 200
[Drag]::mouse_event([Drag]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60

# Move in steps, the way a hand does - each step is a SetEndSelectionPoint.
$steps = 12
for ($i = 1; $i -le $steps; $i++) {
    $x = $x1 + [int](($x2 - $x1) * $i / $steps)
    [void][Drag]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 25
}
[Drag]::mouse_event([Drag]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)

# Park the pointer off the window so it is not composited into the capture,
# but do not click anything - the selection must survive on its own.
Start-Sleep -Milliseconds 250
[void][Drag]::SetCursorPos(10, 10)
Start-Sleep -Milliseconds 250

& "E:\src\winterm-ghostty\harness\wgc-shot\wgc-shot.exe" "hwnd:$Hwnd" $Out
