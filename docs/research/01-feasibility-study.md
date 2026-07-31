# libghostty inside Windows Terminal — Feasibility Study & Plan

*Research date: 2026-07-31. Based on shallow clones of `microsoft/terminal` (main) and
`ghostty-org/ghostty` (HEAD `4d605bf`, 2026-07-30), plus web research. Nobody has attempted
this combination before; all findings below are from direct source inspection.*

## Verdict

**Technically feasible, and the architecture on both sides is surprisingly cooperative — but
the single thing you asked for (Ghostty's *rendering* powering the terminal surface) is the
one piece of libghostty that does not exist on Windows today.** The realistic path is a
two-stage plan:

- **Stage 1 (achievable now, ~months):** embed **libghostty-vt** — Ghostty's parser, buffer,
  scrollback, selection, search, and input encoding, which is Windows-clean and MSVC-CI-tested
  *today* — as Windows Terminal's terminal engine, while keeping WT's AtlasEngine renderer.
  You get Ghostty's VT correctness and feature coverage (Kitty keyboard/graphics protocol,
  etc.) with native Windows text rendering.
- **Stage 2 (the full experience, requires becoming a Ghostty contributor):** write the
  missing **D3D11 renderer backend and Win32 platform support inside Ghostty** (upstream has
  left explicit, documented seams for exactly this), then swap the full
  `ghostty_surface_*` engine into WT behind the same interface built in Stage 1.

One expectation to calibrate: the *performance* gap is smaller than Ghostty's reputation
suggests. WT's AtlasEngine (post-refterm rewrite) is a competent D3D11 glyph-atlas renderer,
and there is no credible Ghostty-vs-WT benchmark because Ghostty doesn't run on Windows; on
Windows, ConPTY overhead is a shared bottleneck for every terminal. The concrete win is
**VT correctness and feature coverage**, plus Ghostty's buffer/reflow/selection behavior —
which is still a very real win.

---

## Part 1 — What the research found

### 1.1 Windows Terminal's shell/engine seam is nearly interface-shaped already

Layering (bottom → top): `TextBuffer` → VT parser/dispatch → `TerminalCore/Terminal` →
`Renderer` + `AtlasEngine` (D3D11) → **`ControlCore`** → `ControlInteractivity` →
`TermControl` (XAML) → `TerminalApp` (tabs/panes/profiles) → `WindowsTerminal` (win32 host).

Key facts:

- **`ControlCore` is the engine façade.** It is the only place where buffer + VT + renderer +
  connection are wired together (`src/cascadia/TerminalControl/ControlCore.{h,cpp,idl}`).
  Its WinRT IDL (~225 lines + `ICoreState.idl`) is the complete contract the shell consumes:
  input injection, scroll state, selection, search, marks, hyperlinks, title/color events,
  clipboard, buffer export. It was *designed* to be process-crossable (the unshipped
  "Process Model 2.0" spec in `doc/specs/#5000`), so the boundary is clean.
- **Rendering hand-off is literally one `HANDLE`.** AtlasEngine creates a DXGI *composition
  swap chain*, and the shared handle is passed up through `SwapChainChanged` into XAML's
  `ISwapChainPanelNative2::SetSwapChainHandle`. No D3D device is shared with XAML. Any engine
  that can produce a composition swap-chain handle drops in unchanged.
- **The connection layer is a pure byte pipe.** `ITerminalConnection.idl` is 33 lines:
  `WriteInput`, `Resize`, `Close`, `TerminalOutput` event. ConPTY lives entirely behind it.
  A replacement engine consumes it as-is. (Three small leaks: upper layers `try_as` the
  concrete `ConptyConnection` for `ReparentWindow`, `ShowHide`, `ClearBuffer`.)
- **Not yet pluggable, but cheaply made so.** `TermControl` holds the *concrete* `ControlCore`
  and calls `get_self<ControlCore>` in 6 places. Promoting `ControlCore.idl` + `ICoreState.idl`
  into an `IControlCore` interface and plugging those 6 leaks is the only invasive change to
  existing WT code — mechanical MIDL work.
