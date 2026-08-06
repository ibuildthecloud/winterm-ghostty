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
| 3 — Real terminal rendering | **complete** (gate passed 2026-08-02) | [0004](docs/sessions/0004-phase-3.md): **the harness is an interactive terminal.** `cmd.exe` runs, keyboard works, `dir` renders a correctly aligned scrolling listing — DirectWrite glyphs, CPU atlas, HLSL `cell_text` instanced draws, ConPTY. DirectWrite face + colour emoji (CBDT via `IDWriteFactory4`, full format set) + HLSL set (`fxc`→DXBC at build time) landed; all `phase1_skeleton` markers gone. Root cause of "nothing renders" was a **missing viewport** — `RSSetViewports` had no callers, and `Clear` ignores the viewport while draws are clipped entirely by it, so it presented as a healthy cleared surface with no D3D error. **Criterion 3 (forced WARP) MET**: `driver=warp feature_level=11_1`, output pixel-equivalent to hardware including CJK and colour emoji. DirectWrite discovery landed and verified live — `MapCharacters` + on-disk path resolution, with `IDWriteTextAnalysisSource` implemented as a COM callback; CJK/kana/colour-emoji all render. Two rendering bugs the user found by looking and no test covered: a missing viewport (`RSSetViewports` had no callers — `Clear` ignores it while draws are clipped by it, so it looked like a healthy cleared surface) and `offset_y` being baseline-relative rather than cell-bottom-relative, which put every glyph high by the descent. Both now have mutation-verified regression tests. **Criterion 1 MET**: PowerShell reaches a prompt with PSReadLine syntax-colouring live per keystroke, `Get-Process` tables align, `top` renders; JetBrains Mono ligatures shape (`->`→`→`, `<=>`→`⟺`) while a space-separated control line stays unligated, proving real HarfBuzz shaping; CJK/kana/colour emoji fall back correctly; **kitty keyboard protocol verified end to end** — `CSI ? u` → `ESC[?0u`, `CSI > 15 u` → `ESC[?15u`, then `a` reports as `ESC[97u`. Recorded in `docs/interactive-verification.md`. Testing it with `CSI > 1 u` alone is misleading — level 1 only disambiguates, so printable keys still send their plain byte. **Criterion 2 MET**: every vttest section visited except 11; sections 2, 6, 8, 9, 10 assessed for the first time and pass (6 now includes Secondary/Tertiary DA and DECREQTPARM); **no regressions vs wintty**. Section 7 (VT52) renders wrong but is **ConPTY's, not ours** — libghostty has no VT52 code at all and Windows Terminal on the same ConPTY path clamps out-of-range `ESC Y` identically. §6 records three instrumentation traps that each produced a retracted conclusion; the VT52 investigation added three more (escape sequences swallowed by `$( )` command substitution, VT52 state bleeding between un-exited probe arms, and an "out-of-range" column that wasn't because the terminal was wider than assumed). Open: occasional wrong character from the synthetic input driver, unattributed. |
| 4 — WT seam (IControlCore) | **complete** (gate passed 2026-08-03) | [0005](docs/sessions/0005-phase-4.md): **WT runs on an interface.** ~90 members + 27 events promoted from `ControlCore` to a new `IControlCore`; `ControlCore` is a marker class implementing it; `TermControl` holds the interface. Six of the seven `get_self` escapes replaced by IDL — the seventh (`TsfDataProvider::_getCore`) hands out WT's internal `Renderer*` and is the TSF coupling the ADR already scopes per-engine. Two escapes needed reshaping because their signatures were never projectable: `SearchResultRows` now returns distinct rows as `IVector<Int32>`, and the QuickFix viewport check became a single-lock `IsBufferRowInViewport` (kept as one predicate for **atomicity** — the original read both bounds under one lock. A first claim that `ScrollOffset`+`ViewHeight` was not equivalent was reasoned from source, never measured, and **retracted**: they agree at 21/21, 5/5 and 0/0 across main-at-bottom, main-scrolled-back and alt buffer. Now pinned by a test.) Per-profile `"engine"` wired end-to-end, `"cascadia"` only — and **verified in the running app**: `"engine": "ghostty"` warns and falls back rather than failing the settings load. That check also validates the positional `settingsLoadWarningsLabels` index, which the `static_assert` cannot (it checks size, not alignment). Tests: **291/291 pre-fork baseline → 295/295** after (4 added: the engine setting, two pinning `IsBufferRowInViewport`, one pinning `SearchResultRows` de-duplication). **Criterion 1 mostly verified**: builds and launches to a live `PowerShell` pane (title propagates through the interface), and the user confirmed on a connected session that **tabs, panes and the WT interface all work normally**. Still unverified: search scrollbar pips (the one path this phase deliberately changed), marks, and the Narrator a11y smoke. **DECISION-NEEDED**: `ControlInteractivity` still holds the concrete type (58 calls, 34 methods, mostly impl-level mouse/selection/UIA) — ADR 0001's "only invasive change" claim understates the work; this is a Phase 5 prerequisite. Also: `"engine"` is deliberately more permissive than every sibling enum setting, verified by mutation. |
| 5 — Ghostty pane MVP | **works: interactive ghostty pane in WT** | All five open questions resolved (see the phase's block below and `docs/phase-5-readiness.md`). **`ControlInteractivity` promotion done**: members on `IControlCore` (`4493f27d8`), then `_core` itself flipped to the interface (`bac77b78b`); the UIA cluster stays concrete behind `_cascadiaCore()`, which QIs for the `ControlCore` *class* interface — QI'ing for `IControlCore` would match every engine and hand the wrong type to `get_self`. WT tests 295/295, unchanged from the Phase 4 baseline. **`termio-external` done** (`d8f35ae8f`, patch 0023): `zig build test` 3089/58 skip/0 fail, both new tests mutation-verified. Built as decision A minus the ring — the parse runs on the caller's thread, because `ConptyConnection::_OutputThread` already overlaps its 128 KiB overlapped `ReadFile` with the previous `TerminalOutput.raise()`, so a ring would duplicate that pipelining for a thread and a copy per surface. **Proven end to end before any WinRT work**: `hwnd-host` with `GHOSTTY_HARNESS_EXTERNAL=1` owns the ConPTY, and the grid size reaches `CreatePseudoConsole` from libghostty's own `resize_pty_cb` (71x18, matching its 1002x584-at-14x32 arithmetic) while synthetic input round-trips — the title becomes `cmd.exe - dir` and back, which is the child reacting and its OSC reply coming back through the parser. Exec path unregressed. **`GhosttyControlCore` done** (`d3d0b6a27`): WT **launches on a ghostty profile and stays up**, with `OpenConsole.exe --headless --width 56 --height 18` + `cmd.exe` beneath it — a real ConPTY, sized through libghostty's own arithmetic. **Unverified: whether the pane draws, and whether typing reaches the shell** — WGC captures no frame on this session and taking foreground to synthesize keystrokes was not safe unattended, so both go to the human evaluation step. Two integration bugs found by running it, not reading it: `ghostty_init` overflowed the UI thread's 1 MB stack (engine now bootstraps on its own 16 MB-reserve thread), and `TsfDataProvider::_getCore` cast unconditionally — **`get_self` yields a non-null garbage pointer**, so the null check under it never fired; TSF now joins UIA as cascadia-only. A third bug made the first pane **blank**: `SwapChainChanged` carries the handle *in its args* (`TermControl` unboxes a `uint64_t` and never re-reads `SwapChainHandle()`), and it is the only place a normal startup binds the panel — so raising it with null args bound nothing at all. **Now verified by capture: a WT tab titled `ghostty test` showing `cmd.exe`'s banner and prompt, drawn by libghostty.** Still unverified: that typing reaches the shell (the window was not foreground, and synthesising keystrokes would have typed elsewhere). **Human-confirmed working**: correct rendering, correct glyph size, the profile's font and colours, and typing reaches the shell. Four more fixes past "it compiles", all found by running it: the blank pane (`SwapChainChanged` carries the handle *in its args*; raising it with null bound nothing, and that handler is the only place a normal startup binds the panel); DIPs vs physical pixels in `set_size`; **XAML scaling any swap chain bound to a `SwapChainPanel`** (patch 26 — libghostty drew 14px cells and 119 columns correctly, the compositor magnified 1.5x and cropped to ~80, reading as "huge font"; cascadia has always cancelled this with `SetMatrixTransform`, and libghostty's binding for it was added in Phase 2 and never called); and a config that was built but never applied (`ghostty_surface_update_config`). Settings translator **done** via new patch 25 `ghostty_config_set` — one function reusing the config-file parser. **Open**: perceived lag, unmeasured and deliberately not optimised against while both sides are Debug builds. Mouse/selection/search/marks remain Phase 6 stubs. **Repaint defect FIXED**: a ghostty pane stopped repainting partway through long output (terminal fine, screen stale; scrolling cured it, resize did not). Cause: libghostty schedules repaints through its  async, which **coalesces by design** (its own comment contrasts it with the non-coalescing ), so a notify landing after the renderer sampled state is folded into a wake that already finished — the last batch never reaches the screen. Measured: 80 notifies, 80 parser calls, <20 renderer wakes,  stopped entirely. Fixed by calling  (= , skips the redraw gate) after each batch — exactly what  does on , which is why **the harness masked this since Phase 1** and a XAML pane with no paint pump did not. Composition mode was correlation, not cause. Four premature conclusions preceded the counters. See [0006](docs/sessions/0006-phase-5.md) §4a. **Second sitting — regression cover, and one deliverable that was not there.** PLAN's "engine init failure → cascadia fallback" was claimed by two comments and implemented by nothing: `Initialize` returning false raises the error state and leaves the pane *dead*. It cannot be done from there — `TermControl` has already bound its events to the core it was handed — so the choice moved into the engine factory, which asks `GhosttyEngine::TryGet()` before committing (`b23fd99ac`). A surface failing later still reports rather than re-engining a session that may already have output. Ten tests added, **every one mutation-verified**: six pinning the settings translation (each rule came from a bug found by hand — font quoting, negative history, doubled padding, the palette), four on the factory including the fallback; `unitControl` 32→42, `unitSettingsModel` 159/159. The translation moved to its own translation unit to be testable at all — a pure function over `IControlSettings`, needing no engine, GPU or pty. New `scripts\smoke-harness.ps1` covers the host/libghostty seam that neither side's unit tests can see: non-ASCII output not crashing the process (**verified by removing patch 24's bootstrap and rebuilding — the check fails with the original `0xC0000005`**), the external round-trip, and output reaching the screen. **Stated plainly: the repaint freeze has no automated cover** — removing WT's post-write render leaves the pixel check passing, because the harness's own wakeup repaints anyway; that case stays item 1 of the new `docs/manual-validation.md`. **Close-confirmation resolved as met by construction**: `_ShouldWarnOnClose` keys off `confirmOnClose` and the tab/pane counts and never asks the core, so only the read-only dialog is engine-dependent — and that is implemented. **Criterion 3 — defterm met on both engines** (human at the machine, default terminal temporarily pointed at the dev build and restored). Verified by thread dump, not by looking at the window: one `ConptyConnection Output Thread` + one libghostty `renderer`/`io` pair + `GhosttyEngine::_tickLoop` in one process is ADR 0006 as a fact about a running process. **`defaultProfile` is the wrong lever** — a handoff matches the handed-off *commandline* to a profile (`_getProfileForCommandLine`), so `cmd.exe` resolves to Command Prompt and `defaultProfile` is never consulted; stock WT behaviour, not the fork's. **Criterion 3 was claimed met once before it was**, on a tab title and threads belonging to a different tab; a clean single-tab run showed zero libghostty surfaces. Retracted and re-established properly — see [0006](docs/sessions/0006-phase-5.md) §10.2. **Azure: not testable on this machine** (no account with Cloud Shell, confirmed with the user) — unmeetable rather than pending. **Input bug found and fixed** (`2a2f9e2f3`): `TrySendKeyEvent` passed the Win32 virtual key where ghostty wants the *native* keycode (the scan code, 0xE000-prefixed for extended keys) — the right value was already a parameter, discarded by `UNREFERENCED_PARAMETER(scanCode)`. Typing `cd` opened cmd's F9 prompt. It hid for the whole phase because printable text arrives correctly through the separate `SendCharEvent` path, so every keypress *also* fired a bogus key and "typing works" stayed true-looking. Fix ports the harness's `winkeys.c`, which had it right since Phase 3 — the correct implementation existed in this repo and was not consulted. |
| 6 — Interaction parity | **in progress** (5 of 6 criteria met 2026-08-06; IME is the one left) | All four open questions resolved from libghostty's API and source, not from the phase text's hopes — see [phase-6-readiness](docs/phase-6-readiness.md). **Clipboard: plain text only** (`ghostty_text_s` carries text and geometry, no attributes; styled copy is a tracked gap, not a blocker). **Search: drivable but degraded** — `Binding.zig` exposes `search`/`search_selection`/`navigate_search`/`start_search`/`end_search` through the same string-binding route Phase 5 used for `scroll_to_row`, and results arrive asynchronously as `SEARCH_TOTAL`/`SEARCH_SELECTED` where WT's `SearchResults` is synchronous; the needle is a plain `[]const u8`, so **no regex and no case folding**, and the human's decision is to **disable those toggles** rather than leave them inert. **Marks: prompt-level only** — `SemanticPrompt` is a `u2`, so `scrollToMark` ships and `SelectCommand`/`SelectOutput` stay stubbed; error pips are impossible because exit codes have nowhere to live. **Scope: nothing graduates** beyond what the engine supports today, on the Phase 5 evidence that every item needing a new libghostty entry point cost a patch and a rebuild cycle. Exit criteria rewritten to be checkable by observation, with an explicit criterion that the deferred list be written up — the old "documented diffs allowed" had no checklist attached and would have let an unimplemented feature pass as a diff. **Session [0007](docs/sessions/0007-phase-6.md), 2026-08-06 - the four open interaction items** (`docs/phase-6-worklist.md`), all found by using the pane rather than reading it, all done. **A drag now selects the characters cascadia would, from the same pixels** - one symptom, four defects. The load-bearing one was found only by measuring: WT hands the core selection *boundaries*, and the anchor arrives from `SetSelectionAnchor` on the first drag movement, *after* the direction is known - but the press was going out earlier, at `LeftClickOnTerminal`, carrying the click position **rounded**. ghostty latches its anchor on a press and will not re-latch, so the selection started a character late whenever the click landed in the right half of a character. **A single click now presses nothing**; the press moved to the anchor. **The press site's `std::round` looks load-bearing and is not** - the drag path re-anchors and discards it, which is what misled two earlier attempts (`e97ae8c4c`, reverted at `40a760907`); it is now its own test. Both engines' rules are measured against their running engines in **[selection-geometry](docs/selection-geometry.md)**: both are boundary models, differing only in how a pixel becomes a boundary (cascadia: pressed cell always whole, far end at the midpoint; ghostty: one 60%-of-cell threshold at both ends). **`clear_selection` is a real binding action** (patch 28) that ends the click gesture with the selection - needed by item 3's re-press, because a press within one cell width of the last is a double click to ghostty. **Settings cross as key and value** (`ghostty_config_set_kv`, patch 25 amended, replacing the line form): WT's default word delimiters reached the engine mangled and **nothing reported it** - the entry parsed, and diagnostics do not surface at all under `-Dapp-runtime=none`, so "no error was logged" is worth nothing as evidence here. A double click on `Corporation.` now returns `Corporation`. One escaping rule survives and belongs to the *field*, not the entry: `selection-word-chars` is parsed as a Zig string literal. **Triple click spans the full row** (`selection-trim-line`, patch 29) **and still copies only the content** - measured, since that was the regression to fear: 25 -> 70 cells highlighted, 26 characters copied. **Order changed** (4 before 3): item 3 was expected to be WT-side only and is not. **Item 2 shipped as a config option rather than a change of ghostty's default**, so it survives upstreaming. **`_mouseTo` has no padding term and that is load-bearing** - ghostty subtracts `padding_left` before taking the fraction across a cell; WT pins it to zero *by configuration*, and the harness had been measuring a geometry nobody ships until it pinned it too. **`zig build test` passing is not evidence that libghostty builds**: the module sets differ, and a missing export in `terminal/main.zig` passed the tests while failing the DLL. Suites: `zig build test` 3094/58 skip/0 fail; WT 54/159/55/51. `smoke-harness.ps1` 3 -> 6 checks. **Second sitting, same day - the phase's own criteria.** **Search works**: literal matches, a total, and next/previous. The design problem was the seam, not the searching - `IControlCore::Search` is synchronous while ghostty answers on its own thread and reports counts back as actions *after* the call returns. `Search()` starts the work and returns what it knows, saying "nothing yet" with a **negative total**, which `SearchBoxControl` already renders as "Searching...": the honest answer and the right-looking one turned out to be the same answer, where a zero would have claimed no matches for a search that had not run. `SearchResultsChanged` brings `TermControl` back round when the numbers land (it re-queries on `OutputIdle`, but a search typed into a quiet terminal produces no output to be idle after). **Regex and case toggles are disabled and unchecked, not ignored** - `SearchSupportsRegex`/`SearchSupportsCaseSensitivity` on `IControlCore`, cascadia true, ghostty false. Match pips are impossible (ghostty reports counts, not positions) and are documented rather than faked. **HTML copy verified, not merely wired**: the styled representation exists only in the `{mime, data}` array reaching the clipboard callback, so the harness now reads that callback - a mixed copy of a bold red-on-blue run returns `text/plain` *and* `text/html` carrying `color:`, `background-color:` and `font-weight: bold` on the styled run only. **`CopyOnSelect()` was a hard `false`** - a ghostty pane ignored the profile setting beside a cascadia pane that honoured it, invisible to every test because the only reader is a click path; the first sitting's report had claimed that criterion met. **A stub returning a plausible constant hides longer than one returning nothing.** **[documented-diffs](docs/documented-diffs.md)** written: 12 entries with stable IDs, each with cause and cost - issues *not* filed, this repo has no remote. **IME is the one criterion left and is a WT-side refactor first**: `IDataProvider::GetRenderer()` must become composition callbacks before a ghostty pane can register with TSF at all (WT's TSF dereferences that renderer unchecked), which would also remove ADR 0001's last `get_self` escape - deliberately not landed blind, since verifying it needs an installed CJK IME and a human. **`IControlCore` gained three members** for search; recorded as a decision for the retro (PROCESS rule 3 vs. a gate that had already decided the behaviour). Suites: WT 54/159/60/51; `smoke-harness.ps1` 3 -> 9 checks. **Third sitting - an hour of manual validation with the user, which found more than the other two put together: five findings, four defects, none reachable by anything automated here.** (1) A stray sliver at the pane's top-left on every rightward drag - not a rendering artifact but WT's *selection markers*, XAML drawn over the swapchain, placed from `SelectionInfo()` which this engine cannot fill in; my own regression from an hour earlier, where `ClearMarkers` should have been true. (2) **Saving a setting crashed the window** - pre-existing since Phase 5, `BackgroundImage()` on a null `IControlAppearance`, because cascadia's `UnfocusedAppearance()` falls back to the settings object and never returns null while ours returned the argument; trigger was *any profile without an unfocusedAppearance, any settings change, pane not focused*. Nothing had ever exercised a settings reload on a ghostty pane. (3) **Search counted from the wrong end** - ghostty's index 0 is the *newest* match and grows backwards in time, WT's status box means Nth-from-the-top, so `1/9` highlighted what cascadia called 9 and Enter walked the wrong way; both number and direction now convert, and the control asks for a first match so the box no longer reads `?/9`. (4) The `Searching...` flash was honest and unreadable; there is now a third answer beside "searching" and "no matches" - **leave the status alone** - which beat the stale-count compromise I had proposed. (5) **The cursor was ghostty's, not the profile's**: `cursorShape` was never in the translator, and fixing it exposed an unfocused pane always drawing a hollow block (**patch 30**, `cursor-style-unfocused`) and ghostty having four shapes to WT's six - I mapped two onto a plain underline and called them approximations, which they were not (**patch 31** adds double and thick underline cursors as real sprite glyphs, so all six map exactly). **`harness/pdbaddr` built to symbolize the crash**: WER gives a module and a fault offset, this machine has no debugger, and `0x7b5af9` was a function nobody would have guessed. **Standing rule, learned twice in one session: `zig build test` passing is NOT evidence that libghostty builds** - the test build compiles a module set that excludes the C API and some exports; always run `build-ghostty.ps1`. **Open gap: nothing here can see a pixel WT draws** - every selection check measures what ghostty selected, and the marker bug was XAML over the swapchain. Final: WT 54/159/62/51, `zig build test` 3096/58 skip/0 fail, smoke 9/9, 31 patches. |
| — | — | **Stack reserve, 2026-08-04:** `ghostty_init` needs more stack than the 1 MB MSVC gives a main thread. First seen in Phase 0 (the harness links `/STACK:16MB`); seen again the first time `"engine": "ghostty"` was launched in WT, as `WindowsTerminal.exe` faulting in `ghostty-internal.dll` with `0xC00000FD` (STATUS_STACK_OVERFLOW) before any pane appeared. `GhosttyEngine` now brings libghostty up on its own thread, reserved 16 MB, rather than on the UI thread — and rather than raising WT's own reserve, which would impose an engine's requirement on the whole app. Zig-built code assumes Zig's 16 MiB default, so MSVC's 1 MB is the outlier. **Any future call into libghostty from a WT-owned thread has to be checked against this.** |
| — | — | **Cross-cutting fix, 2026-08-04 (patch 0024, `1fe550675`):** `libghostty.dll` never ran its own C++ static initializers, so **any non-ASCII byte of output crashed the process** (AV reading `0x78` — a vtable slot off a null vptr — in simdutf, whose dispatch singleton was never constructed). Zig's DLL entry does not run the `.CRT$XI*`/`.CRT$XC*` tables and upstream's `DllMain` only brought up vcrt/acrt; those tables live in our image, not the CRT. Fixed by following MSVC's own sequence with the static CRT's own markers and helpers. **`__scrt_dllmain_before_initialize_c` is the load-bearing step** — it initializes the module's onexit tables, and the first C++ initializer (`initlocks`) calls `atexit`, so without it the CRT reallocs a garbage pointer and `LoadLibrary` dies with heap corruption. Found from a user report (`wsl aptitude`); the real trigger is any non-ASCII. Two hypotheses reasoned from source were wrong before `cdb` settled it in minutes. See `docs/research/crt-static-init-windows.md`, which also flags an **unreconciled Phase 3 record** (its CJK fixture exercises the crashing path yet passed in August — likely build-mode dependent, unproven). |
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

