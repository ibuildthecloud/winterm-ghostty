# PLAN — Staged implementation

One phase ≈ one focused agent session on the Windows machine, executed under the loop in
**`PROCESS.md`** (readiness → unattended execute → deliver + session report → human
evaluate → retro). Every phase has a concrete, *demonstrable* exit criterion — something
that runs, renders, or passes tests — plus re-evaluation questions for the retro. Phases
after the next one are intentionally under-specified; they are detailed at their own
readiness step.

Dependencies: Phases 1→2→3 are the ghostty track; Phase 4 is the WT track and can run any
time after Phase 0 (including in parallel). Phase 5 needs 2+4 (not 3 complete). 6→7→8
follow 5.

## Status ledger

| Phase | Status | Session notes |
|---|---|---|
| 0 — Toolchain + baselines | 4/5 criteria met | [0001](docs/sessions/0001-phase-0.md): repo + pins + #11886 archived (incl. binary shaders); wintty runs a shell; **WT builds from source on VS2026/v145 and launches as a deployed dev package** (no VS2022 needed — PLAN text is stale). Unmet: **upstream libghostty does not link on MSVC** (memset vs libvcruntime, then POSIX `close`/`write` in `termio/Exec.zig`); `zig build test` passes 3061/0. One DECISION-NEEDED: ADR 0004 needs a `windows-build` patch ahead of `init-wtf16`. |
| 1 — Fork bootstrap + first pixels | not started | |
| 2 — SwapChainPanel proof | not started | |
| 3 — Real terminal rendering | not started | |
| 4 — WT seam (IControlCore) | not started | |
| 5 — Ghostty pane MVP | not started | |
| 6 — Interaction parity | not started | |
| 7 — Presentation & performance | not started | |
| 8 — Accessibility & packaging | not started | |
| 9 — Upstreaming loop | ongoing/background | |

---

## Phase 0 — Toolchain + baselines (Windows machine)

Goal: everything builds from source locally; risky unknowns get yes/no answers before any
code is written.

- Verify `CLAUDE.md` (created as a WSL symlink to `AGENTS.md`) resolves under native
  Windows (`type CLAUDE.md` shows AGENTS.md content). If not, delete it and recreate with
  `New-Item -ItemType SymbolicLink` or fall back to a copy kept in sync.
- `git init` this repo (`/…/winterm-ghostty`); initial commit of the docs as they stand;
  ensure `core.symlinks=true` took effect for `CLAUDE.md`;
  commit at session end (and every session thereafter, per PROCESS.md). The `ghostty/`
  and `terminal/` forks created in later phases are their own clones — add them to
  `.gitignore` here; this repo tracks docs, `harness/`, and `scripts/` only.
- Install: Zig (version from ghostty `build.zig.zon`), VS2022 + Windows SDK, `dxc`,
  Windows Terminal build prereqs (see terminal repo README).
- Clone upstream `ghostty-org/ghostty`; build `zig build -Dapp-runtime=none` (libghostty
  DLL+static) and `zig build test` on Windows. Record the pinned commit.
- Clone `microsoft/terminal`; build and launch unpackaged WT from source. Record pin.
- Clone reference repos read-only: `deblasis/wintty`, `amanthanvi/winghostty`,
  `arya-s/phantty`. Fetch PR #11886's diff (`gh pr diff 11886 -R ghostty-org/ghostty`)
  and archive it under `docs/research/` — it is the D3D11 base and could disappear.
- Build & run wintty once: confirms the D3D12/dcomp/SwapChainPanel path works on this
  machine and gives a live behavior reference.
- Write `scripts/` wrappers for the two builds.

Exit criteria (all demonstrable):
- [ ] This repo is a git repository with the docs committed.
- [ ] `libghostty` (upstream, unpatched) builds and its tests pass on this machine.
- [ ] Windows Terminal builds from source and launches.
- [ ] wintty runs a shell locally.
- [ ] PR #11886 diff archived; upstream pins recorded in DESIGN.md.

Open questions (resolve at readiness):
- Which physical machine/GPU is the dev box, and does it have a second config (VM/RDP)
  for WARP-path testing later?
- None design-level — this phase exists to *answer* questions, not consume them.

Re-evaluate: Zig version friction? WT build friction that affects Phase 4 scoping?

## Phase 1 — Ghostty fork bootstrap + first pixels (patch series, ADR 0002/0004)

