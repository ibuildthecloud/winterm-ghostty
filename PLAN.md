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
| 0 — Toolchain + baselines | **complete** (retro done) | [0001](docs/sessions/0001-phase-0.md): repo + pins + #11886 archived (incl. binary shaders); wintty runs a shell; **WT builds from source on VS2026/v145 and launches as a deployed dev package** (no VS2022 needed — PLAN text is stale). Criterion 2's premise is falsified, not outstanding: it asserts *unpatched* upstream builds, which is false at pin `4d605bf0` and only an upstream merge can change. Fixed in-session at the gate's direction: branch `windows`, patch 0 `75c31f2c` → **`ghostty-internal.dll` links, x64 PE, 231 C-API exports**, tests unchanged at 3061/55/0. Retro: amend that criterion's wording, and ratify the ADR 0004 patch-list change (§5.1). |
| 1 — Fork bootstrap + first pixels | 3/4 criteria met | [0002](docs/sessions/0002-phase-1.md): **libghostty renders on Windows.** 4-patch series exported; harness shows a `#282C34` surface tracking config, resizable, DPI-correct, identical on hardware and forced WARP. Appcontainer answered (WT is `runFullTrust`; DLL ships in-package). Unmet: **ARM64 cross-build blocked by a Zig 0.16.0 stdlib bug** (`SelfInfo/Windows.zig:670`, `@ptrCast` alignment on aarch64) — not our code. One DECISION-NEEDED. |
| 2 — SwapChainPanel proof | **complete** | [0003](docs/sessions/0003-phase-2.md): **the WT integration primitive works.** libghostty's dcomp handle bound into a system-XAML `SwapChainPanel` via `ISwapChainPanelNative2::SetSwapChainHandle` — the same call WT already makes. Resize clean 540×430→1400×900; `CompositionScale 1.50`. Device loss → rebuild → re-attach, handle `0x179C`→`0x21D0`, no restart. Added a `swap_chain_changed` action (§4 dev 2). Clear colour static, not animated (§4 dev 1). |
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
- Install: Zig (version from ghostty `build.zig.zon`), **Visual Studio 2026 (MSVC v145)**
  with `terminal/.vsconfig` applied, Windows SDK ≥ 10.0.26100.8249, `fxc`/`dxc`.
  *(Amended at retro: WT's `src/common.build.pre.props` selects v145 when
  `VisualStudioVersion >= 18.0`, and WT's README ships a winget config for VS 2026 —
  VS2022/v143 is not required. `.vsconfig` is the authoritative component list.)*
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
- [x] This repo is a git repository with the docs committed.
- [x] `libghostty` builds and its tests pass on this machine, with the minimum patch set
      required to do so, and that patch set is recorded in `ghostty-patches/`.
      *(Amended at the Phase 0 retro. The original wording said "upstream, **unpatched**",
      which assumed upstream built on Windows. It does not, at pin `4d605bf0` — so as
      written the criterion asserted something only an upstream merge could make true.
      See `docs/sessions/0001-phase-0.md` §2 and §5.1.)*
- [x] Windows Terminal builds from source and launches.
- [x] wintty runs a shell locally.
- [x] PR #11886 diff archived; upstream pins recorded in DESIGN.md.

Open questions — **all resolved**:
- ~~Which physical machine/GPU is the dev box, second config for WARP?~~ SER9, Ryzen AI 9
  HX 370, **integrated AMD Radeon 890M**, 64 GB. WARP validation is done over **RDP into
  this same machine**; there is no second physical config. Recorded in DESIGN.md.

Re-evaluated: **Zig version friction — none** (0.16.0 pinned by `build.zig.zon` +
`flake.nix`, installed locally under `tools/`). **WT build friction — low, and it does not
affect Phase 4 scoping**: v145 builds everything, and WT already builds/launches from
source, so Phase 4's test-suite baseline can be captured before any seam work.
**New friction found where none was expected**: upstream libghostty did not link on
Windows/MSVC at all (now fixed by patch 0 — see the session report).

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
  the pattern reference for device lifecycle/surface modes.
  **Retro correction: #11886 is infrastructure only** — COM bindings, device lifecycle,
  DXGI, an instanced cell-grid pipeline, and hand-written SM 5.0 HLSL. Its `DirectX11.zig`
  contains no `pub fn` at all, only re-exports, and its own header says the GenericRenderer
  integration (Target, Frame, RenderPass, Buffer, Texture, Sampler, shaders) is "planned
  for follow-up work". **We write the `GraphicsAPI` implementation ourselves**; #11886 is
  the layer beneath it, not a shortcut past it. Scope: device creation with
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
- ~~WARP device creation fails on this machine~~ — **PRE-CLEARED 2026-07-31.**
  `harness/warp-probe` creates a D3D11 device three ways on this box: hardware,
  `D3D_DRIVER_TYPE_WARP`, and the explicit `IDXGIFactory4::EnumWarpAdapter` adapter. All
  three succeed at **feature level 11_1** with `BGRA_SUPPORT`. ADR 0002's fallback story
  holds. Re-run the probe over RDP before Phase 7's remote-session work.