Re-evaluate — **answered at the gate (2026-08-02)**:
- ~~Renderer perf acceptable enough to defer Phase 7 polish?~~ **Yes, defer.** Measured
  14.9 MB/s vs Windows Terminal's 42.8 MB/s on the same corpus and transport — **2.9x
  slower**. Accepted as a Phase 7 item rather than a Phase 3 blocker; the candidates are
  already recorded in `docs/perf/throughput.md` (`Present(sync_interval=1)` with no
  frame-latency wait object, no damage tracking, redraw-on-`WM_PAINT`). Phase 7 must reuse
  the identical script and corpus or its targets are not comparable.
- ~~COLRv1 emoji — fix now or ship-gate later?~~ **Later.** DirectWrite renders the COLR
  v0 layer set, which is parity with Windows Terminal's AtlasEngine, so there is no user-
  visible gap to close. `COLR_PAINT_TREE` via `IDWriteFactory8` remains a separable upgrade
  that would put us *ahead* of WT rather than level with it.

Carried into Phase 7 (not blocking the gate): the occasional wrong character from the
synthetic input driver (`7`→`^_`, `0`→`^[`) is unattributed — plausibly `vt.ps1` outrunning
the message pump, but a terminal delivering the wrong key would be serious. Reproduce
against `stty raw -echo; cat -v` to take vttest out of the loop.

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