Goal: the patch-series fork exists and a ghostty surface clears to a color on Windows
through the embedded C API.

- Create `ghostty/` fork (clone upstream at the Phase-0 pin; branch `windows`).
  **Patch tooling**: one commit per patch topic on `windows`, in ADR 0004's order;
  `scripts/rebase-upstream.(ps1|sh)` re-stacks the series on a new upstream pin;
  `scripts/export-patches` emits `git format-patch` output to `ghostty-patches/` in this
  repo (the reviewable artifact). No force-push to any shared remote; the series is
  reproducible from upstream pin + exported patches.
- Patch `init-wtf16`: follow the prescription in upstream's own TODO at the
  `error.UnsupportedOSForCApi` site in `src/global.zig` (~line 68): accept WTF-16 argv
  (`[]const [*:0]const u16` / UNICODE_STRING-style) and convert for
  `std.process.Args`-equivalent handling. Keep the C signature additive (new
  `ghostty_init_w` or platform-conditional arg type — agent decides, note it).
- Patch `platform-win32`: `GHOSTTY_PLATFORM_WINDOWS = 3` in `include/ghostty.h`;
  `ghostty_platform_windows_s` exactly as specified in DESIGN.md; `win32` variant in the
  `Platform` union in `src/apprt/embedded.zig` (payload compiles to `void` fields
  off-Windows, mirroring how Darwin handles it); `ghostty_surface_get_swap_chain_handle`
  / `_get_swap_chain` exports (null until the backend provides them).
- Patch `d3d11-backend` (skeleton): `directx11`-style `Backend` enum variant in
  `src/renderer/backend.zig` defaulting on Windows; `src/renderer/D3D11.zig` implementing
  the `GraphicsAPI` contract enumerated in `src/renderer/generic.zig` — port the revived
  #11886 diff (archived in Phase 0) as the base, wintty's `src/renderer/directx12/` as
  the pattern reference for device lifecycle/surface modes. Scope: device creation with
  hardware→WARP fallback chain, hwnd-mode swapchain, and a frame that clears and
  presents. Pipelines/atlas/shaders are Phase 3 — stub the option-factory methods with
  compiling no-ops. **If `GenericRenderer.drawFrame` cannot run end-to-end without real
  pipelines, a temporary direct clear-and-present path gated behind a comment-marked
  `phase1_skeleton` flag is acceptable; it must be removed in Phase 3.**
- `harness/hwnd-host`: minimal C (or Zig) Win32 app: `ghostty_init` → config →
  `ghostty_app_new` → `ghostty_surface_new(hwnd mode)` → message pump calling
  `ghostty_app_tick` on `wakeup_cb`, forwarding resize/DPI. Lives in this repo, builds
  via `scripts/`.
- MSIX/appcontainer probe: link the DLL into a trivial packaged app, run API-set
  validation. Record result (ships in-package vs out-of-process fallback) in DESIGN.

Escalation triggers (stop the item, report DECISION-NEEDED, per PROCESS.md):
- Appcontainer validation fails with no small fix — the packaging fallback is a human
  decision.
- The `GraphicsAPI` contract on current upstream main has drifted materially from what
  #11886/wintty implement (new required methods are fine to stub; changed semantics are
  not).
- The WTF-16 fix can't stay additive (would break existing C API signatures).
- WARP device creation fails on this machine (invalidates the ADR 0002 fallback story).

Exit criteria:
- [ ] Harness shows a libghostty-cleared, resizable, DPI-correct surface (hardware AND
      forced-WARP), on x64; ARM64 cross-build compiles.
- [ ] Each patch builds + `zig build test` passes independently.
- [ ] Appcontainer/MSIX answer recorded.

Open questions (resolve at readiness):
- ADRs 0002 and 0004 flipped to `Accepted`? (This phase builds directly against both.)
- Did Phase 0 archive the #11886 diff intact, and does a first read confirm it matches
  what the research claimed (GraphicsAPI-shaped, composition swapchain)?
- Fork remote strategy: private GitHub fork vs local-only clone for now? (Affects nothing
  technical; decide for backup/collaboration reasons.)
- WTF-16 entry point: new `ghostty_init_w` vs platform-conditional argv type — currently
  delegated to the agent; confirm we're comfortable delegating, or decide now.

Re-evaluate: how much of #11886 survived the rebase vs rewritten? Is the GraphicsAPI
contract stable enough on upstream main, or do we need a tighter pin cadence?

