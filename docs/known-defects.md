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