Open questions — **all resolved at the Phase 3→4 readiness step (2026-08-02)**:
- ~~ADRs 0001 and 0007 flipped to `Accepted`?~~ **Both Accepted 2026-08-02.** ADR 0001 also
  gained an enumerated escape table: there are **seven** `get_self<ControlCore>` call sites
  in `TermControl.cpp`, not six. Six are straightforward IDL promotions; the seventh
  (`TsfDataProvider::_getCore()`, line 256) exists only to reach `core->GetRenderer()` and
  hand out WT's internal `Renderer*`, which a libghostty engine has no equivalent for. It
  is the TSF/IME coupling ADR 0001 already lists under Consequences — reimplemented per
  engine, not promoted. Phase 4 leaves cascadia's behaviour there unchanged.
- ~~**Which WT test suites are runnable locally?**~~ **Answered empirically.** The Phase 0
  build left the conhost-side suites built but the cascadia ones absent; all four cascadia
  unit-test projects now build (`UnitTests_TerminalCore`, `UnitTests_SettingsModel`,
  `UnitTests_Control`, `ut_app`). Baseline recorded in the Phase 4 session report. Two
  traps found: `nuget restore` needs `-SolutionDirectory` unless invoked from the repo
  root, and `Invoke-OpenConsoleTests` with no `-Test` runs *every* unit suite in one
  `te.exe` and **hangs partway through the conhost `ScreenBufferTests`** — run the suites
  individually with a timeout. The conhost/UIA/feature suites are out of scope for this
  phase: an `IControlCore` promotion cannot reach them.
