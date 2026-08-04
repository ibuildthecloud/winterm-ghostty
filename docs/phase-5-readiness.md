# Phase 5 readiness — findings and recommendations

Prepared 2026-08-03 at the Phase 4→5 readiness step, against `ghostty/` @ `6b025ce5d` and
`terminal/` @ `ca7996296`. Answers PLAN's "Open questions (resolve at readiness)" for
Phase 5. **Recommendations only — the readiness step is interactive, and nothing here is
settled until the human agrees.**

## Q1 — ADR 0006 accepted?

**Yes**, flipped 2026-08-03 at the user's direction.

## Q2 — `termio-external` backpressure semantics

PLAN calls this "the phase's core design question, decide before coding" and "the highest-
risk new design in the project". It turns out ghostty has already answered it for its own
backend, and the answer is **block the producer**.

### What the exec backend actually does

`src/termio/Exec.zig` runs two stages over a fixed ring of `buffer_count` buffers:

- **gather** (owns the pty fd) fills a free buffer and publishes it,
- **parse** takes each batch, calls `processOutput`, then releases the slot.

The producer blocks when the ring is full, and the code says why in as many words
(`Exec.zig:1540`):

```zig
// Claim the next free buffer. This blocks only when the
// parse stage is a full ring behind, which is exactly when
// we should stop reading and let the kernel queue exert
// backpressure on the child.
while (pipeline.count == buffer_count) {
    pipeline.slot_free.waitUncancelable(global.io(), &pipeline.mutex);
}
```

So ghostty's backpressure story is: *stop reading, let the OS pipe fill, let the child
block on write*. There is no credit scheme and no partial-consume protocol anywhere in it.

Separately, at each batch boundary the parse stage calls
`io.renderer_state.yieldToDemand()`, which futex-waits briefly **iff** the renderer is
waiting on the state mutex. That is a fairness hand-off between parse and render, *not*
flow control, and it is orthogonal to the question here.

### The three candidate designs

| | Design | Verdict |
|---|---|---|
| **A** | `ghostty_surface_write_pty_output` blocks while the ring is full | **DECIDED 2026-08-03** |
| B | Partial consume, returns bytes accepted; embedder buffers the rest | Rejected |
| C | Credit / callback flow control | Rejected for MVP |

**A** makes the embedder's calling thread play exactly the role the gather stage plays. It
reuses the pipeline that already exists and is already tested by every ghostty session, and
it keeps the new backend a thin variant rather than a second concurrency design. It is also
the smallest, most upstreamable patch — which ADR 0006 explicitly cares about.

**B** pushes an unbounded buffer into `GhosttyControlCore`: whatever the engine will not
take has to live somewhere on the C++ side, and under `yes`-style flood that grows without
limit unless we *also* invent a stop-reading rule — i.e. we end up implementing A anyway,
one layer up and with an extra copy.

**C** is the right answer only if blocking the caller is unacceptable. It is not — see
below — so it buys complexity for nothing at MVP. Revisit only if measurement shows a
problem.

### Why blocking is safe here (verified, not assumed)

PLAN's stated hazard is "WT's connection read thread must not deadlock against the render
lock." Two facts settle it:

1. **`TerminalOutput` is raised on a dedicated thread, not the UI thread.**
   `ConptyConnection::_OutputThread` is created with `CreateThread`
   (`ConptyConnection.cpp:458`) and raises the event from there
   (`:797`). Blocking it stalls that thread only.
2. **WT already expects the handler to be slow.** From `ConptyConnection.cpp:756`:
   *"we want to queue ReadFile() calls before processing the string, because
   TerminalOutput.raise() may take a while (relatively speaking)"*. Slow consumers are a
   designed-for case, not a violation.

Blocking that thread propagates backpressure the correct way: the ConPTY pipe fills, and
the child throttles — the same end state the exec backend produces.

**The contract this imposes on `GhosttyControlCore`**, and the thing to get right:

> The `TerminalOutput` handler must hold **no** WT-side lock and must not wait on the WT
> dispatcher while calling `ghostty_surface_write_pty_output`.

Deadlock is only reachable if the blocked thread holds something ghostty's parse or render
thread needs. If the handler does nothing but convert bytes and call in, there is no such
edge. This belongs in a comment at the call site, because it is invisible at the point
where someone would later be tempted to take a lock "just for a moment".

### Open risk to measure in-phase

PLAN's own re-evaluation question — *backpressure under a `yes`/`cat` flood* — stays. The
thing to watch is not throughput but **UI responsiveness while the ring is saturated**: the
parse stage holds `renderer_state.mutex` across `processOutput` and only yields at batch
boundaries. `scripts/bench-throughput.ps1` already produces the flood; reuse it.

## Q3 — UTF-16 → UTF-8 at the boundary

PLAN asks who buffers a surrogate pair split across `TerminalOutput` events, and says
"must be the C++ side; specify the small state machine."

**The state machine already exists in WT and should simply be used.**
`src/inc/til/u8u16convert.h` ships `til::u16state` — *"state structure for maintenance of
UTF-16 partials"*, a two-`wchar_t` buffer — and a stateful overload
`til::u16u8(std::wstring_view in, outT& out, u16state& state)`. Hold one `u16state` per
`GhosttyControlCore` and feed every `TerminalOutput` payload through it. No new code, and
it is the same helper the rest of WT uses.

