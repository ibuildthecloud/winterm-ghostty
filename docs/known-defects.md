# Known defects

Things a ghostty pane gets **wrong**, as opposed to things it deliberately does
differently. Those live in [documented-diffs.md](documented-diffs.md), and the
distinction is the point: a diff is a decision with a cost attached, a defect is
a bug nobody chose.

**Each entry has a stable ID** (`KD-nn`), for the same reason the diffs do —
there is no issue tracker wired to this repository, so the ID is what an issue
would be filed against.

Each entry says how it was found, what is actually known versus suspected, and
**the measurement that would tell the hypotheses apart**. That last part matters
more than the hypothesis: this project has repeatedly produced a plausible cause
by reading source and had it turn out wrong.

---

### KD-01 — Kitty graphics images render at the wrong scale

**Reported** 2026-08-07 by the user, from use: an image sent with the Kitty
graphics protocol appears — so transmission, storage, placement and the D3D11
image pipeline all work — but it is drawn at the wrong size.

**Not** the same thing as GD-14. Sixel is absent by design; this is a feature
that works and is drawn incorrectly.

#### What is known

- Something renders, so `prepKittyImage`, the placement list, the structured
  buffer and `image.hlsl` are all functioning end to end.
- Text on the same surface is correct, which rules out anything that scales the
  whole swap chain uniformly — including patch 26's `SetMatrixTransform`, which
  undoes XAML's scaling of a `SwapChainPanel` for every pipeline at once.
- This machine composites at **1.5** (`CompositionScale 1.50`, recorded in
  Phase 2), so a DIP-versus-physical-pixel error would show as a 1.5× or 1/1.5×
  size error specifically.

#### Two hypotheses, and they need different fixes

1. **We draw it at the wrong size.** Images carry their own pixel geometry
   (`dest_size` in `image.hlsl`, from `rp.dest_width`/`dest_height` via
   `renderPlacement(storage, &image, cell_size.width, cell_size.height)`),
   whereas text is positioned purely by the cell grid. So a cell size passed in
   the wrong units would mis-size images while leaving text perfect. The
   DIP-versus-physical class of bug has already bitten this project twice — in
   `set_size`, and in the SwapChainPanel transform.

2. **We tell the application the wrong size, and it sends a wrongly-sized
   image.** Kitty clients commonly ask the terminal for its window and cell
   pixel dimensions (`CSI 14 t` / `CSI 16 t`; ghostty implements size reports,
   see `include/ghostty/vt/size_report.h`) and scale the image *before*
   transmitting. If that report is wrong, the image arrives wrong and the
   renderer draws exactly what it was given.

Hypothesis 2 would also mean the bug is invisible to any test that constructs
the escape sequence itself, because such a test never asks.

#### The measurement that separates them

Emit a Kitty graphics sequence carrying an image of a **known pixel size**, with
the size specified explicitly rather than negotiated, then photograph the pane
and measure the drawn rectangle:

- drawn size ≠ requested size → **hypothesis 1**, and the ratio names the cause
  (1.5 or 1/1.5 is DPI).
- drawn size == requested size → **hypothesis 2**; then compare what `CSI 14 t`
  and `CSI 16 t` report against the pane's real pixel dimensions.

Both halves are automatable with `harness/wgc-shot` plus the focus/typing script
from session 0008 — no human needed, and the measurement is in pixels rather
than in someone's impression of "too big".

#### Owner

Phase 7 (presentation). It should be measured **before** the phase commits to
damage-gated presentation, because the image pipeline's geometry is part of what
a dirty-rect calculation would have to get right.