## Phase 2 — SwapChainPanel proof (composition mode)

Goal: the WT-integration primitive works end to end: dcomp surface handle from Zig,
consumed by a XAML SwapChainPanel.

- `d3d11-backend`: composition mode — `DCompositionCreateSurfaceHandle` +
  `CreateSwapChainForCompositionSurfaceHandle`, premultiplied `FLIP_SEQUENTIAL`;
  `ghostty_surface_get_swap_chain_handle` export.
- `harness/xaml-host`: minimal WinUI 3 (or XAML-island) app binding the handle via
  `ISwapChainPanelNative2::SetSwapChainHandle` (wintty's `Interop/ISwapChainPanelNative.cs`
  is the recipe).
- Resize + `CompositionScale` handling; device-removed → recreate → re-attach handle.

Exit criteria:
- [ ] Animated clear-color in a SwapChainPanel; live resize with no stretch artifacts;
      per-monitor DPI change handled.
- [ ] Kill the device (dxcap or TDR sim) → surface recovers without app restart.

Open questions (resolve at readiness):
- Harness UI stack: WinUI 3 or system-XAML islands? **This matters beyond the harness**:
  Windows Terminal uses system XAML islands while wintty's interop recipe targets WinUI 3
  — the `ISwapChainPanelNative2` interop IIDs differ between the two stacks. The harness
  should preferably prove the *system-XAML* variant (what Phase 5 needs); confirm the
  interop call shape for it, or decide to prove both.
- Harness language: C# (fast, wintty recipe ports directly) vs C++/WinRT (closer to WT's
  Phase 5 reality)? Recommendation pending Phase 1 learnings.
- Device-lost recovery contract: after recreation, is a *new* dcomp handle mandatory
  (re-raise attach) or can the old handle be revived? Decide the C API semantics before
  building recovery.

Re-evaluate: any dcomp/XAML surprise that changes the WT attach plan (Phase 5)?

## Phase 3 — Real terminal rendering in the harness

Goal: full ghostty rendering of a live shell in the harness — the engine is real before WT
ever sees it.

- Complete `d3d11-backend`: gpu_data byte-parity with Metal, glyph atlas textures,
  all cell pipelines (bg/fg/color/cursor/images), HLSL for the shared shader set.
- `dwrite-discovery` patch (ADR 0005): DirectWrite discovery + `MapCharacters` fallback +
  negative cache; FreeType raster; verify CJK + emoji fallback (note CBDT-vs-COLRv1 gaps).
- `winkeys` patch: key/char pairing; wire harness keyboard input → interactive shell
  (ghostty exec/ConPTY path is fine here — `termio-external` comes with WT integration).
- Validate: vttest sweep, `zig build test` per patch, side-by-side against wintty for
  visual/behavioral drift; measure `cat`-a-large-file throughput vs wintty and WT.

Exit criteria:
- [ ] Interactive PowerShell + a TUI app (e.g. btop/vim) fully usable in the harness with
      correct fonts, ligatures, emoji fallback, kitty keyboard protocol active.
- [ ] vttest results recorded; no regressions vs wintty on the same scenarios.
- [ ] Works under forced WARP.

Open questions (resolve at readiness):
- ADR 0005 flipped to `Accepted`?
- **Shader toolchain for D3D11**: D3D11 consumes DXBC (classic `fxc`, SM 5.0), not the
  DXIL that `dxc`/SM 6 emits — wintty's SM 6 HLSL is a D3D12-ism we can't copy blind.
  Decide: route ghostty's existing glslang→SPIRV-Cross pipeline to HLSL output compiled
  with `fxc`, or hand-port the shaders to SM 5.0? (Check what #11886 actually did — it
  shipped pre-compiled shaders.)
- Exit bar for emoji: is CBDT-only (no COLRv1 Segoe glyphs) acceptable for this phase's
  exit, with COLRv1 as a tracked gap re-evaluated at Phase 6?
- Benchmark methodology: pick the throughput/latency harness now (vtebench? plain
  `cat`+timer? termbench?) so Phase 3 and Phase 7 numbers are comparable.

Re-evaluate: renderer perf acceptable enough to defer Phase 7 polish? COLRv1 emoji — fix
now or ship-gate later?

## Phase 4 — WT seam: IControlCore (ADR 0001; parallel track)

Goal: WT runs unchanged on an interface, ready to accept a second engine.

