# Selection geometry: what each engine does with a pointer position

Measured 2026-08-05, against both running engines. Phase 6 worklist item 3 said
"measure before changing"; this is that measurement, and it settles the remedy.

Neither rule here was taken from a description or from reading alone. The cascadia
half came out of `UnitTests_Control::SelectionDragGeometryTests`, which drives
`ControlInteractivity::PointerPressed/Moved` in pixels against a real `ControlCore`
and reads the selection back. The ghostty half came out of
`GHOSTTY_HARNESS_SELECT_SWEEP` in `harness/hwnd-host`, which drags across a ruler
line one pixel at a time and prints the selected text.

## Both engines are boundary models

A selection is a half-open interval of *cell boundaries*, not a pair of cells. Both
engines agree on that. They disagree only on how a pixel becomes a boundary.

```
     cell 4          cell 5          cell 6
 ┌───────────────┬───────────────┬───────────────┐
 4               5               6               7      <- boundaries
```

## cascadia

Sweeping press and drag positions across whole cells at 20%-of-a-cell steps, on a
9x19 cell:

```
dragging right:  [ floor(press.x / w) , round(drag.x / w) )
dragging left:   [ round(drag.x / w)  , floor(press.x / w) + 1 )
```

Two consequences, both verified by the sweep:

1. **The cell the drag started on is always selected whole**, in either direction,
   and *where inside it the press landed makes no difference*. The press site does
   round to the nearest cell (`_getTerminalPosition(..., round: true)`), but the
   first drag movement re-anchors with `floor`, `+1` when the drag runs leftwards,
   and that throws the rounding away. This is the fact that misled: the rounding at
   the press site looks load-bearing and is not.
2. **The far end moves at a cell's midpoint.**

## ghostty

`SelectionGesture.zig` uses one threshold for both ends, at 60% of the cell width -
`@round(cell_width * 0.6)`, with the comment "chosen empirically because it felt
good". Confirmed on the real engine at a 14px cell (threshold 8px), scale 1.5,
`padding_left` 4px:

```
b60(x) = floor((x - padding_left) / w) + (frac >= round(0.6 * w) ? 1 : 0)

selection = [ min(b60(press.x), b60(drag.x)) , max(...) )
```

Measured: the drag end flips at physical x ≡ 8 (mod 14) across six consecutive
cells, and the press flips the anchor between mouse x=45 and x=46 - both exactly
where a 60% threshold predicts, in both drag directions. Padding is in the formula
because it is really there: the fit is exact with `padding_left = 4` and impossible
without it. Windows Terminal pins `window-padding-x/y` to zero for its ghostty
surfaces (it insets the SwapChainPanel itself), so the term vanishes there - but it
vanishes *by configuration*, not by nature.

## Therefore

WT hands its core **boundaries already**, not cells: the anchor from
`SetSelectionAnchor` and the far end from `SetEndSelectionPoint`. The mapping to
ghostty is one line - to mean boundary `B`, send a pixel inside cell `B` at a
fraction below 0.6:

```
pixel(B) = (B + 0.25) * cellWidth        // DIPs; 0.25 is a margin either side
```

Sending the cell *centre*, which is what the code did, works out to the same
boundary (0.5 < 0.6) - so the far end of a drag was never the bug. **The bug was
which position the press used.** `LeftClickOnTerminal` fires before the drag
direction is known and carries WT's rounded index, so ghostty latched its anchor
one cell late whenever the click landed in the right half of a character. The
direction-corrected anchor arrives afterwards, from `SetSelectionAnchor`, and the
old code delivered it as a mere mouse *move* - ghostty had already latched.

The fix is to press at the anchor, not at the click. ghostty latches the anchor on
a press and will not re-latch: a second press within one cell width and inside
`mouse-interval` is a double click, which selects by word. So the press has to be
preceded by something that ends the click sequence - which is the `clear_selection`
action of worklist item 4. **That is why item 4 now lands before item 3**, against
the worklist's stated order.
