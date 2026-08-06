# Phase 6 worklist — the four open interaction items

Written 2026-08-05 after a manual pass with the user. Each item has the symptom as the
user described it, what is known, and what the fix has to do. Items 1, 2 and 4 change
`ghostty/` and therefore belong to named patches on the `windows` branch (ADR 0004): one
commit per patch topic, each building and passing `zig build test` on its own.

## 1. `ghostty_config_set` should take a key and a value, not a line

**Patch 25, amended.** It currently reuses ghostty's config-*file* line parser, so every
setting crosses the boundary as `key = value` text. Nothing about ghostty required that -
it was the cheap implementation.

It failed the first time it met a real value: WT's default `wordDelimiters` contains a
backslash and a double quote, so the entry ended its own quoted string early and ghostty
got a truncated set. **The entry still parsed**, so nothing logged a rejection; the only
symptom was a double click selecting `Corporation.` where cascadia selected `Corporation`.

Escaping fixed the instance. The shape still admits the class.

- Add `ghostty_config_set_kv(config, key, key_len, value, value_len)` assigning the value
  verbatim, with no parsing of the value at all.
- WT side: `TranslateGhosttySettings` returns key/value pairs instead of formatted lines;
  the escaping in `setQuoted` disappears entirely.
- The existing settings tests change shape with it — they currently assert on strings like
  `font-family = "Cascadia Mono"`, which stop existing. Keep what each test *pins* (the
  quoting test becomes "the value arrives verbatim, including quotes and backslashes").

## 2. Triple-click highlights only to the last word, not the full row

**New patch.** Cascadia highlights the **entire width** of the line and trims surrounding
whitespace on copy. ghostty's line selection ends at the last cell with content, so the
highlight stops short. Confirmed by hand against a cascadia pane in the same window.

Not fixable from the WT side: the highlight is drawn from ghostty's own selection extent.

- Change ghostty's line selection to span the full row.
- **Confirm the copy half separately** before assuming it is fine: cascadia trims, and if
  ghostty's extent grows to the full row then its copy must trim too, or triple-click copy
  starts carrying trailing spaces. This is the regression the patch could introduce.

## 3. Drag rounding — caret model vs cell model

**WT side only.** Cascadia selects the character *under* the cursor and extends to the next
one at its **midpoint**. ghostty currently anchors one character late and extends the moment
the pointer touches the next character.

**The diagnosis is settled; the remedy is not.** `ControlInteractivity` has already applied
the midpoint rule before calling: the click site passes `round=true` ("rounding can push the
position to the next cell") and the drag anchor does `termPos.x++` when the drag runs
leftwards, to "place the anchor on the right side of the current cell". So what arrives at
`_mouseTo` is a selection **boundary**, not a character index.

Sending the cell centre re-reads that boundary as a character — the current bug. But sending
the cell **edge** was tried and is worse: it lands on the ambiguous seam, so the selection
flickered and dragging left dropped the character. That attempt is reverted (`40a760907`).

The models genuinely differ: WT's boundary means "before character N" when dragging right
and "after character N-1" when dragging left. ghostty anchors on a *cell*. Resolving it
needs the drag direction at the point the position is sent — either by tracking the anchor
in the core and biasing the pixel, or by not accepting the pre-rounded index.

**Measure before changing.** `GHOSTTY_HARNESS_SELECT` in `harness/hwnd-host` drives the
exact sequence and prints what ghostty selected; it is what caught the content-scale bug
correctly. Extend it to take pixel offsets rather than whole cells, establish ghostty's
sub-cell rule, and only then choose the mapping.

## 4. `ClearSelection` imitates ghostty's click handling

**New patch, small.** ghostty has no clear-selection binding, so `ClearSelection` sends a
press and release without movement, because that is what collapses a selection in ghostty's
own mouse handling. It is behaviour-by-imitation and would break silently if that handling
changed.

- Add a `clear_selection` binding action upstream-style, and call it.
- While there: the lazily-synthesised mouse release exists because WT never reports a
  button release outside VT mouse mode. Confirmed harmless (`has_selection` stays 1 across
  it), but a real "end selection" action would remove the inference too.

## Order

3 first — it is WT-side, needs no rebuild of libghostty, and is the one the user hits every
time they drag. Then 1 (amend patch 25, rebuild, re-run the settings tests), then 4 (small
patch, same rebuild cycle), then 2 (the one with a regression risk of its own).
