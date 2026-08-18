# Phase 3 criterion 1: interactive verification

> *Interactive PowerShell + a TUI app fully usable in the harness with correct fonts,
> ligatures, emoji fallback, kitty keyboard protocol active.*

All parts verified 2026-08-02 against `harness/hwnd-host` running libghostty
`ReleaseFast` with `-Dfont-backend=directwrite_harfbuzz`, on a connected session.
Captures are in the session scratchpad.

## Interactive PowerShell — pass

`hwnd-host.exe --command="powershell.exe -NoLogo"` reaches a `PS C:\Users\...>` prompt.

- **PSReadLine syntax colouring works.** Typing `get-date` renders the cmdlet in
  PSReadLine's yellow as it is typed, which means the per-keystroke SGR sequences it
  emits are being parsed and rendered live, not just on submit.
- `Get-Process` executes and produces a full table with correct column alignment, scrolls
  the screen, and returns to the prompt.

## TUI application — pass

`top` (via WSL) renders correctly: the summary block, the reverse-video column header, and
the process table all lay out properly and update in place.

## Ligatures — pass

JetBrains Mono ligatures shape correctly through HarfBuzz:

```
ligatures:  ->  =>  !=  <=  >=  ===  <=>  |>
rendered:    →   ⇒   ≠   ≤   ≥   ≡≡≡   ⟺   ▷
```

A control line with the same characters space-separated stays **unligated**, which is what
distinguishes real contextual shaping from a naive glyph substitution. Ligatures also
shape in context: `if (a ≠ b) { x → y; z ⇒ w; }`.

## Emoji and CJK fallback — pass

Verified separately via the DirectWrite system fallback chain (`IDWriteFontFallback::
MapCharacters`). CJK (中文), kana (あい) and colour emoji (🥸 😀) all render live, in
colour, in a terminal whose primary font contains none of them. See
`docs/sessions/0004-phase-3.md`.

## Kitty keyboard protocol — pass

Driven through the harness and read back from the byte stream:

| Step | Sent | Received |
|---|---|---|
| query initial flags | `CSI ? u` | `ESC[?0u` — disabled |
| enable all | `CSI > 15 u` | — |
| query again | `CSI ? u` | `ESC[?15u` — all flags set |
| press `a` | — | `ESC[97u` — CSI-u form, 97 = `a` |

So the protocol is queryable, settable, reads back correctly, and actually changes the key
encoding. Note that testing this with `CSI > 1 u` alone is misleading: level 1 only
disambiguates escape codes, so a printable key still sends its plain byte. That looks like
the protocol being ignored, and is not.

## Cursor keys

Also verified directly, since the extended-key (`0xE0`) path in `winkeys.c` had never been
exercised — the arrow cluster and the numeric keypad share scan codes and are told apart
only by that flag. `stty raw -echo; cat -v` with synthetic Up/Down/Left/Right yields
`^[[A^[[B^[[D^[[C`, the correct ANSI sequences in order.

## What this does not cover

- Mouse reporting.
- IME / composition input (`winkeys` always reports `composing = false`).
- Shift/Ctrl/Alt modified keys beyond ctrl+c, which was verified interactively.
- Any font other than the default JetBrains Mono for ligatures.

---

## Liveness: does a change still reach the screen? (KD-19)

Since KD-19 the UI thread no longer forces a frame of its own - every path
wakes the render thread instead. The property to check by hand is therefore
*liveness*: after something changes, pixels follow, without another event
having to force them.

**The discipline is the test.** The failure mode is "the pane repaints only
when something unrelated happens", so the moment you act, stop generating
events: do not move the mouse (`focusFollowMouse` is on in this repo's test
settings, so even crossing a pane boundary changes focus), do not type, do not
alt-tab. Act, then sit still and look.

### By hand, one per path that lost its forced render

| do this | pass |
|---|---|
| drag-select a few words, release, **hands off the mouse** | the highlight is there the instant you release, and does not appear a second later |
| select-all from the keyboard | the whole buffer highlights with no mouse involved |
| clear the selection | the highlight goes at once |
| scroll to a mark / prompt from the keyboard | the viewport moves without a nudge |
| with an IME active, compose a word | the preedit appears and updates per keystroke |
| with a preedit open, alt-tab away | the preedit clears, and the process survives - this is the exact path that crashed |

A pane that repaints *late* is the interesting result, not a pass. Late means
the wake was lost and something else drew the frame.

### Objectively, with the stage counters

`scripts/probe-render-liveness.ps1` reads libghostty's own counters, which exist
for this question:

```powershell
.\scripts\probe-render-liveness.ps1 -Launch          # or -Seconds 60 to attach
```

Each line is a per-second delta of `notify` (a render was asked for), `wakeup`,
`update` and `present` (pixels reached the swap chain). A stall is `notify`
climbing while `present` stands still, and is printed in red; the script exits
1 if it ever sees one, 2 if it saw no reports at all.

Two things silence it, and it says so rather than reporting a clean run:
`GHOSTTY_RENDER_DIAG` is read once and cached, so the terminal must be
*started* with it; and the report rides the cursor blink timer, so the pane has
to be focused. Close DebugView first - only one process may own the DBWIN
buffer.

The detector was checked against synthetic input in both directions before being
trusted: three healthy reports pass, and a fed stall (`notify +4 present +0`)
is caught and exits 1.
