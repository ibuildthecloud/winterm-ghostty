# Known defects

Things a ghostty pane gets **wrong**, as opposed to things it deliberately does
differently. Those live in [documented-diffs.md](documented-diffs.md), and the
distinction is the point: a diff is a decision with a cost attached, a defect is
a bug nobody chose.

**Each entry has a stable ID** (`KD-nn`), for the same reason the diffs do —
open entries now carry a GitHub issue link beside the
heading. The ID remains the durable name: it survives issue renumbering, appears
in commit messages and code comments, and is what this file and the diffs
cross-reference. The issue tracks the work; this file holds the evidence.

Each entry says how it was found, what is actually known versus suspected, and
**the measurement that would tell the hypotheses apart**. That last part matters
more than the hypothesis: this project has repeatedly produced a plausible cause
by reading source and had it turn out wrong.

---

### KD-01 — Kitty graphics images render distorted — **closed 2026-08-07, resolved**

**Reported** by the user, from use: an image sent with the Kitty graphics
protocol appeared skewed — wrong aspect ratio, not merely the wrong size.

**Resolved by one fix of ours and one upgrade of the client.** `chafa
--format=kitty favicon.svg` now renders at **ink aspect 0.969** — exactly the
ground truth from rendering the same SVG square with ImageMagick — full size and
undistorted.

Two independent causes, and it took both:

