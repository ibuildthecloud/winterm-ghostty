# Phase 7 readiness — presentation & performance

Answers to the three open questions PLAN.md attaches to Phase 7, plus what the
answers change about the phase's exit criteria. Written 2026-08-07, after the
first sitting had already done the throughput half.

Everything here is checked against source in this tree. Where a claim is an
inference rather than a measurement it says so.

---

## The measurement Phase 7 actually starts from

The first sitting's numbers matter to every question below, so they go first:

| | Throughput |
|---|---|
| a ghostty pane, as shipped 2026-08-06 | 4.2 MB/s |
| a ghostty pane, forced render **throttled** (shipped now) | **28.0 MB/s** median |
| a ghostty pane, forced render **removed entirely** | **37.4 MB/s** |
| a cascadia pane | **38.1 MB/s** |

The third row is the one that reframes the phase. **With the forced render out,
the engine is already at parity.** The remaining 26% is not renderer cost — it
is the cost of forcing renders at all, which exists only because libghostty's
wakeup can coalesce a notify into a wake that has already sampled state.

So Phase 7 is not "make the renderer faster". It is one upstream correctness fix
plus the presentation policy that was deferred into this phase by name.

---

## Q1 — Where does the waitable-swapchain wait live?

**The question assumed this is hard because ghostty's renderer thread runs a
libxev loop. Cascadia solves it without an event loop at all, and that answer is
sitting in this repo.**

`AtlasEngine` — the engine we are benchmarked against, in `terminal/`:

- Creates the swap chain with `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`
  (`src/renderer/atlas/AtlasEngine.r.cpp:320`).
- `SetMaximumFrameLatency(1)` (`:379`).
- Waits by **blocking the render thread**: `WaitForSingleObjectEx(handle, 100, true)`
  in `_waitUntilCanRender()` (`:436-448`), reached from the render loop at
  `src/renderer/base/renderer.cpp:157`. No loop integration, no bridge, no
  dedicated wait thread.
- Guards the auto-reset event against a double wait with a `waitForPresentation`
  flag — the comment at `:438` is the whole subtlety: *"IDXGISwapChain2::GetFrameLatencyWaitableObject
  returns an auto-reset event. Once we've waited on the event, waiting on it
  again will block until the timeout elapses."*

The hooks on our side are already stubbed and labelled for this phase:

- `ghostty/src/renderer/directx11/Frame.zig:50-55` — `complete(sync)` **ignores
  `sync`**: *"Phase 1 presents on the immediate context and does not yet use a
  waitable swap chain. The frame-latency wait object and the damage-gated present
  policy are Phase 7."*
- `ghostty/src/renderer/D3D11.zig:57-60` — `swap_chain_count = 2`, with the note
  that a third buffer is only useful once the waitable swap chain exists.

### The open question offered three options; one of them does not exist

PLAN asks: "xev async bridge, dedicated wait thread, or timer-approximation
first?" **libxev cannot wait on a Win32 event handle at all.** In the pinned
dep (`build.zig.zon:19-24`, upstream `9ce8e8e6`, unvendored and unpatched):

- `Loop.associate_fd` (`backend/iocp.zig:867-875`) is `CreateIoCompletionPort`,
  which only accepts handles that support IOCP association — files, sockets,
  pipes. A frame-latency waitable object is an auto-reset **event**, which does
  not.
- There is no `RegisterWaitForSingleObject`, no `WaitForSingleObject`, no
  thread-pool wait bridge anywhere in libxev.

So "xev async bridge" is not an option to choose, it is a feature to write —
upstream, in someone else's project, before Phase 7 could use it.

**Recommendation: block, like cascadia, at the top of the draw.** It is the
smallest change, it matches the engine we have to match, and the timeout bounds
the damage.

**Fallback if that measurably hurts input:** a dedicated wait thread that calls
`draw_now.notify()`. That async already exists and is already documented as the
one that *must not* coalesce (`Thread.zig:67-70`), so the plumbing is in place —
it is only currently notified from macOS's DisplayLink path
(`generic.zig:918-925`).

**The cost this buys, stated honestly:** ghostty's render thread is not
cascadia's. Cascadia's render thread does nothing but render, so blocking it
costs nothing else. ghostty's runs an xev loop carrying six registrations
(`ghostty/src/renderer/Thread.zig:49-73`) — `wakeup` and `stop` and `draw_now`
asyncs, and `render_h`, `draw_h` and `cursor_h` timers — so a blocking wait
delays *all* of them by up to one frame interval. That is acceptable for a 60 Hz
wait and **not** acceptable if the wait ever hits the 100 ms timeout. It needs a
counter on the timeout path before it is trusted, not an assumption.

Note also `Thread.zig:68` on `draw_now`: it exists precisely because it must
*not* "coalesce like the wakeup does" — the same coalescing that forced the
Windows Terminal integration to call a render per chunk.

