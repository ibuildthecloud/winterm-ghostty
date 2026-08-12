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

> **Re-check this whenever the render throttle changes.** Phase 7 replaced the
> per-chunk `render_now` this step exists to guard with an 8 ms trailing
> throttle, which is exactly the shape of change that could bring the freeze
> back.
>
> **Checked 2026-08-07, focused pane, passes.** `dir /s C:\Windows\System32`
> followed by a marker echo: photographed at 3 s (mid-scroll, actively moving)
> and at 8 s (complete - 25,005 files, the marker, and the prompt back), with
> no scroll, resize or keystroke in between. The last batch reaching the screen
> is the whole assertion: the freeze's signature is precisely that it does not.
> Driven by `keyshot2.ps1` in the session scratchpad - launch, force focus,
> type, photograph with `harness/wgc-shot` at fixed offsets.
>
> **The unfocused half of this step is still unchecked**, and it is the half
> the original bug needed: the freeze was found in a pane that was not
> focused. A split with focus elsewhere still wants a human.

## 1b. The child agrees with the pane about its size

Added after KD-02, where a ghostty pane told its shell it was 56x18 while being
109x27 — for six phases, in plain sight, because nothing ever asked.

1. Open a ghostty pane.
2. Run `wsl -d <distro> stty size` (or `mode con` without WSL).
3. Compare with the pane's own answer: run the `askcell` probe, or count.

**Pass:** rows and columns match the pane, immediately, without resizing the
window first.
**Fail:** they disagree — and note whether resizing the window corrects it. That
asymmetry is the signature of a size applied before the pseudoconsole is ready
to receive it, and it is what disguised this as a rendering quirk.

Worth doing after any change to connection startup, surface sizing, or the
`resize_pty` path.

## 1c. Which rasterizer the pane got, and WARP

Phase 7's third criterion is "usable over RDP (WARP) with no fallback dialogs",
and until 2026-08-07 it had only ever been checked in `harness/hwnd-host` — a
different presentation path from a pane, on a machine with a working GPU.

The device now reports itself through `OutputDebugString`, which is the only
channel a packaged app has. Capture it with a DebugView-style listener (there is
a minimal one in the session scratchpad, `dbwin.ps1`) while opening a pane:

```
[ghostty-d3d11] device: driver=hardware feature_level=11_1 size=800x600
```

1. Open a ghostty pane. **Pass:** a `device:` line naming a driver.
2. Relaunch with `GHOSTTY_D3D11_DRIVER=warp` in the launching shell's
   environment. **Pass:** `driver=warp`, the pane renders identically — check
   something non-trivial, colours and CJK and an image — and **no dialog
   appears**.
3. Over RDP, repeat 1. **Pass:** whichever driver it picks, the pane renders.

**Status: all three verified 2026-08-07, in a pane, over a live RDP session**
(`rdp-tcp#0`, Active). A GPU *is* exposed to the remote session here, so a pane
picks `driver=hardware feature_level=11_1` over RDP; forced WARP renders
`driver=warp feature_level=11_1`. No dialog in either case.

The two renders were compared rather than eyeballed: 344,199 sampled pixels,
**0 differing by more than 8**, max channel delta 1. WARP output is
pixel-equivalent to hardware.

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

## 6. Keyboard input

The unit tests pin the translation rules, but nothing automated presses a key.

1. In a ghostty pane, type `dir` and Enter. Then `cd ..` and Enter.
2. Backspace over some text. Use the arrow keys, Home and End.
3. Try ctrl+c on a running command.

**Pass:** what you typed is what arrives, and nothing extra happens.
**Fail:** characters go missing, or a letter behaves like a different key -
`d` acting like Delete, or `cd` opening cmd's "Enter command number:" prompt.
That is the virtual key being sent where ghostty wants the native keycode.
Steps 2 and 3 matter most: the extended keys carry a 0xE000 prefix, and
control characters must reach ghostty as *keys*, never as text.

## 7. Close confirmation

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

## 8. A background window's pane is not focused (KD-04)

