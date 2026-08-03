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
| 6 | Terminal reports | **pass** (all sub-tests) | pending | Primary Device Attributes returns `ESC[?61;6;7;21;22;23;24;28;32;42c`, which vttest decodes as VT100 family with selective erase, DRCS, horizontal scrolling, colour, Greek, Turkish, rectangular editing, text macros and ISO Latin-2. Device Status Report 5 returns `ESC[0n` ("TERMINAL OK") and DSR 6 returns `ESC[5;1R`, both marked OK. **Secondary DA** returns `ESC[>0;10;1c` — vttest decodes Pp=0, Pv=10 ("firmware version 1.0"), Pc=1 ("ROM cartridge registration number ok"). **Tertiary DA** returns `ESC P!|00000000 ESC \` — marked ok. **DECREQTPARM** returns `ESC[2;1;1;128;128;1;0x` for argument 0 and `ESC[3;1;1;128;128;1;0x` for argument 1, both marked OK, and correctly distinguishes solicited (2) from unsolicited (3). |
| 7 | VT52 mode | **not our behaviour — ConPTY** | pending | The section does not render its expected screen, but the cause is outside libghostty: **ConPTY emulates VT52 and the sequences never reach our engine**. Windows Terminal over the same ConPTY path is byte-for-byte identical. See below. |
| 9 | Known bugs | **pass (partial)** — no bug present | pending | The section checks a terminal does *not* reproduce documented VT100 defects. **Bug B (scrolling region)**: letters run `F`…`P` down the line starts with `A`–`E` correctly scrolled away, and `K`–`P` — the range vttest says to inspect — is not confused. **Wrap around with cursor addressing**: the top row is an unbroken line of `+`, the rightmost column is filled with `*`, nothing strays into the leftmost column, and the top line is not scrolled away. Both bugs absent. **Funny scroll regions** ran to completion without corruption, but only its first stage (20 correctly numbered lines, no scroll region) was individually assessed. Tests 3, 4 and 6 depend on DECCOLM and 5 and 8 on double-width lines — both already-recorded gaps — so they were not run. |
| 10 | Reset and self-test | **pass** (RIS + DECSTR) | pending | **DECSTR** (soft reset) and **RIS** (reset to initial state) both execute, clear the screen and leave the terminal in a sane state — vttest redraws its menu correctly afterwards in each case, which is the real check. DECTST (Invoke Terminal Test) not run. |
| 11 | Non-VT100 (VT220/VT320/XTERM) | not run | pending | |

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

## Section 7 (VT52): ConPTY emulates VT52, we never see it

Section 7 does not render the screen it describes ("a centered rectangle of `*`s with
`!`s on the inside ... Only this, and nothing more"). Two things are visibly wrong: a
column of `**Foobar` survives down the right-hand side, and the bottom `*` border is
drawn twice.

Both come from one cause, and the cause is not ours.

**What vttest assumes.** `tst_vt52` in `vt52.c` draws with deliberately out-of-range
cursor addresses and relies on the terminal ignoring the offending axis. Its own comment
says so, for the top border:

```c
/* Make the movement a little more complicated by using cursor-addressing
 * which is out of bounds vertically so that only the column is updated. */
vt52cup(1, 70);
for (i = 70; i >= 10; i--) { tprintf("*"); vt52cub1();
  if (i % 2) vt52cup(max_lines + 3, i - 1); else vt52cub1(); }
```

The cleanup loop that erases `**Foobar` works the same way — it addresses
`min_cols + 1 + adj` (column 82 or 83 on an 80-column terminal) for two rows out of every
three, expecting the column to stay where it was (71) so `EL` erases from there:

```c
for (i = 2; i <= max_lines - 1; i++) {
  int adj = i % 3;
  if (adj) vt52cup(i, min_cols + 1 + adj);   /* past right-margin of row i */
  else     vt52cup(i, box_r);                /* column 71 */
  vt52el();
}
```

So the rows where `i % 3 == 0` erase correctly and the other two thirds do not — exactly
the pattern on screen. And with the row clamped instead of ignored, half the top border's
`*`s land on the bottom row, which is the doubled bottom border.

**What actually happens.** Measured by byte, not by eye — each arm enters VT52, moves,
leaves VT52 with `ESC <`, then asks with `ESC[6n`, writing the answers to a file:

| Probe | Result | "ignore the axis" | "clamp the axis" |
|---|---|---|---|
| in-range `ESC Y` (8,40) | `ESC[8;40R` | — | — |
| column out of range (8,82) at 80 cols | `ESC[8;80R` | `ESC[8;20R` | **`ESC[8;80R`** |
| row out of range (30,40) at 27 rows | `ESC[27;40R` | `ESC[5;40R` | **`ESC[27;40R`** |

Both axes clamp. That is the defect vttest trips over.

**It is not libghostty's.** libghostty contains no VT52 implementation at all: no `ESC Y`
and no `ESC <` in `stream.zig`'s escape dispatch, and no DECANM entry in `modes.zig`
(`modeFromInt(2, false)` returns null). Yet the terminal answers `ESC[?2;1$y` to a DECRQM
for mode 2 and stops parsing CSI after `ESC[?2l`. The component that does implement it is
**ConPTY**, which parses and re-emits the child's output before libghostty ever sees it.

Confirmed by running the identical probe under Windows Terminal — a completely different
engine and renderer on the same `wsl.exe → ConPTY` path:

| | our harness (80 cols) | Windows Terminal (72 cols) |
|---|---|---|
| DECRQM mode 2 | `ESC[?2;1$y` | `ESC[?2;1$y` |
| in-range (8,40) | `ESC[8;40R` | `ESC[8;40R` |
| column out of range | `ESC[8;80R` (clamped to 80) | `ESC[8;72R` (clamped to 72) |
| row out of range | `ESC[27;40R` | `ESC[27;40R` |

Identical in kind, each clamping to its own width. So section 7 measures ConPTY, not the
terminal hosting it, and **there is no regression here** — any Windows terminal hosting a
ConPTY child behaves this way. It would only become our problem if libghostty were ever
fed VT52 directly, which the WT integration does not do.

Recorded at length because the first three attempts at this measurement were wrong in
three different ways, and the trap is reusable: a probe that runs `printf` inside `$( )`
has its escape sequences **captured by the command substitution** and never sends them to
the terminal at all; an arm that enters VT52 without `ESC <` leaves the *next* arm in VT52
and poisons it; and a column chosen as "out of range" is only out of range if the terminal
is actually the width you assumed.

## A false alarm worth recording

Section 8's final screen prints `Push <RETURN>^[%^[`, which looks like our terminal
failing to consume `ESC %` (the ISO-2022 character-set designator) and leaking it to the
screen. It is not. Feeding `ESC % G` and `ESC % @` directly through the harness renders
`BEGINAFTER-GAFTER-AT|` with no escape characters visible, so both are consumed
correctly — vttest was printing its own caret notation to show the reader what it sent.

Recorded because the failure mode is plausible enough to be worth not re-investigating,
and because the check took one command.

## Open: occasional wrong character from synthetic input

Twice during this sweep a `PostMessage`d digit arrived as an unrelated control character —
`7` came through as `^_` (0x1F) and `0` as `^[` (0x1B) — each time landing vttest on "Bad
choice, try again". Re-sending the same key immediately afterwards worked.

**Not yet attributed.** It is at least as likely to be the driver as the terminal:
`scratchpad/vt.ps1` posts `WM_KEYDOWN`/`WM_KEYUP` on fixed 120 ms/600 ms sleeps with no
handshake, so it can outrun the message pump. But a terminal that occasionally delivers
the wrong key would be a serious defect, and the user independently reported input feeling
laggy, so this should not be dismissed. Worth reproducing against `stty raw -echo; cat -v`
— which reads bytes directly and removes vttest from the loop — before deciding whether it
belongs to `winkeys`, the harness pump, or the driver script.

## Regressions vs wintty

**None.** Sections 1, 3 and 4 match the baseline. Sections 2, 6, 8, 9 and 10 are assessed
here for the first time and pass — wintty deferred section 2 and left the rest pending,
because its auto-feed harness could not drive them.

Section 7 (VT52) does not render correctly, but it is not a regression: the sequences are
consumed by ConPTY before libghostty sees them, and Windows Terminal on the same path
behaves identically. See the section 7 analysis above.

The query responses in section 6 also agree with wintty's esctest baseline, which
concluded that "the transport is clean and the only gaps are query types libghostty
deliberately does not answer". Nothing here contradicts that: the queries vttest asks
about are all answered, and answered correctly.

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

Every section has now been visited except 11 (non-VT100), and section 1 has been re-run at
80 columns since the PTY size defect was fixed. What remains open is narrow and recorded
above: section 11 not run, section 5's cursor-key sub-test inconclusive under synthetic
input, section 9's DECCOLM- and double-width-dependent tests skipped as already-known gaps,
DECTST not run, and the occasional wrong character from the input driver unattributed.

Two gaps are base-Ghostty behaviour rather than anything this backend introduced, and both
are recorded rather than fixed: double-sized characters (section 4) and DECCOLM
(section 2). One apparent failure — section 7's VT52 — is ConPTY's, not ours.

On that basis the phase criterion "vttest results recorded; no regressions vs wintty" is
**met**: results are recorded section by section, and no section regresses against wintty's
baseline.
