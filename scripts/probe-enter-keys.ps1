<#
.SYNOPSIS
    Print the bytes a pane sends for Enter and its modifier combinations.

.DESCRIPTION
    KD-30. Ctrl+Enter did nothing in a ghostty pane, and reading the encoder
    produced a confident, detailed and wrong answer: the key was consumed by one
    of ghostty's own keybindings before the encoder was reached, so no amount of
    reading that table could have said anything. Only the wire answers "what
    arrives" - and the distinction that mattered, *nothing at all* versus *a
    sequence the application does not understand*, looks identical on screen and
    is unmissable in a byte log.

    So this runs harness\rawin\rawin.exe as the pane's own process, which puts
    the child end in raw VT-input mode and names every byte it receives, posts
    each chord, and reads the log back.

    Each chord is preceded by a digit, so the log labels itself:

        1 <CR>              <- enter
        2 <ESC>[27;2;13~    <- shift+enter
        3 <LF>              <- ctrl+enter

    **Transport.** The key messages are posted to the window's InputSite child,
    the way scripts\probe-shift-posted.ps1 does, because that needs no
    foreground window and cannot disturb whoever is at the keyboard - this
    machine is usually driven over Remote Desktop, where a detached session has
    no foreground window at all and SendInput has nowhere to go.

    The cost is that the modifiers exist only as key *events*, never as keyboard
    state, which is KD-25's exact hazard. A ghostty pane is unaffected: it
    tracks the modifier stream (GhosttyModifiersFor) precisely so that a
    modifier which is never "held" still counts. A **cascadia** pane reads
    GetKeyState, so ctrl+enter posted this way can report <CR> rather than <LF>
    - an artifact of the transport, not a difference between the engines. For a
    cascadia reference, read terminalInput.cpp's VK_RETURN case, or measure with
    a real keyboard.

    Measured on 2026-09-03, same build, same chords, so the artifact is on the
    record rather than rediscovered:

        chord               ghostty pane        cascadia pane (control)
        enter               <CR>                <CR>
        shift+enter         <ESC>[27;2;13~ <CR> <CR>
        ctrl+enter          <LF> <CR>           <CR>
        ctrl+j              <LF> j              j
        ctrl+shift+enter    <LF> <CR>           <CR>
        ctrl+numpad-enter   <LF> <CR>           <CR>

    Read the *first* byte group of each ghostty row: that is the encoding, and
    it is what this probe is for. The trailing unmodified byte is the same
    artifact seen from the other side - WT's message pump translates the posted
    key into a WM_CHAR using the real keyboard state, which has no ctrl in it -
    and the cascadia column is that byte with nothing in front of it, since a
    cascadia pane loses the modifier entirely. With a real keyboard neither
    happens: the reporter's own byte dump shows exactly one sequence per chord.

.EXAMPLE
    .\scripts\probe-enter-keys.ps1                          # the deployed dev package
    .\scripts\probe-enter-keys.ps1 -Root C:\tmp\wt -Profile gh
    .\scripts\probe-enter-keys.ps1 -Hwnd 0x00120A34         # a window already open
#>
[CmdletBinding()]
param(
    # A profile name from the settings the build under test is using. Which
    # engine it selects is the profile's business; this probe reports what
    # arrived and assumes nothing.
    [string] $Profile = 'PowerShell',

    # Launch a portable build: the directory holding WindowsTerminal.exe.
    # Without this, the launcher alias below is used instead.
    [string] $Root,

    # The dev package's execution alias, used when -Root is not given.
    [string] $Launcher = 'wtgd.exe',

    # Post into a window that is already open instead of launching one.
    [IntPtr] $Hwnd = 0,

    # Seconds rawin reads for. It must outlast the injection run.
    [int] $Seconds = 45,

    [string] $Log,

    [switch] $KeepOpen
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$rawin = Join-Path $RepoRoot 'harness\rawin\rawin.exe'
if (-not (Test-Path $rawin)) {
    throw "rawin.exe not found at $rawin - build it with harness\rawin\build.ps1"
}

if (-not $Log) {
    $Log = Join-Path $env:TEMP ("enter-keys-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (Test-Path $Log) { Remove-Item $Log -Force }

Add-Type -Namespace EnterKeys -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder buf, int max);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
'@

# The XAML content of a WT window lives in this child window; posting key
# messages to it reaches the focused TermControl without activating anything.
function Find-InputSite([IntPtr] $parent)
{
    $script:found = [IntPtr]::Zero
    $cb = [EnterKeys.Win+EnumProc]{
        param($h, $l)
        $sb = New-Object System.Text.StringBuilder 256
        [void][EnterKeys.Win]::GetClassNameW($h, $sb, $sb.Capacity)
        if ($sb.ToString() -like '*InputSite*') { $script:found = $h; return $false }
        return $true
    }
    [void][EnterKeys.Win]::EnumChildWindows($parent, $cb, [IntPtr]::Zero)
    return $script:found
}

# lParam for a key message: repeat count 1, scan code in bits 16-23, extended
# flag in bit 24. TermControl reads the scan code off this, and a ghostty pane
# turns it into libghostty's native keycode - which is why the scan codes below
# are real ones and not zero (a zero scan code means "injected character",
# handled deliberately differently - KD-25).
function Get-KeyLParam([int] $scan, [bool] $up, [bool] $extended)
{
    $l = 1 -bor ($scan -shl 16)
    if ($extended) { $l = $l -bor (1 -shl 24) }
    if ($up) { $l = $l -bor (1 -shl 30) -bor (1 -shl 31) }
    return [IntPtr] $l
}

$WM_KEYDOWN  = 0x0100
$WM_KEYUP    = 0x0101
$VK_LCTRL    = 0xA2
$VK_LSHIFT   = 0xA0
$SCAN_LCTRL  = 0x1D
$SCAN_LSHIFT = 0x2A

# name, vkey, scan, extended, and which modifiers to wrap it in.
$chords = @(
    @{ N = 1; Name = 'enter';             Vk = 0x0D; Scan = 0x1C; Ext = $false; Ctrl = $false; Shift = $false }
    @{ N = 2; Name = 'shift+enter';       Vk = 0x0D; Scan = 0x1C; Ext = $false; Ctrl = $false; Shift = $true  }
    @{ N = 3; Name = 'ctrl+enter';        Vk = 0x0D; Scan = 0x1C; Ext = $false; Ctrl = $true;  Shift = $false }
    @{ N = 4; Name = 'ctrl+j';            Vk = 0x4A; Scan = 0x24; Ext = $false; Ctrl = $true;  Shift = $false }
    @{ N = 5; Name = 'ctrl+shift+enter';  Vk = 0x0D; Scan = 0x1C; Ext = $false; Ctrl = $true;  Shift = $true  }
    @{ N = 6; Name = 'ctrl+numpad-enter'; Vk = 0x0D; Scan = 0x1C; Ext = $true;  Ctrl = $true;  Shift = $false }
)

# --- The window -----------------------------------------------------------
if ($Hwnd -ne 0)
{
    $target = $Hwnd
}
else
{
    # rawin as the pane's own process: -p keeps the profile (and so the engine)
    # and replaces only the command line.
    $before = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

    if ($Root)
    {
        $exe = Join-Path $Root 'WindowsTerminal.exe'
        if (-not (Test-Path $exe)) { throw "no WindowsTerminal.exe under $Root" }
        Start-Process $exe -ArgumentList @('-w', 'new', '-p', "`"$Profile`"", $rawin, $Log, "$Seconds") | Out-Null
    }
    else
    {
        & $Launcher -w new -p $Profile $rawin $Log "$Seconds"
    }

    # rawin writes the first log line itself, so waiting for it proves the child
    # is up and reading - not merely that a window appeared.
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Log) -and (Select-String -Path $Log -Pattern 'rawin start' -Quiet)) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path $Log)) { throw "rawin never wrote $Log - did the pane open?" }

    # A second instance of the same build joins the running one, so the window
    # may belong to a process that already existed. Prefer a new one; fall back
    # to any window of this build rather than refusing, since joining is the
    # normal case for a packaged build.
    $mine = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue |
              Where-Object { $_.MainWindowHandle -ne 0 -and $_.Id -notin $before })
    if (-not $mine) {
        $mine = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue |
                  Where-Object { $_.MainWindowHandle -ne 0 })
    }
    if (-not $mine) { throw 'no WindowsTerminal window found to post into' }
    $target = [IntPtr] $mine[0].MainWindowHandle
}

$site = Find-InputSite $target
if ($site -eq [IntPtr]::Zero) { throw 'no InputSite child window - nothing to post to' }
Write-Host "profile : $Profile"
Write-Host "window  : hwnd $target  inputSite $site"
Write-Host "log     : $Log"
Write-Host ''

# --- Post -----------------------------------------------------------------
foreach ($c in $chords)
{
    # The label. Digit keys are 0x31.. with scan codes 0x02..
    $digitVk = 0x30 + $c.N
    $digitScan = 0x01 + $c.N
    [void][EnterKeys.Win]::PostMessageW($site, $WM_KEYDOWN, [IntPtr] $digitVk, (Get-KeyLParam $digitScan $false $false))
    [void][EnterKeys.Win]::PostMessageW($site, $WM_KEYUP,   [IntPtr] $digitVk, (Get-KeyLParam $digitScan $true  $false))
    Start-Sleep -Milliseconds 250

    if ($c.Ctrl)  { [void][EnterKeys.Win]::PostMessageW($site, $WM_KEYDOWN, [IntPtr] $VK_LCTRL,  (Get-KeyLParam $SCAN_LCTRL  $false $false)) }
    if ($c.Shift) { [void][EnterKeys.Win]::PostMessageW($site, $WM_KEYDOWN, [IntPtr] $VK_LSHIFT, (Get-KeyLParam $SCAN_LSHIFT $false $false)) }

    [void][EnterKeys.Win]::PostMessageW($site, $WM_KEYDOWN, [IntPtr] $c.Vk, (Get-KeyLParam $c.Scan $false $c.Ext))
    [void][EnterKeys.Win]::PostMessageW($site, $WM_KEYUP,   [IntPtr] $c.Vk, (Get-KeyLParam $c.Scan $true  $c.Ext))

    if ($c.Shift) { [void][EnterKeys.Win]::PostMessageW($site, $WM_KEYUP, [IntPtr] $VK_LSHIFT, (Get-KeyLParam $SCAN_LSHIFT $true $false)) }
    if ($c.Ctrl)  { [void][EnterKeys.Win]::PostMessageW($site, $WM_KEYUP, [IntPtr] $VK_LCTRL,  (Get-KeyLParam $SCAN_LCTRL  $true $false)) }

    Write-Host ("  posted {0}" -f $c.Name)
    Start-Sleep -Milliseconds 500
}

Start-Sleep -Seconds 1

# --- Read it back ---------------------------------------------------------
Write-Host ''
Write-Host '--- what arrived --------------------------------------------------'
if (-not (Test-Path $Log)) { throw "no log at $Log" }

# One log line per read, so one chord's bytes can span lines: flatten, then cut
# on the labels.
$flat = ((Get-Content -Path $Log) |
         Where-Object { $_ -match '^recv\[' } |
         ForEach-Object { $_ -replace '^recv\[\d+\]:\s*', '' }) -join ''

foreach ($c in $chords)
{
    $pattern = if ($c.N -lt 6) { "{0}(.*?){1}" -f $c.N, ($c.N + 1) } else { "{0}(.*)$" -f $c.N }
    $m = [regex]::Match($flat, $pattern)
    $bytes = if ($m.Success) { $m.Groups[1].Value.Trim() } else { '(label not found)' }
    if ($bytes -eq '') { $bytes = 'NOTHING' }
    Write-Host ("{0,-20} {1}" -f $c.Name, $bytes)
}

Write-Host ''
Write-Host "raw log: $Log"
if ($KeepOpen -or $Hwnd -ne 0) { return }
Write-Host 'The pane closes itself when rawin reaches its deadline.'
