# Throughput: cat a large file

Measures how fast the terminal drains its pty. The child times itself around a
`cat` of a fixed corpus; when the terminal cannot keep up the write blocks, so
the child's wall time is a measure of the terminal rather than of the shell.

Run with `scripts/bench-throughput.ps1`.

## Method

- Corpus is generated once and is **deterministic**, so runs are comparable
  across builds and terminals. It mixes plain ASCII, SGR colour changes,
  reverse video and CJK: a corpus of plain ASCII measures the fast path and
  little else.
- All three terminals run the **same corpus** through the **same**
  `wsl.exe -> ConPTY` path on the same machine, so the transport is common and
  what differs is the terminal.
- The probe writes its own elapsed milliseconds to a file, so nothing depends on
  the host being able to see the window.

## Results — 2026-08-02

8 MB corpus (8,389,452 bytes), best of 3 runs, **RDP session connected**.

| Terminal | Best | Throughput | Relative |
|---|---|---|---|
| Windows Terminal | 187 ms | **42.8 MB/s** | 2.9x faster |
| **this backend (D3D11 + DirectWrite)** | 538 ms | **14.9 MB/s** | baseline |
| conhost | 3026 ms | 2.6 MB/s | 5.7x slower |

**We are roughly 2.9x slower than Windows Terminal.** That is the number worth
carrying, and it is consistent with the "input is a little laggy" observation
from the interactive sessions.

> **Superseded 2026-08-06.** This measures `hwnd-host`, not a Windows Terminal pane, and
> the pane is what a user has. See the 2026-08-06 section below: libghostty in a pane
> reaches parity with cascadia once a forced per-chunk render is removed, so this 2.9x is
> a property of the harness rather than of the engine. Left in place because the method
> and the detached/connected finding still stand.

Faster than conhost by a wide margin, but conhost is not the bar — Windows
Terminal is what this work would have to replace.

### The detached measurement understated the gap

The first run of this benchmark was taken on a **detached** RDP session, where
DWM stops compositing. Re-measuring connected changed the answer:

| Terminal | Detached | Connected |
|---|---|---|
| Windows Terminal | 37.0 MB/s | **42.8 MB/s** |
| this backend | 15.3 MB/s | 14.9 MB/s |
| conhost | 2.7 MB/s | 2.6 MB/s |

Windows Terminal got materially faster when the session was live; we did not.
So the detached figures flattered us, and the gap is 2.9x rather than 2.4x.
Worth recording because the intuition would have been the opposite — that a
terminal doing real presentation work would look *worse* once it had to
present.

## Results — 2026-08-06: the harness was measuring the wrong thing

The numbers above are the **harness**, and the harness is not a Windows Terminal pane.
Re-measured with everything in Release/`ReleaseFast`, on a connected session, with nothing
else compositing:

| What | Throughput |
|---|---|
| stock Windows Terminal (cascadia) | **38.1 MB/s** |
| libghostty in `hwnd-host` | 15.2 MB/s |
| libghostty in a WT pane, as shipped that morning | **4.2 MB/s** |
| libghostty in a WT pane, forced render removed entirely | **37.4 MB/s** |

**The engine was never the problem.** With the forced render taken out, a ghostty pane
drains at 37.4 against cascadia's 38.1 — parity. The 2.9x above measured `hwnd-host`'s own
render pumping, and planning against it would have sent Phase 7 hunting in the renderer.

### Where it went

`GhosttyControlCore::_connectionOutputHandler` forced a synchronous `render_now` on *every*
chunk of pty output, on the connection's output thread — the thread whose blocking is the
backpressure to the child. Every chunk paid for a full rebuild-and-present before the next
could be read. That call is not gratuitous: it is the Phase 5 fix for the pane freezing
mid-output, because libghostty's wakeup coalesces and can drop the final batch.

Throttling it (`til::throttled_func`, 8 ms) recovers most of the loss, and *how* it is
throttled matters more than the interval:

| | Throughput |
|---|---|
| render per chunk | 4.2 MB/s |
| throttled, `leading + trailing` | 12.6 MB/s |
| throttled, **`trailing` only** | **28.0 MB/s** median, 34.0 best |

A leading invocation runs **inline on the calling thread**, so it goes on blocking the
backpressure path once per interval and recovers only a third of the gap. Trailing alone
puts every render on the timer thread. The trailing edge is also exactly the final render
the freeze fix needs, so the guarantee is kept rather than traded away.

