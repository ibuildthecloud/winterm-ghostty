# winterm-ghostty — Agent Instructions

Windows Terminal's shell powered by ghostty's engine (`libghostty.dll` + a new D3D11
backend), selectable per profile beside the stock cascadia engine. This repo holds the
docs, the test harnesses, and build scripts; the `ghostty/` and `terminal/` forks are
separate clones created by the plan (gitignored here).

## Read order, every session

1. `PROCESS.md` — **the session contract.** The phase loop, the rules for unattended
   execution, escalation triggers, and the session-report format. Non-negotiable.
2. `PLAN.md` — find the current phase in the status ledger; your session is that phase
   and nothing more.
3. `DESIGN.md` — target architecture; the design envelope you implement within.
4. `docs/adr/` — decisions and rejected alternatives. Implementation may only build
   against ADRs marked `Accepted`. Never contradict an accepted ADR without stopping and
   reporting (see PROCESS.md rule 3).
5. `docs/sessions/` — prior session reports, most recent first, for context on where the
   last session actually left things (trust reports over assumptions).

`docs/research/` is background from the July 2026 investigation — useful for "why", never
authoritative over DESIGN.md/ADRs.

## Hard rules (summary — PROCESS.md is authoritative)

- Scope is the current phase. Do not start the next phase. Finish early → harden, don't
  advance.
- Exit criteria are a contract: each ends checked, or reported unmet with the reason.
- Decide small (naming, layout, test structure — note it), escalate big (ADR conflicts,
  public API shapes, new dependencies, invalidated DESIGN assumptions — stop that item,
  write a DECISION-NEEDED entry, continue with independent work).
- End every session with a report in `docs/sessions/NNNN-phase-<n>.md` and an updated
  status-ledger row in `PLAN.md`. Commit this repo at session end minimum. Never
  force-push anywhere.
- In `ghostty/`: every change belongs to a named patch on the `windows` branch (one
  commit per patch topic, ADR 0004 order); each patch must build and pass
  `zig build test` independently.
- Report honestly: failing tests and unmet criteria go in the report as-is.

## Environment

- Native Windows (not WSL): Zig (version pinned by `ghostty/build.zig.zon`), Visual
  Studio 2022 + Windows SDK, `dxc`. Phase 0 sets this up and records exact versions.
- Builds go through `scripts/` wrappers once they exist; prefer extending a script over
  documenting an ad hoc command.
- Upstream pins for both forks are recorded in `DESIGN.md`; never advance a pin outside a
  readiness/retro step.