Worth recording for the retro: with `ConptyConnection` specifically, a split pair should
never actually arrive. That connection converts UTF-8 → UTF-16 through `til::u8state`,
which buffers *incomplete UTF-8 sequences*, so each raise carries only whole codepoints —
and a non-BMP codepoint's two surrogates are produced together. But `ITerminalConnection`
has three implementations (`Conpty`, `Azure`, `Echo`) and is a public interface; `Azure`
emits from a websocket with no such guarantee. Use the state machine regardless — it costs
nothing and does not depend on which connection is attached.

## Q4 — Threading contract for `GhosttyControlCore`

Draft, to be confirmed against the C API during implementation rather than trusted from
here. `ControlCore.idl`'s own background/UI-thread event split is the template.

| Direction | Arrives on | Must be marshalled? |
|---|---|---|
| `TerminalOutput` → `write_pty_output` | WT connection output thread | No — call straight in, no locks held |
| ghostty write callback → `Connection.WriteInput` | ghostty io thread | No — `WriteInput` is thread-safe on `ConptyConnection` (verify for `Azure`) |
| ghostty actions (`SET_TITLE`, `COLOR_CHANGE`, `PWD`, `PROGRESS_REPORT`, bell) | ghostty io/parse thread | **Yes** — these become WinRT events WT expects on the UI thread |
| `swap_chain_changed` | renderer thread | **Yes** — `SwapChainChanged` is a UI-thread event in `ControlCore.idl` |
| Key/char/mouse input → `ghostty_surface_*` | WT UI thread | No |
| Resize (cell metrics → `Connection.Resize`) | WT UI thread | No |

The rows marked **Yes** are the ones that will crash or corrupt XAML if got wrong, and they
are exactly the ones `ControlCore.idl` already annotates as "always called from the UI
thread (bugs aside)".

## Q5 — Settings translator scope for the MVP

PLAN proposes font, size, scheme, scrollback, padding. **Recommend confirming exactly
that**, and explicitly *excluding* for this phase: opacity/acrylic, background image,
cursor shape/colour, selection colours, bell style, `useAtlasEngine`-adjacent rendering
toggles, and every `experimental.*` field.

Rationale: the MVP criterion is "a fully interactive shell in a WT tab", and the five
proposed fields are the ones without which a pane is visibly wrong rather than merely
unstyled. Everything else is parity work, which is what Phase 6 is for.

## The `ControlInteractivity` promotion — inventory

Measured 2026-08-03 against `ControlInteractivity.cpp`. Of the 34 distinct core methods it
calls, **14 are already on `IControlCore`/`ICoreState`** and 20 are not. Of those 20:

**17 promote cleanly** — either already-projectable signatures, or `til::point` parameters
that become the already-projected `Core::Point`:

> `AnchorContextMenu`, `AttachToNewControl`, `Close`, `CopyOnSelect`,
> `CopySelectionToClipboard`, `Detach`, `GetHyperlink`, `GotFocus`, `IsVtMouseModeEnabled`,
> `LeftClickOnTerminal`, `LostFocus`, `SendMouseEvent`, `SetEndSelectionPoint`,
> `SetSelectionAnchor`, `ShouldSendAlternateScroll`, `UserScrollViewport`, plus the
> `GetFont` replacement below.

**1 does not need promoting at all.** `GetFont()` is called in exactly one place
(`_getTerminalPosition`, line 756) and only for `.GetSize()`, to convert pixels to cells.
`IControlCore::FontSize` already returns precisely that as a `Windows.Foundation.Size`.
Swap the call; do not widen the interface.

**2 are genuinely not projectable, and they are both UIA:**

| Member | Why |
|---|---|
| `AttachUiaEngine` / `DetachUiaEngine` | take `Microsoft::Console::Render::UiaEngine*` — a raw pointer to WT's own render engine |
| `GetRenderData` | returns `IRenderData*`; `ControlInteractivity::GetRenderData()` is a pass-through that hands WT internals to its own callers (the automation peer) |

These are one cluster, not three problems: **accessibility**. `DESIGN.md` already scopes it
that way — *"UIA text provider (over engine buffer read-back)"* is listed among the
cross-cutting couplings that "must be reimplemented per engine". So they get the same
treatment as Phase 4's seventh escape (`TsfDataProvider::_getCore`): left on the concrete
type, reimplemented per engine later, **not** forced through the interface.

That makes the promotion tractable: 17 mechanical promotions, 1 deletion, and an
accessibility cluster deferred to Phase 8 (Accessibility & packaging), which is where it
belongs anyway.

**Consequence for the MVP:** a ghostty pane will be able to take mouse and selection input
— which is what Phase 5 needs — while its Narrator/UIA story stays cascadia-only until
Phase 8. Worth stating in the Phase 5 exit criteria rather than discovering later.

## Prerequisite carried from Phase 4

**`ControlInteractivity` must be interface-typed before a second engine can work.** It
holds the concrete `ControlCore` and makes 58 calls across 34 methods, most of them
impl-level input handling (`SendMouseEvent`, `LeftClickOnTerminal`, `SetSelectionAnchor`,
`AttachUiaEngine`). It is the object that actually drives input, so a ghostty pane cannot
receive a mouse event until this is done. See `docs/sessions/0005-phase-4.md` §5.1.

Sequence it first in Phase 5, ahead of `termio-external`.
