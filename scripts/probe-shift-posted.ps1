<#
.SYNOPSIS
    Type a shifted chord into a pane with shift present only as a key *event*,
    never as keyboard state, and report the bytes the child received.

.DESCRIPTION
    KD-25. TermControl reads the modifiers with CoreWindow::GetKeyState when
    XAML raises KeyDown, which answers "what is held now" rather than "what was
    held when this key was pressed". A person holds shift for about a tenth of
    a second so the two agree; a remote desktop client sends shift-down, the
    key and shift-up back to back, and the answer arrives after the release.

    Posting the four key messages reproduces exactly that state of affairs -
    the events arrive in order, and nothing is ever held - which is why this
    probe needs no foreground at all and cannot disturb whoever is at the
    keyboard. It is the mechanism under test, not the transport: the real
    report came from the Windows App on Android.

    Expected: `;/a` before the fix (shift lost), `;:?A` style output after.

.EXAMPLE
    .\probe-shift-posted.ps1 -Root C:\tmp\wt -Profile gh -Log C:\tmp\gh.log
#>
[CmdletBinding()]
param(
    # The portable install to run: the directory holding WindowsTerminal.exe.
    [string]$Root,
    # Post into a window that is already open instead of launching one. The log
    # still says which pane received it, so the active tab does not have to be
    # guessed.
    [IntPtr]$Hwnd = 0,
    # Profile to open. Its commandline must be rawin.exe writing to -Log.
    [string]$Profile = 'gh',
    [string]$Log,
    # Send the characters as VK_PACKET unicode events - the transport the
    # Windows App on Android uses - instead of as key presses.
    [switch]$Packet,
    [switch]$KeepOpen
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace Posted -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder buf, int max);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
'@

# The XAML content of a WT window lives in this child window, and posting key
# messages to it reaches the focused TermControl without the window ever being
# activated.
function Find-InputSite([IntPtr]$parent)
{
    $found = [IntPtr]::Zero
    $cb = [Posted.Win+EnumProc]{
        param($h, $l)
        $sb = New-Object System.Text.StringBuilder 256
        [void][Posted.Win]::GetClassNameW($h, $sb, $sb.Capacity)
        if ($sb.ToString() -like '*InputSite*')
        {
            $script:found = $h
            return $false
        }
        return $true
    }
    [void][Posted.Win]::EnumChildWindows($parent, $cb, [IntPtr]::Zero)
    return $script:found
}

# lParam for a key message: repeat count 1, the scan code in bits 16-23, and
# the extended flag in bit 24. TermControl reads the scan code off this, and
# the ghostty pane turns it into libghostty's native keycode.
function Key-LParam([int]$scan, [bool]$up)
{
    $l = 1 -bor ($scan -shl 16)
    if ($up) { $l = $l -bor (1 -shl 30) -bor (1 -shl 31) }
    return [IntPtr]$l
}

$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$VK_LSHIFT = 0xA0
$VK_PACKET = 0xE7

# vkey, scan, and what the chord should produce on a US layout.
#
# The Packet set is what the Windows App on Android actually sends, measured
# with harness/keylog: not shift plus a key, but the composed character in a
# VK_PACKET event whose scan code IS the UTF-16 unit. The soft shift key is a
# separate press that is over before the character arrives.
$keyChords = @(
    @{ Name = ';'; Vk = 0xBA; Scan = 0x27; Shift = $false; Want = ';' },
    @{ Name = ':'; Vk = 0xBA; Scan = 0x27; Shift = $true;  Want = ':' },
    @{ Name = '?'; Vk = 0xBF; Scan = 0x35; Shift = $true;  Want = '?' },
    @{ Name = 'A'; Vk = 0x41; Scan = 0x1E; Shift = $true;  Want = 'A' },
    @{ Name = 'a'; Vk = 0x41; Scan = 0x1E; Shift = $false; Want = 'a' }
)
$packetChords = @(
    @{ Name = 'packet ;'; Vk = $VK_PACKET; Scan = 0x3B; Shift = $false; Want = ';' },
    @{ Name = 'packet :'; Vk = $VK_PACKET; Scan = 0x3A; Shift = $false; Want = ':' },
    @{ Name = 'packet ?'; Vk = $VK_PACKET; Scan = 0x3F; Shift = $false; Want = '?' },
    @{ Name = 'packet A'; Vk = $VK_PACKET; Scan = 0x41; Shift = $false; Want = 'A' },
    @{ Name = 'packet a'; Vk = $VK_PACKET; Scan = 0x61; Shift = $false; Want = 'a' }
)
$chords = if ($Packet) { $packetChords } else { $keyChords }

if ($Hwnd -ne 0)
{
    $hwnd = $Hwnd
}
else
{
    if (-not $Root) { throw 'pass -Root to launch a window, or -Hwnd to use one that is open' }
    if ($Log -and (Test-Path $Log)) { Remove-Item $Log -Force }

    # A second instance of the same build joins the running one rather than
    # starting a process of its own, and the window it opens then belongs to
    # *that* build. Refuse rather than measure the wrong binary.
    $before = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    Start-Process (Join-Path $Root 'WindowsTerminal.exe') -ArgumentList @('-w', 'new', '-p', "`"$Profile`"") | Out-Null
    Start-Sleep -Seconds 6

    $mine = Get-Process WindowsTerminal | Where-Object { $_.Id -notin $before -and $_.MainWindowHandle -ne 0 }
    if (-not $mine) { throw 'no new terminal process appeared - another instance of this build is running and took the window' }
    $hwnd = [IntPtr]$mine[0].MainWindowHandle
}
$site = Find-InputSite $hwnd
if ($site -eq [IntPtr]::Zero) { throw 'no InputSite child window - nothing to post to' }
Write-Host "window: hwnd $hwnd  inputSite $site"

foreach ($c in $chords)
{
    if ($c.Shift)
    {
        [void][Posted.Win]::PostMessageW($site, $WM_KEYDOWN, [IntPtr]$VK_LSHIFT, (Key-LParam 0x2A $false))
    }

    [void][Posted.Win]::PostMessageW($site, $WM_KEYDOWN, [IntPtr]$c.Vk, (Key-LParam $c.Scan $false))
    [void][Posted.Win]::PostMessageW($site, $WM_KEYUP, [IntPtr]$c.Vk, (Key-LParam $c.Scan $true))

    if ($c.Shift)
    {
        [void][Posted.Win]::PostMessageW($site, $WM_KEYUP, [IntPtr]$VK_LSHIFT, (Key-LParam 0x2A $true))
    }

    Write-Host "  posted $($c.Name) (want $($c.Want))"
    Start-Sleep -Milliseconds 400
}

Start-Sleep -Seconds 1
if (-not $KeepOpen -and $Hwnd -eq 0)
{
    $r = [IntPtr]::Zero
    [void][Posted.Win]::SendMessageTimeoutW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero, 2, 3000, [ref]$r)
    Start-Sleep -Seconds 2
}

if ($Log)
{
    Write-Host "--- $Log"
    if (Test-Path $Log) { Get-Content $Log } else { Write-Host '(nothing was received)' }
}