A terminal that is not in front must not look focused or cost anything. The
mechanism this guards is subtle enough that it was diagnosed wrongly twice:
XAML's routed `GotFocus` fires for a control in a window that has *never* been
brought to the front, and `WM_ACTIVATE` says "active" for that window too, so
the only truthful signal is the foreground window itself.

Most of this is scriptable, and `scripts\probe-idle-focus.ps1` does it: it
proves the engine from the process under test, then counts libghostty's blink
reports while the window sits behind another one. Run that first.

```powershell
.\scripts\probe-idle-focus.ps1                 # a profile with "engine": "ghostty"
```

**Pass:** ~0 blink reports per second in the background, against ~1.7/sec while
in front. The script prints both, and fails if the background rate is above 0.5.

What still needs eyes, because nothing here can see a pixel WT draws, and
because a focus gate that is too aggressive fails in the *other* direction:

1. Open a window on a ghostty profile and click into the pane. **The cursor is
   drawn; typing works.**

   Whether it *blinks* is not the check, and expecting it to blink will mislead
   you: a cascadia pane obeys the Windows "show blinking cursor" setting
   (`SM_CARETBLINKINGENABLED`, off on this machine, which is why its cursor sits
   steady) while a ghostty pane ignores it and blinks regardless. That
   difference is KD-05, not this. What matters here is drawn versus absent.
2. Click another application. **The cursor goes** (`cursor-style-unfocused`) and
   the pane does not blink.
3. Click back. **The cursor returns.**
4. Do 1-3 again with a **cascadia** pane beside it. It must *appear on focus and
   go on unfocus* the same way - the gate is in `TermControl`, which both
   engines share, so this is the regression check for the shared half. Its
   cursor may well not blink where the ghostty one does; see above.
5. The case the defect was actually about: a window that is never brought to the
   front. **Do not test this by launching a terminal and not clicking it** - a
   launch normally wins the foreground, so the pane is focused, and a blinking
   cursor there is correct. That version of this step wasted a round of
   validation.

   Let the script arrange it and watch the screen:

   ```powershell
   .\scripts\probe-idle-focus.ps1 -HoldForeground -KeepOpen
   ```

   `-KeepOpen` leaves the terminal up at the end rather than closing it three
   seconds later, which is not long enough to decide whether a cursor is there.

   It puts Paint in front first and keeps taking the foreground back for the
   terminal's first seconds, so the terminal really does come up behind it, and
   then reclaims the foreground at the end so the silence can be told apart from
   a diagnostic that never ran. A pass reads:

   ```
   phase: never activated (the foreground never came here)
     blink reports:  0 before  |  0 during 12.0s in the background (0.00/sec)  |  3 after coming back
   ```

   Silent while it was never in front, blinking the moment it was - same window,
   same run.

   **While it runs, look at that terminal window: it must show no cursor at
   all**, and take one when the script brings it forward at the end. That part
   is still eyes only; nothing here can see a pixel WT draws.

---

## What is covered automatically

Do not re-test these by hand unless one of them is what you are changing.

| Check | Where |
| --- | --- |
| Settings -> ghostty config: font quoting, infinite vs finite scrollback, zero padding, scheme and full palette | `UnitTests_Control` / `GhosttySettingsTests.cpp` |
| `"engine": "ghostty"` parses and warns only on genuinely unknown names | `UnitTests_SettingsModel` / `ProfileTests.cpp` |
| Engine factory: cascadia is the default, and a ghostty profile falls back to cascadia when libghostty will not start | `UnitTests_Control` / `GhosttyEngineSelectionTests.cpp` |
| Key translation: native keycode not virtual key, the 0xE000 extended prefix, control characters never sent as text | `UnitTests_Control` / `GhosttyKeyTests.cpp` |
| Non-ASCII output does not crash a host process | `scripts\smoke-harness.ps1` check 1 |
| Input reaches the child over the external backend | `scripts\smoke-harness.ps1` check 2 |
| Child output reaches the screen at all | `scripts\smoke-harness.ps1` check 3 |

Note what check 3 is not: it does **not** reproduce item 1 above. Removing
Windows Terminal's post-write render call still leaves it passing, because the
harness's own wakeup path repaints anyway. The unfocused split-pane case is
still a human's job.
