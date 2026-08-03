# vttest against the D3D11 backend

[vttest](https://invisible-island.net/vttest/) is the interactive, *visual* VT
compliance tester. It writes no machine-readable log — you read the rendered screen —
which makes it the right tool for a renderer and the wrong tool for a script.

This records a sweep against `harness/hwnd-host` running libghostty with the
`directwrite_harfbuzz` font backend and the D3D11 renderer, and compares it to wintty's
recorded baseline in
`reference/wintty/windows/docs/vt-compliance/vttest-results.md`.

Date: 2026-08-01. Build: `ReleaseFast`, `-Dfont-backend=directwrite_harfbuzz`.

## Host

vttest runs inside WSL and is hosted over `wsl.exe -> ConPTY -> libghostty`, the same
path wintty validates against.

```powershell
# vttest is not installed via apt (that needs a sudo password non-interactively).
# Build it from the upstream tarball with wintty's script. WSL frequently has no
# outbound DNS even when the host is online, so fetch the tarball Windows-side:
Invoke-WebRequest https://invisible-island.net/archives/vttest/vttest.tar.gz -OutFile C:\temp\vttest.tar.gz
wsl.exe -- bash /mnt/e/src/winterm-ghostty/reference/wintty/windows/scripts/vttest/build-vttest.sh /mnt/c/temp/vttest.tar.gz
# produces the ~/vttest symlink

cd harness\hwnd-host
.\hwnd-host.exe --command="wsl.exe -e /home/<user>/vttest"
```

## Driving sections

**This harness can be driven with synthetic keyboard input; wintty's could not.**

wintty's notes record that "synthetic keyboard input does not reach the Wintty window
(WinUI lifted-input focus cannot be forced from a detached process)", so they drove
sections by auto-feeding an inner `script` pty, which cannot exercise the keyboard
sections at all and distorts size-dependent ones.

Because `hwnd-host` is a plain Win32 window, `PostMessage` delivers `WM_KEYDOWN`/`WM_KEYUP`
straight to its HWND. That reaches `winkeys` exactly as a real keypress would, and it
cannot leak into another application the way `SendInput`/`SendKeys` can — which matters,
because `SendKeys` goes to whatever holds focus.

`scratchpad/vt.ps1` in the session scratch dir is the driver used here; the mechanism is
three lines:

```powershell
# scan code in lParam bits 16-23; winkeys maps scan code -> physical key
[M]::PostMessage($hwnd, 0x0100, [IntPtr]$vk, [IntPtr](1 -bor ($scan -shl 16)))
```

Screens are captured with `harness/wgc-shot` (Windows Graphics Capture — needs a
*connected* session; see the note in `harness/hwnd-host/main.c`).

## Per-section results

| # | Section | This backend | wintty baseline | Notes |
|---|---|---|---|---|
| 1 | Cursor movements | **pass** | pass | Cursor-control characters inside ESC sequences render four identical lines. At an 80-column terminal the border is completely unbroken — top, bottom and both sides edge to edge — with the hollow E-frame centred. **The section must be run at 80 columns**; see below, the bottom border row is not size-independent. |
| 2 | Screen features | **pass (partial)** | *deferred — harness* | wintty could not assess this. Here the section ran to completion. **DECSCNM verified by pixel measurement**: light background is `#FFFFFF`, dark is `#282C34`. **DECCOLM (132-column) is not honoured** — the ruler wraps, i.e. the terminal stays at its window width. Most modern terminals ignore DECCOLM deliberately. |
| 3 | Character sets | **pass** | pass | US-ASCII, British (`#` correctly renders as `£`), DEC Special Graphics line drawing, both DEC Alternate ROM sets, and SI/SO G0/G1 switching all correct. |
| 4 | Double-sized characters | **not implemented** | not implemented | Matches wintty exactly: double-width and double-height lines render as normal single-size text. A base-Ghostty limitation — `src/terminal/stream.zig` dispatches only `ESC #8` (DECALN); `ESC #3`/`#4`/`#5`/`#6` fall through. Not Windows- or D3D11-specific. |
| 8 | VT102 Insert/Delete Char/Line | **pass** | *pending* | Assessed here for the first time. The screen-accordion setup fills 80 columns per row correctly; the Delete Character rounds produce the required "right column staggered by one" diagonal and hold it across repeats; the ANSI Insert Character check renders its two `A B C ... Z` lines identically. |
| 5 | Keyboard | **partly assessed** | pending | The keyboard-layout diagram renders correctly (a dense reverse-video test in its own right). The Cursor Keys sub-test reports `(Unknown cursor key)`, but that is **not** an encoding fault — see below. |
| 6, 7, 9, 10, 11 | Reports, VT52, known bugs, reset, non-VT100 | not yet run | pending | Reachable here for the first time, since this harness can supply real key input and wintty's could not. |

## Section 1 must be run at 80 columns

On a wider terminal, section 1's **bottom `+` row alone** overruns — every other row of
the box stops correctly. That asymmetry is the clue, and it is vttest's own doing rather
than a terminal defect. From `tst_movements` in vttest's `main.c`:

```c
cup(max_lines - 1, inner_r - 1);   /* column 70 */
cuf(42 + hlfxtra);                 /* forward 42 -> 112, RELIES ON CLAMPING */
cub(2);
for (col = width - 2; col >= 3; col--) { tprintf("+"); ... }
```

That `cuf(42)` deliberately overshoots and depends on the cursor clamping at the right
margin. vttest computes for `width = 80`, so on an 80-column terminal the clamp lands at
80 and `cub(2)` yields 78 — the correct right end. On a wider terminal the clamp lands at
the *actual* width, so the row starts further right and overruns. Every other row uses an
explicit `cup(row, col)` and is unaffected.

Confirmed by measurement — the overrun endpoint tracks the terminal width, not the box:

| Terminal width | Bottom `+` row ends at |
|---|---|
| ~99 columns | column 96 |
| ~122 columns | column 115 |
| **80 columns** | **unbroken, edge to edge** |

Our clamping is correct: the cursor clamps at the real right margin. Clamping at 80
regardless of terminal width — which is what vttest implicitly wants — would be wrong.

This matches wintty's advice from the other direction; their notes call for "a
size-matched launch (fixed window on the primary monitor, no post-draw resize)" for
size-dependent sections. At the default DPI here, `--font-size=8` with a ~541px client
gives 80 columns.

## Cursor keys encode correctly; vttest's cursor test is inconclusive here

Section 5's Cursor Keys sub-test reports `<27>   (Unknown cursor key)`, i.e. it saw a
bare `ESC` rather than a full sequence. That reads like a key-encoding bug, and it is not.

Echoing the raw bytes instead — a shell running `stty raw -echo; cat -v` in the harness,
driven with the same synthetic Up/Down/Left/Right — produces:

```
^[[A^[[B^[[D^[[C
```

`ESC[A`, `ESC[B`, `ESC[D`, `ESC[C`: exactly the right ANSI cursor sequences, in the right
order. This is the first direct verification of the extended-key (`0xE0`) path in
`harness/hwnd-host/winkeys.c`, which nothing had exercised before.

vttest distinguishes a standalone `ESC` from an escape sequence with a short
inter-character timeout. The synthetic-input → ConPTY → WSL path evidently delivers the
`ESC` far enough ahead of the `[A` to defeat it. So the sub-test result is an artifact of
*how the keys are injected*, not of what the terminal sends, and it should not be recorded
as a pass or a failure. Assessing it properly needs real hardware key input, or a driver
that delivers the whole sequence within vttest's window.

## A false alarm worth recording

Section 8's final screen prints `Push <RETURN>^[%^[`, which looks like our terminal
failing to consume `ESC %` (the ISO-2022 character-set designator) and leaking it to the
screen. It is not. Feeding `ESC % G` and `ESC % @` directly through the harness renders
`BEGINAFTER-GAFTER-AT|` with no escape characters visible, so both are consumed
correctly — vttest was printing its own caret notation to show the reader what it sent.

Recorded because the failure mode is plausible enough to be worth not re-investigating,
and because the check took one command.

## Regressions vs wintty

**None.** Sections 1, 3 and 4 match the baseline, section 2 is assessed here for the first
time and passes the part wintty deferred, and section 8 is assessed here for the first
time and passes.

## PTY size — was a defect, now fixed

The child used to start believing the terminal was 80x24 regardless of the window,
because `apprt/embedded.zig` hardcoded an 800x600 initial surface size and the pty is
sized (and the child spawned) *during* surface init, so a size pushed afterwards arrived
too late. Fixed in ghostty `e74facf7d`: `Platform.Win32.initialSize()` reads the client
rect via `GetClientRect`.

Verified by asking the child rather than by eye — `stty size` inside the harness now
matches the window at whatever size it is launched:

| Window | `stty size` |
|---|---|
| default, `--font-size` unset | `18 71` |
| default, `--font-size=8` | `27 99` |

The digit that used to echo at the bottom-left of the menu now echoes after the prompt,
and the E-frame in section 1 is now hollow and correctly placed. Both were the same
mismatch.

## Running vttest: two things to get right

1. **vttest needs at least 24 rows.** Below that its layout breaks and section 1 draws
   the E-frame as solid rows rather than a hollow box. That is not a terminal defect. Use
   `--font-size` to fit: at the default DPI here, `--font-size=8` gives 27 rows.
2. **vttest draws at 80 columns.** It is a VT100 tester. On a wider terminal the box
   correctly occupies the left 80 columns. An 80-column window is required to see the
   border touch both edges.

## What this does and does not establish

It establishes that the renderer draws vttest's content correctly — cursor addressing,
scrolling regions, screen attributes, character sets and glyph shapes — and that no
regression against wintty exists in the sections both have assessed.

It does not yet cover sections 5-11, and section 1's size-dependent border needs re-running
once the PTY size defect is fixed. Until then this is **partial** evidence for the phase's
"vttest results recorded; no regressions vs wintty" criterion, not complete evidence.