- Create `terminal/` fork. Promote `ControlCore.idl`+`ICoreState.idl` → `IControlCore`;
  convert `TermControl`/`ControlInteractivity` to hold it; add IDL for the six
  `get_self` escapes.
- Add the per-profile `engine` setting (ADR 0007) end-to-end with only `"cascadia"` valid,
  wired to a factory at pane creation.
- Run WT's existing unit/feature test suites.

Exit criteria:
- [ ] Forked WT builds, launches, and behaves identically (tabs, panes, search, marks,
      a11y smoke with Narrator) with cascadia behind the interface.
- [ ] WT test suites pass at pre-fork levels.
- [ ] `"engine": "cascadia"` parses; unknown values warn and fall back.

Open questions (resolve at readiness):
- ADRs 0001 and 0007 flipped to `Accepted`?
- Which WT test suites are actually runnable locally (unit vs the UI/feature suites that
  need special infra)? Sets what "pass at pre-fork levels" concretely means — establish
  the baseline *before* the seam change lands.
- Interface naming/shape: single `IControlCore` vs splitting the event surface
  (`IControlCoreEvents`)? WinRT versioning conventions in the WT codebase may force a
  choice — inspect first, then delegate the rest.
- Fork base: track the Phase-0 pin or advance to current main before branching? (WT moves
  slower than ghostty; a fresh pin here is probably cheap and right.)

Re-evaluate: is the interface promotion clean enough to PR upstream now? (If yes, open it
— it shrinks the fork permanently.)

## Phase 5 — Ghostty pane MVP inside Windows Terminal

Goal: `"engine": "ghostty"` renders a live shell in a WT pane.

- `termio-external` patch (ADR 0006): embedder-fed output bytes, backpressure story,
  input via write callback. (Highest-risk new design in the project — do first.)
- `GhosttyControlCore` MVP: ctor from settings+connection; surface in composition mode;
  swap-chain handle → `SwapChainChanged`; key/char/mouse input; resize (cell metrics →
  `Connection.Resize`); scroll state ↔ scrollbar; title/color/CWD/bell/connection-state
  events; UTF-16↔UTF-8 at the boundary; settings→`ghostty_config_t` translator (font,
  size, scheme, scrollback, padding).
- Fallback path: engine init failure → `RendererEnteredErrorState` + cascadia fallback.

Exit criteria:
- [ ] A profile with `"engine": "ghostty"` opens a fully interactive shell in a WT tab;
      cascadia and ghostty panes run side-by-side in one window.
- [ ] Tab title, resize, scrollback via scrollbar, close-confirmation all work.
- [ ] Defterm handoff and an Azure-connection profile still work (on cascadia AND ghostty
      profiles — proves ADR 0006).

Open questions (resolve at readiness):
- ADR 0006 flipped to `Accepted`?
- **`termio-external` backpressure semantics** — the phase's core design question, decide
  before coding: does `ghostty_surface_write_pty_output` block, partially consume with a
  bytes-accepted return, or use a credit/callback flow-control scheme? (WT's connection
  read thread must not deadlock against the render lock; study how ghostty's own read
  thread yields via `renderer_state.yieldToDemand`.)
- UTF-16→UTF-8 conversion at the boundary: who buffers a surrogate pair split across
  `TerminalOutput` events? (Must be the C++ side; specify the small state machine.)