Exit criteria:
- [x] Harness shows a libghostty-cleared, resizable, DPI-correct surface (hardware AND
      forced-WARP), on x64.
- [~] ~~ARM64 cross-build compiles.~~ **DEFERRED at the Phase 1 retro (2026-07-31).**
      Blocked outside this project: Zig 0.16.0's own stdlib fails to target
      `aarch64-windows-msvc` (`std/debug/SelfInfo/Windows.zig:670`, `@ptrCast` increases
      pointer alignment — function pointers need 4-byte alignment on aarch64, 1 on x86_64).
      A trivial Zig program cross-compiles fine, so it is the `std.debug` self-info path,
      not a blanket toolchain failure. Nothing before Phase 8 needs ARM64.
      **Re-test at the next Zig pin bump**; carrying a local stdlib patch was rejected
      because it would be invisible to `ghostty-patches/` and rot silently.
- [x] Each patch builds + `zig build test` passes independently.
- [x] Appcontainer/MSIX answer recorded.

Open questions — **all resolved at the Phase 0 retro (2026-07-31); phase is ready**:
- ~~ADRs 0002 and 0004 flipped to `Accepted`?~~ **Both Accepted.** 0004 additionally
  amended: `windows-build` added as patch 0, and the per-patch build rule reworded so an
  indivisible topic isn't forced into non-building halves.
- ~~Did Phase 0 archive #11886 intact, and does a first read confirm the research?~~
  **Archived and binary-complete** (text diff + the two `.cso` blobs, which `gh pr diff`
  drops). First read **partially** confirms: the module layout and composition approach are
  as described, but the PR is **infrastructure only** and implements none of the
  `GraphicsAPI` contract. Phase 1 writes that itself — the phase text above is corrected.
- ~~Fork remote strategy?~~ **Local only, no remote, nothing pushed.** `ghostty-patches/`
  in this repo is the durable artifact. ADR 0004 amendment §3.
- ~~WTF-16 entry point: `ghostty_init_w` vs platform-conditional argv?~~ **Confirmed
  delegated to the agent**, within the envelope "keep the C signature additive"; record the
  choice in the session report.

Starting state (not assumptions — verified in Phase 0):
- `ghostty/` clone exists at pin `4d605bf0`, branch `windows`, carrying patch 0
  (`75c31f2c`). `zig build -Dapp-runtime=none` → `ghostty-internal.dll` with 231 C-API
  exports; `zig build test` → 3061 pass / 55 skip / 0 fail.
- Build wrappers exist: `scripts/zigenv.ps1`, `scripts/build-ghostty.ps1`
  (`-Test`, `-Target` for the ARM64 cross-build), `scripts/build-terminal.ps1`.
- Still to build in this phase: `scripts/rebase-upstream.*` and `scripts/export-patches`
  (patch 0 was exported with a raw `git format-patch` — the tooling itself is Phase 1 work).
- Harness screenshots must use `PrintWindow` against a specific `HWND`, never
  `Graphics.CopyFromScreen` (session 0001, deviation 10).

Re-evaluate: how much of #11886 survived the rebase vs rewritten? Is the GraphicsAPI
contract stable enough on upstream main, or do we need a tighter pin cadence?

## Phase 2 — SwapChainPanel proof (composition mode)

Goal: the WT-integration primitive works end to end: dcomp surface handle from Zig,
consumed by a XAML SwapChainPanel.

- `d3d11-backend`: composition mode — `DCompositionCreateSurfaceHandle` +
  `CreateSwapChainForCompositionSurfaceHandle`, premultiplied `FLIP_SEQUENTIAL`;
  `ghostty_surface_get_swap_chain_handle` export.
- `harness/xaml-host`: minimal **system-XAML** app in **C++/WinRT**, binding the handle via
  `ISwapChainPanelNative2::SetSwapChainHandle`. **Mirror WT's own
  `TermControl::_AttachDxgiSwapChainToXaml`** (`TermControl.cpp:1364`), which is already
  exactly this call — not wintty's C# WinUI 3 recipe.
- Resize + `CompositionScale` handling; device-removed → recreate → re-attach handle.

Exit criteria:
- [ ] Animated clear-color in a SwapChainPanel; live resize with no stretch artifacts;
      per-monitor DPI change handled.
- [ ] Kill the device (dxcap or TDR sim) → surface recovers without app restart.

