# Architecture Decision Records

Nygard-style ADRs for the winterm-ghostty project. Each records a decision and the
alternatives rejected, with the reasoning that would otherwise be lost.

Process:

1. ADRs land as `Proposed`. Flipping to `Accepted` is the decision gate; implementation
   builds against accepted ADRs.
2. ADRs are immutable once accepted — supersede, never edit.
3. `DESIGN.md` describes current/target state; ADRs are history. Sequencing lives in
   `PLAN.md`, never in an ADR.

All ADRs below were drafted 2026-07-31 from the research in `docs/research/`. They capture
decisions explored during the initial feasibility investigation; review and flip to
`Accepted` before the phase that implements each.

## Index

- [0001](0001-replace-engine-at-the-controlcore-seam.md) — Replace the terminal engine at the ControlCore seam
- [0002](0002-d3d11-renderer-backend.md) — D3D11 as the ghostty GPU backend on Windows
- [0003](0003-full-engine-not-vt-hybrid.md) — Embed the full libghostty engine, not a libghostty-vt hybrid
- [0004](0004-ghostty-fork-as-patch-series.md) — Maintain the ghostty fork as an upstream-shaped patch series
- [0005](0005-directwrite-discovery-freetype-raster.md) — DirectWrite discovery/fallback with FreeType rasterization
- [0006](0006-wt-owns-conpty.md) — Windows Terminal keeps ConPTY; ghostty gets an external-stream termio backend
- [0007](0007-per-profile-engine-setting.md) — Per-profile `engine` setting; cascadia stays the default