- Threading contract for `GhosttyControlCore`: which ghostty callbacks arrive on which
  thread, and which WinRT events must be dispatcher-marshaled? Write the table before
  implementation (ControlCore.idl's own background/UI-thread event split is the template).
- Settings translator scope for MVP: exactly which `IControlSettings` fields map in this
  phase (font, size, scheme, scrollback, padding — confirm) and what explicitly doesn't.

Re-evaluate: `termio-external` backpressure under `yes`/`cat` flood — correct? Anything in
the IControlCore obligation map that's harder than designed?

## Phase 6 — Interaction parity

Goal: daily-drivable ghostty panes.

- Selection (mouse + keyboard + markers), clipboard (plain/HTML/RTF where applicable),
  copy-on-select.
- Search box (`Search`/`SearchResults`), scrollbar pips via read-back.
- Hyperlinks (hover tooltip, ctrl-click), marks + `scrollToMark` (ship the PowerShell
  OSC 133/7/9;4 integration script), `ReadEntireBuffer` export.
- IME: TSF → preedit/ime_point; verify Japanese/Chinese input + candidate-window
  placement.
- Ghostty custom-shader support surfaced (WT retro shader as the test asset).

Open questions (resolve at readiness):
- Clipboard fidelity: can ghostty's read-back produce styled (HTML/RTF) copies, or is
  plain-text the phase exit and styled copy a tracked gap?
- Search capability mapping: WT's `SearchRequest` supports regex and case toggles — what
  does ghostty's search support, and which unsupported combinations degrade how?
- Marks parity: are ghostty's OSC 133 semantics close enough to WT's mark categories
  (prompt/command/output/error) for `SelectCommand`/`SelectOutput`, or do those actions
  stay stubbed?
- Which of the "stub initially" items (completions, quick fixes, persistence) graduate
  into this phase vs stay deferred? Decide from Phase 5's learnings.

Exit criteria:
- [ ] A checklist pass of WT's terminal-aware actions on a ghostty pane matches cascadia
      behavior (documented diffs allowed, each with an issue filed).
- [ ] IME verified with at least one CJK language end-to-end.

## Phase 7 — Presentation & performance (DESIGN presentation policy)

Goal: beat-or-match cascadia on the numbers that matter.

- Waitable swapchain, damage-gated Present, `ALLOW_TEARING`, occlusion-stops-drawing.
- Partial uploads + scroll-as-rotation; `iocp-fixes` patch (libxev timer fix, 64 KiB
  overlapped reads).
- Benchmarks vs cascadia (same machine, same profile): large-file `cat` throughput,
  latency (vtebench/typometer-style), idle CPU/GPU (cursor blink must present nothing),
  RDP session usability.

Open questions (resolve at readiness):
- Where does the waitable-swapchain wait live in ghostty's renderer thread (a libxev
  loop)? Waiting a Win32 handle inside an xev loop needs a design: xev async bridge,
  dedicated wait thread, or timer-approximation first?
- Latency measurement method: instrumented (ETW present events / PresentMon) vs external
  (photon-to-pixel is out of scope) — pick one that can compare cascadia and ghostty
  fairly on the same machine.
- Are the Phase-7 numeric targets (≥ cascadia throughput, ≤ median latency) still the
  right bar given Phase 3's measurements, or should they be revised before work starts?

Exit criteria:
- [ ] Idle ghostty pane: 0 presents/sec with cursor blinking.
- [ ] Throughput ≥ cascadia on `cat` benchmark; latency ≤ cascadia median.
- [ ] Usable over RDP (WARP) with no fallback dialogs.

## Phase 8 — Accessibility & packaging

Goal: shippable.

- UIA `ITextProvider`/`ITextRangeProvider` over read-back (harvest winghostty
  `win32_uia/` semantics); Narrator + NVDA smoke tests.
- MSIX packaged build with the engine DLL (per Phase-1 answer); ARM64 end-to-end.
- Settings-UI affordance for the `engine` field; docs.

Open questions (resolve at readiness):
- UIA text-provider performance: screen readers walk text ranges aggressively — is the
  read-back API's per-call cost acceptable, or does the provider need a snapshot/cache
  layer? (Prototype the hot path before committing to a design.)
- Packaging: what did the Phase-1 appcontainer probe conclude, and does the packaged
  build carry the engine DLL in-package or out-of-process?
- Signing/identity for the MSIX (test cert vs proper identity) — a machine/infra
  decision, not a code one.

Exit criteria:
- [ ] Narrator reads a ghostty pane comparably to cascadia.
- [ ] Packaged MSIX installs and runs on x64 + ARM64.

## Phase 9 — Upstreaming loop (background, ongoing)

Open questions (standing, revisit each retro):
- When to contact deblasis — before Phase 1 (shared heritage, avoid divergence) or after
  first pixels (something concrete to show)? Recommendation: before Phase 1.
- Attribution/provenance notes for harvested MIT code (wintty/winghostty/AtlasEngine) —
  decide the convention (per-file header note vs NOTICES file) before the first harvest
  lands in Phase 1.

- Immediately: libxev IOCP timer fix → mitchellh/libxev; contact deblasis re:
  collaboration/patch heritage.
- After Phase 4: `IControlCore` PR → microsoft/terminal.
- After Phase 3: infra patches (`init-wtf16`, CI) → ghostty-org/ghostty; keep
  `d3d11-backend`/`dwrite-discovery`/`termio-external` rebased and offer when upstream
  reopens the renderer door.
- Track upstream ghostty main monthly; rebase the series; note API breaks in the ledger.