Open questions — **all resolved at the Phase 1 retro (2026-07-31); phase is ready**:
- ~~Harness UI stack: WinUI 3 or system-XAML?~~ **System XAML.** Not a preference call —
  WT already does this exact binding in `TermControl.cpp:1364`:
  `SwapChainPanel().as<ISwapChainPanelNative2>()` then `SetSwapChainHandle(...)`.
  Windows Terminal is the only target, so the harness mirrors that and nothing else.
- ~~Harness language: C# or C++/WinRT?~~ **C++/WinRT**, matching WT. The project's aim is
  a change Microsoft could plausibly adopt, so the harness must not introduce anything that
  would read as unnatural upstream. wintty's C# interop is reference material only.
- ~~Device-lost recovery contract?~~ **A new handle is expected; the embedder re-attaches.**
  WT's `ControlCore::_renderEngineSwapChainChanged` already implements precisely this: it
  `DuplicateHandle`s the renderer's new handle and raises `SwapChainChanged` so
  `TermControl` re-binds. Its comment even covers the race — "even if the renderer is
  currently in the process of discarding this value and creating a new one".
  **Consequence for this phase:** a getter is not sufficient. libghostty needs a *change
  notification* so Phase 5 can drive `SwapChainChanged`. Verify by forcing a TDR rather
  than trusting the inference.

Starting state (verified in Phase 1, not assumed):
- The C API and the `Platform.Win32` union already carry `composition` as a mode;
  `Device.init` returns `error.Unsupported` for it and
  `ghostty_surface_get_swap_chain_handle` returns null. This phase fills those in rather
  than reshaping anything.
