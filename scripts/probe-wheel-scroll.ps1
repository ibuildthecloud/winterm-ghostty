# Scroll a pane with a burst of small wheel deltas, as a precision touchpad
# sends them, and capture where the viewport ends up.
#
# KD-31's question. A two-finger scroll arrives as many WM_MOUSEWHEEL events of
# a fraction of WHEEL_DELTA each, several per rendered frame, and
# ControlInteractivity accumulates them into a fractional row. Whether the
# accumulation survives is measured by where the scroll *stops*: N events of
# delta D should move the viewport N*D/120 * (lines per notch) rows, and a pane
# that loses progress stops short of that. Aim it at a buffer of numbered lines
# (`for /L %i in (1,1,500) do @echo line %i`) and read the top line off the
# capture. Run it on a cascadia pane first - that is the expected answer.
#
# The wheel goes to the window under the pointer, so no foreground is needed,
# but the pointer is moved: do not run this while the user is at the mouse.
param(
    [Parameter(Mandatory = $true)][int] $Hwnd,
    [Parameter(Mandatory = $true)][string] $Out,

    # Positive scrolls up (back into history), as on Windows.
    [int] $Delta = 30,
    [int] $Count = 40,
    [int] $IntervalMs = 4
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Wheel {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, int d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    public static readonly IntPtr PER_MONITOR_V2 = new IntPtr(-4);
    public const uint WHEEL = 0x0800;
}
'@

[void][Wheel]::SetProcessDpiAwarenessContext([Wheel]::PER_MONITOR_V2)

$r = New-Object Wheel+RECT
[void][Wheel]::GetWindowRect([IntPtr]$Hwnd, [ref]$r)
$x = [int](($r.L + $r.R) / 2)
$y = [int](($r.T + $r.B) / 2)
[void][Wheel]::SetCursorPos($x, $y)
Start-Sleep -Milliseconds 200

$sw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $Count; $i++) {
    [Wheel]::mouse_event([Wheel]::WHEEL, 0, 0, $Delta, [UIntPtr]::Zero)
    # Spun, not slept: Start-Sleep rounds up to the 15.6 ms timer tick, which
    # is one event per frame and hides exactly what this is for.
    $until = $sw.Elapsed.TotalMilliseconds + $IntervalMs
    while ($sw.Elapsed.TotalMilliseconds -lt $until) { }
}
"sent $Count x $Delta in $($sw.ElapsedMilliseconds) ms (= $($Count * $Delta / 120) notches)"

Start-Sleep -Milliseconds 600
# Park the pointer off the window: it is composited into the capture.
[void][Wheel]::SetCursorPos(10, 10)
Start-Sleep -Milliseconds 200
& "E:\src\winterm-ghostty\harness\wgc-shot\wgc-shot.exe" "hwnd:$Hwnd" $Out
