# Kitty graphics: how fast can a client push frames?

Asked because of a concrete goal — rendering an RDP client's framebuffer into a
pane — where the transmission medium is not a detail but the whole problem.

Run with `kittybench.ps1` (session scratchpad; runs *inside* the pane).

## Method, and the first version of it that was wrong

Send N frames of raw RGBA (`f=32`), reusing one image and placement
(`i=1,p=1`), replies suppressed (`q=2`), cursor held still (`C=1`) so the screen
does not scroll.

**Timing the send loop measures the writer, not the terminal.** With `t=f` the
pty carries only ~100 bytes per frame, so nothing ever backpressures and the
loop returns long before a single frame is decoded. Measured that way once, it
claimed *"104 fps"* — of which 78% was the local file write and none of which
was the terminal.

The fix: after the frames, send a query the terminal must answer (`CSI 16 t`)
and time until the reply arrives. The pty is processed in order, so the reply
cannot come back until every frame before it has been consumed.

**And check the screen.** A terminal that rejects every transmission is
extremely fast. The pane was photographed at the end of the run and is filled
with the transmitted image.

## Results — 2026-08-07, 1920x1080 RGBA (8.3 MB/frame), 20 frames

| medium | end-to-end | terminal alone | notes |
|---|---|---|---|
| **`t=f` (file)** | **58.4 fps**, 462 MB/s | **~145 fps** | 342.6 ms total, of which **204.8 ms was the client's file write** |
| `t=d` (direct) | **~2.5 fps** | — | derived: 8.3 MB inflates to ~11 MB of base64 through a 28.6 MB/s pty |

`t=d` was not measured directly here. PowerShell base64-encoding 8.3 MB and
chunking it into ~2,700 escape-sequence pieces per frame is itself far slower
than the terminal, so the run measured the client and timed out. The ~2.5 fps
figure comes from the measured pty throughput instead, which is sound because
direct transmission is pty-bound by construction.

## What this settles

- **`t=f` is already fast enough for video-rate 1080p**, and needs no changes:
  `Termio.zig:265` sets `.allWithTempDir(global.tmpDirPath())`, so the file and
  temporary-file mediums are enabled today.
- **The terminal is not the bottleneck — the client's file write is**, at 60% of
  the wall time. That inverts the intuition that the terminal is the slow part.
- **It bounds what Windows shared memory would be worth.** shm's advantage over
  `t=f` is removing the filesystem round-trip, so the ceiling it could reach is
  roughly the ~145 fps the terminal already sustains: call it a 2.5x gain over
  `t=f`, not the 20x gain it is over `t=d`. Worth having for a demanding client;
  not the difference between possible and impossible.
- **Animation frames are irrelevant to this use case.** Kitty's animation
  support is for pre-loading frames and letting the terminal cycle them on a
  timer. A live stream pushes a frame when one arrives — ordinary transmit and
  display, which works now.

## Caveats

- One machine, one size, 20 frames, hardware rasterizer.
- Frames are a flat colour. Real frames are not more expensive to *transmit*,
  but PNG (`f=100`) would add decode cost that this does not measure.
- The terminal may coalesce *rendering* of frames it has already ingested. That
  is correct behaviour, and ingest is what was measured.
- Path constraints matter and are easy to trip over: the terminal is a Windows
  process and opens the path with Windows APIs, so a WSL client must write
  somewhere both sides can see and send the **Windows** form of the path. `t=t`
  additionally requires the file to live under the terminal's temp directory and
  to have `tty-graphics-protocol` in its name.