A dedicated wait thread signalling an xev async remains the fallback if the
blocking wait measurably delays input handling. It should not be built first.

---

## Q2 — How to measure latency fairly

The phase asks for "latency ≤ cascadia median" without saying how it is
measured, and the two obvious tools each answer a different question:

- **PresentMon / ETW** measures present-to-display intervals. It would tell us
  about presentation cadence, which is Q1's business, and nothing about how long
  after a keystroke a character appears.
- **An in-app instrumented timestamp** cannot compare the two engines fairly,
  because the two paths do not share an input entry point — and the thing we are
  measuring is exactly the difference between those paths.

**Recommendation: build a keystroke-to-pixel probe on the capture tooling this
repo already has.** `harness/wgc-shot` uses `Direct3D11CaptureFramePool`, and a
WGC frame carries `SystemRelativeTime` — a QPC-comparable timestamp for the
frame DWM composited. So:

1. Timestamp a `SendInput` of one character (QPC).
2. Keep pulling frames, comparing the cell region against the previous frame.
3. Take the `SystemRelativeTime` of the first frame in which it changed.

This measures what a user actually waits for, uses **the identical instrument on
both engines**, and needs no external tool or Java runtime. Its bias — DWM
composition latency is included — is common to both engines, which is what makes
the comparison fair even though the absolute number is not photon-to-pixel.

It is not free: the frame pool has to run continuously rather than
grab-one-and-exit as `wgc-shot` does today, and the pixel comparison needs to be
scoped to the cell the character lands in. Budget it as a real work item.

**Precondition, learned twice already:** it only works on a **connected**
session. A detached session stops DWM compositing and yields no frames at all.

---

## Q3 — Are the numeric targets still right?

Two of the three want changing, and one for a reason that matters.

### "Throughput ≥ cascadia" — keep it

It looked ambitious at 4.2 MB/s. At 37.4 vs 38.1 with the forced render out it
is **already met by the engine**, and the criterion is really a restatement of
"land the upstream wakeup fix". Keep it exactly as written; it is now a
meaningful pass/fail rather than an aspiration.

### "Latency ≤ cascadia median" — keep, but it has no baseline yet

Nothing has ever measured latency on either engine here. Q2's probe has to exist
and produce a cascadia number *before* this criterion can be said to be unmet,
let alone met. Sequence it first in the phase, not last.

### "Idle ghostty pane: 0 presents/sec with cursor blinking" — **unmeetable as written**

A visibly blinking cursor changes pixels, and changed pixels require a present.
Zero presents per second with a blinking cursor is not a demanding target, it is
a contradiction.

What cascadia does, which is presumably what was meant:

- The cursor blink timer flips a flag and **deliberately does not trigger a
  redraw** — `renderer.cpp:30-32`, in explicit contrast to the rendition blinker
  three lines below it, which does call `TriggerRedrawAll()`.
- The blink invalidates only the cursor's rectangle
  (`_invalidateCurrentCursor` → `InvalidateCursor(&rect)`, `renderer.cpp:1612-1634`).
- `_present()` builds a dirty rect and **returns without presenting at all** when
  it is empty (`AtlasEngine.r.cpp:451-470`), and otherwise presents through
  `Present1` with `DXGI_PRESENT_PARAMETERS` carrying that rect plus
  `scrollRect`/`scrollOffset`.

On our side it is currently much worse than "one present per blink", and the
measurement is worth having before the criterion is rewritten:

- `cursorTimerCallback` (`Thread.zig:663-697`) flips the flag and then calls
  **`wakeup.notify()`** (`:685-686`) — the general "something changed" wakeup,
  not a cursor-specific one. Interval is 600 ms (`CURSOR_BLINK_INTERVAL`, `:22`).
- That reaches `renderCallback` → `updateFrame` → `rebuildCells`, and
  `rebuildCells` sets `self.cells_rebuilt = true` **unconditionally**
  (`generic.zig:2593-2594`).
- `needs_redraw = size_changed or self.cells_rebuilt or hasAnimations or sync`
  (`generic.zig:1476-1484`), so the whole grid is rebuilt and the whole surface
  presented — about **1.67 full presents per second on a completely idle pane**,
  whether or not the cursor is even visible.

There *is* row-level dirty tracking already — `terminal.RenderState.dirty` is a
three-state `false | partial | full` (`terminal/render.zig:264-277`) with a
per-row `dirty` flag — but it gates **cell rebuild work only, never
presentation**. `rebuildCells` has no early return for `dirty == .false`.

That makes the cheapest win in the phase a small one: make `cells_rebuilt`
honest. It is a precondition for the idle criterion under any wording.

**Proposed restatement:** *an idle ghostty pane presents nothing when nothing has
changed, and a cursor blink presents only the cursor cell's dirty rectangle —
not the surface.* That is checkable, it is what cascadia does, and it is the
behaviour the criterion was reaching for.

