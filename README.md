# winterm-ghostty

Windows Terminal's shell — tabs, panes, profiles, settings — powered by ghostty's terminal
engine (`libghostty.dll` with a new D3D11 backend), selectable per profile alongside the
stock cascadia engine.

## Start here

1. **`PROCESS.md`** — how work happens: the readiness → unattended-execute → deliver →
   evaluate → retro loop, the rules for executing agents, and the session-report format.
   Read this first in every session.
2. **`DESIGN.md`** — target architecture (the two-tower model, fork contents, obligation
   maps, harvest table).
3. **`docs/adr/`** — the seven decisions and every alternative rejected, with reasoning.
   ADRs are `Proposed`; the readiness step flips them to `Accepted` before implementation.
4. **`PLAN.md`** — staged plan. One phase ≈ one agent session, each with demonstrable exit
   criteria and a status ledger. Session reports land in `docs/sessions/`.
5. **`docs/research/`** — the July 2026 research this all derives from: feasibility study
   of both codebases (01), the synthesis design with per-source rationale (02).

## Working model

This repo is docs + build glue; the code lives in two forks created by the plan:

- `ghostty/` — fork of ghostty-org/ghostty, maintained as an ordered patch series
  (ADR 0004). Created in Phase 1.
- `terminal/` — fork of microsoft/terminal carrying the `IControlCore` seam (ADR 0001).
  Created in Phase 4.
- `harness/` — minimal Win32/WinUI hosts for exercising `libghostty.dll` without WT.
- `scripts/` — build wrappers and patch-queue tooling.

Session protocol is defined in `PROCESS.md`. Requires a native Windows environment
(Zig + VS2022 + Windows SDK) — see Phase 0.

## Key external references

- ghostty upstream: https://github.com/ghostty-org/ghostty (research pin `4d605bf`)
- Windows Terminal: https://github.com/microsoft/terminal
- deblasis D3D11 PR (the renderer base): https://github.com/ghostty-org/ghostty/pull/11886
- wintty (D3D12 + WinUI reference): https://github.com/deblasis/wintty
- winghostty (WGL port; libxev fix, UIA): https://github.com/amanthanvi/winghostty
- phantty (vt + DirectWrite reference): https://github.com/arya-s/phantty
- Upstream Windows requirements: https://github.com/ghostty-org/ghostty/discussions/2563
