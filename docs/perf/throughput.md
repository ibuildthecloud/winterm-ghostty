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

8 MB corpus (8,389,452 bytes), best of 2-3 runs.

| Terminal | Best | Throughput | Relative |
|---|---|---|---|
| Windows Terminal | 216 ms | **37.0 MB/s** | 2.4x faster |
| **this backend (D3D11 + DirectWrite)** | 522 ms | **15.3 MB/s** | baseline |
| conhost | 2947 ms | 2.7 MB/s | 5.6x slower |

**We are roughly 2.4x slower than Windows Terminal.** That is the number worth
carrying, and it is consistent with the "input is a little laggy" observation
from the interactive sessions.

Faster than conhost by a wide margin, but conhost is not the bar — Windows
Terminal is what this work would have to replace.

## Caveats, which are load-bearing here

- **The session was detached** (RDP disconnected), so DWM was not compositing.
  That affects presentation for all three terminals, but not necessarily
  equally, and a terminal that throttles when nothing is visible would look
  artificially good. **Re-run connected before treating the ratio as settled.**
- Our build was `ReleaseFast`. Worth stating because
  `scripts/build-ghostty.ps1` defaults to `Debug`, and a Debug number is
  meaningless — full safety checks on every index and integer op.
- One machine, one corpus, one size. No claim about scaling.
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
