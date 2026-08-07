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

### KD-01 — Kitty graphics images render distorted — **closed 2026-08-07, not a defect**

**Reported** by the user, from use: an image sent with the Kitty graphics
protocol appeared skewed — wrong aspect ratio, not merely the wrong size.

**Measured, and the engine is right on every count.** Kept as a closed entry
rather than deleted, because the wrong conclusion was reachable from every
direction and the measurements are what stopped it.

#### What was measured

Three probes into a live ghostty pane, each photographed with
`harness/wgc-shot` and measured in pixels rather than judged by eye:

1. **Natural size.** A 200x100 raw-RGBA image (`f=32`, explicit `s`/`v`, no
   `c`/`r`) drew at exactly **200x100**, aspect 2.000, both axes scale 1.000,
   with its orientation marker in the right corner.
2. **Cell-sized.** The same image sent as `c=10,r=4` drew at **138x112** —
   13.8 px per column, 28 px per row, this pane's real cell size — with a
   five-band source rendering as five equal bands, in order, no offset and no
   clamping. The full source was sampled and scaled to exactly the requested
   cell box, which is what the protocol specifies for `c`/`r`.
3. **The size report, asked from inside the pane** — the path that matters,
   since a reply travels engine → WT connection → ConPTY rather than the
   harness's own pty:

   | query | reply | |
   |---|---|---|
   | `CSI 14 t` | window 1526 x 756 px | |
   | `CSI 16 t` | **cell 14 wide x 28 high** | matches the measurement in (2) |
   | `CSI 18 t` | 109 cols x 27 rows | 109x14 = 1526, 27x28 = 756 — consistent |

#### The actual cause

The producer was `chafa 1.14.0`, converting an SVG, with its output **captured to
a file** and replayed later. That capture's first APC control block is:

```
a=T,f=32,s=1264,v=632,c=158,r=79,m=1
```

A 1264x632 source — exactly 2:1 — asked to be displayed over 158 columns by 79
rows. Note `1264/158 = 8` and `632/79 = 8`.

**chafa is not at fault.** With no terminal on stdout it cannot learn the cell
geometry, so it falls back to a nominal 8x8 pixel cell — reproduced directly:

```
$ chafa -f kitty favicon.svg | head -c 300     # stdout is a pipe
a=T,f=32,s=464,v=232,c=58,r=29                 # 464/58 = 232/29 = 8
```

Run **live in a ghostty pane**, the same chafa command renders the image with
correct proportions. It asks, and this terminal answers correctly.

`c`/`r` mean "scale this image to fill that many cells", so replaying an
8x8-derived capture on this pane's real 14x28 cells draws it at 158x14 = 2212 by
79x28 = 2212 — **a perfect square**. Aspect 2.000 in, 1.000 out. kitty itself
would render it identically.

**The general lesson: kitty-protocol output captured to a file is
terminal-specific.** The `c`/`r` geometry is baked at generation time against
whatever cell size the generator believed.

#### What to do about it

Nothing in this repository. In a pipeline that pre-generates:

- **Generate at display time**, with the terminal attached — verified correct.
- **Or declare the cell shape**: `chafa --font-ratio 1/2` matches this pane's
  14x28 cells, and a file generated that way was replayed into a pane and came
  out identical to the live run.
- **Or omit `c`/`r`** entirely and send only `s`/`v`, letting the terminal place
  the image at its natural pixel size — probe 1 shows that path is exact.

#### The trap worth remembering

Two of the three hypotheses this entry originally carried were wrong, and both
were reachable by reading source: a row-pitch mismatch (dead — upstream converts
every image to RGBA before upload, `image.zig:851-872`) and a DPI error in our
geometry (dead — probe 1 is exact). A third, "our renderer mis-samples when
scaling", survived one bad screenshot: a 13-row image placed near the bottom of
the screen **scrolled while drawing**, which looks exactly like a vertical
sampling offset. Shrinking the image until it could not scroll made the same
test read clean.

A self-describing source image — coloured bands rather than a solid fill — is
what turned that around. It says directly which source rows landed where, so an
offset, a squeeze and a clamp are distinguishable by looking instead of inferred
from a bounding box.

