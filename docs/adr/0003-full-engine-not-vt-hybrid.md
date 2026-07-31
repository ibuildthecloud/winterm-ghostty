# 0003 — Embed the full libghostty engine, not a libghostty-vt hybrid

Status: Proposed (2026-07-31)

## Context

Two integration levels exist:

- **libghostty-vt** — parser, terminal state, scrollback pages, selection, search, input
  encoding. Shipped, zero-dependency, explicitly Windows-supported, MSVC-CI-tested today,
  with `include/ghostty/vt/render.h` (an incremental render-state API purpose-built for a
  host-owned renderer). API explicitly alpha.
- **Full libghostty** (`ghostty_app_t`/`ghostty_surface_t`) — the above plus ghostty's own
  renderer, font pipeline, IO threads, and action system. Blocked on Windows only by the
  missing GPU backend, platform tag, and init fix (ADR 0002 and `DESIGN.md` §A).

The original feasibility study (docs/research/01) proposed a staged approach: Stage 1
embeds libghostty-vt behind WT's AtlasEngine (bridging vt render-state into AtlasEngine's
`IRenderEngine` paint-sink methods), Stage 2 swaps in the full engine. That staging was
premised on the D3D backend being 3–6+ months of from-scratch work. The subsequent
discovery of deblasis's D3D11 PR #11886 and wintty's production D3D12 backend invalidated
that premise: the GPU work substantially exists.

## Decision

Skip the vt+AtlasEngine hybrid. Build directly toward the full libghostty engine behind
`IControlCore` (ADR 0001), with the D3D11 backend of ADR 0002.

## Alternatives rejected

- **libghostty-vt + AtlasEngine bridge as a shipped stage**: requires building a second,
  throwaway integration (vt render-state → `IRenderEngine` cluster feed, plus
  selection/search/marks plumbed over vt APIs) whose interface work does not carry forward
  cleanly to the full engine (the full engine replaces exactly that layer). It also
  delivers none of ghostty's renderer-side features (inline preedit, kitty graphics
  rendering, custom shaders) and would still leave the a11y/IME work to be redone.
- **libghostty-vt with a from-scratch host renderer** (phantty's shape): all of the above
  plus owning a renderer forever that upstream will never maintain.

## Consequences

- The project's critical path runs through the ghostty fork's D3D11 backend before
  anything renders in WT; the WT-side seam work (ADR 0001) proceeds in parallel against
  the cascadia engine.
- **Fallback retained**: if the D3D11 backend stalls badly, the vt+AtlasEngine hybrid
  remains the documented plan B — the feasibility study (docs/research/01) records its
  design, and nothing in ADRs 0001/0006/0007 precludes it (a `GhosttyVtCore` would be a
  third `IControlCore` implementation).
- We accept full-libghostty's alpha C API churn on more surface area than vt alone would
  expose; ADR 0004's patch-series discipline is the mitigation.
