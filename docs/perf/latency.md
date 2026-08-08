# Latency: keystroke to pixel

Phase 7's criterion is "latency ≤ cascadia median". Until 2026-08-07 there was
no number for **either** engine, so the criterion could not be passed or failed.

Run with `harness/keylatency`.

## Method

```
t0   QueryPerformanceCounter, immediately before SendInput
t1   Direct3D11CaptureFrame::SystemRelativeTime of the first captured frame
     whose watch region differs from the baseline
```

Both are on the QPC timebase, so `t1 - t0` is a real interval.

- **The same instrument measures both engines.** Neither side is instrumented,
  which matters because the input path is exactly what differs between them.
  PresentMon would measure presentation cadence, not input response; an in-app
  timestamp cannot compare two different input paths fairly.
- **DWM composition is included.** That is a bias, and it is the *same* bias on
  both sides — which is what makes the comparison fair even though the absolute
  numbers are not photon-to-pixel.
- Each round types the same character, walking along the prompt line. An earlier
  version alternated with Backspace so the screen returned to its start; a
  Backspace at an already-empty prompt changes nothing, and those rounds were
  recorded as "no change detected" rather than as the no-ops they were. Half the
  data was being thrown away for tidiness.

## Results — 2026-08-07

Fresh pane per engine, 20 rounds each, same machine and session, cascadia
selected by a temporary per-profile `"engine": "cascadia"`.

| | min | **median** | max |
|---|---|---|---|
| ghostty pane | 39.5 | **51.0 ms** | 68.1 |
| cascadia pane | 23.9 | **41.4 ms** | 55.0 |

**The criterion is not met: 51.0 against 41.4, about 10 ms and roughly 24%
worse.** The gap at the best case is larger — 39.5 against 23.9.

## Where the gap plausibly lives

Not yet investigated, so this is a candidate rather than a finding — but a
pointed one. Ten milliseconds is a little over half a frame at 60 Hz, and the
one thing cascadia does for latency that we do not is the waitable swap chain:

- `AtlasEngine` creates its swap chain with
  `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`, calls
  `SetMaximumFrameLatency(1)`, and blocks on the frame-latency object before
  doing any work (`AtlasEngine.r.cpp:320, :374-381, :436-448`).
- We present with `SyncInterval = 1`, two buffers, no waitable object and no
  maximum-frame-latency setting (`directx11/device.zig:195`, `D3D11.zig:57-60`).

Queuing a frame the display is not ready for is exactly how a frame of latency
accumulates, and `SetMaximumFrameLatency(1)` exists to stop it. That makes the
waitable swap chain the next work item, and this file the way to tell whether it
helped.

## Caveats

- **Measures "time to first visible response", not "time to glyph."** A
  keystroke also resets the cursor blink, so the first changed pixels may be the
  cursor. That is still a response to the keystroke.
- One machine, one session, 20 rounds. The medians are 10 ms apart and the
  distributions overlap; treat this as "there is a gap of about this size", not
  as a precise figure.
- Requires a **connected** session — a detached one yields no frames at all.