- **None of the handle-based composition path is bound yet** — `IDXGIFactoryMedia`,
  `CreateSwapChainForCompositionSurfaceHandle`, `DCompositionCreateSurfaceHandle`,
  `ISwapChainPanelNative2` are all absent. #11886 wired `IDXGIFactory2::
  CreateSwapChainForComposition`, which is the *object-based* path
  (`ISwapChainPanelNative::SetSwapChain`) and not what we use.
- **wintty implements the handle-based path** in `src/renderer/directx12/dcomp.zig` and
  `dxgi.zig` (MIT, harvestable). Being D3D12 barely matters: the creator takes an
  `IUnknown*`, so only the argument differs — D3D12 passes an `ID3D12CommandQueue`, we
  pass the `ID3D11Device`. Vtable layouts, IIDs, and the surface access mask are
  version-independent, and those are the parts most likely to be silently wrong if
  hand-written.
- `syncToWindow` (the Phase 1 hwnd resize fix) **cannot work here** — there is no window to
  query. Composition resize must be driven from the surface size the embedder sets, which
  is the plumbing Phase 1 skipped. Once it exists, hwnd mode should probably use it too.
- `DXGI_ALPHA_MODE.PREMULTIPLIED` is already selected for composition in `device.zig` but
  has never been exercised; this is where blending errors would first appear.

Re-evaluate: any dcomp/XAML surprise that changes the WT attach plan (Phase 5)?

## Phase 3 — Real terminal rendering in the harness

Goal: full ghostty rendering of a live shell in the harness — the engine is real before WT
ever sees it.

- Complete `d3d11-backend`: gpu_data byte-parity with Metal, glyph atlas textures,
  all cell pipelines (bg/fg/color/cursor/images), HLSL for the shared shader set.
- `dwrite-discovery` patch (ADR 0005, **rewritten and Accepted 2026-07-31**): a
  `directwrite_harfbuzz` backend — DirectWrite discovery with `MapCharacters` + negative
  cache, **DirectWrite/D2D rasterization** into the atlas via
  `CreateDxgiSurfaceRenderTarget`, HarfBuzz shaping. Colour glyphs via
  `TranslateColorGlyphRun`. Verify CJK + emoji fallback.
- `winkeys` patch: key/char pairing; wire harness keyboard input → interactive shell.
  **The ConPTY path is unproven** — see the escalation triggers below.
- Validate: vttest sweep, `zig build test` per patch, side-by-side against wintty for
  visual/behavioral drift; measure `cat`-a-large-file throughput vs wintty and WT.

Exit criteria:
- [ ] Interactive PowerShell + a TUI app (e.g. btop/vim) fully usable in the harness with
      correct fonts, ligatures, emoji fallback, kitty keyboard protocol active.
- [ ] vttest results recorded; no regressions vs wintty on the same scenarios.
- [ ] Works under forced WARP.

Open questions — **all resolved at the Phase 2→3 readiness step (2026-07-31)**:
- ~~ADR 0005 flipped to `Accepted`?~~ **Accepted, after being rewritten.** The draft chose
  FreeType rasterization; evidence reversed it. `Backend.default()` shows Windows' FreeType
  default is a stopgap ("A future DirectWrite backend can replace this if needed") while
  macOS already renders with CoreText — so "stay on FreeType for cross-platform
  consistency" described a consistency that does not exist. And Segoe UI Emoji is COLR v1
  with **no CBDT/sbix font anywhere on Windows**, so FreeType meant building colour-glyph
  support ourselves, permanently, for one platform.
- ~~**Shader toolchain**~~ — **`fxc` / SM 5.0 DXBC** (Phase 0), and the sub-question is now
  settled: **hand-author `shaders.hlsl`**. Every backend authors its own shader source —
  Metal has `shaders.metal`, OpenGL has a `glsl/` directory — and SPIRV-Cross is used only
  for *custom* shadertoy shaders. Routing the main set through glslang→SPIRV-Cross would
  invent a pattern no backend uses, which is bad for upstreaming.
- ~~**Emoji exit bar**: is CBDT-only acceptable with COLRv1 as a tracked gap?~~ **Moot.**
  ADR 0005's rewrite makes DirectWrite render colour glyphs, so COLR v0/v1, SVG, PNG, sbix
  and CBDT all come from the platform. Measured: Segoe UI Emoji is COLR v1 carrying a full
  v0 layer set (3,372 base glyphs), and **AtlasEngine renders the v0 layers** — it requests
  `DWRITE_GLYPH_IMAGE_FORMATS_COLR` on an `IDWriteFactory4` and never asks for paint trees.
  So emoji land on par with Windows Terminal. `COLR_PAINT_TREE` via `IDWriteFactory8` is a
  separable later upgrade that would put us ahead.
- ~~**Benchmark methodology**~~ — **purpose-built corpus benchmark**, `scripts/bench-throughput.ps1`
  plus a fixed corpus committed to this repo (ASCII, CJK, SGR-heavy, scroll-heavy), timed
  identically across our harness, wintty and WT. Rejected vtebench (Rust; toolchain
  friction on Windows) and `ghostty-bench +terminal-stream` as the primary (engine-internal,
  cannot compare terminals) — the latter is still recorded per-run for regression tracking.
  **Phase 7 must reuse the identical script and corpus** or its targets are not comparable.

Escalation triggers (stop the item, report DECISION-NEEDED, per PROCESS.md):
- **The ConPTY/exec path has never executed.** `pty.zig` has a `WindowsPty` with
  `CreatePseudoConsole`, and `Exec.zig` has a `threadMainWindows`, but upstream could not
  link on Windows at all before patch 0, so none of it has run. wintty documented a
  concrete defect: under ConPTY the child is already in ConPTY's job object before ghostty
  sees it, so `xev.Process` silently no-ops and **process exit is never detected** — they
  replaced it with a dedicated `WaitForSingleObject` thread. Investigate and fix; if the
  fix turns out to need the `iocp-fixes` patch (ADR 0004 patch 6) pulled forward, that is a
  patch-order change and needs reporting rather than deciding.
- D2D/D3D11 interop on the shared atlas surface behaving differently under WARP than
  hardware (the composition path has only ever been exercised on hardware).
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
- MSIX packaged build with the engine DLL. **Phase 1 answered this: WT's package declares
  `runFullTrust`, so it is not appcontainer-restricted and the DLL ships in-package** —
  which matters because libghostty imports ntdll directly via Zig's stdlib and would fail
  Store API-set validation. See DESIGN.md → Packaging constraints.
- ARM64 end-to-end. **Carries a deferred blocker from Phase 1:** Zig 0.16.0 cannot target
  `aarch64-windows-msvc` at all (stdlib bug, see Phase 1's exit criteria). This phase
  cannot start its ARM64 work until a Zig release fixes it. **Check this at Phase 8
  readiness, not during the phase** — if it is still broken, ARM64 is a ship-gate
  discussion, not an implementation task.
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
  first pixels (something concrete to show)? Recommendation: before Phase 1. **Now also
  relevant:** patch 0 already harvests wintty's pipe helpers, and both of its fixes are
  upstream bugs deblasis has plainly already hit.
- ~~Attribution/provenance convention~~ — **DECIDED at the Phase 0 retro: per-file header
  note** naming project + license at the harvested code, plus a commit-message line. See
  ADR 0004 "Amendments from Phase 0" §4. First instance: patch 0.
- **New:** patch 0 (`windows-build`) is upstreamable as-is and is the first thing to offer
  — ahead of `init-wtf16`. Both halves are upstream bugs, not port scaffolding.

- Immediately: libxev IOCP timer fix → mitchellh/libxev; contact deblasis re:
  collaboration/patch heritage.
- After Phase 4: `IControlCore` PR → microsoft/terminal.
- After Phase 3: infra patches (`init-wtf16`, CI) → ghostty-org/ghostty; keep
  `d3d11-backend`/`dwrite-discovery`/`termio-external` rebased and offer when upstream
  reopens the renderer door.
- Track upstream ghostty main monthly; rebase the series; note API breaks in the ledger.
