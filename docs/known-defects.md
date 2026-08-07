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

### KD-01 — Kitty graphics images render distorted — **partially explained; see KD-02**

**Reported** by the user, from use: an image sent with the Kitty graphics
protocol appeared skewed — wrong aspect ratio, not merely the wrong size.

**The image *drawing* is right on every count — but the terminal lies to the
child about its size, and that is [KD-02](#kd-02).** A client that sizes its
output from the terminal is therefore given bad input, which is enough on its
own to produce the reported distortion. This entry was briefly closed as "not a
defect"; that verdict was wrong and is corrected here.

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


---

### KD-02 — The child is told the wrong terminal size — **fixed 2026-08-07**

**Found** 2026-08-07, while chasing KD-01, by reading a `script` capture header
that said `COLUMNS="56" LINES="18"` in a pane that is 109x27.

Confirmed directly. In a ghostty pane, `wsl -d Ubuntu-24.04 stty size` answers:

```
18 56
```

while the same pane's own reports, measured in the same session, are:

| | |
|---|---|
| `CSI 18 t` (text area) | **109 cols x 27 rows** |
| `CSI 14 t` (window px) | 1526 x 756 |
| `CSI 16 t` (cell px) | 14 x 28 |

Those three agree with each other and with the rendering — 109x14 = 1526,
27x28 = 756. The **ConPTY** does not agree with any of them.

#### Why nobody saw it

It is visible in every screenshot taken this session and I looked past all of
them: typed commands wrap at about column 56 in a 109-column window. It reads as
normal terminal wrapping unless you are counting.

#### What it breaks

Everything that asks the terminal how big it is, not just images:

- Line wrapping — half the pane is unusable for long lines.
- Any full-screen TUI: `vim`, `less`, `top`, `htop` will draw into a 56x18 box.
- Image clients like `chafa`, which size their output from the view they are
  told about. This is the KD-01 connection: the terminal reports **correct
  pixels and wrong cells**, so a client deriving cell geometry from the two gets
  an inconsistent answer.

#### Where to look

The plumbing exists and is wired: libghostty's `resize_pty_cb` →
`GhosttyEngine::_resizePty` (`GhosttyEngine.cpp:308-314`) →
`GhosttyControlCore::ResizeConnection` (`GhosttyControlCore.cpp:392-401`) →
`_connection.Resize(rows, columns)`. So the question is not whether the path is
connected but **what values travel it and when** — whether libghostty ever calls
back with the final grid, or only with an early one before the surface reaches
its real size.

56x18 is suspicious in itself: the Phase 5 report records the first ghostty pane
running `OpenConsole.exe --headless --width 56 --height 18`. That suggests an
initial size that is never corrected, which would mean **this has been wrong
since Phase 5** and no test has ever asked the child how big it thinks it is.

#### The check that should exist

`wsl stty size` (or `mode con`) against the pane's own `CSI 18 t`, in the smoke
run or the manual list. Nothing automated has ever compared the two, which is
exactly how a bug this visible survived six phases.

#### Root cause

`ConptyConnection::Resize` applies a size to the pseudoconsole **only while the
connection is `Connected`**; before that it just records the numbers for
`Start()` to use. But `Start()` transitions to `Connecting`
(`ConptyConnection.cpp:403`), *then* creates the pseudoconsole (`:412`), and only
reaches `Connected` at `:477`. A resize arriving inside that window is recorded
and applied to nothing.

That window is exactly where ours arrives: `TermControl::_InitializeTerminal`
initializes the core before starting the connection, libghostty sizes its surface
during that initialization, and the resulting `resize_pty` callback is the one
carrying the real grid.

Captured live with a DBWIN reader against the packaged app's own `_trace` output:

```
resizeConnection 56x18 cells                 <- ghostty's default grid
set font-size = 12
cellSize 14x28 px
pushSize panel=1024.0x520.0 dips scale=1.500 -> 1536x780 px
resizeConnection 109x27 cells                <- correct, and lost
```

The value was computed correctly every time. It simply never reached the
pseudoconsole.

#### Fix

`GhosttyControlCore` remembers the last grid size `resize_pty` asked for and
re-applies it when the connection reports `Connected`. `Resize` is idempotent, so
the replay costs nothing when the size already took.

#### Verified

`wsl -d Ubuntu-24.04 stty size` in a fresh pane now answers **`27 109`**,
matching the pane's own `CSI 18 t`. Before the fix the same probe answered
`18 56`, and only a window resize corrected it — which is what made this look
like a rendering quirk rather than a pty bug.

`unitControl` 62 passed / 0 failed / 1 skipped (the key test skips off a US
layout).

#### What it did *not* fix

The Kitty image aspect ratio of KD-01. That is a separate cause — see KD-03.

---

### KD-03 — `c`+`r` image placement stretches instead of fitting

**Upstream ghostty behaviour, not our port**, and the actual cause of KD-01's
distortion. Recorded here because it is user-visible and unresolved, not because
it is ours to fix alone.

When a Kitty graphics placement specifies **both** `c` (columns) and `r` (rows),
ghostty scales the image to exactly `c x cell_width` by `r x cell_height`,
**ignoring the source aspect ratio**. Its own comment says so
(`src/terminal/kitty/graphics_storage.zig:809-818`):

> If we have a specified cols AND rows then we calculate the width and height
> from them directly, we don't need to adjust for aspect ratio.

Confirmed by measurement in a pane: a 200x100 source sent as `c=34,r=17` draws at
**476x476** — exactly the cell box, aspect forced to 1.000.

#### Why that breaks chafa

chafa **letterboxes**. Decoding the canvas it actually transmits for a square
SVG at `c=34,r=17`:

```
canvas       : 272x136
ink in canvas: 100x102, aspect 0.980   (fills 36.8% of width, 75.0% of height)
```

The ink keeps the source's square aspect inside a 2:1 canvas. That is only
correct if the terminal *fits* the canvas into the cell box preserving aspect —
under ghostty's stretch it becomes 2:1 tall, which is exactly the reported
symptom (measured ink aspect 0.484 against a ground truth of 0.969 from
rendering the same SVG square with ImageMagick).

#### Unresolved

kitty's specification says the image "will be scaled (enlarged/shrunk) as needed
to **fit** the specified area", which reads as fit-preserving-aspect and matches
what chafa assumes — but **this has not been checked against a real kitty**, and
that check is what would decide whether ghostty diverges from the protocol or
chafa relies on behaviour the spec does not promise. Until then this is a
discrepancy with evidence, not a verdict.

If ghostty does diverge, the fix is upstream and affects every platform, not
just Windows.

#### Workaround today

Omit `c`/`r` and send only `s`/`v`; natural-size placement is pixel-exact
(verified). For chafa specifically, that means generating at display time is not
enough — the letterboxing is in the canvas either way.
