# Manual validation checklist

Everything here was found by hand, and everything here still needs a hand. The
automated coverage is listed at the bottom so it is obvious what this list is
*not* duplicating.

Run this against a Debug Windows Terminal with a profile carrying
`"engine": "ghostty"`. Read the whole of a step before doing it; several of the
bugs below only appear if you do not touch anything.

## Why these are manual

Each one needs a real window on a real GPU, and most need a human to notice
that something *looks* wrong rather than that a value is wrong. A unit test
sees a correct terminal; the defect is in the pixels, the window, or the
timing.

---

## 1. Repaint on output, unfocused

The Phase 5 freeze. libghostty's wakeup async coalesces by design, so a notify
that lands just after the render thread sampled state can be folded into a
wake that has already finished - and nothing draws the result.

1. Open a ghostty pane, split it (`alt+shift+d`) so there are two.
2. **Click the other pane** so the ghostty one is not focused.
3. In the ghostty pane's shell, run something long: `dir C:\Windows\System32`.
4. Do not touch the mouse. Do not resize.

**Pass:** the output appears as it is produced.
**Fail:** the pane holds a stale frame and only catches up when you scroll.
Note precisely what unstuck it - the first time this was found, resizing did
*not* force a redraw and scrolling did, which is what identified the wakeup
rather than the swap chain.

## 2. Non-ASCII output

Covered automatically for the harness (see below), but not for Windows
Terminal's own control.

1. `wsl aptitude` - box drawing, a full-screen TUI.
2. Anything with wide CJK and emoji.

**Pass:** it draws, and the pane survives.
**Fail:** the whole terminal process dies. That is the CRT static-initializer
regression; the smoke script's first check names it.

## 3. Padding and borders

1. Open a ghostty pane beside a cascadia one.
2. Compare the inset on all four edges.

**Pass:** the two panes are inset identically.
**Fail:** the ghostty pane has a visible frame, or its content is shifted. It
is padded twice - Windows Terminal insets the SwapChainPanel and ghostty pads
inside that. Check all four edges: the first fix for this removed the right
and bottom inset only, which reads as "it moved" rather than "it is still
wrong".

## 4. Font size and DPI

1. Open a ghostty pane. Compare its text size with a cascadia pane at the same
   profile font size.
2. Drag the window to a monitor at a different scaling (150% vs 200%).
3. Change the scaling of the current monitor while the window is open.

**Pass:** the text matches the cascadia pane and stays right across the move.
**Fail:** text is scaled by the DPI factor (1.5x, 2x). XAML always scales a
swap chain bound to a SwapChainPanel; the engine applies an inverse matrix to
cancel it, and that has to survive a DPI change and a device loss, not just
startup.

## 5. Tab tear-off

The one that only appears if you do something odd with the window.

1. Open a ghostty pane.
2. Drag the tab out of the window to make a new window.
3. Type in it.

**Pass:** it keeps rendering and keeps taking input in the new window.
**Fail:** blank pane, or input goes nowhere. Detach/attach has to re-capture
the dispatcher and re-raise the swap chain to the new control.

## 6. Close confirmation

Windows Terminal has no "a process is still running" prompt - `_ShouldWarnOnClose`
keys off `confirmOnClose` plus the tab and pane counts, and never asks the
core anything. So this is engine-independent by construction, and the only
part a ghostty pane participates in is the read-only dialog, which reads
`IControlCore::IsInReadOnlyMode`.

1. Set `"confirmOnClose": "always"`, or open two panes in one tab.
2. Close the window. The confirmation should appear as it does with cascadia
   panes only.
3. Toggle read-only on the ghostty pane (`toggleReadOnlyMode`), then close the
   pane.

**Pass:** step 2 warns; step 3 shows the read-only close dialog.
**Fail on step 3 only** would mean the ghostty core's read-only flag is not
reaching the app.

---

## What is covered automatically

Do not re-test these by hand unless one of them is what you are changing.

| Check | Where |
| --- | --- |
| Settings -> ghostty config: font quoting, infinite vs finite scrollback, zero padding, scheme and full palette | `UnitTests_Control` / `GhosttySettingsTests.cpp` |
| `"engine": "ghostty"` parses and warns only on genuinely unknown names | `UnitTests_SettingsModel` / `ProfileTests.cpp` |
| Engine factory: cascadia is the default, and a ghostty profile falls back to cascadia when libghostty will not start | `UnitTests_Control` / `GhosttyEngineSelectionTests.cpp` |
| Non-ASCII output does not crash a host process | `scripts\smoke-harness.ps1` check 1 |
| Input reaches the child over the external backend | `scripts\smoke-harness.ps1` check 2 |
| Child output reaches the screen at all | `scripts\smoke-harness.ps1` check 3 |

Note what check 3 is not: it does **not** reproduce item 1 above. Removing
Windows Terminal's post-write render call still leaves it passing, because the
harness's own wakeup path repaints anyway. The unfocused split-pane case is
still a human's job.
