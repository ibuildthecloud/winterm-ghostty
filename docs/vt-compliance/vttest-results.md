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
| 1 | Cursor movements | **pass, with a harness caveat** | pass | Cursor-control characters inside ESC sequences render the required four identical lines. The initial full-screen border was **not** unbroken: the right edge drew at column ~79 while the surface was ~100 columns. See "PTY size" below — this is a startup-ordering defect in the harness, not a renderer fault. |
| 2 | Screen features | **pass (partial)** | *deferred — harness* | wintty could not assess this. Here the section ran to completion. **DECSCNM verified by pixel measurement**: light background is `#FFFFFF`, dark is `#282C34`. **DECCOLM (132-column) is not honoured** — the ruler wraps, i.e. the terminal stays at its window width. Most modern terminals ignore DECCOLM deliberately. |
| 3 | Character sets | **pass** | pass | US-ASCII, British (`#` correctly renders as `£`), DEC Special Graphics line drawing, both DEC Alternate ROM sets, and SI/SO G0/G1 switching all correct. |
| 4 | Double-sized characters | **not implemented** | not implemented | Matches wintty exactly: double-width and double-height lines render as normal single-size text. A base-Ghostty limitation — `src/terminal/stream.zig` dispatches only `ESC #8` (DECALN); `ESC #3`/`#4`/`#5`/`#6` fall through. Not Windows- or D3D11-specific. |
| 5-11 | Keyboard, reports, VT52, VT102, known bugs, reset, non-VT100 | not yet run | pending | Newly *reachable* here, since keyboard input works. |

## Regressions vs wintty

**None attributable to the renderer.** Sections 3 and 4 match the baseline exactly.
Section 2 is assessed here for the first time and passes the part wintty deferred.

The one visible difference — section 1's broken border — traces to the PTY size, not to
drawing. Glyph placement itself is correct: the centred E-frame is intact, and `dir`,
`top` and the character-set grids all align. wintty's own notes describe the same class
of artifact in their harness ("the inner `script` pty size and a post-launch window
resize do not match Wintty's grid, which produces layout artifacts that are *not* Wintty
bugs"), but ours has a concrete cause worth fixing.

## PTY size (open defect)

The child starts believing the terminal is 80 columns while the surface is ~100. The
D3D11 device is created at `800x600` (80 columns at 10px cells) and the window only
reports its real client size afterwards, so anything spawned before that resize
propagates sees the smaller grid. Evidence:

- The right `*`/`+` border drew at column ~79 on a ~100-column surface.
- Within the *same* screen, the bottom `+` row extended to column ~98 — so a resize did
  arrive, just after vttest had already queried its size.
- After a manual window resize, the borders spanned the full width, confirming the resize
  path works and only the ordering is wrong.

To confirm which of the two it is, run `wsl.exe -- stty size` in the harness and compare
with the window's column count: a flat mismatch means the resize never reaches the child,
matching values mean it is purely a startup race.

Also observed while at the menu: a typed digit echoed at the bottom-left of the screen
rather than after the prompt, which is consistent with the same row/column mismatch.

## What this does and does not establish

It establishes that the renderer draws vttest's content correctly — cursor addressing,
scrolling regions, screen attributes, character sets and glyph shapes — and that no
regression against wintty exists in the sections both have assessed.

It does not yet cover sections 5-11, and section 1's size-dependent border needs re-running
once the PTY size defect is fixed. Until then this is **partial** evidence for the phase's
"vttest results recorded; no regressions vs wintty" criterion, not complete evidence.
