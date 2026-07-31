# 0007 — Per-profile `engine` setting; cascadia stays the default

Status: Proposed (2026-07-31)

## Context

No engine-selection setting exists in WT today — there has only ever been one engine. The
nearest knobs, `rendering.graphicsAPI` and `rendering.software`, are **global** settings
that select backends *inside* AtlasEngine.

With two `IControlCore` implementations (ADR 0001), something must choose per pane.
Engines are parallel towers sharing no state; an engine choice binds at pane creation.

## Decision

Add a per-profile setting:

```jsonc
"engine": "cascadia" | "ghostty"   // default: "cascadia"
```

flowing through the existing pipe (settings JSON → `TerminalSettingsModel` →
`IControlSettings` → the pane-creation factory in `TerminalApp`, which constructs the
matching `IControlCore`). Cascadia remains the default indefinitely; ghostty is opt-in
per profile.

## Alternatives rejected

- **Global setting** (`rendering.*`-style): kills the side-by-side comparison workflow — a
  "PowerShell (ghostty)" profile next to the stock one is both the primary dev/test loop
  and the user rollback story (one profile edit, not an app-wide flip).
- **Replace cascadia outright**: throws away the permanent safety net and turns every
  ghostty gap into a blocker instead of a known limitation.
- **`auto` heuristic** (pick engine by capability): premature; revisit only if ghostty
  reaches full parity and a default flip is on the table.

## Consequences

- Different engines can run in different panes of the same window (different swap chains,
  same `SwapChainPanel` mechanics, shared connection layer).
- **No hot-swap of a live session**: scrollback/parser/selection state lives inside the
  engine and cannot be transplanted with fidelity. Engine changes take effect on the next
  pane/tab, like existing renderer-adjacent settings.
- Settings that are engine-specific (ghostty config passthrough, cascadia-only shader
  options) need per-engine validation warnings in the settings UI eventually; not a
  blocker for early phases.
