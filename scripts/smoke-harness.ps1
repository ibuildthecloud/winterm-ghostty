<#
.SYNOPSIS
    Unattended smoke test for libghostty in a Windows host process.

.DESCRIPTION
    Two bugs found in Phase 5 were invisible to every unit test on either side,
    because both live in the seam between a Windows host and libghostty rather
    than inside either one:

      1. Any non-ASCII output crashed the process with an access violation.
         The DLL's C++ static initializers never ran, so libghostty's tables
         were still zeroed by the time the parser reached them (patch 0024).
         `zig build test` cannot see this: it builds an executable whose CRT
         starts normally. It only appears once libghostty is a DLL loaded by
         someone else - which is what this script is.

      2. Input reached the terminal but never reached the child, or the child's
         output never reached the screen. The external termio backend (ADR
         0006) is the whole of Windows Terminal's IO path, and nothing below
         the harness exercises it end to end.

    Both checks drive harness/hwnd-host, the same host Windows Terminal's
    control emulates, and both are pass/fail on process exit code rather than
    on anything a human has to look at.

.PARAMETER Harness
    hwnd-host.exe to test. Defaults to the one in harness/hwnd-host.

.EXAMPLE
    scripts\smoke-harness.ps1
#>
[CmdletBinding()]
param(
    [string]$Harness = (Join-Path $PSScriptRoot '..\harness\hwnd-host\hwnd-host.exe'),
    # Generous on purpose: these run on CI-grade machines and a Debug
    # libghostty. A flaky timeout would be worse than a slow test.
    [int]$FeedTimeoutMs = 8000,
    [int]$PtyTimeoutMs = 15000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Harness = (Resolve-Path $Harness).Path
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("ghostty-smoke-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

$failures = @()

function Invoke-Harness {
    param([hashtable]$Env, [int]$TimeoutMs, [string]$Name)

    $stderr = Join-Path $scratch "$Name.err"

    # The harness reads its configuration from the environment (its command
    # line belongs to ghostty_config_load_cli_args), so set it on this process
    # and restore afterwards rather than leaking it into later checks.
    $saved = @{}
    foreach ($k in $Env.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Env[$k])
    }
    try {
        # Neither -NoNewWindow nor -RedirectStandardOutput, and this is not
        # cosmetic. The harness spawns a ConPTY, and the child attaches to a
        # console it resolves from the harness's own: with -NoNewWindow it
        # inherits the caller's (which under an automated runner has no
        # console and a null stdin, so cmd.exe reads EOF and exits 0), and
        # redirecting stdout breaks the attach too. Either way conhost is left
        # rendering an empty screen with no client, which looks exactly like a
        # renderer that stopped painting. Only stderr is redirected - the
        # harness traces there and writes nothing to stdout.
        $p = Start-Process -FilePath $Harness -PassThru -RedirectStandardError $stderr
        if (-not $p.WaitForExit($TimeoutMs)) {
            # A hang is a failure, not a reason to leave a window on screen.
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            $p.WaitForExit(5000) | Out-Null
            return [pscustomobject]@{
                ExitCode = $null
                Stderr   = (Get-Content -Raw -ErrorAction SilentlyContinue $stderr)
                TimedOut = $true
            }
        }
        return [pscustomobject]@{
            ExitCode = $p.ExitCode
            Stderr   = (Get-Content -Raw -ErrorAction SilentlyContinue $stderr)
            TimedOut = $false
        }
    }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

function Add-Failure { param([string]$Message) ; $script:failures += $Message ; Write-Host "  FAIL $Message" -ForegroundColor Red }
function Add-Pass { param([string]$Message) ; Write-Host "  ok   $Message" -ForegroundColor Green }

Write-Host "harness: $Harness" -ForegroundColor DarkGray

# --- 1. Non-ASCII output does not crash the process -------------------------
#
# The content is chosen to reach the parts that were uninitialized: box drawing
# (what `wsl aptitude` draws, the original repro), wide CJK, a combining mark,
# and an emoji ZWJ sequence, which between them need the width tables, the
# grapheme break tables and the fallback font path.
Write-Host 'check: non-ASCII output survives (static initializers ran)' -ForegroundColor Cyan
$feed = Join-Path $scratch 'feed.bin'
# Built from code points rather than typed literally, so the file this script
# lives in stays ASCII and no editor or git filter can silently change what
# gets fed.
function U { param([int[]]$cp) ; -join ($cp | ForEach-Object { [char]::ConvertFromUtf32($_) }) }

$box = U 0x250C, 0x2500, 0x2500, 0x2510   # the shapes aptitude draws
$cjk = U 0x4F60, 0x597D, 0x4E16, 0x754C   # wide: needs the width tables
$comb = "e" + (U 0x0301) + " a" + (U 0x030A)  # combining marks
$zwj = U 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467  # grapheme break tables
$flag = U 0x1F1EF, 0x1F1F5
$keycap = "1" + (U 0xFE0F, 0x20E3)

# CRLF, not LF: this is raw pty output with no ONLCR translation under it, so
# a bare newline moves down without returning, and the feed staircases across
# the screen. A real child emits CRLF; so does this.
$text = @(
    "`e[2J`e[H",
    "$box aptitude 0.8.13`r`n",
    "wide: $cjk`r`n",
    "combining: $comb`r`n",
    "emoji: $zwj $flag $keycap`r`n"
) -join ''

# Written as UTF-8 bytes without a BOM: this is pty output, not a text file.
$bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
[System.IO.File]::WriteAllBytes($feed, $bytes)

$r = Invoke-Harness -Name 'feed' -TimeoutMs $FeedTimeoutMs -Env @{
    GHOSTTY_HARNESS_EXTERNAL = '1'
    GHOSTTY_HARNESS_FEED     = $feed
    GHOSTTY_HARNESS_EXIT_MS  = '2000'
}
if ($r.TimedOut) {
    Add-Failure 'harness hung feeding non-ASCII output'
}
elseif ($r.ExitCode -ne 0) {
    # 0xC0000005 here is the patch 0024 regression: the tables are zeroed
    # again, which means the DLL is not running its static initializers.
    Add-Failure ("harness exited 0x{0:X8} feeding non-ASCII output{1}" -f $r.ExitCode,
        $(if ($r.ExitCode -eq -1073741819) { ' - access violation, the CRT static initializers did not run (patch 0024)' } else { '' }))
}
elseif ($r.Stderr -notmatch 'feed survived') {
    Add-Failure 'harness exited 0 but never reported surviving the feed'
}
else {
    Add-Pass ("{0} bytes of non-ASCII parsed and rendered" -f $bytes.Length)
}

# --- 1b. read_text returns the buffer -------------------------------------
#
# Windows Terminal's ReadEntireBuffer asks ghostty for the whole screen with a
# GHOSTTY_POINT_SCREEN selection and TOP_LEFT/BOTTOM_RIGHT coords - "the whole
# buffer without having to know how big it is". That shape is easy to get
# subtly wrong (viewport vs screen, exact vs edge coords) and the failure is
# silent: a wrong selection returns *some* text. Feeding known markers and
# demanding them back is the cheap way to keep it honest.
Write-Host 'check: read_text returns the whole buffer' -ForegroundColor Cyan
$rbFeed = Join-Path $scratch 'readback.bin'
[System.IO.File]::WriteAllBytes($rbFeed, [System.Text.Encoding]::UTF8.GetBytes(
    "`e[2J`e[HREADBACK_ALPHA`r`nREADBACK_BETA`r`n"))

$r = Invoke-Harness -Name 'readback' -TimeoutMs $FeedTimeoutMs -Env @{
    GHOSTTY_HARNESS_EXTERNAL = '1'
    GHOSTTY_HARNESS_FEED     = $rbFeed
    GHOSTTY_HARNESS_READBACK = '1'
    GHOSTTY_HARNESS_EXIT_MS  = '2000'
}
if ($r.TimedOut -or $r.ExitCode -ne 0) {
    Add-Failure 'harness did not survive the read-back feed'
}
elseif ($r.Stderr -match 'readback FAILED') {
    Add-Failure 'ghostty_surface_read_text refused the whole-screen selection'
}
elseif ($r.Stderr -notmatch 'READBACK_ALPHA<LF>READBACK_BETA') {
    Add-Failure 'read_text did not return what was fed - the selection shape is wrong'
}
else {
    Add-Pass 'the whole-screen selection returns exactly what was written'
}

# --- 1bb. WT's word delimiters reach the engine intact ----------------------
#
# The bug that reshaped the settings entry point: WT's default wordDelimiters
# went over as part of a config-file *line*, lost its meaning to that line's
# syntax, and was rejected by a diagnostic libghostty never surfaces. The
# setting looked forwarded and ghostty quietly kept its own word boundaries -
# visible only as a double click that kept a trailing "." cascadia dropped.
#
# So the check is the symptom: feed a sentence, double click a word, and demand
# the character cascadia would have left out.
Write-Host "check: WT's word delimiters survive the trip into ghostty" -ForegroundColor Cyan
$wordFeed = Join-Path $scratch 'words.bin'
[System.IO.File]::WriteAllBytes($wordFeed, [System.Text.Encoding]::UTF8.GetBytes(
    "`e[2J`e[HMicrosoft Corporation. Ltd`r`n"))

# WT's default wordDelimiters, escaped exactly as GhosttySettingsTranslator
# emits it - the backslash doubled because selection-word-chars is parsed as a
# Zig string literal by the field itself, and nothing else touched.
$wordChars = ' ./\\()"' + "'" + '-:,.;<>~!@#$%^&*|+=[]{}~?'

# x lands inside "Corporation", which starts at column 10.
$r = Invoke-Harness -Name 'words' -TimeoutMs $FeedTimeoutMs -Env @{
    GHOSTTY_HARNESS_EXTERNAL    = '1'
    GHOSTTY_HARNESS_FEED        = $wordFeed
    GHOSTTY_HARNESS_WORD_CHARS  = $wordChars
    GHOSTTY_HARNESS_DOUBLECLICK = '130,5'
    GHOSTTY_HARNESS_EXIT_MS     = '2000'
}
if ($r.TimedOut -or $r.ExitCode -ne 0) {
    Add-Failure 'harness did not survive the word-delimiter feed'
}
elseif ($r.Stderr -match 'selection-word-chars REJECTED') {
    Add-Failure 'ghostty rejected the word delimiters outright'
}
elseif ($r.Stderr -notmatch '\[dclick\] cells \d+\+\d+ text "([^"]*)"') {
    Add-Failure 'no word came back from the double click'
}
elseif ($Matches[1] -ne 'Corporation') {
    Add-Failure ("double click selected '{0}', cascadia would select 'Corporation'" -f $Matches[1])
}
else {
    Add-Pass 'a double click ends the word where WT says it ends'
}

# --- 1bc. A triple click reaches the edge but copies no trailing space ------
#
# ghostty's triple click stops where the line's content stops; cascadia's runs
# to the edge of the pane, and the highlight is drawn from ghostty's own
# selection extent, so parity means asking for the wider one. The risk in doing
# that is the copy: a wider extent must not start putting the rest of the row's
# blanks on the clipboard.
#
# Both halves are visible here at once. ghostty_text_s carries no bottom-right
# corner, so the harness prints the selection's cell span next to its text - the
# span is what is highlighted, the text is what a copy takes, and they are meant
# to disagree.
Write-Host 'check: a triple click spans the line but copies only its content' -ForegroundColor Cyan
$lineFeed = Join-Path $scratch 'line.bin'
[System.IO.File]::WriteAllBytes($lineFeed, [System.Text.Encoding]::UTF8.GetBytes(
    "`e[2J`e[HMicrosoft Corporation. Ltd`r`n"))

$spans = @{}
foreach ($trim in 'true', 'false') {
    $r = Invoke-Harness -Name "line-$trim" -TimeoutMs $FeedTimeoutMs -Env @{
        GHOSTTY_HARNESS_EXTERNAL    = '1'
        GHOSTTY_HARNESS_FEED        = $lineFeed
        GHOSTTY_HARNESS_TRIM_LINE   = $trim
        GHOSTTY_HARNESS_TRIPLECLICK = '60,5'
        GHOSTTY_HARNESS_EXIT_MS     = '2000'
    }
    if ($r.TimedOut -or $r.ExitCode -ne 0 -or $r.Stderr -notmatch '\[tclick\] cells (\d+)\+(\d+) text "([^"]*)"') {
        Add-Failure "no triple-click selection came back with selection-trim-line = $trim"
        $spans = $null
        break
    }
    $spans[$trim] = @{ Len = [int]$Matches[2]; Text = $Matches[3] }
}
if ($spans) {
    if ($spans['false'].Len -le $spans['true'].Len) {
        Add-Failure ("selection-trim-line = false did not widen the highlight ({0} cells either way)" -f
            $spans['true'].Len)
    }
    elseif ($spans['false'].Text -ne 'Microsoft Corporation. Ltd') {
        Add-Failure ("the wider selection copied '{0}' - trailing blanks reached the clipboard" -f
            $spans['false'].Text)
    }
    else {
        Add-Pass ("the highlight grows {0} -> {1} cells and the copied text does not" -f
            $spans['true'].Len, $spans['false'].Len)
    }
}

# --- 1c. A drag selects the same characters cascadia would ------------------
#
# The pieces of the selection mapping are pinned on their own sides - what
# ControlInteractivity rounds a pixel to by UnitTests_Control's
# SelectionDragGeometryTests, and where ghostty puts a boundary by the sweep in
# docs/selection-geometry.md - but what a user feels is the two stacked, and
# stacking them wrongly is exactly what put the selection a character off. Only
# the real engine can answer this one, so it lives here.
#
# The harness does WT's own rounding and then sends what GhosttyControlCore
# sends for it. The expectation is the ruler line sliced by the cell span
# cascadia would have selected for the same pixels.
Write-Host 'check: a pixel drag selects the characters cascadia would' -ForegroundColor Cyan
$ruler = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
$rulerFeed = Join-Path $scratch 'ruler.bin'
[System.IO.File]::WriteAllBytes($rulerFeed, [System.Text.Encoding]::UTF8.GetBytes(
    "`e[2J`e[H$ruler`r`n"))

# Pixel pairs chosen to cover what was broken: the same drag started from the
# left, middle and right of one character (all three must select identically -
# the press position is not supposed to matter), and the same run dragged
# right-to-left (which has to keep the character it started on).
$drags = @(
    @{ From = 42; To = 85 },
    @{ From = 44; To = 85 },
    @{ From = 46; To = 85 },
    @{ From = 85; To = 42 },
    @{ From = 40; To = 49 }
)
$dragFailed = $false
$seen = @()
foreach ($d in $drags) {
    $r = Invoke-Harness -Name ("drag-{0}-{1}" -f $d.From, $d.To) -TimeoutMs $FeedTimeoutMs -Env @{
        GHOSTTY_HARNESS_EXTERNAL  = '1'
        GHOSTTY_HARNESS_FEED      = $rulerFeed
        GHOSTTY_HARNESS_SELECT_WT = ("{0},{1},5" -f $d.From, $d.To)
        GHOSTTY_HARNESS_EXIT_MS   = '2000'
    }
    if ($r.TimedOut -or $r.ExitCode -ne 0) {
        Add-Failure ("harness did not survive the drag {0}->{1}" -f $d.From, $d.To)
        $dragFailed = $true
        continue
    }
    if ($r.Stderr -notmatch '\[selwt\] cells \[(\d+),(\d+)\) text "([^"]*)"') {
        Add-Failure ("no selection reported for the drag {0}->{1}" -f $d.From, $d.To)
        $dragFailed = $true
        continue
    }
    $lo = [int]$Matches[1]
    $hi = [int]$Matches[2]
    $actual = $Matches[3]
    $expected = $ruler.Substring($lo, $hi - $lo)
    if ($actual -ne $expected) {
        Add-Failure ("drag {0}->{1} selected '{2}', cascadia would select '{3}' (cells [{4},{5}))" -f
            $d.From, $d.To, $actual, $expected, $lo, $hi)
        $dragFailed = $true
    }
    $seen += $actual
}
# The first three are the same drag from three points inside one character.
# They differing at all is the original bug, whatever they each selected.
if (-not $dragFailed -and ($seen[0] -ne $seen[1] -or $seen[1] -ne $seen[2])) {
    Add-Failure ("where inside a character the press landed changed the selection: '{0}', '{1}', '{2}'" -f
        $seen[0], $seen[1], $seen[2])
    $dragFailed = $true
}
if (-not $dragFailed) {
    Add-Pass ("{0} drags selected exactly the cells cascadia would" -f $drags.Count)
}

# --- 1e. Copy carries styles as well as text --------------------------------
#
# Windows Terminal puts plain text and HTML on the clipboard together, and the
# HTML is the only representation that carries colours. It is also the only one
# read-back cannot produce - ghostty_text_s has no attributes - so this has to
# go through copy_to_clipboard and be read where the representations arrive, in
# the runtime's clipboard callback.
#
# The fixture is a bold red-on-blue run followed by plain text, so a copy that
# has really carried the styles looks different from one that has quietly
# fallen back to text in a wrapper.
Write-Host 'check: copy carries colours, not just characters' -ForegroundColor Cyan
$colourFeed = Join-Path $scratch 'colour.bin'
[System.IO.File]::WriteAllBytes($colourFeed, [System.Text.Encoding]::UTF8.GetBytes(
    "`e[2J`e[H`e[1;31;44mCOLOURED`e[0m plain`r`n"))

$r = Invoke-Harness -Name 'copy' -TimeoutMs $FeedTimeoutMs -Env @{
    GHOSTTY_HARNESS_EXTERNAL  = '1'
    GHOSTTY_HARNESS_FEED      = $colourFeed
    GHOSTTY_HARNESS_SELECT_WT = '1,120,5'
    GHOSTTY_HARNESS_COPY      = 'mixed'
    GHOSTTY_HARNESS_EXIT_MS   = '2500'
}
if ($r.TimedOut -or $r.ExitCode -ne 0) {
    Add-Failure 'harness did not survive the copy'
}
elseif ($r.Stderr -match '\[clip\] REJECTED') {
    Add-Failure 'ghostty rejected copy_to_clipboard'
}
else {
    $mimes = @([regex]::Matches($r.Stderr, '\[clip\] mime=(\S+) len=(\d+) head=(.*)') |
        ForEach-Object { @{ Mime = $_.Groups[1].Value; Len = [int]$_.Groups[2].Value; Head = $_.Groups[3].Value } })
    $plain = $mimes | Where-Object { $_.Mime -eq 'text/plain' } | Select-Object -First 1
    $html = $mimes | Where-Object { $_.Mime -eq 'text/html' } | Select-Object -First 1

    if (-not $plain -or -not $html) {
        Add-Failure ("a mixed copy produced {0}, expected text/plain and text/html" -f
            (($mimes | ForEach-Object { $_.Mime }) -join ' + '))
    }
    elseif ($plain.Head -notmatch 'COLOURED') {
        Add-Failure ("the plain representation is '{0}'" -f $plain.Head)
    }
    # The styled run has to be styled: a colour and the bold it was printed
    # with. Without this the check would pass on HTML that is a <div> around
    # the same characters.
    elseif ($html.Head -notmatch 'color:' -or $html.Head -notmatch 'font-weight:\s*bold') {
        Add-Failure ("the HTML carries no colour or weight: '{0}'" -f $html.Head)
    }
    else {
        Add-Pass 'a mixed copy carries text/plain and text/html, with colours and weight'
    }
}

# --- 1d. Search finds, counts and navigates ---------------------------------
#
# The counts are the difficult part, and not because searching is hard.
# IControlCore::Search is synchronous - Windows Terminal asks and expects the
# answer in the return value - while ghostty searches on its own thread and
# reports back through the app tick, after the call has already returned. The
# WT side handles that by returning what it knows (a negative total, which the
# search box renders as "Searching...") and raising SearchResultsChanged when
# the real numbers land.
#
# This check exists to prove the numbers land at all, and are right: three
# occurrences of one needle across three lines, then next/next/previous.
Write-Host 'check: search counts matches and navigates them' -ForegroundColor Cyan
$searchFeed = Join-Path $scratch 'search.bin'
[System.IO.File]::WriteAllBytes($searchFeed, [System.Text.Encoding]::UTF8.GetBytes(
    "`e[2J`e[Halpha needle beta`r`nneedle gamma`r`ndelta needle`r`n"))

$r = Invoke-Harness -Name 'search' -TimeoutMs $PtyTimeoutMs -Env @{
    GHOSTTY_HARNESS_EXTERNAL = '1'
    GHOSTTY_HARNESS_FEED     = $searchFeed
    GHOSTTY_HARNESS_SEARCH   = 'needle'
    GHOSTTY_HARNESS_EXIT_MS  = '4000'
}
if ($r.TimedOut -or $r.ExitCode -ne 0) {
    Add-Failure 'harness did not survive the search'
}
elseif ($r.Stderr -match '\[search\] REJECTED') {
    Add-Failure 'ghostty rejected the search binding action'
}
elseif ($r.Stderr -notmatch '\[search\] total=(-?\d+)') {
    Add-Failure 'no total came back - the search never reported anything'
}
elseif ([int]$Matches[1] -ne 3) {
    Add-Failure ("search found {0} matches, the fixture has 3" -f $Matches[1])
}
else {
    # Every index the search reported, in order, for the sequence Windows
    # Terminal's search box produces: select the first match, then forward,
    # then backward.
    #
    # 0, 2, 0 - and which end those count from is the whole point. ghostty's
    # index 0 is the *newest* match and grows backwards in time, where WT's
    # status box means "the Nth from the top". So on a three-match fixture:
    #
    #   first    -> idx 0, the bottom-most match, which WT calls 3 of 3
    #   forward  -> idx 2, because forward is *down* the buffer and there is
    #               nothing below, so it wraps to the top: WT's 1 of 3
    #   backward -> idx 0 again, wrapping back
    #
    # Forwarded unconverted, "1/3" highlighted what cascadia calls 3 and Enter
    # moved the highlight the wrong way. The conversion lives in
    # GhosttyControlCore (_currentMatchFromTop and _navigateSearch); this pins
    # the engine behaviour it converts from, wrap included.
    $selected = @([regex]::Matches($r.Stderr, '\[search\] selected=(-?\d+)') |
        ForEach-Object { [int]$_.Groups[1].Value })
    if (($selected -join ',') -ne '0,2,0') {
        Add-Failure ("search navigation walked {0}, expected 0,2,0" -f ($selected -join ','))
    }
    else {
        Add-Pass 'three matches found; first/forward/backward walked 0, 2, 0 (top-down 3, 1, 3)'
    }
}

# --- 2. External termio carries input to the child --------------------------
#
# `dir` typed into cmd.exe: the text goes through the terminal's own encoder
# and out the write callback, which is the half of ADR 0006 that a feed cannot
# reach. The trace is the assertion - it is printed by the harness's pty, on
# the far side of libghostty.
Write-Host 'check: external termio round-trip (input reaches the child)' -ForegroundColor Cyan
$r = Invoke-Harness -Name 'pty' -TimeoutMs $PtyTimeoutMs -Env @{
    GHOSTTY_HARNESS_EXTERNAL  = '1'
    GHOSTTY_HARNESS_INPUT     = 'dir\r'
    GHOSTTY_HARNESS_TRACE_PTY = '1'
    GHOSTTY_HARNESS_EXIT_MS   = '5000'
}
if ($r.TimedOut) {
    Add-Failure 'harness hung driving the external backend'
}
elseif ($r.ExitCode -ne 0) {
    Add-Failure ("harness exited 0x{0:X8} driving the external backend" -f $r.ExitCode)
}
elseif ($r.Stderr -notmatch '\[extpty\] write \d+ bytes to child') {
    Add-Failure 'no bytes reached the child - the external write path is broken'
}
else {
    Add-Pass 'input reached the child through the external backend'
}

# --- 3. Output actually repaints the window ---------------------------------
#
# Everything above proves bytes moved. This proves they reached the screen:
# capture, make the child print, capture again, and require a large fraction
# of the window to have changed - large enough that a blinking cursor cannot
# pass for a repaint. Nothing but pixels can answer that; the terminal can be
# entirely correct while the window shows a stale frame.
#
# Be clear about what this does NOT cover. The Phase 5 freeze - where a pane
# held a stale frame because libghostty's wakeup coalesced a notify into a
# wake that had already finished - does not reproduce here. Removing the
# render call from Windows Terminal's output handler still leaves this check
# passing, because the harness's own wakeup path repaints anyway. So treat
# this as a guard on the whole path being alive, not as a regression test for
# the coalescing bug. That one still needs a human and a split pane; the
# checklist in docs/ carries it.
Write-Host 'check: child output repaints the window' -ForegroundColor Cyan

$wgc = Join-Path $PSScriptRoot '..\harness\wgc-shot\wgc-shot.exe'
if (-not (Test-Path $wgc)) {
    Write-Host '  SKIP wgc-shot.exe not built' -ForegroundColor Yellow
}
else {
    # WPF's decoder rather than System.Drawing: the GDI+ types live in
    # System.Drawing.Common, a NuGet package that is not there to reference on
    # a stock PowerShell 7.
    Add-Type -AssemblyName PresentationCore

    # Both frames are reduced to a small grid before comparing. That is not an
    # optimisation - it is the measurement. Averaged into blocks, a blinking
    # cursor disappears into the block that contains it, while a screenful of
    # new text moves nearly every block. So "did the window repaint" survives
    # as a question with a clear answer.
    function Get-FrameBlocks {
        param([string]$Path, [int]$Size = 64)

        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                $stream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)

            # Locals, and ::new rather than New-Object: inside a New-Object
            # argument list PowerShell binds the comma tighter than the
            # division, so the two scale factors parse as one array.
            $sx = $Size / $frame.PixelWidth
            $sy = $Size / $frame.PixelHeight
            $scale = [System.Windows.Media.ScaleTransform]::new($sx, $sy)
            $small = [System.Windows.Media.Imaging.TransformedBitmap]::new($frame, $scale)
            $bgra = [System.Windows.Media.Imaging.FormatConvertedBitmap]::new(
                $small, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)

            $stride = $bgra.PixelWidth * 4
            $px = [byte[]]::new($stride * $bgra.PixelHeight)
            $bgra.CopyPixels($px, $stride, 0)
            return $px
        }
        finally { $stream.Dispose() }
    }

    $before = Join-Path $scratch 'before.png'
    $after = Join-Path $scratch 'after.png'

    $env:GHOSTTY_HARNESS_EXTERNAL = '1'
    $env:GHOSTTY_HARNESS_TRACE_PTY = '1'
    # `dir` of the Windows directory: hundreds of lines, so the frame changes
    # almost everywhere rather than in a corner.
    $env:GHOSTTY_HARNESS_INPUT = 'dir C:\Windows\System32\*.dll\r'
    $env:GHOSTTY_HARNESS_INPUT_DELAY_MS = '6000'
    $env:GHOSTTY_HARNESS_EXIT_MS = '14000'
    $p = $null
    try {
        # See Invoke-Harness: stdout must not be redirected or the pty child
        # never attaches.
        $p = Start-Process -FilePath $Harness -PassThru `
            -RedirectStandardError (Join-Path $scratch 'repaint.err')

        # Long enough for the prompt to be on screen and settled, and well
        # before the input fires.
        Start-Sleep -Milliseconds 4000
        & $wgc $p.Id $before 2>&1 | Out-Null
        $capturedBefore = Test-Path $before

        # Input fires at 6s; give the child time to run and the frame to land.
        Start-Sleep -Milliseconds 5000
        & $wgc $p.Id $after 2>&1 | Out-Null
        $capturedAfter = Test-Path $after

        $p.WaitForExit(10000) | Out-Null
    }
    finally {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        foreach ($k in 'GHOSTTY_HARNESS_EXTERNAL','GHOSTTY_HARNESS_TRACE_PTY','GHOSTTY_HARNESS_INPUT',
                       'GHOSTTY_HARNESS_INPUT_DELAY_MS','GHOSTTY_HARNESS_EXIT_MS') {
            Remove-Item "env:$k" -ErrorAction SilentlyContinue
        }
    }

    if (-not ($capturedBefore -and $capturedAfter)) {
        # Capture needs a connected session: a disconnected one stops DWM
        # compositing and no window yields frames. That is an environment
        # limitation, not a regression, so it is a skip.
        Write-Host '  SKIP no frames captured - needs a connected (not disconnected) session' -ForegroundColor Yellow
    }
    else {
        $pa = Get-FrameBlocks $before
        $pb = Get-FrameBlocks $after
        if ($pa.Length -ne $pb.Length) {
            # Different window size between captures; nothing to compare.
            $changed = 1.0
        }
        else {
            $differing = 0
            for ($i = 0; $i -lt $pa.Length; $i += 4) {
                # 8/255 of headroom: a capture is not bit-exact frame to frame.
                if ([math]::Abs($pa[$i] - $pb[$i]) -gt 8 -or
                    [math]::Abs($pa[$i + 1] - $pb[$i + 1]) -gt 8 -or
                    [math]::Abs($pa[$i + 2] - $pb[$i + 2]) -gt 8) { $differing++ }
            }
            $changed = $differing / ($pa.Length / 4)
        }
        if ($changed -lt 0.10) {
            Add-Failure ("window changed by only {0:P1} after the child printed - output is not repainting" -f $changed)
            Write-Host "       compare $before with $after" -ForegroundColor DarkGray
        }
        else {
            Add-Pass ("{0:P0} of the window repainted after the child printed" -f $changed)
        }
    }
}

# --- Result -----------------------------------------------------------------
Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "smoke: $($failures.Count) failed" -ForegroundColor Red
    Write-Host "logs kept in $scratch" -ForegroundColor DarkGray
    exit 1
}
Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
Write-Host 'smoke: all checks passed' -ForegroundColor Green
