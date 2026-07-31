# PROCESS — How phases are executed

This project runs as a series of largely-unattended agent sessions, one per phase of
`PLAN.md`, with a human gate between phases. This file is the contract for those sessions.
Read it at the start of every session.

## The loop

```
┌─▶ 1. READINESS  (human + agent, interactive)
│      Confirm the next phase is specified well enough to run unattended.
│      Fill gaps in PLAN.md; flip any ADRs the phase builds against to Accepted.
│
│   2. EXECUTE    (agent, unattended)
│      Do the phase. Stay inside its scope. Hit the exit criteria.
│
│   3. DELIVER    (agent)
│      Demonstrable deliverable + session report. Stop. Do NOT start the next phase.
│
│   4. EVALUATE   (human)
│      Run/inspect the deliverable against the exit criteria.
│
└── 5. RETRO      (human + agent, interactive)
       Fold learnings back into DESIGN.md / ADRs / PLAN.md. Then loop to 1.
```

## Rules for the executing agent (step 2)

1. **Scope is the phase.** Do not begin the next phase, even if trivial. If you finish
   early, spend the time hardening exit criteria (tests, docs), not advancing.
2. **Exit criteria are the contract.** Every checkbox in the phase must end as either
   checked, or explicitly reported as unmet with the reason. Never silently reinterpret a
   criterion.
3. **Decide small, escalate big.** Implementation choices inside the phase's design
   envelope (naming, file layout, test structure) — decide and note them. Anything that
   contradicts an Accepted ADR, changes a public API shape, adds a dependency, or
   invalidates an assumption in DESIGN.md — **stop work on that item**, record it in the
   session report as a BLOCKED/DECISION-NEEDED entry, and continue with independent items.
   If nothing independent remains, end the session early with the report.
4. **Record deviations as you go.** Anything done differently from PLAN/DESIGN gets a
   line in the session report with the reason, at the moment it happens.
5. **Keep the patch discipline** (ADR 0004): in `ghostty/`, every change belongs to a
   named patch; each patch must build and pass `zig build test` on its own.
6. **Commit hygiene:** commit at meaningful checkpoints in each repo (this repo, and the
   forks once they exist). Never force-push. The docs repo gets a commit at session end at
   minimum.
7. **Report honestly.** Failing tests, skipped criteria, and flaky behavior go in the
   report as-is. An unmet criterion reported clearly is a good outcome; a masked one is
   the failure mode this process exists to prevent.

## The session report (step 3)

Written to `docs/sessions/NNNN-phase-<n>.md` (increment NNNN). Contents, in order:

1. **Outcome** — one paragraph: what works now that didn't before.
2. **Exit criteria** — the phase's checklist, each checked or annotated why not.
3. **How to verify** — exact commands/steps for the human evaluation (step 4).
4. **Deviations** — what was done differently from PLAN/DESIGN and why.
5. **Decisions needed** — the BLOCKED items, each with enough context to decide quickly,
   and a recommendation.
6. **Learnings for the plan** — anything that should change later phases, ADRs, or
   DESIGN.md (proposals only — the retro decides).
7. **Next-phase readiness gaps** — what the next phase's spec is missing, from the
   vantage point of having just done this one.

Also update the status ledger row in `PLAN.md` (status + one-line note).

## The retro (step 5) — checklist

- [ ] Learnings folded into `DESIGN.md` (current state only) and/or new/superseding ADRs.
- [ ] `PLAN.md` later phases amended if assumptions changed; exit criteria adjusted.
- [ ] Decisions-needed resolved; outcomes recorded (ADR if a real alternative was
      rejected, DESIGN.md otherwise).
- [ ] Next phase passes the readiness bar (below); its ADRs flipped to Accepted.

## The readiness bar (step 1)

A phase is ready for unattended execution when:

- Its **"Open questions (resolve at readiness)"** block in `PLAN.md` is empty or every
  question has a recorded answer — in DESIGN.md/an ADR for design decisions, or replaced
  inline with the decision for smaller calls. An unanswered open question is a hard block
  on starting the phase.
- Its goal and exit criteria are concrete and testable by command or observation.
- Every design question it will hit is answered in DESIGN.md/ADRs, or explicitly
  delegated ("agent decides X within envelope Y").
- Its escalation triggers are listed (the known unknowns that must stop work, not get
  guessed at).
- The inputs it needs exist (archived diffs, pinned commits, tools from prior phases).

Phases late in `PLAN.md` are *intentionally* under-specified today; they are brought up to
this bar at their own readiness step, informed by everything learned before them.

## Current readiness assessment (as of 2026-07-31)

- **Phase 0: ready.** Mechanical; no design decisions. Its one judgment call (toolchain
  versions) is dictated by the upstream repos.
- **Phase 1: ready, with named escalation triggers** (in the phase text): appcontainer
  verdict, GraphicsAPI contract drift on upstream main, WTF-16 entry-point shape if
  upstream's TODO comment doesn't match reality, and the clear-color stub boundary if
  `generic.zig` can't run without full pipelines.
- **Phases 2–3: close.** Detail them at their readiness steps using the archived #11886
  diff and the Phase 1/2 session reports.
- **Phases 4–9: outline only, by design.**