- **Precedent for a C-ABI engine exists in-tree.** `HwndTerminal.hpp` exports a flat
  `extern "C"` API (`CreateTerminal`, `TerminalSendOutput`, `TerminalSendKeyEvent`, …)
  consumed from C# by the WPF control — the same shape as `ghostty_surface_*`.
- **The renderer interface is NOT the right cut point.** `IRenderEngine` is a *cell-pull paint
  sink* fed by WT's own `TextBuffer` via `IRenderData` (which returns `TextBuffer&` by
  reference). libghostty owns its own buffer, so it cannot sit behind `IRenderEngine`; the
  replacement point is `ControlCore` and everything beneath it. (Inversely, `IRenderEngine`'s
  paint-sink shape is exactly what a libghostty-vt bridge can *feed* — see Stage 1.)
- **The two genuinely hard couplings:** (a) **UIA accessibility** — `TermControlUiaProvider`
  implements `ITextProvider`/`ITextRangeProvider` directly over `TextBuffer`; a replacement
  engine must reimplement it over its own buffer or ship without screen-reader support.
  (b) **TSF/IME** — the TSF provider hands composition preview text into
  `IRenderData::tsfPreview`, a WT-renderer type; libghostty has its own preedit API
  (`ghostty_surface_preedit`) which maps well, but the plumbing must be rebuilt.
- **Packaging constraint:** `TerminalControlLib` builds with `/APPCONTAINER` and MSIX API-set
  validation. A Zig-produced DLL must restrict itself to the app-container-approved API
  surface (or the engine gets hosted outside the packaged component). Zig must emit
  MSVC-ABI COFF for x64 *and* ARM64.

### 1.2 libghostty has far more Windows support than its reputation — except rendering

The tree already contains: a working **ConPTY backend** (`src/pty.zig` `WindowsPty` with
`CreatePseudoConsole`, `src/Command.zig` `startWindows`, a Windows PTY read thread), a
Windows **font-discovery** backend (`freetype_windows`, scanning `C:\Windows\Fonts`),
MSVC ABI handling in `build.zig` (defaults to `-target *-windows-msvc`, names artifacts
`ghostty-internal.dll` / `-static.lib`), and CI jobs that build libghostty and run its tests
**on Windows runners with MSVC**.

What's missing, ranked by severity:

1. **No GPU backend works on Windows for the embedded runtime** *(fatal; the bulk of Stage 2).*
   Metal is Darwin-only; the OpenGL backend is a compile-only stub for `apprt.embedded`
   ("libghostty is strictly broken for rendering on this platforms" — `src/renderer/OpenGL.zig`)
   and requires desktop GL 4.3, which rules out ANGLE and the RDP/software-rendering matrix WT
   must support. **The good news:** `src/renderer/generic.zig` is a clean
   `Renderer(comptime GraphicsAPI)` abstraction with a ~15-method contract already proven
   across two very different APIs (Metal, OpenGL), and shaders go through
   glslang → SPIRV-Cross, which supports HLSL output. A `src/renderer/D3D11.zig` backend
   mirroring `src/renderer/metal/` is architecturally straightforward, just large.
2. **No Win32 platform tag in the embedding API** *(fatal; small-medium).* The
   `Platform` union in `src/apprt/embedded.zig` is `{ macos, ios }`; `ghostty_surface_new`
   returns `UnsupportedPlatform` on Windows by construction. Needs a `win32` variant whose
   payload is designed together with the D3D backend — for WT specifically, the right payload
   is "create a composition swap chain and expose its shared handle," not an HWND.
3. **`ghostty_init` hard-fails on Windows** *(fatal but trivial).* `src/global.zig` returns
   `error.UnsupportedOSForCApi` because the C entry point takes `char**` argv; the code
   comment prescribes the WTF-16 fix.
