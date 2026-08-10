# winterm-ghostty: every mouse press is reported twice

Written 2026-08-09. This is a terminal-side report, not an application bug.
Everything below is measured in a standalone program with **no kitty graphics,
no images, and no RDP** - the only thing involved is terminal input.

## Resolved 2026-08-09

**Cause: mouse reporting was not implemented.** `SendMouseEvent` returned "not
handled" and `IsVtMouseModeEnabled` returned false, so Windows Terminal routed
every pointer event down its *selection* path. Applications saw events only as a
by-product: the selection path drives ghostty's mouse to make selections, and
ghostty reports whatever mouse input it receives.

That single cause explains all three observations:

- **Presses double** — two `MOUSE_PRESS` call sites (`SetSelectionAnchor`, and
  `LeftClickOnTerminal` replaying one press per click of a multi-click) against
  one release site. Hence the asymmetry.
- **A lone click sends no press at all**, which is why click handling was
  erratic rather than merely doubled.
- **Right-click never arrives** — the selection path only ever passes
  `GHOSTTY_MOUSE_LEFT`. Nothing was consuming right-click for a context menu; it
  was never sent.

**The 1015/1006 dual-encoding hypothesis below was wrong**, though it fitted the
evidence well, including the press/release asymmetry. The duplication happens
before encoding. `VRDP_MOUSE_SGR_ONLY=1` would not have helped.

Two corrections for anyone reading the original report: this was **not** an
upstream ghostty bug — upstream receives real mouse events where we synthesised
them from selection callbacks — and stock Windows Terminal works because
cascadia's `SendMouseEvent` is fully implemented. Neither comparison would have
pointed at the cause.

Fixed in `GhosttyControlCore`: `IsVtMouseModeEnabled` now answers from
`ghostty_surface_mouse_captured`, and `SendMouseEvent` dispatches left, right and
middle press/release plus scroll on both axes, with modifiers. Confirmed by the
reporter with the probe below. Recorded as GD-07 in documented-diffs.md.

The report that follows is kept unedited, because the measurement in it was
right and only the hypothesis was wrong.

---

## Symptom

One physical left-click produces **two identical `Down` events and one `Up`**.
Held-button state as seen by an application therefore goes
`down, down, up, down, down, up, ...`, which most applications do not treat as
a click at all. Users see "the first click works, later ones don't", "only
double-click registers, and it registers as a single click", and drag not
working (a drag needs a clean down).

## Evidence

Captured with `src/bin/input_probe.rs` in `~/src/vrdp` (run it with
`cargo run --bin input-probe`; it prints each decoded event with a timestamp and
writes `/tmp/input-probe.log`). Three separate clicks, unmodified transcript:

```
[ 20.650] raw Mouse(MouseEvent { kind: Down(Left), column: 58, row: 11, modifiers: KeyModifiers(0x0) })
[ 20.650] raw Mouse(MouseEvent { kind: Down(Left), column: 58, row: 11, modifiers: KeyModifiers(0x0) })
[ 26.678] raw Mouse(MouseEvent { kind: Up(Left),   column: 58, row: 11, modifiers: KeyModifiers(0x0) })

[ 28.030] raw Mouse(MouseEvent { kind: Down(Left), column: 26, row: 16, modifiers: KeyModifiers(0x0) })
[ 28.030] raw Mouse(MouseEvent { kind: Down(Left), column: 26, row: 16, modifiers: KeyModifiers(0x0) })
[ 31.197] raw Mouse(MouseEvent { kind: Up(Left),   column: 26, row: 16, modifiers: KeyModifiers(0x0) })

[ 32.615] raw Mouse(MouseEvent { kind: Down(Left), column: 44, row: 21, modifiers: KeyModifiers(0x0) })
[ 32.615] raw Mouse(MouseEvent { kind: Down(Left), column: 44, row: 21, modifiers: KeyModifiers(0x0) })
```

Note the pairs share a **timestamp to the millisecond** and identical
coordinates. This is not delivery batching or a slow reader; it is the same
event reported twice.

The asymmetry is the interesting part: **presses double, releases do not.**

## What was ruled out

- **Not the kitty graphics protocol.** The probe renders nothing and never
  transmits an image. Duplication happens with input alone.
- **Not RDP.** The probe has no network connection of any kind.
- **Not output buffering.** An earlier version of the probe was piped through
  `tee`, which genuinely did cause late, bursty behaviour - because with a pipe
  on stdout the mouse-enable sequences go into the pipe rather than the
  terminal. That was a harness bug and is fixed; the duplication survives it,
  with stdout a real tty.
- **Not the application's decoding.** The duplicates are visible in the *raw*
  crossterm events, before any interpretation.

## Leading hypothesis: two mouse encodings answered at once

crossterm's `EnableMouseCapture` emits:

```
ESC[?1000h ESC[?1002h ESC[?1003h ESC[?1015h ESC[?1006h
```

That enables **both** `1015` (urxvt extended coordinates) **and** `1006` (SGR
extended coordinates). A terminal is expected to pick one encoding - SGR takes
precedence - and report each event once. If the terminal instead answers in
both encodings, a client parsing the stream sees every event twice.

This also explains why only presses double. The SGR encoding names the button
on release (`ESC [ < 0 ; x ; y m`); the legacy/urxvt encoding reports a release
as "some button released" without identifying which, so a parser can attribute
two presses but only one usable release.

**Test for this:** enable the modes by hand *without* 1015 -

```
ESC[?1000h ESC[?1002h ESC[?1003h ESC[?1006h
```

The probe does exactly this under `VRDP_MOUSE_SGR_ONLY=1`. If duplicates
disappear, the terminal is answering in multiple encodings and should suppress
all but the highest-precedence one. If they persist, it is emitting each report
twice regardless of encoding and the fault is elsewhere in the mouse path.

## How to reproduce without the spike

Any program that enables mouse reporting will do; the spike is not required.
The minimum is to put the terminal in raw mode, write
`ESC[?1000h ESC[?1002h ESC[?1003h ESC[?1015h ESC[?1006h`, and print the bytes
that arrive on stdin. A single click should produce one press report and one
release report. Compare the same program under stock Windows Terminal and, if
available, upstream ghostty - that separates "our fork" from "ghostty" from
"the Windows Terminal control".

## A second, probably related finding

**Right-click never reaches the application at all.** Across a long session,
zero `BUTTON2` events were ever observed (18 left-down, 9 left-up, 6 move, 0
right). The terminal appears to consume right-click - plausibly for
paste/context-menu - even while an application has mouse reporting enabled. An
application that has asked for mouse reporting should receive right-click.

## Why this matters beyond the spike

Any full-screen mouse-driven TUI in this terminal will misbehave the same way:
duplicated presses break click handling, and the missing right button removes
context menus. Both are terminal-level correctness issues rather than
application quirks.