This is a criterion change and therefore a **gate decision, not mine** (PROCESS
rule 3). It is written here rather than acted on.

---

## What this makes the work list

In order, because each one gates the next:

1. **Latency probe** (Q2), and a cascadia baseline from it. Without this the
   phase has one measurable criterion instead of two.
2. **Make `cells_rebuilt` honest** — feed the dirty state that already exists
   into it instead of setting it on every rebuild. Smallest change on this list
   and it alone takes an idle pane from ~1.67 full presents/sec toward zero.
3. **Damage-gated present**: `Present1` with `DXGI_PRESENT_PARAMETERS` and an
   empty-dirty-rect early return. Note `Present1` is not currently reachable —
   it is a `Reserved` vtable slot (`directx11/dxgi.zig:230, :298`) and needs
   binding first. Cascadia's implementation is a working reference in the same
   tree.
4. **Waitable swap chain** (Q1): swap-chain `Flags` is currently `0`
   (`directx11/device.zig:195`) and `GetFrameLatencyWaitableObject` /
   `SetMaximumFrameLatency` are `Reserved` slots (`dxgi.zig:308-310`), so this
   is three bindings plus the wait. Blocking wait, with a counter on the timeout
   path. `swap_chain_count` 2 → 3 at the same time.
5. **The upstream wakeup re-arm fix**, which removes the forced render and with
   it the last 26% of the throughput gap. Largest single win, and a correctness
   fix rather than an optimization — the freeze it works around is still a real
   bug, currently papered over by a throttle.

   > **Corrected 2026-08-07. The paragraph that stood here was wrong.** It said
   > the IOCP async loses a notify that arrives after the callback samples
   > state. Reading the whole path shows it does not:
   >
   > - the loop does `swap(false)` before the callback (`iocp.zig:291`), but
   > - a notify during the callback sets the flag back to true *and* posts a
   >   packet (`async.zig:601-611`, `iocp.zig:853-865`), and
   > - on `.rearm`, `start_completion` → `perform` → `.async_wait` pushes the
   >   completion back onto the list **without clearing the flag**
   >   (`iocp.zig:740-743`), and
   > - `wakeupCallback` returns `.rearm` unconditionally (`Thread.zig:588`).
   >
   > So the next drain swaps `true` and runs the callback again. The notify
   > survives. There is no lost wakeup to fix.
   >
   > Phase 5's own evidence — "80 notifies, 80 parser calls, <20 renderer
   > wakes" — is **coalescing working as designed**, not a defect. The symptom
   > that mattered was rendering stopping *entirely*, and coalescing does not
   > explain that.
   >
   > **So the cause of the Phase 5 freeze has never been established**, and
   > `ghostty_surface_render_now`, the `til::throttled_func` and this 26% are all
   > a workaround for something we have not diagnosed. The fork's comment at
   > `Surface.zig:916-937` states the same unsupported mechanism and needs the
   > same correction.
   >
   > Next step is a reproduction with instrumentation, not a change.
6. **Occlusion and scroll-as-rotation**, the remaining named items. Occlusion
   has a head start: `ghostty_surface_set_occlusion` already exists and gates
   `renderCallback` (`Thread.zig:648`), so an occluded pane already does no
   rebuild work — what is missing is `DXGI_PRESENT_TEST` and the DXGI-side
   occlusion status, which appear nowhere.
7. **RDP/WARP criterion**: nearly free to check and currently unverified for a
   *pane* — Phase 3 verified forced WARP in the harness only. Needs a run that
   says which driver a pane resolves to over RDP, and confirms no fallback
   dialog.

## Two things found on the way that are not work items yet

**There is no periodic draw in our configuration.** `syncDrawTimer`
(`Thread.zig:312-351`) only arms the 8 ms `draw_h` timer when
`renderer.hasAnimations()`, which is `has_custom_shaders`
(`generic.zig:1018-1020`). With no custom shaders the timer never runs and every
frame is wakeup-driven. Any reasoning about frame pacing that assumes a 120 Hz
tick is wrong here.

**`ghostty_surface_render_now` runs on the caller's thread**, not the renderer
thread (`Surface.renderNow`, `Surface.zig:928-937`) — a full `updateFrame` +
`drawFrame` inline. So Windows Terminal's throttle is currently doing a complete
rebuild-and-present on a `til::throttled_func` timer thread, concurrently with
the renderer thread doing its own. That is worth a second look when item 5
removes the forced render; it may also explain part of the remaining gap.

## One tooling gap worth fixing early

`scripts/bench-throughput.ps1` drives **`hwnd-host` only** (its `-Harness`
parameter is the sole target). Every pane number quoted above — 4.2, 28.0, 37.4,
38.1 — was taken by hand, outside it. A phase whose exit criterion is a
throughput comparison should not have its headline numbers produced by a
procedure that is not in the repo. Teach it to drive a WT pane on a named engine
before the next round of measurement, or the results are not reproducible by
anyone else.