4. **No DirectWrite font backend** *(high; quality parity).* FreeType rasterization ≠ DWrite
   rendering (different hinting/gamma from every other Windows app), no system font-fallback
   chain, linear font-directory scans. Upstream's own comment: "A future DirectWrite backend
   can replace this if needed." Shaping is HarfBuzz either way, which is fine.
5. **PTY/event-loop maturity gaps** *(medium; validation).* Windows read path is a naive
   1 KiB blocking loop vs the tuned POSIX pipeline; `getProcessInfo` returns null (breaks
   foreground-process queries → WT's close-confirmation); libxev's IOCP backend builds and
   passes tests but is unproven under load; no PowerShell/cmd shell-integration scripts
   (OSC 7 pwd, prompt marks).

Also important: **the embedder does not drive rendering.** libghostty owns a renderer thread,
frame pacing, cursor blink, and damage tracking; the host only forwards input, resize, focus,
and handles ~68 `GHOSTTY_ACTION_*` callbacks (new tab/split, set title, bell, pwd, clipboard,
progress, scrollbar state…). That action list maps almost one-to-one onto the events
`ControlCore` already raises — the two designs converge on the same shape. There is even a
designed escape hatch (`must_draw_from_app_thread`) for graphics APIs that need UI-thread
submission.

### 1.3 libghostty-vt is the piece that is real today

`libghostty-vt` — parser, terminal state, screen/scrollback pages, selection, search, key/mouse
*encoding* — is shipped, documented, zero-dependency (not even libc; OS services are injected
as function pointers), explicitly supports Windows, builds under MSVC in CI with CMake
examples, and crucially exposes **`include/ghostty/vt/render.h`**: an incremental,
dirty-region-aware render-state API (row iterators, cell cursors, color resolution)
purpose-built for a host-owned renderer. Caveat: the API is explicitly **alpha** — Mitchell
has promised a tagged release "within 6 months" of Sep 2025, but none exists as of July 2026,
so vendor a pinned commit and expect breakage on updates.

### 1.4 The ecosystem context (why this is a good moment)

- Official Ghostty-for-Windows is uncommitted; earliest exploration "Nov/Dec 2026" per
  maintainer relay, explicitly not a promise. Upstream's stated requirements for any Windows
  port: **Direct3D renderer, no GTK/Qt, minimal C++, C# shell preferred** — which is,
  almost verbatim, the Windows Terminal architecture.
- Three unofficial projects prove the core runs on Windows: **winghostty** (Zig+Win32 fork,
  OpenGL), **wintty** (C# WinUI 3 shell over `libghostty.dll` with a **DX12 renderer** —
  proof the Zig-DLL-behind-a-.NET-shell shape works), and **phantty** (libghostty-vt +
  DirectWrite discovery + FreeType). Nobody has touched Windows Terminal itself.
- WT has no extension mechanism for engines/renderers (long-open request, microsoft/terminal
  #4000) — this is necessarily a **fork** of WT, though step 1 below is a plausible upstream PR.

---

## Part 2 — The plan

### Phase 0 — De-risking spike (1–2 weeks)

Goal: prove the two riskiest unknowns before committing.

1. Build `libghostty-vt` on Windows (`zig build -Demit-lib-vt -Dtarget=x86_64-windows-msvc`),
   run the `example/c-vt-render` / `c-vt-stream` CMake examples. (CI says this works; verify
   locally, including ARM64.)
2. Throwaway harness: feed ConPTY output from a real shell into `ghostty_terminal_vt_write`,
   walk `render.h` state, dump to console. Measures parse throughput and validates the
   render-state API shape against what AtlasEngine needs.
3. On the WT side: confirm a foreign MSVC-ABI static lib/DLL links into
   `TerminalControlLib` and survives the packaged-build API-set validation (or determine the
   engine DLL must live outside the appcontainer surface).

### Phase 1 — Make Windows Terminal engine-pluggable (upstreamable)

Fork `microsoft/terminal`. Promote `ControlCore.idl` + `ICoreState.idl` into an
**`IControlCore`** WinRT interface; change `TermControl` and `ControlInteractivity` to hold
the interface; eliminate the 6 `get_self<ControlCore>` escapes by adding IDL for
`SearchResultRows`, the QuickFix viewport query, `PersistTo`/`RestoreFromPath`/
`UpdateQuickFixes`/`PreviewInput`. Existing `ControlCore` becomes the first implementation;
everything above it (tabs, panes, profiles, settings, search box, context menus, window
management) is untouched.

This step has standalone value and aligns with WT's own shelved Process-Model-2.0 design —
worth attempting as an upstream PR, which would drastically reduce long-term fork burden.

### Phase 2 — Stage 1 engine: libghostty-vt core + AtlasEngine rendering

Implement **`GhosttyVtCore : IControlCore`** (C++/WinRT wrapping the `ghostty/vt.h` C API):

- **Terminal state:** `ghostty_terminal_*` replaces `TerminalCore/Terminal` + WT's parser +
  `TextBuffer`. ConPTY bytes flow `ITerminalConnection.TerminalOutput` →
  `ghostty_terminal_vt_write`; responses flow back via `WriteInput`. Input encoding uses
  ghostty-vt's key/mouse/paste encoders (this alone brings the Kitty keyboard protocol).
- **Rendering bridge:** a small render loop walks `render.h`'s dirty-row iterators and feeds
  **AtlasEngine's existing `IRenderEngine` paint-sink methods** (`PaintBufferLine`,
  `PaintCursor`, invalidation) — AtlasEngine doesn't need `TextBuffer`, it needs clusters and
  attributes, which the render-state API provides. Text stays DirectWrite-rendered, so Windows
  font quality, fallback, and the RDP/software path are all preserved for free.
- **Shell features:** selection/search/marks/hyperlinks implemented over ghostty-vt's
  selection, search, and OSC modules, surfaced through the `IControlCore` members mapped in
  the seam inventory (title, scroll state, `SelectedText`, `SearchResults`, `ScrollMarks`,
  hovered-hyperlink trio, `ReadEntireBuffer`, taskbar progress…).
- **Stub initially:** shell-driven completions, quick fixes, buffer persistence, retro shader.
- **Hard items to schedule explicitly:** UIA `ITextRangeProvider` over the ghostty page-list
  (or a degraded-a11y flag), and TSF composition routed through a preview overlay instead of
  `IRenderData::tsfPreview`.

**Deliverable:** Windows Terminal UX, DirectWrite text, Ghostty's VT engine — Kitty
keyboard/graphics, Ghostty's reflow/scrollback/selection semantics. This is a shippable,
independently valuable milestone, and it forces every interface decision Stage 2 needs.

### Phase 3 — Stage 2 upstream work: make libghostty render on Windows

Contribute to `ghostty-org/ghostty` (maintainers have left explicit invitations at each seam):

1. `ghostty_init` WTF-16 argv fix (days).
2. `win32` platform tag in `apprt/embedded.zig` + `ghostty_platform_win32_s` in the header.
   For WT, design the payload as "backend creates a DXGI **composition** swap chain; embedder
   retrieves its shared handle" — AtlasEngine proves this exact pattern works under XAML.
   Include an HWND variant for non-XAML embedders (this is also what upstream's own future
   Windows app needs, which is the argument for accepting it).
3. **`src/renderer/D3D11.zig`** implementing the `generic.zig` `GraphicsAPI` contract
   (~15 methods: Target/Frame/RenderPass/Pipeline/Buffer/Texture/Sampler + shaders), shader
   translation via the existing glslang → SPIRV-Cross pipeline with HLSL output, WARP as the
   software fallback (this is how the GL-4.3/RDP problem gets solved properly). Use the
   `must_draw_from_app_thread` hook if device/swapchain rules require it. This is the
   largest single work item of the whole project.
4. Optional but ship-quality: a `directwrite` font backend (discovery + rasterization,
   HarfBuzz retained for shaping), paralleling the existing `coretext` backend. Without it,
   text is FreeType-rendered and will look subtly non-native.
5. Hardening: Windows PTY read-path throughput, `getProcessInfo` (foreground process for
   close-confirmation), libxev IOCP under load, PowerShell/cmd shell-integration scripts.

### Phase 4 — Stage 2 integration: full `GhosttyControlCore`

Swap in a second `IControlCore` implementation wrapping the full `ghostty_app_t` /
`ghostty_surface_t` API: runtime callbacks (`wakeup_cb` → dispatcher-queued
`ghostty_app_tick`, clipboard callbacks → WT clipboard events), the ~68-action
`GHOSTTY_ACTION_*` switch mapped onto `IControlCore` events (the macOS
`Ghostty.Action.swift` is the template — new-tab/split actions route to WT's pane model,
`SET_TITLE`/`PWD`/`PROGRESS_REPORT`/`SCROLLBAR` map to existing events), IME via
`ghostty_surface_preedit`/`ime_point` wired to WT's TSF handler, settings via a
`IControlSettings` → `ghostty_config_t` translator. Keep Stage 1's core as the fallback
engine behind a profile setting (`"engine": "ghostty-vt" | "ghostty" | "cascadia"`).

### Sequencing note

Phases 1–2 and Phase 3 are independent and can run in parallel; Phase 4 needs both. If the
goal is "Ghostty experience on Windows" more than "inside WT specifically," also weigh
contributing the D3D backend upstream and using **wintty** (whose C#-shell/DX12 architecture
matches upstream's stated preference) — the upstream renderer work is identical either way.

## Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| libghostty C API is alpha; upstream migrating off GitHub | High | Vendor pinned commit; isolate behind `IControlCore`; keep cascadia engine as fallback |
| D3D11 backend scope creep | High | It's Phase 3, not the gate for shipping Stage 1 |
| UIA/screen-reader parity | High | Explicit work item; degraded-a11y flag only for prototypes |
| MSIX `/APPCONTAINER` API-set validation of Zig DLL | Medium | Phase 0 spike; fallback is hosting the engine DLL outside the packaged component |
| FreeType text looks non-native (Stage 2) | Medium | DirectWrite backend (Phase 3.4); Stage 1 sidesteps entirely |
| Fork maintenance vs microsoft/terminal | Medium | Land Phase 1 (`IControlCore`) upstream — it matches their own Process Model 2.0 spec |
| ConPTY caps throughput regardless of engine | Accept | The win is correctness/features, not raw throughput |

## Rough effort

- Phase 0: 1–2 weeks. Phase 1: 2–4 weeks. Phase 2: 2–4 months to daily-drivable
  (a11y/IME polish is the long tail). Phase 3: 3–6+ months of upstream-quality Zig/D3D work.
  Phase 4: 1–2 months once Phase 3 lands. One experienced person can carry Stage 1 alone;
  Stage 2 is a serious open-source campaign.

## Key source references

- WT seam: `src/cascadia/TerminalControl/{ControlCore,ControlInteractivity,TermControl}.{idl,h,cpp}`,
  `src/cascadia/TerminalConnection/ITerminalConnection.idl`, `HwndTerminal.hpp`,
  `doc/specs/#5000 - Process Model 2.0/`
- Ghostty seams: `include/ghostty.h`, `include/ghostty/vt/render.h`, `src/apprt/embedded.zig`
  (`Platform` union, `CAPI`), `src/renderer/generic.zig` (`GraphicsAPI` contract),
  `src/renderer/OpenGL.zig:162` (embedded stub), `src/font/backend.zig`, `src/pty.zig`,
  `src/global.zig:68` (C-API Windows gate), `macos/Sources/Ghostty/Ghostty.Action.swift`
- Context: mitchellh.com/writing/libghostty-is-coming · ghostty discussions #2563, #12290 ·
  microsoft/terminal #4000 · wintty (deblasis/wintty) · winghostty · phantty