> ## RETRACTED 2026-08-07: the 37.4 figure measured a terminal that was not drawing
>
> "Forced render removed entirely = 37.4 MB/s = parity with cascadia" is **wrong**,
> and the conclusion built on it — that the engine is already fast enough and only
> the workaround costs us — is wrong with it.
>
> On Windows, pty output had **never** woken the renderer. `Termio`, `Options` and
> `StreamHandler` held `renderer_wakeup: xev.Async` by value, and libxev's IOCP
> async keeps its state in the struct, so a copy's `notify()` set a bool nobody
> read and returned success. Removing the forced render therefore did not "let the
> engine run" — it removed *all* rendering during the flood except the cursor
> blink. 37.4 MB/s was the cost of parsing 8 MB and drawing it about twice a
> second.
>
> Measured with stage counters during `dir /s`, throttle bypassed:
>
> ```
> before the fix   notify=41 wakeup=79  update=79  present=81    <- +2/sec, the blink
> after the fix    notify=41 wakeup=404 update=404 present=406   <- +321 in one second
> ```
>
> **Corrected numbers**, same 8 MB corpus, same probe, same session:
>
> | | MB/s |
> |---|---|
> | ghostty pane, wakeup fixed, forced render **deleted** (shipped) | 30.9, 30.9, 30.9 — **median 30.9** |
> | cascadia pane, same session | 30.3, 37.7, 39.0, 32.3 — **median ~35** |
>
> ghostty's three runs are identical to a tenth; cascadia's spread 30.3–39.0 on
> the same machine in the same session. **The cascadia figure is the shakier of
> the two** and wants re-measuring on a quiet machine before any gap is quoted
> precisely. On what is here, the gap is somewhere around 10–15%, not the 25% a
> first reading of these numbers suggests and not the zero the retracted 37.4
> claimed.
>
> So the gap is **real renderer cost of roughly 25%**, not an artifact of a
> workaround. That is a harder problem than the retracted number implied, and it
> is the problem Phase 7 is actually for.
>
> The engine-identity check in the harness is worth distrusting too: with
> `profiles.defaults.engine = ghostty`, `ghostty-internal.dll` is loaded in the
> process even for a cascadia pane. The reliable per-pane check is the search
> box's regex/case toggles, which a ghostty pane greys out.

### What is left

~25%, and it is the cost of forcing renders at all. The proper fix is upstream: a wakeup
that re-arms when a notify arrives mid-wake would make the forced render unnecessary and
should reach ~37 MB/s. That is Phase 7 design work.

### Method notes learned the hard way

- **Other GPU load moves the number by 20%.** A single Windows Terminal window open
  elsewhere took the harness from 15.2 to 12.3 MB/s. The script guards against a detached
  session but not against this; close everything before measuring.
- **Check which engine a profile actually resolves to.** `profiles.defaults.engine` is
  inherited, so a profile with no explicit `engine` may not be the one you think. A
  "cascadia vs ghostty" comparison that returned identical numbers turned out to be
  ghostty measured twice.
- **Cold windows are fine.** Launching a fresh window per run costs nothing measurable —
  cascadia returned 210, 214, 210 ms. Startup is not in these numbers.
- **First runs lie.** One trailing-only run came back 3235 ms against a 235-390 ms spread
  over six. Take a median over several, and re-run before believing an outlier.

## Caveats

- Our build was `ReleaseFast`. Worth stating because
  `scripts/build-ghostty.ps1` defaults to `Debug`, and a Debug number is
  meaningless — full safety checks on every index and integer op.
- One machine, one corpus, one size. No claim about scaling.
- Measured over RDP, which is not a local display. The ratio between terminals
  is the useful part, not the absolute numbers.
- **wintty was not measured.** The Phase 3 plan asks for a comparison against
  it as well; it is not built in this tree.

## Where the gap plausibly lives

Not yet investigated, so these are candidates rather than findings:

- `Present(sync_interval = 1)` with no frame-latency wait object.
  `Frame.complete` takes a `sync` argument and discards it; the waitable swap
  chain is deferred to Phase 7 by `Frame.zig`'s own note.
- The harness redraws on `WM_PAINT` and otherwise relies on the renderer
  thread's cadence, so a burst of output may be presented more often than it
  needs to be.
- No damage tracking: every frame redraws the whole grid.

Phase 7 is "Presentation & performance" in the plan, so a gap here is expected
at this stage rather than alarming. It is recorded now so the phase starts with
a measurement instead of an impression.