- ~~Interface naming/shape?~~ **Single `IControlCore` carrying members *and* events,
  alongside the existing `ICoreState`** — `runtimeclass ControlCore : IControlCore,
  ICoreState`. `ICoreState` is already a WinRT `interface` that `ControlCore` implements,
  so this follows the codebase's own precedent. Splitting the 27 events onto an
  `IControlCoreEvents` was rejected (second QI; complicates `TermControl`'s revoker
  plumbing, which is written against a single object). Recorded in ADR 0001.
- ~~Fork base?~~ **Stay on the Phase-0 pin `ca7996296`.** The `terminal/` clone is already
  checked out there and is only two days older than this readiness step, so advancing buys
  nothing and costs a re-baseline.

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
- **Explicitly out of scope:** screen-reader support on ghostty panes. `AttachUiaEngine`/
  `DetachUiaEngine`/`GetRenderData` hand out pointers to cascadia's own renderer objects, so
  they stay on the concrete type and UIA remains cascadia-only until Phase 8 (which harvests
  winghostty's MIT `win32_uia/`). Cascadia panes are unaffected, and since `engine` is
  per-profile with cascadia the default, a Narrator user simply does not opt in. Stated here
  so it is a known limitation rather than a discovery.

Open questions — **resolved at the Phase 4→5 readiness step (2026-08-03)**; full
research in `docs/phase-5-readiness.md`:
- ~~ADR 0006 flipped to `Accepted`?~~ **Accepted 2026-08-03.**
- ~~**`termio-external` backpressure semantics**~~ — **DECIDED: block the producer.**
  ghostty's own exec backend already answers this: its gather stage blocks when the ring is
  full, and the code says why — *"exactly when we should stop reading and let the kernel
  queue exert backpressure on the child"* (`Exec.zig:1540`). `termio-external` does the
  same, with the embedder's calling thread playing the gather role. Verified safe rather
  than assumed: `TerminalOutput` is raised on a dedicated `CreateThread` output thread, not
  the UI thread (`ConptyConnection.cpp:458`), and WT's own comment notes the raise "may take
  a while (relatively speaking)". **Contract:** the handler must hold no WT-side lock and
  must not wait on the dispatcher while calling in. Note PLAN's original framing was
  slightly off — `renderer_state.yieldToDemand` is a parse/render *fairness hand-off*, not
  flow control, so it is not the mechanism to model this on.
- ~~UTF-16→UTF-8 surrogate-pair buffering?~~ **The state machine already exists in WT:**
  `til::u16state` + the stateful `til::u16u8` overload (`src/inc/til/u8u16convert.h`). Hold
  one per `GhosttyControlCore`. With `ConptyConnection` a split pair should never arrive
  (its `til::u8state` buffers incomplete UTF-8, so raises carry whole codepoints), but
  `ITerminalConnection` has three implementations and `Azure` gives no such guarantee — use
  it regardless. No new code.
- ~~Threading contract~~ — drafted in the readiness doc; the marshalling-required rows are
  the ghostty action callbacks (`SET_TITLE`, `COLOR_CHANGE`, `PWD`, `PROGRESS_REPORT`, bell)
  and `swap_chain_changed`. To be confirmed against the C API during implementation.
- ~~Settings translator scope~~ — **CONFIRMED 2026-08-03: font, size, scheme, scrollback,
  padding.** Explicitly out until Phase 6: opacity/acrylic, background image, cursor
  shape/colour, selection colours, bell style, and every `experimental.*` field.

**Prerequisite carried from Phase 4:** `ControlInteractivity` must be interface-typed before
a ghostty pane can receive input — it holds the concrete `ControlCore` and makes 58 calls
across 34 mostly impl-level methods. Sequenced first, ahead of `termio-external`.

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

Open questions - **all resolved at the Phase 5-6 readiness step (2026-08-05)**, from
libghostty's API and source rather than from this phase's original hopes. Evidence and
reasoning in `docs/phase-6-readiness.md`.

- **Clipboard fidelity: plain and HTML; RTF is the gap.** Read-back
  (`ghostty_surface_read_selection`/`read_text`) returns `ghostty_text_s` — text and
  geometry, no attributes — but *copying is not read-back*. The `copy_to_clipboard` binding
  action takes `plain`/`vt`/`html`/`mixed`, and the result arrives through
  `write_clipboard_cb` as an **array** of `{mime, data}` representations, which is the shape
  WT needs to put plain and HTML on the clipboard together. So **HTML copy is in scope**
  (it is what the engine supports, and Phase 5 already wired that callback). **RTF is the
  tracked gap**: ghostty offers no RTF. *This corrects an earlier reading of this question
  that concluded no styled copy was possible — see `docs/phase-6-readiness.md` Q1.*
- **Search: drivable, literal and case-sensitive only.** `Binding.zig` provides `search`,
  `search_selection`, `navigate_search`, `start_search`, `end_search`, so WT's search box
  can drive it via `ghostty_surface_binding_action` - the `scroll_to_row` route. Results
  arrive asynchronously as `SEARCH_TOTAL`/`SEARCH_SELECTED` actions, where WT's
  `SearchResults` is synchronous; design for that. The needle is a plain `[]const u8`:
  **no regex, no case folding.** **Decision: disable the regex and case toggles on a
  ghostty pane** - a toggle that silently does nothing would misrepresent the results.
  Patching libghostty for search options is a tracked follow-up, not this phase.
- **Marks: prompt-level only.** `SemanticPrompt` is a `u2` (`none`/`prompt`/
  `prompt_continuation`), so ghostty records where prompts are and nothing else. Ship
  prompt-level `scrollToMark`. `SelectCommand`/`SelectOutput` **stay stubbed**, and
  scrollbar error pips are impossible (exit codes have nowhere to live). Widening
  `SemanticPrompt` touches row packing and wants its own ADR.
- **Scope: nothing graduates beyond what the engine already supports.** In scope:
  selection + copy-on-select, search (degraded as above), prompt-level `scrollToMark`,
  `ReadEntireBuffer` export, IME. Deferred with a documented diff: hyperlinks (no link
  read-back in the C API), `SelectCommand`/`SelectOutput`, completions, quick fixes,
  persistence, win32-input-mode parity. The Phase 5 learning behind this: every item
  needing a new libghostty entry point cost a patch and a rebuild cycle, while everything
  reachable through an existing binding action or callback was cheap.

Exit criteria:
- [ ] Selection works by mouse and keyboard on a ghostty pane, `HasSelection`/`SelectedText`
      are honest, and copy-on-select behaves as it does on cascadia.
- [ ] Copy produces correct plain text, including a multi-line and a wide-character
      selection, and **HTML copy carries colours and styles**. RTF is **out of scope** and
      reported as a known gap.
- [ ] The search box drives ghostty search: a literal match navigates forwards and
      backwards, the total is reported, and the regex/case toggles are **visibly disabled**
      rather than inert.
- [ ] `scrollToMark` moves between prompts. `SelectCommand`/`SelectOutput` remain stubbed
      and are listed as documented diffs.
- [ ] IME verified with at least one CJK language end-to-end, including candidate-window
      placement.
- [ ] The deferred list above is written up as documented diffs, each with an issue filed -
      "documented diffs allowed" must not quietly absorb an unimplemented feature.

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
