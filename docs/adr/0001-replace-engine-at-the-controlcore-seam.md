# 0001 — Replace the terminal engine at the ControlCore seam

Status: Accepted (2026-08-02, at the Phase 3→4 readiness step)

## Context

Windows Terminal has no extension point for alternate terminal engines
(microsoft/terminal #4000 is a years-open request). Its layering offers three candidate
cut points for swapping in libghostty:

1. **`IRenderEngine`** (`src/renderer/inc/IRenderEngine.hpp`) — the renderer interface
   AtlasEngine implements. It is a *cell-pull paint sink*: the WT `Renderer` reads WT's own
   `TextBuffer` via `IRenderData` (which returns `TextBuffer&` by reference) and pushes
   clusters into the engine. libghostty owns its own buffer and renderer as a unit, so it
   cannot sit behind this interface.
2. **`ControlCore`** (`src/cascadia/TerminalControl/ControlCore.{h,cpp,idl}`) — the façade
   that owns {parser + buffer + renderer + connection wiring}. Its IDL (~225 lines plus
   `ICoreState.idl`) is the complete contract the shell consumes, and the boundary was
   designed to be process-crossable (unshipped Process Model 2.0 spec, `doc/specs/#5000`).
   Everything above it (TermControl XAML, tabs, panes, profiles, settings) is
   engine-agnostic through this contract, except seven `get_self<ControlCore>` escapes —
   six of them IDL-promotable, plus one TSF coupling (see below).
3. **`IPaneContent`** (`src/cascadia/TerminalApp/IPaneContent.idl`) — the shell's pane
   abstraction (~10 members; `SnippetsPaneContent` is precedent). Cutting here loses every
   terminal-aware action in `AppActionHandlers.cpp` (copy/search/marks/scroll/font-size),
   which are typed against `TermControl`.

The rendering hand-off above `ControlCore` is a single DXGI composition swap-chain
`HANDLE` passed to XAML's `ISwapChainPanelNative2::SetSwapChainHandle` — the same
primitive wintty's ghostty fork already exports (`ghostty_surface_get_swap_chain_handle`).

## Decision

Promote `ControlCore.idl` + `ICoreState.idl` into an **`IControlCore`** WinRT interface.
`TermControl` and `ControlInteractivity` hold the interface; the `get_self` leaks are
replaced with IDL members.

**The escapes, enumerated (verified against pin `ca7996296`, 2026-08-02).** There are
*seven* `get_self<ControlCore>` call sites in `TermControl.cpp`, not six. Six are
straightforward IDL promotions:

| Line | Escape |
|---|---|
| 650 | `SearchResultRows` (+ `ForegroundColor`) for the search pips |
| 1468 | `RestoreFromPath` |
| 2640 | `PersistTo` |
| 3747 | `UpdateQuickFixes` |
| 3867 | `PreviewInput` |
| 4040 | `GetRenderData` — the QuickFix viewport query |

The seventh, `TsfDataProvider::_getCore()` at line 256, is **not** IDL-promotable: it exists
to reach `core->GetRenderer()` and hand out WT's internal `Renderer*`, for which a
libghostty-backed engine has no equivalent. It is the TSF/IME coupling already listed under
Consequences, and it is reimplemented per engine rather than promoted. Phase 4 keeps
cascadia's behaviour here unchanged; Phase 5+ supplies the ghostty path
(`ghostty_surface_preedit` + `_ime_point`, with ghostty rendering preedit inline).

**Shape (decided at the Phase 3→4 readiness step, 2026-08-02):** a *single*
`IControlCore` carrying both members and events, alongside the existing `ICoreState` —
`runtimeclass ControlCore : IControlCore, ICoreState`. `ICoreState` is already a WinRT
`interface` that `ControlCore` implements, so this follows a precedent the codebase has
established rather than inventing one. Splitting the 27 events onto a separate
`IControlCoreEvents` was rejected: it adds a second `QueryInterface` and complicates
`TermControl`'s event-revoker plumbing, which is written against a single object, for no
benefit to either engine. The existing cascadia `ControlCore` becomes implementation #1;
`GhosttyControlCore` (wrapping `libghostty.dll`) becomes implementation #2. Both towers
terminate in a composition swap-chain handle and consume the same `ITerminalConnection`.

## Implementation note (Phase 4, 2026-08-02)

Two of the six promotions could not be a straight copy of the existing signature, because
the escapes existed precisely *because* those signatures are not projectable:

- **`SearchResultRows`** returned `const std::vector<til::point_span>&`. Its only consumer
  draws one scrollbar pip per row, so it now returns `IVector<Int32>` of distinct rows and
  the consecutive-duplicate filtering moved from `TermControl` into the implementation.
- **The QuickFix viewport query** reached `GetRenderData()->GetViewport()` and read both
  bounds under one console lock. It is now a single `IsBufferRowInViewport(Int32)`
  predicate rather than separate accessors, to preserve that atomicity — two property
  reads would take two locks.

  **Correction (2026-08-03):** this note first claimed `ICoreState::ScrollOffset` +
  `ViewHeight` was *not* a valid substitute, because `Terminal::_VisibleStartIndex()`
  short-circuits to `0` in the alt buffer. That was reasoned from the source and never
  measured, and it is **wrong**. `Terminal::GetViewport()` returns the *visible* viewport,
  and `ScrollOffset` tracks its `Top()` in every case tested — main buffer at the bottom
  (21/21), main buffer scrolled back (5/5), and alt buffer (0/0). The derivation would
  have worked; atomicity is the real and sufficient justification.
  `ControlCoreTests::TestIsBufferRowInViewportAltBuffer` now pins the agreement, so a
  future divergence surfaces as a failing test rather than folklore.

`ControlCore` is now a marker class (`[default_interface]`, constructor only). MIDL requires
a default interface on any runtimeclass that is constructed or passed as a parameter, and
every member has moved to `IControlCore`.

**Deviation — `ControlInteractivity` still holds the concrete type.** This ADR says both
`TermControl` and `ControlInteractivity` hold the interface. `TermControl` does.
`ControlInteractivity` makes 58 calls across 34 distinct core methods, and most are
impl-level rather than part of the projected contract — `AttachUiaEngine`/`DetachUiaEngine`,
`SendMouseEvent`, `LeftClickOnTerminal`, `SetSelectionAnchor`/`SetEndSelectionPoint`,
`GetRenderData`, `GetFont`, `GetHyperlink`, `CopySelectionToClipboard`,
`IsVtMouseModeEnabled`, `ShouldSendAlternateScroll`, `UserScrollViewport`,
`AnchorContextMenu`, `AttachToNewControl`. Interface-typing it means promoting roughly
twenty more members — the mouse, selection and UIA surface — which is well beyond the
"mechanical MIDL promotion plus six call-site fixes" this ADR calls its only invasive
change. Phase 4's exit criteria do not require it; a second engine in Phase 5 does. Carried
as a Phase 5 prerequisite pending a decision at the retro.

## Consequences

- The only invasive change to existing WT code is mechanical MIDL promotion plus six
  call-site fixes; it is upstreamable to microsoft/terminal on its own merits (it is their
  own Process Model 2.0 boundary).
- The interface is large (~90 methods/properties + 23 events); a replacement engine must
  implement the "must" subset before anything renders (inventory in `DESIGN.md`).
- Cross-cutting couplings that bypass the seam must be reimplemented per engine: UIA text
  provider (over engine buffer read-back) and TSF/IME plumbing (ghostty renders its own
  preedit, dissolving WT's `IRenderData::tsfPreview` coupling).
- Engines are parallel towers sharing no mutable state; hot-swapping a live session is out
  of scope (see ADR 0007).