1. **Ours: [KD-02](#kd-02)** — the child was told the terminal was 56x18 when it
   was 109x27, so the image was sized against a view a third of the pane.
2. **The client: chafa 1.14.0 cannot ask.** The pty carries no pixel dimensions
   (`ws_xpixel=0`, a ConPTY property no Windows terminal can change), and 1.14.0
   has no `--probe`. Its fallback picks `c`/`r` for 1:2 cells while rasterizing
   at 8x8 square px per cell and letterboxing — two assumptions that cannot both
   be right. chafa **1.16 added terminal probing**; on 1.18.2 the plain
   invocation is correct.

That the probe works is also a useful check on us: chafa's queries travel
pane → ConPTY → WSL and the replies come back, and it derives the right cell
geometry from them. Our `CSI 14 t` / `CSI 16 t` / `CSI 18 t` answers are correct
end to end, not just when a Windows-side process asks.

**This entry was briefly closed as "not a defect". That verdict was wrong** — it
rested on a logo *looking* fine rather than on a measurement, which is the exact
sloppiness the rest of this investigation avoided. It took the user pushing back
twice to reopen it.

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

### KD-03 — `c`+`r` image placement stretches — **resolved 2026-08-07: correct, matches kitty**

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

#### Resolved: kitty does the same thing

Checked against kitty's source rather than its prose. `update_dest_rect` in
`kitty/graphics.c` computes an aspect-preserving dimension **only when one is
zero**:

```c
const bool auto_cols = num_cols == 0, auto_rows = num_rows == 0;
if (auto_cols) { ... }
if (auto_rows) { ... }
ref->effective_num_rows = num_rows;
ref->effective_num_cols = num_cols;
```

With both `c` and `r` supplied it takes them as given. **kitty stretches, ghostty
stretches, and our port matches both** — measured at 476x476 for `c=34,r=17`.
There is nothing to fix here, and the same file would look the same in kitty.

The spec's word "fit" is what misled the earlier reading; the source is
unambiguous.

#### So the fix is on the generating side

chafa rasterizes at a fixed 8x8 px per cell and letterboxes, while choosing
`c`/`r` for the terminal's real 1:2 cells. Those two only agree on a
square-celled terminal. `--stretch` makes the raster fill its canvas, so the
terminal's stretch restores the aspect instead of compounding it:

| invocation | drawn ink aspect (ground truth 0.969) |
|---|---|
| `chafa -f kitty favicon.svg` | 0.484 — 2x too tall |
| `chafa -f kitty --stretch favicon.svg` | 2.011 — fills the whole 109x27 view, now 2x too wide |
| **`chafa -f kitty --stretch --size 20x10 favicon.svg`** | **0.971 — correct** |

`--stretch` alone is not enough: without `--size` it fills the view, and the view
is itself 2:1. It has to be paired with a cell box of the right shape — with
14x28 cells a square image needs `c = 2r`.

Whether chafa should be doing this itself is a question for chafa; on the
evidence here its kitty output is distorted on any terminal whose cells are not
square, which is nearly all of them.

---

### KD-04 — A background pane keeps blinking and keeps presenting — **fixed 2026-08-11**

**Found** 2026-08-07 by measurement, while asking whether the idle present rate
drops to zero when a pane is not focused. It does not.

Counters through a run that focused a pane for 6 s, moved focus to another
**window** for 12 s, then came back:

```
notify=5 wakeup=7  update=7  present=8
...                                        <- +2/sec, unbroken
notify=5 wakeup=53 update=53 present=54
```

No gap. The pane presented at the blink rate for the whole unfocused period.

#### The first explanation was wrong, and its own numbers said so

This entry used to claim that `LostFocus` is never raised, because XAML's routed
focus events do not fire when another top-level window takes the foreground.
**They do.** Traced on 2026-08-11, with `GhosttyControlCore` printing every focus
call: another window taking the foreground produced `LostFocus` within
milliseconds, the blink timer stopped, and the diagnostic — which reports *from*
the blink timer — went silent for the whole background period. Over 12 s in the
background the totals moved by +7 presents, where a running blink adds ~24.

The tell was in the numbers above the whole time: **`notify` never moves.** A
focus change queues a render, so a run that begins focused and ends focused
without `notify` changing is a run in which the surface was never told anything
about focus in either direction — not one in which a `LostFocus` went missing.

#### What was actually happening

XAML's routed focus is **app-internal**. A control in a window that has never
been brought to the front still receives `GotFocus`, because logical focus lives
inside the app's own tree. So:

- A window that comes up behind another one — a terminal launched from a script,
  or by another app, while the user works elsewhere — gives its pane `GotFocus`.
- No deactivation ever follows, because the window was never activated.
- The pane believes it is focused **for as long as it lives**: focused-looking
  blinking cursor, focus reported to the application, and a full rebuild plus a
  full-surface present every 600 ms.

Reproduced deterministically by holding another window in front while the
terminal starts: `[ghostty-diag]` climbing +2/sec, unbroken, for the life of the
window, with the foreground never once ours.

**And `WM_ACTIVATE` does not answer the question either.** WT's activation signal
(`IslandWindow` → `AppHost::_WindowActivated` → `TerminalPage`) reports the active
window of the *thread's input queue*, not the foreground. Measured:
`TerminalPage::WindowActivated(1)` arriving while `GetForegroundWindow()` was
another application's window. A first version of the fix gated on that flag and
changed nothing at all.

#### The fix

`TermControl::_pushCoreFocus` (terminal patch 52) sends the core routed focus
**and** the window really being in front — `GetForegroundWindow() ==
OwningHwnd()` — and only when the pair changes, since `GotFocus`/`LostFocus`
enable and disable the UIA engine and send the focus-reporting escapes.
Activation is kept as a *trigger* to re-evaluate (`TermControl::WindowActivated`,
fanned out from `TerminalPage::WindowActivated` exactly like
`WindowVisibilityChanged`, plus the initial state in `_SetupControl`), never as
the answer. XAML's `GotFocus` is a second trigger, and it arrives after the
foreground has changed, so a genuine activation is evaluated at least once with
the foreground already correct — measured, both triggers agreeing.

`GhosttyControlCore::_createSurface` also pushes the initial state, because a
libghostty surface is born believing it is focused ("it is up to the apprt to set
the correct value" — `renderer/Thread.zig`) and we are the apprt.

Measured after, all four cases on the running app:

| case | result |
|---|---|
| window in front | routed focus + in front → focused, blink runs at ~1.7/sec |
| foreground moves away | `LostFocus`, blink stops, reports stop |
| foreground comes back | focused again, blink resumes |
| window never in front | `GotFocus` with `inFront=0` → **never focused, never blinks** |

`scripts\probe-idle-focus.ps1` is the instrument: 7 blink reports before
backgrounding, **1 in the following 15 s** (0.07/sec against 1.7/sec).

**Not covered by any automated test.** It needs a real window, a real foreground
and a GPU; the WT suites cannot see any of it. The probe script is the check, and
it is item 8 of [manual-validation](manual-validation.md).

#### What this leaves

The blink *rate*, and whether it blinks at all, are still ours to get wrong:
KD-05 — the system's cursor-blink settings are ignored — is untouched by this, and
is what makes an idle **focused** ghostty pane cost ~1.7 presents/sec where a
cascadia pane on the same machine costs none.

---

### KD-05 — The system's cursor-blink settings are ignored  ([#2](https://github.com/ibuildthecloud/winterm-ghostty/issues/2))

Cascadia reads them (`TerminalCore/terminalrenderdata.cpp:41-52`):

```cpp
const auto enabled = GetSystemMetrics(SM_CARETBLINKINGENABLED);
const auto interval = GetCaretBlinkTime();
_cursorBlinkInterval = enabled && interval <= 10000 ? milliseconds(interval)
                                                   : TimerDuration::max();
```

So with blinking disabled system-wide, cascadia's blink timer never fires.

`GhosttySettingsTranslator.cpp` contains **no mention of blink at all**:
`cursor-style-blink` is never set, and ghostty's interval is the hard-coded
600 ms of `CURSOR_BLINK_INTERVAL`.

Consequences:

- **Turning off cursor blinking in Windows — frequently an accessibility
  setting — has no effect on a ghostty pane.** That is the part that matters.
- The blink *rate* is user-configurable on Windows (200–1200 ms) and is ignored.
- An idle pane pays ~1.7 presents/sec that a cascadia pane would not.

**Note the fix is not purely ours.** Setting `cursor-style-blink = false` would
stop the cursor *appearing* to blink, but `Thread.zig:264-271` starts the blink
timer unconditionally with no config gate, so the wakeups and presents would
continue. Reaching zero needs the timer gated upstream as well.

---

### KD-06 — A ligature's second half blinks with the cursor — **fixed 2026-08-09**

**Reported** by the user, from use: type `--` at a shell prompt, move the cursor
back onto the **first** dash, and the **second** dash blinks in antiphase with
the block cursor. The user also established the workaround before any of this
was measured: **Consolas does not do it, Cascadia Code does.**

**Confirmed by measurement**, not by eye. Frames of a live pane captured with
`harness/wgc-shot` and diffed per pixel; cells in this pane are 13 px wide with
column 0 starting at x=18.

| what is on the line | cursor parked on | pixels changing per blink |
|---|---|---|
| `--` | first dash | **365 px across x=[239..261] — two cells** |
| `--` | second dash | 331 px, x=[252..264] — one cell |
| `xy` | first letter | 338 px, x=[239..251] — one cell |

338 px is exactly one 13x26 cell, i.e. the cursor block and nothing else. Only
the first case leaks past the cursor's own cell, and it leaks **only on the three
pixel rows that carry the dash's ink** — rows 89-91 of a 26-row cell. It is a
glyph disappearing, not a rectangle being painted.

Rendered directly, cursor-on versus cursor-off, the second dash is simply gone:

```
cursor on    @@@+=======%@                    <- col 17 block, col 18 EMPTY
cursor off      ########-  *#######=          <- col 17 dash,  col 18 dash
```

#### Cause

ghostty deliberately breaks font-shaping runs at the cursor cell
(`font/shaper/run.zig:178`, `FontShapingBreak{ cursor: bool = true }`), so a
ligature under the cursor is normally split into its component glyphs. That break
is computed from `state.cursor.viewport` — a **position**, not the blink phase
(`renderer/generic.zig:2658-2662`) — so shaping cannot legitimately differ
between blink phases, and in the healthy cases above it does not.

The break is only applied when the row is re-shaped, and
`renderer/generic.zig:2408-2410` re-shapes a row only when it is dirty:

```zig
if (!rebuild) {
    // Only rebuild if we are doing a full rebuild or this row is dirty.
    if (!dirty.*) continue;
```

Moving the cursor changes no cell contents, so the row is not dirty and is not
re-shaped. The `--` therefore keeps the **ligature** shaping it was given when
the cursor was still to the right of it — one glyph, owned by the first cell,
whose ink spans both cells. Drawing the block cursor over that first cell
replaces what the first cell draws, and the ligature's right half goes with it.

The two shapings are distinguishable in the captures, which is what makes this
more than a story. A run correctly broken at the cursor renders the two cells as
the *same* lone-dash glyph at the *same* sub-cell offset; a surviving ligature
renders them at different offsets:

```
broken (correct)   #%%%%%%%%%*  #%%%%%%%%%*      <- identical, offset 1
ligature (stale)      ########-  *#######=       <- offsets 3 and 1
```

Every observation follows from this:

- **`xy` is unaffected** — no ligature, each cell owns its own glyph.
- **Cursor on the *second* dash is unaffected** — the ligature glyph is owned by
  the first cell, which is not the cell the cursor is covering.
- **Consolas is unaffected** — it has no `--` ligature to strand.

#### The ordering is what decides it, and it is why this was hard to reproduce

Four printf-based repro attempts failed before the mechanism was clear. Writing
`--` and the cursor-back escape in one burst means the renderer's *first* shaping
of that row already has the cursor on the dash, so the run is broken correctly
and nothing is wrong. Inserting a pause between the two writes — the order a
person produces by typing and then pressing Left — reproduces the stale ligature
from a plain `printf`, with no shell, no readline and no typing involved.

**So the trigger is "shape, then move the cursor onto it", not typing.** Any
repro that emits text and cursor movement together will report this bug as
absent.

#### Scope

The row-dirty gate and the cursor break are both in code shared with upstream
(`renderer/generic.zig`, `font/shaper/run.zig`), not in our D3D11 backend, so
**this is very likely an upstream ghostty defect that we inherit** rather than a
port bug. That has not been confirmed against a native ghostty build, and it
should be before anything is filed upstream — see below.

#### The measurement that would settle the remaining questions

1. **Is it upstream?** Same sequence on a native ghostty (macOS or Linux) with a
   ligating font: print `--`, wait a frame, move the cursor onto the first dash,
   watch the second. One run answers it.
2. **Which half of the fix is right?** Either mark the cursor's old and new rows
   dirty when the cursor moves within the viewport, or make the cursor position
   part of what invalidates a row's cached shaping. The first is cheaper; the
   second is harder to get wrong. Both need a throughput re-measure, because
   dirtying a row per cursor move touches the hot path.

Both remain open. The third question this entry carried — *does disabling the
break confirm the mechanism* — has been answered, below.

#### Confirmed by disabling the break — 2026-08-08

This is why the entry states a cause rather than a hypothesis.
`FontShapingBreak.cursor` was temporarily defaulted to `false` in
`config/Config.zig`, libghostty rebuilt (`ReleaseFast`,
`-Dfont-backend=directwrite_harfbuzz`) and dropped into the dev package.

**Note which way that knob points.** `no-cursor` sets `cursor: false`, and
`shape.zig:89` then does `if (!config.cursor) self.cursor_x = null` — it
*disables* the break. So it predicts the symptom becomes **universal**, appearing
in the write-and-move-in-one-burst case that renders correctly today. Predicting
a change in a case that currently *works* is a much sharper test than watching a
symptom disappear.

| case | break on (normal) | break off |
|---|---|---|
| `…q--`, cursor on first dash | **338 px, x=[239..251]** — one cell, correct | **365 px, x=[239..261]** — two cells, the bug |
| `…qxy`, cursor on the `x` | 338 px | **338 px — unchanged** |

The prediction held exactly, down to the pixel range, and the no-ligature control
did not move — so the effect is ligature-specific and not a general widening.
The rendering matches the report too: cursor on, column 18 empty; cursor off,
both dashes at the ligature's two distinct sub-cell offsets.

```
break off, cursor on    @@@********%@                 <- col 17 block, col 18 EMPTY
break off, cursor off      ********-  +*******+       <- ligature, offsets 3 and 1
```

The change was reverted and libghostty rebuilt; the same case measured 338 px
again afterwards, which is what confirms the revert rather than a file hash.

**`no-cursor` is therefore not a workaround**, and exposing it as a WT profile
setting would only hand users a switch that makes this worse. That is worth
saying explicitly because "expose the setting we don't forward" is the obvious
wrong move from reading `GhosttySettingsTranslator` alone.

#### Fixed

`renderer/generic.zig` now remembers the cursor's last viewport position and
marks the rows it left and arrived on dirty — **only when it actually moves**.
Dirtying unconditionally would re-shape the cursor's row every frame, including
the ~1.7 frames per second the blink timer already costs an idle pane, trading a
rendering defect for a performance one.

Measured, cursor parked on the first dash of `--`, per blink:

| | changed region |
|---|---|
| before | **365 px across two cells** — the neighbour's ink rows included |
| after | **338 px** — one 13x26 cell, the cursor block and nothing else |

#### Upstream, on the evidence

Both halves are upstream code: the dirty gate is present verbatim at the pin,
and **no** cursor movement marks a row dirty — `Screen.cursorLeft`,
`cursorRight`, `cursorUp`, `cursorDown` and `cursorAbsolute` all mark nothing.
So the stale-shaping path is reachable upstream exactly as it was here.

**That is inference, not a measurement.** No native ghostty build was run. Two
things could differ on another platform and would need ruling out before
anything is filed upstream: a full rebuild (`state.dirty == .full`) happening
more often there, which hides it; or *our* port dirtying less than native does,
since we drive the pty externally.

It would also be easy to miss rather than absent. It needs a specific order —
the row shaped while the cursor is elsewhere, *then* the cursor moved onto a
ligature — it is cosmetic, it self-corrects the moment anything is typed, and
one dash flickering next to a blinking block cursor reads as "the cursor
blinking".

The fix was verified against the D3D11 renderer only; `generic.zig` is shared
with the Metal and OpenGL backends.

#### Workaround today

Use a font without a `--` ligature. Consolas is confirmed clear.

---

### KD-07 — zooming in crashes the terminal — **fixed 2026-08-08**

**Reported** by the user against the published v0.2.0 portable build: press
`ctrl+=` and the window freezes, then dies. **This shipped.** v0.2.0's release
was withdrawn (the tag is kept).

```
Faulting module : ghostty-internal.dll
Exception code  : 0xC00000FD      <- STATUS_STACK_OVERFLOW
```

#### Cause

`WindowsTerminal.exe` linked with MSVC's default **1 MB** stack reserve.
Zig-built code assumes Zig's **16 MiB**, and a DLL has no stack of its own - its
PE `SizeOfStackReserve` is ignored, so a synchronous call from a WT-owned thread
into libghostty runs on *that thread's* stack.

**Fixed** by reserving 16 MB in `WindowsTerminal.vcxproj`. Reserve is address
space; commit stays 4 KB and grows on demand, so it costs essentially no memory.

This is the **fourth** instance of PLAN.md's 2026-08-04 note - after
`ghostty_init`, the first WT launch, and `ghostty_surface_preedit`. The first
three were each fixed by wrapping that one call in
`GhosttyEngine::RunWithEngineStack`. That approach is opt-in, and the failure
mode of forgetting is a crash on someone else's machine, so the fix this time
replaces the rule with a property of the binary.

#### What the measurements actually showed

| exe stack | control DLL | result |
|---|---|---|
| 1 MB | stock | crash, zoom 11 |
| 1 MB | `ghostty_surface_set_size` wrapped in `RunWithEngineStack` | crash, zoom 12-13 |
| **16 MB** | wrapped | **passes** (20 zoom in, 20 out, split) |
| **16 MB** | **stock** | **passes** |

The second row is the useful one: **wrapping the most plausible call site did
not fix it.** The crash moved two presses later and stayed. The overflowing path
was never identified, and that is precisely the argument against hunting call
sites - the audit found `_pushSize`, the audit was wrong, and the real path is
still unknown. The last two rows show the wrapper is redundant once the reserve
is raised, so it was reverted.

#### Cost

Upstreamability. `microsoft/terminal` has no reason to raise its exe's stack for
this engine, so this patch does not travel. Staying at 1 MB would mean finding
and wrapping every deep call - the attempt above is evidence of how that goes.

#### Wrong turns worth keeping

**A CPU-target theory that was well-supported and wrong.** The CI build crashed
where a local build of the same commit did not, and a local build pinned to
`-Dcpu=baseline` crashed too - which looked like proof that codegen decided it.
It did not: those "surviving" runs were **cascadia panes**, so they proved
nothing. The CPU pin (`-Dtarget=x86_64-windows-msvc -Dcpu=baseline`, now in
`build-ghostty.ps1`) is still right - an artifact should not depend on who built
it - but it is **not** the fix for this, and was briefly recorded as if it were.

**A smoke gate that certified the wrong engine.** Three consecutive "passes"
were cascadia:

- Setting only `profiles.defaults.engine` did **not** produce a ghostty pane;
  the gate now writes an explicit profile and points `defaultProfile` at it.
- `GhosttyControlCore::AdjustFontSize` is a **no-op**, so a visibly zooming pane
  is *evidence of cascadia* - and the screenshots showed exactly that, unread.
- The first engine assertion listened on DBWIN but discarded the PID in the
  first four bytes of the buffer. DBWIN is machine-global, so it was proving the
  engine using traces from the developer's *other* terminal.

`scripts/smoke-release.ps1` now asserts a `[ghostty]` trace **from the process
under test**, always, and fails otherwise. The user called this one before the
evidence did.

#### Still unknown

- **Which call overflows.** Raising the reserve fixed it without identifying it,
  and `ghostty_surface_set_size` is ruled out. A debugger-quality stack would
  settle it; ReleaseFast emits no PDB, and the builds that carry symbols do not
  crash.
- ~~Whether `ctrl+=` does anything on a ghostty pane.~~ **Answered by the user:
  zoom works.** It does not go through `GhosttyControlCore::AdjustFontSize`,
  which is empty - ghostty handles the binding itself, so the key reaches
  `ghostty_surface_key` and the font reload happens inside that call. That call
  runs on WT's UI thread, which is almost certainly the path that was
  overflowing, and fits what the evidence never explained: why wrapping
  `ghostty_surface_set_size` changed nothing.

---

### KD-08 — `?` arrives as `/` in applications using the kitty keyboard protocol — **fixed 2026-08-08**

**Reported** by the user, from use: typing `?` into a full-screen application
produced `/`. Every other application was fine, which is exactly what made it
look like that application's bug.

#### Cause

`GhosttyControlCore.cpp` hardcoded `ev.consumed_mods = GHOSTTY_MODS_NONE`.

ghostty computes `effectiveMods() = mods.unset(consumed_mods)` and, on the kitty
path, sends the text directly only when the result is empty
(`key_encode.zig`):

```zig
// Send plain-text non-modified text directly to the terminal.
if (event.utf8.len > 0 and binding_mods.empty() and ...
```

Shift **is** consumed by the layout when producing `?` — the character already
accounts for it. Reporting nothing as consumed made `?` look like
`shift+<something>`, so that branch was skipped and the key was encoded as
`CSI 47;2u`: the **unshifted** codepoint 47, which is `/`, plus a shift
modifier. An application that reads the base key prints `/`.

**Fixed** by asking the layout rather than assuming a US keyboard: if removing a
modifier changes the text the key produces, that modifier was consumed. Shift
covers `?`; ctrl+alt covers AltGr, which on a German layout is what turns `q`
into `@`.

#### Why it looked like one application misbehaving

The legacy encoding path writes the UTF-8 as-is and never consults
`consumed_mods`. Only a client that turns the kitty protocol on reaches the
encoder that does. So "it works everywhere except this one program" was a
property of *which encoder ran*, not of the program.

That framing nearly sent this the wrong way. The first hypothesis was that the
key was being **dropped** in kitty mode; the clarification that `?` came out as
`/` — a key arriving with its shift lost, not a key going missing — is what
pointed at modifier accounting.

#### The measurement that nearly lied

A probe captured `?` under kitty flags `13` and recorded zero bytes, which read
as "the key is dropped". The **control run with the protocol off captured zero
bytes too**, proving the harness was at fault rather than the terminal: the keys
were synthetic virtual-key events that never reached the pty, and a file-based
capture needs its reader to exit cleanly to flush.

What settled it was the user running the probe by hand and reading the bytes off
the screen. Two lessons worth keeping: **run the control**, and for a key-encoding
question prefer printing live (`cat -v -u`) over capturing to a file, since
anything arriving late lands at the shell prompt where readline eats the `ESC`
and leaves mangled fragments.

Also note the probe's flags were unrepresentative: `13` includes *report all keys
as escape codes*, which no ordinary application requests. Testing a mode nobody
uses answers a question nobody asked.

---

### KD-09 — A pane's traces block the UI thread on the debugger channel — **fixed 2026-08-11**

**Found** 2026-08-11 from a user report while validating KD-04: "after running
wtgd, nothing pops up, the terminal is never shown". The window did eventually
appear — minutes later.

#### `OutputDebugString` is not free, and our own comment said it was

`GhosttyControlCore::_trace` wrote straight to `OutputDebugStringW` on the
calling thread, three calls per line (prefix, text, newline), carrying this
comment:

> OutputDebugString costs nothing when no debugger is attached

Measured on this machine at the time of the report:

```
call #0:      2 ms
call #1: 10,005 ms
call #2: 10,010 ms
```

DBWIN is a **machine-wide** channel. Once anything has attached to it and
stopped servicing it — a debugger that was killed, a script that exited without
closing the shared events — every writer on the box waits on
`DBWIN_BUFFER_READY` and gives up only after its full ten-second timeout, per
call. Nothing is attached in any meaningful sense; the shared objects simply
still exist with nobody draining them.

A ghostty pane traces about forty lines while it starts — the settings
translation alone is one line per setting — on the UI thread, at three calls
each. That is the terminal window not appearing.

#### What wedged it here: our own probe script

`scripts\probe-idle-focus.ps1` listens on DBWIN to read libghostty's counters.
Its `Dispose` stopped the listener thread and **left the events and the mapping
open**, which is precisely the state that costs every writer ten seconds a call.
So the instrument written to measure KD-04 broke the thing it was measuring, and
the person who ran it got a terminal that would not open. `smoke-release.ps1`
had the same shape. Both now close the handles.

#### The fix

Traces go through a bounded queue drained by one worker thread (terminal patch
53), so a wedged channel costs a trace and never the terminal, and one call per
line instead of three. The lines the release gate matches on are unchanged —
better, in fact, since each record is now a whole line rather than a fragment.

#### What this does not cover

A **Debug** Windows Terminal still crawls on a wedged channel, because WT's own
`#ifdef _DEBUG` traces write synchronously on the UI thread too
(`TerminalPage.cpp`). Those are upstream's and do not exist in a Release build.
Ours were the only unconditional ones. libghostty writes two lines at device
creation (`renderer/directx11/device.zig`) on the renderer thread, which can
delay a first frame but not the window.

#### The instrument lied twice in one hour

Worth recording, because both cost more time than the defect:

1. A launch-loop script reported "NO WINDOW" for 6 of 6 launches while windows
   were opening on screen in front of the user, who said so. The callback
   incremented `$script:n` and the function returned a local `$n` — always zero.
   **A detector that has never been seen to report success is not a detector.**
2. The wedged channel was real and measured, but the "0 of 6" that seemed to
   confirm it proved nothing. With the counter fixed and the channel clear:
   4 of 4 launches, window in **1.3 s**.

---

### KD-10 — A focused pane presents on every blink, but the drawn cursor barely toggles  ([#16](https://github.com/ibuildthecloud/winterm-ghostty/issues/16))

**Found** 2026-08-12 while validating the KD-04 fix, from a user's report that a
pane brought to the front "did not have a blinking cursor" until the mouse moved
onto it.

#### Why this is presumed to be KD-19

Recorded after KD-19 was diagnosed, because the two fit and the fit is checkable
even though the proof is not.

1. **The race was live in the build that crashed.** `GhosttyControlCore.cpp` at
   `506e4bba8`, the commit 0.2.4 was cut from, contains **six** `_renderNow()`
   call sites - the same six KD-19 removed. Every selection drag on that build
   ran the renderer's whole frame update on the UI thread while the surface's
   render thread ran its own.
2. **The fault class matches, in both of its observed forms.** KD-19's race is
   two threads inside the renderer's allocator: one clearing and repopulating
   every row's highlight `ArrayList` and resizing `row_data`, the other
   iterating those same structures. That produces a freed block read
   (0.2.7, named exactly) *or* the same block freed twice
   (`BlockNotBusy`, 0.2.4). This entry recorded both shapes on 0.2.4 - the
   double free at 23:57 and an access violation at 19:32 - which is the pairing
   the race predicts.
3. **The caller is ours, and it is the free itself.** The stack below has
   `RtlFreeHeap` called from two `ghostty-internal.dll` frames, not from a
   system component handed a bad pointer.

**What would make it certain, and why it cannot.** Naming those two RVAs. v0.2.4
shipped no PDB and no machine here has one that matches what CI built, so those
frames stay anonymous forever. This is inference from build contents and fault
class, not a resolved stack.

**The bar for closing it**: time on a build that has the KD-19 fix - 0.2.8 or
later - without a heap-corruption crash. If one *does* occur, it resolves now:
symbols ship from 0.2.6 and the 0.2.7 dump read frame by frame.

#### What is measured

One run, no input of any kind, window brought to the front after being held
back, with `GHOSTTY_RENDER_DIAG=1` and captures interleaved:

```
after coming forward: 10 blink reports, ~1.2 s apart
  [ghostty-diag] notify=11 wakeup=18 update=18 present=21
  [ghostty-diag] notify=11 wakeup=20 update=20 present=23   <- +2 present per report
  ...
8 captures over ~6 s: every consecutive pair pixel-identical
```

So the blink timer is running (its own heartbeat is what emits those lines), it
wakes the renderer twice a second, the renderer presents twice a second - and
the pixels never change.

A pane launched normally, focused from birth, never held back, with no input,
shows the same thing with one exception: **exactly one toggle** across eight
frames, 28 pixels in a one-pixel-wide column (`x 241..241 y 105..132`), which is
precisely the bar cursor for a 28-pixel cell. Then static.

#### Not the focus gate

The same run traces `GotFocus` reaching the core when the window comes forward,
and a capture at that moment plainly shows the bar cursor drawn after the
prompt. Focus arrives; the cursor is drawn; it just does not blink. A pane that
has never been in front draws no cursor and reports no blinks at all, which is
KD-04 working.

#### The instrument was wrong twice before this was believed

- Eight frames at a fixed 200 ms sleep were all identical, and were read as
  "not blinking". One `wgc-shot` invocation costs ~400 ms of process startup, so
  the real cadence was ~600 ms - exactly the blink interval. **A capture cadence
  must never be commensurate with the thing being sampled**; the intervals are
  jittered now.
- "Identical frames" was then suspected to mean a stale capture. Ruled out: with
  three characters typed into the pane, consecutive captures differ by 743
  pixels. The captures do track the swap chain.

#### The hypothesis, and what would settle it

KD-06 was this shape: the cursor moved and no row was invalidated, so a stale
ligature stayed on screen. The suspicion here is the same family - the blink
toggles `cursor_blink_visible` and notifies, but nothing marks the cursor's cell
dirty, so the rebuild produces the same cells and the present carries identical
pixels. Input dirties something, which is why moving the mouse onto the pane
made it start blinking for the reporter.

To settle it, instrument the renderer rather than the pixels: on a blink wake,
does `rebuildCells` see the cursor cell as dirty, and does the cursor's own
draw state change between frames? A `GHOSTTY_RENDER_DIAG`-style counter on the
cursor path would answer it in one run. Pixel capture is too slow an instrument
for a 600 ms toggle - at ~400 ms a shot it can only sample, never watch.

#### Why it matters beyond cosmetics

If the cursor cell is not dirtied, then the ~1.7 presents/sec an idle focused
pane costs are buying **nothing at all** - the same pixels, twice a second, for
the life of the window. That is Phase 7's idle criterion and KD-05's cost, and
it makes both cheaper to fix than they looked.

---

### KD-11 — Alt+drag did not block-select — **fixed 2026-08-17**

**Reported** by the user, from use: block select (alt+mouse) works on a cascadia
pane and does nothing on a ghostty one — an alt+drag draws the ordinary linear
selection, with no error anywhere.

#### What was wrong

Both engines have the feature; they are told about it differently, and the
translation was missing.

Cascadia is told once, at the click: `ControlCore::LeftClickOnTerminal` takes
`altEnabled` and calls `_terminal->SetBlockSelection(altEnabled)`.
`GhosttyControlCore::LeftClickOnTerminal` took the same parameter and named it
`/*altEnabled*/` — it went nowhere.

ghostty asks per *mouse event* instead. `SelectionGesture.drag` takes a
`rectangle` flag, and `Surface` fills it in from the modifiers that came with
the latest mouse position:

```zig
pub fn isRectangleSelectState(mods: input.Mods) bool {
    return if (comptime builtin.target.os.tag.isDarwin())
        mods.alt
    else
        mods.ctrlOrSuper() and mods.alt;
}
```

Every mouse event the selection path sent carried `GHOSTTY_MODS_NONE`, so the
answer was always "no rectangle". Note the second branch: forwarding WT's alt
faithfully would not have been enough either — off macOS this engine wants
ctrl+alt.

#### The fix

`GhosttySelectionMods.h` maps "WT says this drag is a block selection" to the
modifiers the engine's predicate requires, and `GhosttyControlCore` latches the
alt state at the click (as cascadia does — releasing alt mid-drag does not turn
a block selection back into a linear one) and puts those modifiers on every
mouse *position* of the drag.

Positions only. A press is read differently — `if (mods.ctrlOrSuper()) .output
else .line` chooses what a third click selects — so a press claiming ctrl would
quietly turn alt+triple-click into "select the command's output". The presses
stay bare, and the harness confirms the rectangle forms all the same.

#### Measured, on the real engine

`GHOSTTY_HARNESS_SELECT_BLOCK` drives the sequence `GhosttyControlCore` sends,
in cells, with and without those modifiers. Over three rows of
`ABCDEFGHIJ` / `KLMNOPQRST` / `UVWXYZ0123`, dragging cell (2,0) → (5,2):

```
[selblock] block=1 text "CDE<LF>MNO<LF>WXY"
[selblock] block=0 text "CDEFGHIJ<LF>KLMNOPQRST<LF>UVWXY"
```

A rectangle takes columns 2..4 out of every row; the plain drag runs to the end
of the first row and back from the start of the last. `scripts/smoke-harness.ps1`
pins both, and the *contrast* is the regression signal — the bug was that the
two were identical.

#### Confirmed in a pane, by hand

**2026-08-17, by the user, on the deployed dev package**: one window, a ghostty
pane and a cascadia pane side by side on the same fourteen identical lines.
Alt+drag block-selects on **both**. A capture taken at the same moment shows the
rectangle in the ghostty pane — four rows, columns K..V, square edges.

That was a human check because the synthetic-mouse driver written for it could
not do it. `SetCursorPos` + `mouse_event` into the dev-package window,
DPI-aware, with a focusing click first, moves the pointer exactly where it is
told and produces **no selection at all** — and produces none on a **cascadia**
pane either. An instrument that fails identically on the engine that is known to
work measures itself, so nothing about the fix could be read off it in either
direction. Left unfixed: the pane check is one drag by a person, and the two
automated layers above cover the regression.

#### What is still not block-selectable

A double- or triple-click *drag* selects by word or by line and ignores the
rectangle flag, in ghostty's gesture and in cascadia's expansion modes alike, so
alt changes nothing there on either engine. `ToggleBlockSelection` — the
keyboard action that flips an existing selection between shapes — still returns
false on a ghostty pane: the rectangle lives inside ghostty's `Selection` and no
C entry point reaches it. Only the alt+drag gesture is fixed.

---

### KD-12 — A pane double-frees and the process dies with heap corruption — **presumed fixed 2026-08-18 by [KD-19](#kd-19--the-ui-thread-runs-the-renderers-frame-update-racing-the-render-thread--fixed-2026-08-18)**

**Reported** by the user, from use: the portable **v0.2.4.0** build
(`C:\Users\darre\Downloads\winterm-ghostty-0.2.4.0-x64-portable\terminal-0.2.4.0`)
crashed while they were using it, 2026-08-17 23:57 local.

#### What is measured

Windows kept a full user-mode dump, because `LocalDumps` is enabled on this
machine. `!analyze -v` on it is unambiguous about the *kind* of fault:

```
ERROR_CODE: (NTSTATUS) 0xc0000374 - A heap has been corrupted.
FAILURE_BUCKET_ID: HEAP_CORRUPTION_ACTIONABLE_BlockNotBusy_DOUBLE_FREE_c0000374_ntdll.dll!RtlpHpFreeHeap
```

`BlockNotBusy` is the heap saying it was handed a block that is **not currently
allocated** — a double free, not a stray write. And the caller is ours:

```
ntdll!RtlFreeHeap+0x231
ghostty-internal.dll + 0x8252ec      <- the free
ghostty-internal.dll + 0x24c2a3
```

(RVAs against the module base `00007ffd`e23f0000` in that dump. The symbol names
cdb prints for those two frames are nearest-export guesses and mean nothing —
see below.)

**A second crash the same day**, 19:32 local, same build, same DLL: an access
violation (`0xc0000005`) at **RVA `0x1d0f17`**, with the stack unwalkable past
the faulting frame. Whether it is the same fault seen earlier in its life — a
use-after-free rather than the second free — is a hypothesis, not a finding.

Both dumps and the exact DLL they were taken against are preserved in
`dist/crash-0.2.4/` (gitignored), out of reach of WER's rotation.

#### Where a crash is recorded at all

Worth stating, because the answer is "only locally, and only by Windows":

- `%LOCALAPPDATA%\CrashDumps\WindowsTerminal.exe.<pid>.dmp` — a full dump, kept
  only because this machine has `LocalDumps` configured. Not a default.
- `%ProgramData%\Microsoft\Windows\WER\ReportArchive\AppCrash_WindowsTerminal.*`
  — the WER report folder.
- Application event log, IDs **1000** (faulting module and offset) and **1001**
  (the bucket).

**Nothing is sent anywhere, and the engine records nothing itself.** ghostty's
Sentry crash reporting is compiled out on Windows — `src/build/Config.zig`
defaults `sentry` to true only on macOS/iOS — and this fork does not pass
`-Dsentry`. So a user's crash is invisible to us unless they say so.

#### Why these frames cannot be named, and what was done about it

The v0.2.4 portable ZIP ships **no PDB**, so its RVAs cannot be resolved. That
is the whole gap between "a double free somewhere in libghostty" and a
diagnosis, and it is not recoverable after the fact: no PDB on any machine here
matches a binary CI built, and a same-named PDB from a different build resolves
addresses to confidently wrong functions.

**Fixed forward, from 0.2.6**: `scripts/package-symbols.ps1` collects the PDBs
for everything in the published layout and `release.yml` publishes them as
`winterm-ghostty-<version>-x64-symbols.zip`. Pairing is by **CodeView GUID**,
read out of each image and checked against the PDB's own MSF stream-1 header —
not by filename — and every signature is written into `SYMBOLS.txt` so a
debugger's match can be verified rather than assumed. PDBs are stored under the
name the image records (zig records a bare `ghostty.pdb`), because that is the
only name dbghelp will look for.

Proven end to end before shipping: with the collected PDB on the symbol path,
`harness/pdbaddr` resolves addresses to function *and source line*
(`grow + 0x2f13  ghostty/src/terminal/PageList.zig:3680`). That was a local
Debug build and says **nothing** about this crash — different binary, different
layout — it only shows the pipeline works.

**And the first attempt at that shipped broken, which is the more useful
finding.** v0.2.6 published a symbols ZIP whose manifest read
`ghostty-internal.dll ... no codeview record` — the engine had no PDB at all,
because `-Dstrip` defaults to **true** for `ReleaseFast`. The same flag decides
something worse:

```zig
// GhosttyLib.zig
.strip = deps.config.strip,
.unwind_tables = if (deps.config.strip) .none else .sync,
```

So every shipped build up to and including 0.2.6 had **no unwind tables in the
engine** — which is exactly why this dump's stack degenerates into
`0x53000000`53000000` after two frames. The stack was never truncated by bad
luck; it could not be walked. From 0.2.7 the release passes `-Dstrip=false`,
and `package-symbols.ps1` **fails the build** if a binary this project owns
yields no PDB, so the silent version of this cannot recur.

**Verified on the published 0.2.7 artifacts**, not on a green build: the
symbols ZIP was downloaded, `ghostty.pdb` put beside the shipped
`ghostty-internal.dll`, and `pdbaddr` asked for the same three RVAs. It answers
with function and source line —
`innerStrokePath + 0x307  ghostty/src/font/sprite/canvas.zig:386`.

Those names are **not** this crash's answer, and the run is a neat demonstration
of why: the identical RVAs resolved in a local Debug build to
`deallocate` / `grow` / `getIndex`, and here to `innerStrokePath` / `init` /
`png_write_zTXt`. Nothing but the binary's own PDB can name its addresses, which
is precisely why the 0.2.4 dump stays unreadable and why the ZIP now ships.

So this defect stays open with the class of fault (double free), the module
(ours), and the fact that it happened twice in one day of ordinary use. The
**next** occurrence on 0.2.7 or later can be named, and its stack read.

#### What is not known

**What the pane was doing.** Neither dump has been correlated with an action —
no repro, no idea whether it was output, a resize, a close, a selection, or a
pty ending. That is the other half of the diagnosis and it has to come from the
person who was there.

---

### KD-13 — Intense text is neither brightened nor un-emboldened — **fixed 2026-08-18**

**Reported** by the user, from use: `top` in a ghostty pane beside a cascadia
one on the same profile. Cascadia draws some words and numbers in a brighter
white; the ghostty pane draws them like everything else.

#### What was wrong

WT's `intenseTextStyle` is **two independent switches**, and neither reached the
engine. Its default is `bright` — brighten intense text, and *do not* use a bold
face — so both halves were wrong at once, in opposite directions.

Measured off one capture, two panes, one profile (`Cascadia Code` 11, scheme
"Not Campbell"), sampling the most common colour on a line of SGR-1 text:

```
ghostty  BOLD line  #CCCCCC      cascadia  BOLD line  #F2F2F2
ghostty  plain line #CCCCCC      cascadia  plain line #CCCCCC
```

and the ink count on that line — 2196 lit pixels in the ghostty pane against
1600 in the cascadia one — is the other half: the ghostty pane *was* drawing
heavier strokes for intense text, where cascadia was not. Cascadia only asks for
a bold weight when the style says so (`AtlasEngine.cpp:662`, feeding
`DWRITE_FONT_WEIGHT_BOLD` into the run's axis values); how ghostty arrives at a
bold face for this variable font was not chased, because the fix is to stop
asking for one.

#### Why `bold-color = bright` alone was not the fix

The first attempt set exactly that, rebuilt, and measured **no change**:
`#CCCCCC` still. ghostty's rule is in `terminal/style.zig:158`:

```zig
.none => default: {                     // the *default* foreground
    if (self.flags.bold) {
        if (opts.bold) |bold| switch (bold) {
            .bright => {},              // <- nothing happens here
            .color => |v| break :default v,
        };
    }
    break :default opts.default;
},
```

`bright` lifts a **palette** colour to its bright twin; text in the default
foreground has no index to lift, and on a `top` screen that is most of the
intense text. Cascadia handles that case explicitly — `TextColor::GetColor`
looks the default foreground up in the dark half of the palette and, on a match,
returns the bright entry (`TextBuffer/TextColor.cpp:163`, "If we find a match,
return instead the bright version of this color").

#### The fix

`GhosttySettingsTranslator` now does that same lookup and hands ghostty the
resulting colour outright, which — per `bold-color`'s own documentation — also
turns the rest of the bold colours bright, so one entry covers both halves of
cascadia's rule. No match means the foreground is genuinely its own colour, the
case cascadia leaves alone too, and `bright` is then exactly right.

The face half is `font-style-bold = false` when `IntenseIsBold` is not set:
ghostty's spelling for "this style is disabled", which falls back to the regular
face.

Bold+italic is deliberately untouched — matching cascadia there means "italic,
not bold-italic", which ghostty can only be told as a named style of that
particular font, and disabling the style would drop the italic rather than the
weight.

#### Measured, after

Same two panes, same capture geometry:

```
ghostty  BOLD line  #F2F2F2      cascadia  BOLD line  #F2F2F2
ghostty  1;31 block #BA3A45      cascadia  1;31 block #BA3A45   (the scheme's brightRed)
ghostty  plain line #CCCCCC      cascadia  plain line #CCCCCC
```

and the bold row now carries the same stroke weight as the plain row in both
panes. `IntenseTextStyleIsForwarded` pins all four cases of the enum plus the
foreground-not-in-the-palette case; `unitControl` is 66 tests, 65 passed, 1
pre-existing skip.


---

### KD-14 — The glyph atlas held a corrected mask, not coverage — **fixed 2026-08-18**

**Found** while answering a user's question about antialiasing: is a ghostty
pane's thinner, crisper text a style difference from cascadia, or is it wrong?

#### What was wrong

ghostty's cell shader owns every gamma step. `alpha-blending` decides whether
blending happens in linear space and whether the weight correction runs, and the
shader's input is assumed to be the rasterizer's *coverage*: FreeType renders
`.normal`, and CoreText turns platform font smoothing on only when
`font-thicken` is set, which is off by default (`face/coretext.zig:483`).

The DirectWrite face handed it something else. Direct2D applies the **system's**
text rendering params unless a render target says otherwise, and this face set
only the antialias mode. `harness/glyphmask` draws one glyph both ways and
measures the difference:

```
system params: gamma=1.800 contrast=0.500 grayscaleContrast=1.000 mode=DEFAULT
glyph U+0065 of Cascadia Code at 14.6667 px/em, 37x37 bitmap
d2d default params       inked=   49 mass=   34.43
d2d gamma=1 contrast=0   inked=   49 mass=   29.19
differing pixels: 47, max delta: 51
```

47 of 49 inked pixels, up to 51/255, and 18% more ink. The shader's own
correction was then applied on top of DirectWrite's.

#### The fix

Rendering params created once per library with gamma 1.0 and no contrast
enhancement - for grayscale as well as ClearType, since grayscale is the only
antialiasing this backend uses (ADR 0005) - and set on the raster target.
Rendering mode stays `DEFAULT`, so DirectWrite's own per-size choice is
unchanged and only gamma and contrast move.

#### Measured, in a pane

One row of identical text, coverage normalised to the plain foreground:

| | inked | ink mass | faint (<30%) |
|---|---|---|---|
| DirectWrite, system params (before) | 3693 | 2855 | 234 |
| DirectWrite, linear params (after) | 3693 | 2530 | 736 |
| FreeType, for comparison | 3792 | 2686 | 677 |

After the fix the DirectWrite mask has the *shape* FreeType's coverage has - a
faint tail rather than a lifted middle - which is the point. The remaining
difference from cascadia is [GD-16](documented-diffs.md), and is by decision.

`zig build test` passes on both font backends.

---

### KD-15 — Dev builds did not run the font stack that ships — **fixed 2026-08-18**

**Found** by measuring: the KD-14 fix landed, the dev package was rebuilt, and a
capture of the pane was **byte-identical** to the one before it. A fix that
provably changes the glyph mask changed nothing on screen, which meant the code
was not running.

#### What was wrong

`scripts/build-ghostty.ps1` passed no `-Dfont-backend`, so `zig build` fell
through to ghostty's own Windows default - `freetype_windows`
(`font/backend.zig:59`, still carrying upstream's "A future DirectWrite backend
can replace this if needed"). `.github/workflows/release.yml:132` passed
`-Dfont-backend=directwrite_harfbuzz`.

So the two builds ran different font stacks:

| | dev build | release build |
|---|---|---|
| rasterizer | FreeType | DirectWrite / Direct2D |
| discovery | `C:\Windows\Fonts` directory scan | DirectWrite font collection |
| fallback | scan every font's cmap | `IDWriteFontFallback::MapCharacters` |
| colour emoji | none (no `ftcolor` binding) | `TranslateColorGlyphRun` |

Confirmed from the artifact rather than the flags: a default-built
`ghostty-internal.dll` imports `d3d11.dll` and `dcomp.dll` and **no**
`dwrite.dll`, `d2d1.dll` or `windowscodecs.dll` - the whole ADR 0005 font stack
was absent from every local build.

Everything verified locally against the font stack - by hand, by capture, in the
smoke harness - was therefore verifying a stack that no user runs, and ADR 0005,
which is Accepted, was not what a developer was exercising.

#### The fix

`-FontBackend` is now a parameter of `build-ghostty.ps1` with the shipped
backend as its default, so a plain local build matches the release. `''`
reproduces ghostty's own default deliberately, which is how the FreeType numbers
in KD-14 were taken.

#### Not fixed here, and worth knowing

Findings taken on a dev build before this date describe FreeType's behaviour
unless they say otherwise. [KD-13](#kd-13--intense-text-is-neither-brightened-nor-un-emboldened--fixed-2026-08-18)'s
ink counts are one such: the fix there is a settings translation and is backend
independent, but the "ghostty draws a bold face" measurement was FreeType's.


---

### KD-16 — Colour emoji were washed out and flat — **fixed 2026-08-18**

**Reported** by the user, from use, on the first dev build that ran the
DirectWrite font stack ([KD-15](#kd-15--dev-builds-did-not-run-the-font-stack-that-ships--fixed-2026-08-18)):
"our rendering of emojis looks really bad, like washed out and flat".

#### What was wrong

A gamma error, and the same class as [KD-14](#kd-14--the-glyph-atlas-held-a-corrected-mask-not-coverage--fixed-2026-08-18)
but in the other direction. `cell_text` takes its colour-glyph sample as
*linear* - "Color glyphs are already premultiplied linear" - and unlinearizes
only when blending is not linear. Both other backends arrange that decode in
hardware, and only for the colour atlas, since grayscale holds coverage rather
than colour:

| backend | grayscale atlas | colour atlas |
|---|---|---|
| Metal (`Metal.zig:374`) | `r8unorm` | `bgra8unorm_srgb` |
| OpenGL (`OpenGL.zig:430`) | `red` | `srgba` |
| D3D11, before | `R8_UNORM` | `B8G8R8A8_UNORM` |

So sRGB-encoded emoji were read as though already linear and encoded again on
the way out, lifting every midtone. Sampled off a capture of the grinning face:

```
before   fill #FEF178   features #8B7240     pale yellow, muddy brown
after    fill #FDE030   features #422B0D     the font's own colours
```

#### The fix

`initAtlasTexture` picks the sRGB view for the `bgra` atlas and leaves
grayscale alone. One line, and it is the line the comment above it used to
argue against - "must not be sRGB-decoded on read" was right for coverage and
wrong for colour.

#### Worth knowing, and not chased

With the colours right, the two panes still draw *different artwork* for the
same emoji: ghostty's grinning face is the gradient Fluent design, cascadia's
the older flat one. Segoe UI Emoji carries both - ADR 0005 recorded the file as
having a COLR v1 paint tree *and* a complete v0 layer set - and a gradient fill
is something only the v1 tree can produce, so the evidence says we are drawing
v1 where AtlasEngine draws v0. That is the outcome ADR 0005 hoped for as a later
upgrade, arriving without being asked for: we request `GLYPH_IMAGE_COLR` and not
`COLR_PAINT_TREE`, so *why* DirectWrite hands back the v1 rendering is not
established. Someone should find out before this is relied on.


---

### KD-17 — A font *list* named no font at all — **fixed 2026-08-18**

**Found** while answering the user's question "why aren't we using the
configured font in the WT preferences?" The answer for the emoji they were
looking at was that Cascadia Code has no glyph for them
([KD-16](#kd-16--colour-emoji-were-washed-out-and-flat--fixed-2026-08-18) and the
ADR 0005 amendment), but the question turned this up on the way.

#### What was wrong

A profile's `fontFace` is a CSS-style *list*, not one name: `"Cascadia Code,
Segoe UI Emoji"` means the first family for text and the second for whatever the
first does not cover. WT parses it with `til::iterate_font_families`, which
splits on commas and treats quotes and backslashes as the list's syntax
(`AtlasEngine.api.cpp:652`).

The translator forwarded the whole string as one `font-family` value. ghostty
then searched for a family *literally* named `Cascadia Code, Segoe UI Emoji`,
found nothing, and fell back to the font it bundles - with no diagnostic a
libghostty built without an app runtime can surface. A profile's font, silently
ignored.

Nobody had hit it because a single-family `fontFace` has no comma in it, which
is what every profile on this machine had.

#### The fix

`til::iterate_font_families` - the same parser, called from the translator - and
one `font-family` entry per family, which is how ghostty's repeatable key wants
it.

#### Measured, in a pane

`"face": "Cascadia Code, Segoe UI Emoji"`, both panes, one capture, sampling the
grinning face:

| | dominant colours |
|---|---|
| ghostty, before | `#FDE030 #422B0D #F8C52C` — the bundled Noto |
| ghostty, after | `#FFB02E #BB1D80 #FFFFFF` |
| cascadia | `#FFB02E #BB1D80 #FFFFFF` |

So the fix also hands users the lever the ADR 0005 amendment asks about: naming
the system emoji font in the profile puts it ahead of the bundled Noto, without
anyone deciding it for them.

`unitControl`: 67 tests, 66 passed, 1 pre-existing skip. One existing test
changed with the fix, and its old expectation was the wrong one - it asserted
that `Back\slash "Quoted"` reaches ghostty verbatim, where WT itself reads that
profile as a single family named `Backslash Quoted`.


---

### KD-18 — Glyph constraints are ignored, so emoji are not sized to the cell — **open**

**Found** by reading, while chasing why emoji look different between the panes
([GD-18](documented-diffs.md)). Not yet measured in a capture, which is the next
step and is written down here so it is not skipped.

#### What is known

`font.Glyph.RenderOptions.constraint` is how ghostty tells a rasterizer to scale
and align a glyph to the cell. Both other faces honour it -
`face/freetype.zig:474` and `face/coretext.zig:341` each call
`constraint.constrain(...)` and rasterize at the size it returns - and
`SharedGrid.zig:418` sets it for **every emoji**:

```zig
render_opts.constraint = .{
    .size = .cover,            // as large as possible, aspect preserved
    .align_horizontal = .center,
    .align_vertical = .center,
    .pad_left = 0.025,
    .pad_right = 0.025,
};
```

`face/directwrite.zig` never reads `opts.constraint` at all. Its `renderGlyph`
places the glyph from the font's own metrics and nothing else, so emoji are
drawn at whatever size the face reports rather than scaled to cover the cell,
and Nerd Font glyphs miss the constraint table in `Glyph.zig` the same way.

This is a deviation from upstream ghostty, which is the standard this engine
holds itself to, so it is a defect rather than a diff.

#### What is not known

**What it looks like.** No capture has isolated it. The measurement: one pane,
a row of emoji and a row of Nerd Font icons, ink bounding box per cell against
the cell rectangle - upstream covers the cell to within the 2.5% padding and
centres what is left over, and any difference from that is the size of this bug.

`font-thicken` is *not* part of this: upstream documents it as CoreText-only, so
ignoring it matches FreeType and is correct.


---

### KD-19 — The UI thread runs the renderer's frame update, racing the render thread — **fixed 2026-08-18**

**Reported** by the user: the portable **v0.2.7.0** build crashed while they were
using it, 2026-08-18 13:02 local. This is the first crash with symbols
([KD-12](#kd-12--a-pane-double-frees-and-the-process-dies-with-heap-corruption--open)
is the one that could not be read), and the stack names every frame.

#### What crashed

```
ghostty_internal!rebuildRow+0x79f      generic.zig:2801   <- for (highlights.items) |hl|
ghostty_internal!rebuildCells+0x1012   generic.zig:2455
ghostty_internal!updateFrame+0x5344    generic.zig:1382
ghostty_internal!renderNow             Surface.zig:942
ghostty_internal!ghostty_surface_render_now   embedded.zig:1964
Microsoft_Terminal_Control!GhosttyControlCore::_renderNow      GhosttyControlCore.cpp:1149
Microsoft_Terminal_Control!GhosttyControlCore::SetPreedit      GhosttyControlCore.cpp:1779
Microsoft_Terminal_Control!TsfDataProvider::ClearComposition   TermControl.cpp:293
Microsoft_Terminal_Control!TSF::Handle::Unfocus                Handle.cpp:85
Microsoft_Terminal_Control!TermControl::_LostFocusHandler      TermControl.cpp:2552
   ... XAML routed event, CoreMessaging dispatch ...
```

`c0000005`, a **read** of `0x0000026ba1f95120`. That is a heap address, not a
stack one, and the thread had ~970 KB of stack left (`StackBase 99e8c00000`,
`StackLimit 99e8b13000`), so this is not [KD-07](#kd-07--zooming-in-crashes-the-terminal--fixed-2026-08-08)
again. The address is unmapped in the dump: memory that has been freed and
returned.

#### Why it is a race, from the dump

The process had **463 threads**, of which 14 are ghostty `renderer` threads and
14 are `io` threads - one pair per live surface. Thirteen of the renderer
threads sit in their event loop (`GetQueuedCompletionStatusEx`). **Thread 81,
named `renderer`, is not**: it is parked on a futex

```
ghostty_internal!park+0x174 <- futexWaitInner <- futexWaitUncancelable
```

while the UI thread is inside `rebuildCells`, which holds `draw_mutex`. One
renderer thread blocked on a renderer lock, one UI thread inside the renderer
holding it, at the moment of the fault.

#### The invariant that was broken

Upstream ghostty calls `updateFrame` from exactly one place: that surface's
render thread (`renderer/Thread.zig:384` and `:654`). Its internals rely on
that. The parts of `updateFrame` that mutate renderer-owned state run **outside**
any lock a second caller would take:

- `generic.zig:1313-1356` clears every row's `highlights` list and repopulates it
  through `updateHighlightsFlattened`, which allocates.
- The denormalization that resizes `terminal_state.row_data` is explicitly
  deferred to `endUpdate`, *outside* the terminal critical section, "keeping our
  lock" short.

`rebuildRow` then iterates `highlights.items` through a pointer *into* that same
`row_data`. Reallocate the one while the other walks it and the pointer dangles,
which is exactly the read that faulted.

Our patch `apprt: ghostty_surface_render_now for embedders without a paint loop`
added the second caller, and its doc comment states the case for safety:

> Both halves take the renderer state mutex, the same as the render thread's own
> path, so calling this from the thread feeding output is safe.

That is wrong, and it is the whole defect. The renderer *state* mutex protects
the **terminal**. It does not protect the renderer's own `terminal_state`,
`row_data`, highlight lists or cell buffers, which are private to one thread by
convention rather than by a lock.

#### How often this runs

Six UI-thread call sites, in `GhosttyControlCore.cpp`:

| line | caller |
|---|---|
| 1297 | `SetEndSelectionPoint` - **every mouse-drag update** |
| 1354 | `LeftClickOnTerminal` |
| 1407 | `ClearSelection` |
| 1414 | `SelectAll` |
| 1688 | `ScrollToMark` |
| 1779 | `SetPreedit` - the one that crashed, via TSF unfocus |

So the race is live on every drag, not only in the IME path. It survives because
the window is narrow and usually lands on memory still mapped.

**[KD-12](#kd-12--a-pane-double-frees-and-the-process-dies-with-heap-corruption--open)
is very likely the same root cause** - a double free inside libghostty, one day
earlier, on a build whose symbols were not published. Same class, same allocator,
two threads. That remains a hypothesis: 0.2.4's RVAs cannot be resolved, and
they never will be.

#### The fix, which needs a decision

Three shapes, and they are not equivalent:

1. **Stop calling it from the UI thread.** Restores upstream's invariant exactly:
   `updateFrame` runs on the render thread and nowhere else. The six call sites
   become a wakeup. This is what the *output* path already does - the forced
   render there was deleted in `perf(control): delete the forced render` - so the
   pattern is proven. The risk is the one that patch series kept rediscovering:
   a wake that lands after the render thread has sampled state leaves the pane
   stale until something else forces a frame.
2. **Marshal it.** Keep "render now" as a request, but have the render thread
   perform it and wait for completion. Correct, and preserves the synchronous
   feel the selection path wants, at the cost of a round trip on the UI thread.
3. **Lock the whole frame.** One renderer-wide mutex held across
   `updateFrame`+`drawFrame`, taken by both callers. Smallest diff, and the one
   most likely to deadlock against the terminal state mutex if the order is ever
   inverted.

**Option 1 was chosen** and is what shipped: the export is gone from libghostty
(so the compiler, not a reviewer, prevents its return) and the six call sites
are simply deleted.

#### Why nothing replaces them

Every operation those six perform already queues a render *inside* libghostty,
checked one at a time:

| call site | what queues the render |
|---|---|
| `SetEndSelectionPoint` | `cursorPosCallback` -> `queueRender` on the drag paths |
| `LeftClickOnTerminal` | `mouseButtonCallback`'s selection paths -> `queueRender` |
| `ClearSelection`, `SelectAll` | their binding actions, `Surface.zig:5548`/`5559` |
| `ScrollToMark` | `queueIo(.scroll_viewport)`, and the IO thread wakes the renderer |
| `SetPreedit` | `preeditCallback` -> `queueRender` on all three of its paths |

And the wakeup is not a coalescing one: `wakeupCallback` drains the mailbox and
calls `renderCallback` immediately (`Thread.zig:547`), with the delay-timer code
commented out upstream.

#### About the staleness this was meant to prevent

The fear was reasonable and the diagnosis behind it was wrong, which is why it
is worth writing down. `_connectionOutputHandler` already carries the finding:
the pane that froze mid-output was blamed on "libghostty's wakeup coalescing",
but the real cause was the renderer wakeup being **held by value** - libxev's
IOCP async keeps its state in the struct, so the copy's `notify()` set a bool
nobody read. Fixed in ghostty patch 34, after which output alone drove **321
renders in the second where it used to manage 2**. Nothing was ever wrong with
the wakeup as a mechanism.

#### Measured after the fix

A real left-button drag driven with SendInput - press, twelve moves, release -
then the pointer parked off-window and a capture taken with no other input, so
the selection can only be on screen if the render thread's own wakeup drew it:

```
ghostty pane, dragged row : selection pixels = 4404
cascadia pane, same drag  : selection pixels = 5933
```

Six focus round-trips over the exact path that crashed (foreground away and
back, driving TSF unfocus -> ClearComposition -> SetPreedit) leave the process
alive. `zig build test` passes on both font backends.

`scripts/probe-drag-select.ps1` is that drag, kept so the check is repeatable.
Two things it had to get right, both of which produced a *false* "the selection
never appeared": the calling process must be DPI-aware or every coordinate is
off by the display scale, and the window must be taken to the foreground with
`AttachThreadInput` first, with an activating click before the drag - the click
that raises a window is consumed by activation and selects nothing.

---

### KD-21 — A pane's padding is ghostty's default plus the profile's — **fixed 2026-08-18**

**Reported** by the user, as a suspicion rather than a symptom: *"ghostty is not
being passed or respecting the window padding configuration that is in
settings.json"*. Half right, and the half that was wrong is the interesting one.

The profile's `padding` **is** delivered. `TermControl::_ApplyUISettings`
(`TermControl.cpp:1069`) applies it as the SwapChainPanel's margin, and that
code does not know which engine is behind the panel — a ghostty pane is inset
by `"padding": "8, 8, 8, 8"` exactly as a cascadia one is. What failed is the
other half of the arrangement: `GhosttySettingsTranslator` pins
`window-padding-x/y = 0` so that ghostty does not pad the same pane a second
time, and **that pin never took effect**. Every ghostty pane drew ghostty's
default 2pt inside WT's 8 DIP.

#### What was measured

A live dev window at 144 DPI, two panes split horizontally running the same
shell and showing the same line, captured with `harness/wgc-shot` and measured
in pixels:

| pane | ink extent | first ink, relative to the pane's top-left |
|---|---|---|
| ghostty | 738 x 124 | (19, 19) |
| cascadia | 738 x 124 | (15, 15) |

Identical metrics — same font, same cell advance, the same 738x124 box of ink —
offset by **exactly 4 physical pixels on both axes**. ghostty's default
`window-padding-x`/`-y` is 2, and `Surface.zig`'s `scaledPadding` converts
points to pixels as `floor(pt * dpi / 72)`, so at 144 DPI that default is
`floor(2 * 144/72)` = 4. The number is not close to the prediction, it is the
prediction.

#### Why the pin did not land

`Surface.size.padding` — the value the renderer actually draws with — was
assigned in exactly two places:

1. `Surface.init`, from the config the surface is **born** with. For an
   embedder that is the *app's* config: `ghostty_surface_new` takes no config
   of its own.
2. `contentScaleCallback`, which returns early when the DPI has not changed.

`Surface.updateConfig` — what `ghostty_surface_update_config` runs, and the only
way an embedder can configure a surface at all — refreshed the derived config,
the renderer and termio, and left `size.padding` alone. `resize` looks like the
safety net, but it delegates to `balancePaddingIfNeeded`, whose first line
returns when `window-padding-balance` is `false`, which is the default and which
the translator also sets explicitly.

So `window-padding-x`/`-y` were the settings a reload could not change. This is
upstream behaviour, not something the fork introduced: a `ghostty +reload` would
have had the same problem. It is simply invisible to an app that reads its
config before the surface exists and never changes it afterwards, and fatal to
an embedder, which has no other order available.

A tell worth keeping: the value **did** correct itself on a DPI change. Dragging
a window between monitors of different scale ran `contentScaleCallback`, which
recomputed the padding from the by-then-correct config, and the 4 pixels
vanished for the rest of the session.

#### The fix, and the experiment that confirms it

Two patches, because the defect has two halves:

- ghostty, `config: window padding takes effect on a config update` —
  `updateConfig` recomputes `size.padding` from the new config after
  `setFontSize` (where the cell size balanced padding is measured against
  settles) and forces a resize when it changed, the way `contentScaleCallback`
  already does, so the renderer and the child both see the new grid.
- terminal, `fix(control): a pane is born with zero ghostty padding` —
  `GhosttyEngine::NewConfig` sets the zero padding on the **app** config, which
  is what a surface is actually born with. That closes the ordering window
  rather than depending on the later call, and keeps a pane correct against a
  libghostty built from a pin that predates the engine patch. It is also what
  `harness/hwnd-host` has always done.

Confirmed in the harness rather than by reading the diff.
`GHOSTTY_HARNESS_PADDING_VIA_UPDATE` was added to `hwnd-host` for it: `1`
withholds the app-config pin and pushes it afterwards through
`ghostty_surface_update_config` — Windows Terminal's order — and `2` withholds
it and never pushes it, which is the negative control the run needs, because
"both runs agree" is otherwise equally consistent with the variable doing
nothing. Three runs, same window, first ink measured from the client rect:

```
pin on the app config (default)   ink at (3, 50)   <- control
pinned via update_config (=1)     ink at (3, 50)   <- the fix: identical
never pinned (=2)                 ink at (7, 54)   <- the defect: +4, +4
```

#### What this leaves

`GhosttyControlCore::_mouseTo` states in a comment that it carries no padding
term *because* the pin holds, and says that if the padding ever stops being zero
the term has to grow with it. For the whole time the pin did not hold, it did
not: a pointer aimed at cell X was sent as `(X + 0.25) * cellWidth`, from which
ghostty subtracted 4 px before taking the fraction, landing in cell X-1 at about
94% across — which the 60% rule then resolves to the boundary between X-1 and X,
the intended one. Correct by luck at this cell width, not by construction, and
correct for the right reason now.


---

### KD-20 — A URL highlighted where the last click was, and ctrl+click opened nothing — **fixed 2026-08-18**

**Reported** by the user, from use: *"when we hold ctrl in ghostty it does seem
to highlight URLs but when we click them it does not open in browser like it
does in cascadia."*

Both halves of that sentence were evidence. The highlight was real ghostty
highlighting — of the link at a stale point — and the click had nothing to open
on either side of the seam.

#### What was wrong

**1. ghostty was never told where the pointer was.** `SetHoveredCell` and
`ClearHoveredCell` were empty stubs, and the only mouse positions libghostty
ever received came from a selection (`SetSelectionAnchor`,
`SetEndSelectionPoint`) or from VT mouse reporting. Its cursor sat wherever the
last click or drag had left it.

That is what the user was seeing. ghostty re-runs link detection whenever the
modifiers change — `Surface.zig`'s key handler calls `mouseRefreshLinks` against
`rt_surface.getCursorPos()` — so pressing ctrl lit up the link at that stale
position. A feature that looks like it works and answers about the wrong cell.

**2. The click had nothing to open.** `ControlInteractivity::PointerPressed`
prioritises a hyperlink over everything else on a ctrl+left-click (GH#9396) and
asks the core for one; `GhosttyControlCore::GetHyperlink` returned an empty
string unconditionally, so the branch never ran and the click fell through to
the selection path.

**3. ghostty's own opener could not run either.** ghostty opens a link on the
*release* of a click over one (`Surface.zig`, `processLinks`), and the selection
path sends no press at all for a single click and synthesises the release
lazily. `GHOSTTY_ACTION_OPEN_URL` was unhandled as well — it fell to
`default: return false`, which is what makes libghostty fall back to its own
opener (`rundll32 url.dll,FileProtocolHandler`), so had the click arrived it
would have opened the URL *around* WT's dialog rather than through it.

#### The fix

`SetHoveredCell` sends the position, and everything else follows from ghostty
already doing the work:

- **The position.** One `ghostty_surface_mouse_pos` per *cell* the pointer
  enters, and `ClearHoveredCell` sends a negative one, which is what ghostty
  reads as "outside".
- **The modifiers.** A position has to state them, and WT's hover call carries
  none, so the value is the one the last key event carried. That is not a second
  source of truth: ghostty derives its own modifier state from those same key
  events, so the two can only ever agree. It is dropped on `LostFocus`.
- **The drag.** ControlInteractivity calls `SetHoveredCell` at the end of *every*
  pointer move, a drag's included, where the position has just been sent with
  the selection's modifiers — so the selection path marks the event and the
  hover stands aside. The first hover after a drag is also where the synthesised
  release now happens, since WT reports no release outside VT mouse mode; before
  this the release waited for the next click, and hover positions would have
  been read as a drag that never ended.
- **The link.** `GHOSTTY_ACTION_MOUSE_OVER_LINK` carries the URL under the
  pointer, or an empty one when it leaves. That is what `GetHyperlink`,
  `HoveredUriText` and `HoveredCell` answer with, and what raises
  `HoveredHyperlinkChanged` for the tooltip. WT's own ctrl+click path does the
  rest, unchanged.
- **`GHOSTTY_ACTION_OPEN_URL`** is claimed and raised as `OpenHyperlink`, so a
  link ghostty decides to open goes through WT's opener and its dialog instead
  of `rundll32`.
- **A synthesised release must not open a link.** ghostty opens on release, and
  WT's release is inferred rather than reported, so `_releaseMouseIfHeld` flags
  the window in which an `OPEN_URL` is ours to ignore. Without it, a
  double-click inside a URL followed by ctrl and a mouse move would open it.

The profile's `detectURLs` now reaches ghostty as `link-url`, so a profile that
turns URL detection off gets a pane with no links rather than ghostty's default
of on.

#### Measured, in a pane

A portable build of this tree, driven by `scripts/probe-link-hover.ps1`:

| Step | Before | After |
|---|---|---|
| ctrl+hover a URL in output | the link at the last *click* highlighted, if any | `ftp://example.com/kd20` underlines **under the pointer** |
| ctrl+click a URL | nothing at all | opens through WT's opener — a typed `http://www.google.com` launches the browser |

The click was confirmed by hand, on a typed URL, because the scripted half
of the probe is not yet trustworthy: the run that ctrl+clicked
`ftp://example.com/kd20` produced no refused-scheme dialog, and by then
the window had lost the foreground to the user, so that run says nothing
either way. **Unverified: WT's dialog for a scheme it will not launch.**
The path it takes is the same one the browser case exercises, up to
`TerminalPage::_OpenHyperlinkHandler`.

One thing the probe had to get right, and got wrong first, costing a
capture that showed a working fix as broken: **the injected modifier must
be `VK_LCONTROL`, not `VK_CONTROL`**. `_GetPressedModifierKeys` asks
`CoreWindow::GetKeyState` about `LeftControl` and `RightControl`
specifically, and a generic `VK_CONTROL` injection sets neither, so the
pane never sees ctrl and no link is ever highlighted.

`unitControl`: 68 tests, 67 passed, 1 pre-existing skip. The new one pins
the `link-url` translation; the hover and the click need a window and are
measured above rather than in a test.

#### OSC 8 hyperlinks

Covered by the same path, with no code of their own: ghostty's `linkAtPos`
checks the cell's hyperlink data before it tries the URL regex, reports the
URI through the same `MOUSE_OVER_LINK`, and opens it through the same
`processLinks`. So the readback here answers with the OSC 8 *target*, not
the text it is written under, which is what makes `ls --hyperlink` and a
build log's clickable paths work.

**Measured, by hand, 2026-08-18.** An OSC 8 sequence whose label is
`CLICK THIS TEXT` and whose target is `https://example.com/osc8-target`:
ctrl+hover underlines the label, and ctrl+click opens the target rather
than the words - which is the part worth checking, since the two differ.
By hand rather than by probe: `probe-link-hover.ps1` cannot take the
foreground while someone is at the keyboard, and should not try.

One difference does bite here: ghostty only looks for an OSC 8 link when
the modifiers *equal* ctrl-or-super, so an application's own links are
invisible until ctrl is held, where cascadia shows them on a plain hover.

#### Still ghostty's, not cascadia's

Which text counts as a link, and the fact that every link - OSC 8 included -
previews only while ctrl is held — both are ghostty's rules and are written up as
[GD-01](documented-diffs.md#gd-01--hyperlinks--implemented-2026-08-18).

---

### KD-22 — A ghostty pane never learned the shell's working directory — **fixed 2026-08-18**

**Reported** by the user, from use: Windows Terminal has custom VT sequences
"for things like setting the current working directory of the terminal", and
they do not appear to work on a ghostty pane.

They were right, and the cause was one `return` in libghostty. What follows is
first the inventory — which sequences Windows Terminal actually implements, and
what libghostty does with each — because the fix is only defensible against the
whole list.

#### What Windows Terminal implements

`OutputStateMachineEngine::ActionOscDispatch`
(`src/terminal/parser/OutputStateMachineEngine.cpp:763`) is the whole set. The
non-standard ones — the ones the user was asking about — are these:

| sequence | WT calls | what WT does with it |
|---|---|---|
| `OSC 7;<file: URI>` | `SetCurrentWorkingDirectory` | `PathCreateFromUrlW`, then `ITerminalApi::SetWorkingDirectory` |
| `OSC 9;9;"<path>"` | `DoConEmuAction` sub 9 | same sink, native path, quotes optional |
| `OSC 9;4;<state>;<pct>` | `DoConEmuAction` sub 4 | `SetTaskbarProgress` — the taskbar bar |
| `OSC 9;12` | `DoConEmuAction` sub 12 | `Buffer().StartCommand()` — a prompt mark |
| `OSC 133;A/B/C/D` | `DoFinalTermAction` | prompt / command / output / exit-code marks |
| `OSC 1337;SetMark` | `DoITerm2Action` | `Buffer().StartPrompt()` |
| `OSC 633;Completions;…` | `DoVsCodeAction` | the shell-completions menu |
| `OSC 777;notify;…` | `DoUrxvtAction` | a desktop notification |
| `OSC 9001;CmdNotFound;<cmd>` | `DoWTAction` | **WT's own**: asks WinGet what provides the command |

`OSC 9;9` is the one that matters most on Windows: WT's own comment beside
`SetCurrentWorkingDirectory` says so — *"While ConEmu's OSC 9;9 works well for
native Windows paths, OSC 7 uses file URIs, which may not always work."*

#### What libghostty does with the same bytes

Measured, not read: `harness/hwnd-host` gained a `GHOSTTY_ACTION_PWD` print,
and every sequence above was fed to the shipped DLL through
`GHOSTTY_HARNESS_FEED` with `GHOSTTY_LOG=stderr`, which logs each action as it
is dispatched. One run, 23 cases.

| sequence | libghostty | reaches a WT ghostty pane? |
|---|---|---|
| `OSC 0` / `OSC 2` | `.set_title` | yes |
| `OSC 4` / `10` / `11` / `12` | `.color_change` | yes |
| `OSC 7` | `.pwd` | **yes, after this fix** |
| `OSC 9;9` | `.pwd` | **yes, after this fix** |
| `OSC 1337;CurrentDir=` | `.pwd` | **yes, after this fix** |
| `OSC 9;4` | `.progress_report` | yes — dispatched, and `GhosttyControlCore` raises `TaskbarProgressChanged` |
| `OSC 9;<text>` | `.desktop_notification` | no — `GhosttyControlCore` has no case for it |
| `OSC 777;notify` | `.desktop_notification` | no — same |
| `OSC 133;A/B/C` | marks, held internally | no — `ScrollMarks()` returns an empty vector |
| `OSC 133;D` | `.command_finished` | no — no case for it |
| `OSC 9;12` | *nothing* — ghostty has no ConEmu sub 12 | no |
| `OSC 1337;SetMark` | *nothing* — `unimplemented OSC 1337: SetMark` | no |
| `OSC 633;Completions` | *nothing* — no OSC 633 state at all | no |
| `OSC 9001;CmdNotFound` | *nothing* — no OSC 9001 state at all | no |

So the picture is not "WT's sequences are unsupported". Three of the four
working-directory spellings were parsed correctly and thrown away one layer
later, the taskbar-progress sequence reaches the pane already, and the genuinely
absent ones are the shell-integration set and the two proprietary protocols.

#### The cause

`src/termio/stream_handler.zig`, `reportPwd`:

```zig
if (builtin.os.tag == .windows) {
    log.warn("reportPwd unimplemented on windows", .{});
    return;
}
```

That return is before `terminal.setPwd` and before the `.pwd_change` surface
message, so no `.pwd` action was ever dispatched and
`GhosttyControlCore`'s `GHOSTTY_ACTION_PWD` case — which has existed since
Phase 5 — never ran. `ICoreState::WorkingDirectory` stayed the empty string,
and `Utils::IsValidDirectory("")` is false, so every consumer took its
fallback: a duplicated tab or split opened at the profile's
`startingDirectory` instead of where the shell was.

Nothing above it was wrong. The OSC parser handles all three spellings and
routes them to the same `report_pwd` command
(`terminal/osc/parsers/osc9.zig` for `9;9`, `iterm2.zig` for `CurrentDir`), and
ConPTY relays them from the child unchanged.

#### The fix

`termio: report the pwd on Windows, from OSC 7, OSC 9;9 or OSC 1337`
(ghostty patch 0044). The posix path cannot simply be reused: it requires a
`file:` or `kitty-shell-cwd:` scheme and a present host, and `OSC 9;9` and
`OSC 1337;CurrentDir` carry a bare native path with neither. The Windows path
takes both shapes and always stores a native path, so the embedder does not
have to know which sequence produced it:

- a `file:`/`kitty-shell-cwd:` URI is parsed, its host validated as local — with
  an absent or empty host meaning this machine, per RFC 8089, which is the form
  `file:///C:/src` shell integration emits — and its path percent-decoded and
  un-rooted (`/C:/src` → `C:/src`);
- a native path is taken as-is, with ConEmu's optional surrounding quotes
  stripped;
- either way `/` becomes `\`, and the result must be drive-absolute or UNC and
  free of characters Windows forbids in a path, or it is refused with a warning
  rather than handed on to something that will pass it to `CreateProcess`.

A second, smaller thing turned up beside it and is fixed in the same release:
`GhosttyControlCore`'s constructor seeded the pane's title from the profile the
way cascadia does, but not its working directory (`ControlCore.cpp:112`,
GH#8969). Terminal patch 0061.

#### What was measured

**Through the DLL.** The feed run above: OSC 7 `file:///C:/src/winterm-ghostty`,
OSC 9;9 `"C:\Windows\System32"` and OSC 1337 `CurrentDir=C:\Users\darre` each
produced exactly one `.pwd` action carrying the native path. The negative
controls refused: `file://example.com/C:/evil` logged *OSC 7 host
(example.com) must be local*, and `9;9;"relative\path"` logged *pwd is not an
absolute path*.

**Through Windows Terminal, without a keyboard.** The user was at the machine,
so the SendKeys route was unavailable (it is, correctly, refused —
see the headless-driving notes). Instead: the portable build with
`"firstWindowPreference": "persistedWindowLayout"`, a profile whose
`startingDirectory` is the terminal's own folder and whose command line runs
one script that emits one OSC and idles, closed with `WM_CLOSE` to its hwnd.
WT then writes each pane's `GetNewTerminalArgs` into `settings\state.json`, and
that `startingDirectory` **is** `ICoreState::WorkingDirectory` when the control
has one (`TerminalPaneContent.cpp:94`). No foreground required.

| what the pane emitted | `startingDirectory` in `state.json` |
|---|---|
| `OSC 9;9;"…\pwd-conemu"` | `…\pwd-conemu` |
| `OSC 7;file:///…/pwd-osc7` | `…\pwd-osc7` |
| nothing at all | `…\terminal-0.1.0.0` — the profile's own |

The first two differ from the profile's `startingDirectory`, which is what
makes them evidence: the value can only have come from the sequence.

#### What this does not fix

Still absent, and each needs its own decision rather than a follow-on commit:

- **Shell-integration marks.** ghostty tracks `OSC 133` prompts internally and
  even dispatches `.command_finished`, but `GhosttyControlCore::ScrollMarks`,
  `SelectCommand` and `CommandHistory` are stubs. This is the Phase 5 obligation
  map's "needs a PowerShell integration script" row, not a regression.
- ~~**Desktop notifications.**~~ **Done, 2026-08-18** (terminal patch 0062), at
  the user's direction and in the same session. `GhosttyControlCore` raises the
  same `ShowNotification` event `ControlCore` raises, so the toast, the rate
  limit, the "you are looking at that pane already" rule and click-to-summon are
  `TerminalPage`'s and unchanged. The gate is the profile's
  `compatibility.allowOSC777` — **off by default** — translated to ghostty's
  `desktop-notifications`, which `Surface.zig:1116` tests *before* dispatching,
  so a pane that is not allowed to notify does not do the work. The two engines
  default that setting opposite ways round, which is why the translation is
  pinned by a unit test rather than assumed. One difference comes with it and is
  written up as [GD-19](documented-diffs.md): with the switch on, a ghostty pane
  also honours iTerm2's bare `OSC 9;<text>`, which WT's parser discards.
  Measured with `scripts/probe-notify.ps1`, both ways round: allowed →
  `notification title=11 body=14 chars` on the debugger channel; refused →
  nothing, with the ghostty traces still flowing so the silence is evidence
  rather than an absent probe.
- **`OSC 9001;CmdNotFound` and `OSC 633;Completions`.** libghostty has no parser
  state for either, so these need a new OSC state *and* a new C-API action —
  a public API shape, which under PROCESS.md rule 3 is escalated, not decided
  in passing. Both are WT-proprietary protocols whose value upstream is
  questionable; a `DECISION-NEEDED` entry belongs with them if they are wanted.

---

### KD-23 — `compatibility.allowOSC52` was not honoured on a ghostty pane — **fixed 2026-08-18**

**Found while wiring up notifications for [KD-22](#kd-22--a-ghostty-pane-never-learned-the-shells-working-directory--fixed-2026-08-18)**, and reported to
the user rather than fixed in passing; they asked for it, so here it is.

`compatibility.allowOSC52` decides whether a program running in the pane may
put text on the clipboard. ghostty spells the same switch `clipboard-write`,
and `GhosttySettingsTranslator` never forwarded it. Both sides default to
allowing it, which is exactly why this stayed invisible for eight phases: it
bites only the user who deliberately turned OSC 52 **off** and got a ghostty
pane that wrote the clipboard anyway — a setting silently ignored, in the
direction where ignoring it matters.

`set("clipboard-write", settings.AllowVtClipboardWrite() ? "allow" : "deny")`
is the whole fix (terminal patch 0063).

#### The risk worth measuring rather than reasoning about

`clipboard-write` could plausibly have gated ghostty's *own* copy as well, in
which case a user turning OSC 52 off would have lost ctrl+c on a ghostty pane —
a far worse bug than the one being fixed. It does not: `Surface.clipboardWrite`
is the OSC 52 path (it base64-decodes), and `copy_to_clipboard` goes through
`copySelectionToClipboards`, which never consults the config.

Measured through the shipped DLL with `harness/hwnd-host`, feeding
`OSC 52;c;Y2xpcGJvYXJkIHByb2Jl` ("clipboard probe"):

| run | result |
|---|---|
| `--clipboard-write=allow` | `[clip] mime=text/plain len=15 head=clipboard probe` |
| `--clipboard-write=deny` | `info(surface): application attempted to write clipboard, but 'clipboard-write' is set to deny` |
| `--clipboard-write=deny`, plus a selection and the same `copy_to_clipboard` binding action `GhosttyControlCore` sends | `[clip] copy plain` / `[clip] mime=text/plain len=13 head=OPY THIS LINE` |

The third row is the one that had to be run. The harness prints what would
reach the clipboard instead of setting it, so none of this touched the real
one.

And through a real pane, off the debugger channel — `allowOSC52: false` →
`[ghostty] set clipboard-write = deny`, `true` → `allow`.

#### `ask` is a value we deliberately never send

ghostty's third value asks the embedder to confirm, through the `confirm` flag
on the write callback. `GhosttyEngine::_writeClipboard` names that parameter
`/*confirm*/` and implements no prompt, so `ask` would read as "confirm first"
and behave as "write silently" — worse than either honest answer. A unit test
asserts it is not emitted.

#### The read half needs nothing

WT parses an OSC 52 *query* and then ignores it unconditionally
(`_GetOscSetClipboard(...) && !queryClipboard`), and
`GhosttyEngine::_readClipboard` already answers "nothing available" because
paste is driven from WT's side. A program cannot read the clipboard on either
engine whatever this setting says, so `clipboard-read` is left at ghostty's
default rather than pinned to something that would only look load-bearing.

#### The rest of the `compatibility.*` family, measured

The same question asked of every switch in that family, so the answer is a
list rather than an impression:

| setting | default | on a ghostty pane |
|---|---|---|
| `compatibility.allowOSC52` | true | **honoured** (this fix) |
| `compatibility.allowOSC777` | false | **honoured** ([KD-22](#kd-22--a-ghostty-pane-never-learned-the-shells-working-directory--fixed-2026-08-18)) |
| `compatibility.allowDECRQCRA` | false | moot — ghostty does not implement DECRQCRA at all, which is what the default asks for |
| `compatibility.allowDECNKM` | **false** | **not honoured.** ghostty implements DECNKM (mode 66 is in `modes.zig` and is not logged as unimplemented when fed), with no config to refuse it |
| `compatibility.kittyKeyboardMode` | true | **not honoured** in the off direction; ghostty has no config to disable the protocol |

The last two are open, and neither is a translator line: both need a new
libghostty config, which is a public API shape and therefore escalated rather
than decided in passing. `allowDECNKM` is the more interesting of the two —
its default is *off*, so a ghostty pane differs from cascadia there for
everyone, not only for the user who changed a setting.

---

### KD-24 — After the process exits, Ctrl+D and Enter do nothing — **fixed 2026-08-21**

**Reported by the user, from use.** A pane whose child has exited prints the
message the connection always prints:

```
[process exited with code 56 (0x00000038)]
You can now close this terminal with Ctrl+D, or press Enter to restart.
```

On a ghostty pane neither key does anything. The message is the connection's,
so it appears on both engines and promises the same two things on both; only
cascadia keeps the promise. The pane is not wedged — it is simply deaf to the
only two keys it has just advertised — so the way out is the mouse: the tab's
close button, or `ctrl+shift+w`.

**Both keys are the host's, not the terminal's.** Cascadia answers them in
`ControlCore::SendCharEvent`: with the connection at `>= Closed`, `0x04` raises
`CloseTerminalRequested` and `CR` raises `RestartTerminalRequested`, and
`TerminalPage::_restartPaneConnection` hands the pane a fresh connection.

**Why a ghostty pane never gets there.** It is not that the branch was copied
wrong — the branch does not exist in `GhosttyControlCore`, and the path it lives
on is unreachable anyway:

- On cascadia, `Terminal::SendKeyEvent` returns *no* output for a key down that
  the layout maps to a character (`Terminal.cpp:676`). `TrySendKeyEvent` then
  reports the key unhandled, Windows raises `CharacterReceived`, and
  `SendCharEvent` sees `0x04` / `CR`.
- On ghostty, `ghostty_surface_key` encodes Enter and ctrl+d itself and returns
  `true`. `TermControl` treats a handled key as translated and suppresses the
  character event, so `GhosttyControlCore::SendCharEvent` is never called for
  either key. A branch added there alone would have looked right and changed
  nothing.

So the answer belongs on the key path, ahead of the surface (terminal patch
0064). `GhosttyControlCore::TrySendKeyEvent` checks the connection state first,
and `GhosttyExitKeyFor` — a pure function, unit tested without a surface —
decides which of the two promises a key press is:

| key | on a closed connection |
|---|---|
| Enter, or shift+Enter | restart |
| ctrl+d, ctrl+shift+d | close |
| ctrl+Enter | nothing — it is LF, and cascadia does not restart on it either |
| alt+Enter, alt+d | nothing — alt+enter is WT's fullscreen binding |
| anything else | goes to the surface, as before |

The key *release* is swallowed with the press, so a surface that has just been
told to go away is not handed a lone key-up. The check sits ahead of the
read-only guard on purpose: a read-only pane whose process is gone still has to
be closable, which is cascadia's behaviour too. `SendCharEvent` gets the same
two answers, matched on the character exactly as cascadia matches them — it does
not fire for these keys today, but it is the path an IME commit or an injected
`VK_PACKET` would take, and the promise should not depend on which path the
character took.

#### Measured, in the shipped product

A Debug portable build (`package-portable.ps1`), a profile whose command line
is `cmd.exe /c exit 56` with `closeOnExit: never` and `engine: ghostty`, driven
by **posting `WM_KEYDOWN`/`WM_KEYUP` to the XAML input site** rather than by
stealing focus - the user was at the keyboard, and the first attempt with
`SendKeys` proved only that the window had lost the foreground.
`PostMessage` to the `Windows.UI.Input.InputSite.WindowClass` child needs no
activation at all, which makes it the better probe for anything key-shaped.
ctrl is the one thing that cannot be posted - `_GetPressedModifierKeys` reads
the real key state - so it is injected with `keybd_event(0xA2)` around the
posted `d`.

| step | expected | observed |
|---|---|---|
| pane opens, child exits 56 | the message | `[process exited with code 56 (0x00000038)]` |
| post Enter | restart in place | a **second** run of `cmd /c exit 56`, its exit message below the first, the scrollback intact |
| ctrl + posted `d` | close | the last pane went, and the process exited |

And the same two keys against a **live** `cmd.exe` ghostty pane, because the
cost of getting the guard wrong is breaking Enter for everyone: Enter still
reaches the shell (a second `C:\Users\darre>` prompt), and ctrl+d still goes to
the child rather than closing the pane.

#### What restart does not do yet

`TerminalPage::_restartPaneConnection` calls `HardResetWithoutErase()` before
attaching the new connection, to drop VT state the dead client may have left on
— bracketed paste, mouse tracking, the alternate screen, kitty keyboard flags.
`GhosttyControlCore::HardResetWithoutErase` is a **no-op**: libghostty exposes
no non-erasing hard reset. Its `reset` binding action is a full reset, which
erases, and erasing is exactly what the "WithoutErase" in the name is there to
prevent — a restart would throw away the scrollback the user just read the exit
code from.

So a ghostty pane restarts with whatever modes the previous child left behind.
A shell that exited normally leaves none, which is the case the message is
about; a client killed mid-alt-screen would leave a mess. That gap is a new
libghostty C entry point, not a translator line, so it is **escalated rather
than decided in passing**, and this entry is the record of it.

---

### KD-25 — Shifted characters cannot be typed from a remote keyboard — **fixed 2026-08-21**

**Reported by the user, from use**, typing into a ghostty pane through the
Windows App on Android: `:` and `?` could not be typed at all, nor any other
shifted character. `?` arrived as `/`, `A` as `a`. Not a regression — the same
keys fail on **0.2.2**, checked by the reporter — and invisible at the machine's
own keyboard, which is why it survived every session until someone typed from a
phone.

It reads like [KD-08](#kd-08), and it is neither of the two bugs that turned out
to be here. KD-08 was `?` arriving as `/` in kitty-protocol applications only,
because the modifiers a layout *consumes* were reported as none.

**Two independent defects, and the first hypothesis about the transport was
wrong.** Both are real, both are fixed, and only the second one is what the
reporter was hitting. The first was found by reasoning about the code and
reproduced synthetically; the second was found only by measuring what the
client actually sends. The order matters, because the first explanation
accounted for the symptom perfectly and was still not the cause.

#### Defect 1 — the modifier state is a snapshot, and it is later than the key

`TermControl::_KeyHandler` builds its `ControlKeyStates` from
`_GetPressedModifierKeys()`, which asks `CoreWindow::GetKeyState` for each
modifier when XAML raises the routed `KeyDown`. That answers *what is held now*,
not *what was held when this key was pressed*, and those agree only if the
modifier is still down when the handler runs.

A person holds shift for something like a tenth of a second, so it is. A client
that sends shift-down, the key, and shift-up back to back leaves the handler
asking after the release, and `GhosttyKeyTextFor` is then given no shift: the
layout answers with the unshifted character. A cascadia pane is correct on the
same events because it never asks — its text arrives as `CharacterReceived`,
which Windows generates from the message stream itself.

**Fixed** by reading the stream instead of the state. `GhosttyModifiersFor`
tracks the modifier keys from their own key events and returns the snapshot
**unioned** with what it has seen held. The stream cannot drift the way the
snapshot does, because it is ordered: the shift press is delivered before the
key it modifies and the release after it.

The union is in that direction on purpose. A modifier held before this pane had
focus is in the snapshot and was never seen as an event, so the snapshot cannot
simply be replaced. The opposite risk — a modifier believed held that is not,
which would put every following key in the wrong case — is bounded by clearing
the tracked set on **both** `GotFocus` and `LostFocus`, since a release that
happens while another window owns the keyboard never arrives here.

Caps Lock is deliberately not tracked: it is a state rather than a hold, it is
reported as locked rather than pressed, and it is not subject to the race.

#### Defect 2 — a VK_PACKET is a character, and its scan code is not a scan code

What the Windows App on Android actually sends, measured with `harness/keylog`,
a low-level keyboard hook that sees the injected events before any window does:

```
196381.32 ms  down LSHIFT     vk=0xA0 scan=0x2A shiftState=0
196473.57 ms  up   LSHIFT     vk=0xA0 scan=0x2A shiftState=1
196861.80 ms  down PACKET     vk=0xE7 scan=0x41 shiftState=0
199713.32 ms  down PACKET     vk=0xE7 scan=0x3A shiftState=0
203885.95 ms  down PACKET     vk=0xE7 scan=0x3F shiftState=0
```

The soft shift key is a press of its own that is **over before the character
arrives** — 388 ms before — and the character is then injected as a `VK_PACKET`
whose scan code is the UTF-16 code unit: `0x41` is `A`, `0x3A` is `:`, `0x3F` is
`?`. Shift is not a modifier on this transport at all.

Reading that as a scan code asks a different question. Scan code `0x41` is F7,
`0x3F` is F5, `0x3A` is Caps Lock. So the pane sent F7's escape sequence for a
typed `A`, nothing at all for `:` — and because it reported the key *handled*,
the character event that would have carried the text was suppressed. Confirmed
from the pane's own view, with `GHOSTTY_TRACE_KEYS` set:

```
[ghostty] key down vkey=0xE7 scan=0x3A mods=0x0000 held=0x0000 text=(none)
```

**Fixed** by `GhosttyPacketText`: for `VK_PACKET` the character is the event.
The keycode handed to libghostty is 0 rather than the scan code, the text is
that code unit as UTF-8, and every modifier is marked consumed — the client
already accounted for them when it chose the character. A character outside the
BMP arrives as two packets, so a high surrogate is held until its low surrogate
lands; that state is cleared on a focus change like the modifier state.

#### The measurement that told the two apart

Nothing observable from outside distinguishes them: both produce a lost shift,
and defect 1 explains the reported symptom completely. What settled it was
instrumenting the pane itself (`GHOSTTY_TRACE_KEYS`, read with
`scripts/probe-key-trace.ps1`) and a hook on the raw input (`harness/keylog`),
then comparing. Two rounds of inference from the source produced a confident
wrong answer before either instrument was built.

Worth keeping: **a fix that makes the symptom go away in a synthetic
reproduction is not evidence that the cause was found.** The synthetic
reproduction here posted real key messages, which is a transport the reporter
never used.

#### Measured

**The real transport, before the fix.** A pane running `harness/rawin`, which
names every byte the child receives, with the reporter typing `;?A` from
Android into the shipped 0.2.10:

```
recv[1]: ;
recv[1]: /
recv[1]: a
```

**Both paths, on the built fix**, driven by `scripts/probe-shift-posted.ps1`,
which posts key messages to the XAML input site — no foreground needed, so it
does not fight a user at the keyboard:

| event posted | 0.2.10 | with patch 0065 |
|---|---|---|
| `;` | `;` | `;` |
| shift+`;` (as key events) | `;` | `:` |
| shift+`/` (as key events) | `/` | `?` |
| shift+`a` (as key events) | `a` | `A` |
| packet `0x3A` | nothing | `:` |
| packet `0x3F` | `ESC O P` (F1) | `?` |
| packet `0x41` | `ESC [ 15~` (F5) | `A` |

That probe posts its own messages, so WT's pump also translates them into a
`WM_CHAR` and each chord can land twice — once from the key path and once from
the character path. Read the log for *which* characters appear, not for how
many.

`unitControl` 74/74, including three new pure tests: shift held only in the
event stream still shifts, a release stops applying, and a packet carries its
character in the scan code (surrogate pairs included).

#### The gap left open

`TermControl::_TryHandleKeyBinding` matches key bindings against the same stale
snapshot, on both engines. A `ctrl+shift+f` typed from a remote client can
therefore miss its binding — unreported, not measured here, and a change in
shared upstream code rather than in the ghostty translator, so it is recorded
rather than fixed in passing.
