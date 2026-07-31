# 0001 — Replace the terminal engine at the ControlCore seam

Status: Proposed (2026-07-31)

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
   engine-agnostic through this contract, except six `get_self<ControlCore>` escapes.
3. **`IPaneContent`** (`src/cascadia/TerminalApp/IPaneContent.idl`) — the shell's pane
   abstraction (~10 members; `SnippetsPaneContent` is precedent). Cutting here loses every
   terminal-aware action in `AppActionHandlers.cpp` (copy/search/marks/scroll/font-size),
   which are typed against `TermControl`.

The rendering hand-off above `ControlCore` is a single DXGI composition swap-chain
`HANDLE` passed to XAML's `ISwapChainPanelNative2::SetSwapChainHandle` — the same
primitive wintty's ghostty fork already exports (`ghostty_surface_get_swap_chain_handle`).

## Decision

Promote `ControlCore.idl` + `ICoreState.idl` into an **`IControlCore`** WinRT interface.
`TermControl` and `ControlInteractivity` hold the interface; the six `get_self` leaks are
replaced with IDL members. The existing cascadia `ControlCore` becomes implementation #1;
`GhosttyControlCore` (wrapping `libghostty.dll`) becomes implementation #2. Both towers
terminate in a composition swap-chain handle and consume the same `ITerminalConnection`.

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
