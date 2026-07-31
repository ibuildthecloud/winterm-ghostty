# The Ideal libghostty Windows Backend + Windows Terminal Integration

*A synthesis design. Sources: upstream ghostty `4d605bf`, wintty (DX12 fork), deblasis
upstream PR #11886 (D3D11), winghostty (WGL port), phantty (vt + DirectWrite), zcg/ghostty-win,
marler8997/mite, and microsoft/terminal's AtlasEngine. Nothing is adopted whole; every
decision below names what it takes and what it deliberately rejects.*

---

## Design principles

1. **Upstream-shaped from day one.** Every ghostty-side component implements a contract that
   already exists upstream (`generic.zig`'s `GraphicsAPI`, `font/backend.zig`'s `Backend`,
   `apprt/embedded.zig`'s `Platform`). Upstream has stated exactly what it wants — "a
   Direct3D-based renderer with a similar performance and feature set as our Metal and OpenGL
   backends," submitted as piecemeal PRs — and named deblasis's PR series as the model. Build
   the thing they described, as the patch series they asked for, even while it lives in a fork.
2. **The embedded C API is the product.** winghostty's fatal architectural mistake (for our
   purposes) was deleting `apprt/embedded.zig` and `ghostty.h` to build an exe. Everything
   here targets `libghostty.dll`; the standalone-window path is a test harness, not the goal.
3. **Windows Terminal's compatibility matrix is a hard requirement.** RDP sessions, WARP
   software rendering, hybrid-GPU laptops, device removal, ARM64. This single constraint
   drives the D3D11-over-D3D12 and D3D11-over-OpenGL decisions below.
4. **Own the renderer thread; don't own the UI thread.** Keep ghostty's threaded rendering
   (D3D11 is free-threaded, unlike WGL) — this is where ghostty's latency reputation comes
   from. The `must_draw_from_app_thread` escape hatch stays available but unused.

---

## Part A — The ghostty-side backend (the fork/patch-series against upstream)

### A1. Graphics API: **D3D11, not D3D12** (feature level 11_0)

Take: deblasis PR #11886 (~2.4k LOC D3D11 infrastructure — the abandoned-upstream base to
revive) restructured to the internal architecture wintty's DX12 backend proved out.
Reject: wintty's choice of D3D12 itself, and winghostty's WGL/OpenGL path.

Why D3D11:
- **WARP.** `D3D_DRIVER_TYPE_WARP` gives a fully-featured, surprisingly fast software
  fallback — this is how AtlasEngine survives RDP and driverless machines, and it is nearly
  free on D3D11. D3D12's WARP story is worse and manual. winghostty's own error dialog
  ("This build does not include a DirectX or ANGLE fallback renderer") is the cautionary tale.
- A terminal cell grid is nowhere near D3D12's win conditions (no bindless churn, tiny
  descriptor count, one pipeline family). D3D12 buys wintty nothing but code: its 8.7k LOC
  would be roughly half that on D3D11 (no explicit fences/allocators/barriers/heaps).
- AtlasEngine — the best-tuned Windows terminal renderer in existence — chose D3D11
  deliberately. Upstream is on record as undecided between 11 and 12; 11 is the easier merge.

Structure (mirroring `src/renderer/metal/` layout, as wintty did):

```
src/renderer/D3D11.zig            -- GraphicsAPI impl (~15 methods)
src/renderer/d3d11/
  device.zig                      -- device/context/queue, WARP fallback, device-lost
  surface.zig                     -- 4-mode surface union (from wintty, verbatim design)
  dcomp.zig                       -- DCompositionCreateSurfaceHandle plumbing
  swapchain.zig                   -- creation + presentation policy (see A3)
  Frame.zig / RenderPass.zig / Pipeline.zig / buffer.zig / Texture.zig
  gpu_data.zig                    -- byte-identical to Metal's structs (wintty's rule:
                                     "GenericRenderer writes the same bytes for both")
src/renderer/shaders/hlsl/        -- HLSL SM 5.0, compiled by fxc/dxc build step
```

Harvested patterns, by source:
- **wintty:** the four-mode `Surface` union (`hwnd` / `swap_chain_panel` via dcomp handle /
  unbound `composition` / `shared_texture` with shared fence+version); packed-atomic
  `setTargetSize` so resize never tears; render-thread-only `ResizeBuffers`; device-lost flag
  with TDR-between-present-and-signal handling; premultiplied-alpha `FLIP_SEQUENTIAL`
  composition swapchain; the dcomp access-mask trick shared with Windows Terminal.
- **winghostty:** frame-health plumbing (`healthy`/`failure_context` through render passes,
  suppress present on unhealthy frames); partial buffer uploads (`syncRange` /
  dirty-from-index instead of full-grid re-upload — this is the scroll-perf fix wintty lacks);
  per-step startup diagnostics (`get_dc`→`create_context`-style breadcrumbs, reborn as
  device-creation breadcrumbs) surfaced through `RENDERER_HEALTH` actions instead of
  MessageBoxes.
- **AtlasEngine (learnings, not code):** waitable swapchain
  (`CreateSwapChainForComposition` + `GetFrameLatencyWaitableObject`, latency 1) so the render
  thread blocks on *presentable* rather than *presented*; `DXGI_PRESENT_ALLOW_TEARING` when
  unthrottled; **skip Present entirely when a frame produced no damage** (cursor-blink-only
  frames re-render nothing); dirty-rect Present1 as a later optimization.

### A2. Platform tag / C API

Take: wintty's `ghostty_platform_windows_s` shape — fields are *mode selectors*, libghostty
never retains or calls through the pointers:

```c
// GHOSTTY_PLATFORM_WINDOWS = 3
typedef struct {
  void*    hwnd;              // standalone/test mode: bind via DComp target to this HWND
  bool     composition;       // WT/WinUI mode: create dcomp-surface-handle swapchain
  struct { bool enabled; uint32_t width, height; } shared_texture;
} ghostty_platform_windows_s;

GHOSTTY_API void* ghostty_surface_get_swap_chain_handle(ghostty_surface_t);  // dcomp HANDLE
GHOSTTY_API void* ghostty_surface_get_swap_chain(ghostty_surface_t);         // IDXGISwapChain1*
```

Plus the two enabling fixes: `ghostty_init` WTF-16 argv entry point (upstream's own TODO
prescribes it), and wintty's `pending_key` WM_KEYDOWN/WM_CHAR pairing buffer in
`apprt/embedded.zig` (a real Win32 message-pump impedance fix no other source has).

Also adopt wintty's read-back exports (`ghostty_surface_read_cells` / `_read_selection` /
`_read_text`) — they exist precisely because a rich host shell (search UI, UIA) needs them;
Windows Terminal needs them for the same reasons (§B4, §B5).

### A3. Presentation policy (the part nobody has finished)

This is the one component with no complete prior implementation — wintty is `Present(1,0)`
blocking vsync with full-grid uploads; winghostty has partial uploads but WGL vsync. The
ideal combines them and adds AtlasEngine's discipline:

1. Waitable composition swapchain, frame latency 1.
2. Damage gate: `updateFrame` tracks whether any instance buffer, atlas region, or uniform
   changed; if not, no Present.
3. Partial uploads via winghostty's dirty-range mechanism, generalized: bg/fg instance
   buffers upload `[dirty_from, dirty_to)` only; viewport scroll becomes an index rotation +
   tail upload, not a full rebuild.
4. Vsync off ⇒ `ALLOW_TEARING`; occluded surface (WT tells us via `set_occlusion`) ⇒ stop
   the draw timer entirely (upstream already has the plumbing).

### A4. Font stack: DirectWrite discovery + fallback, FreeType rasterization

Take: wintty's `directwrite_freetype` backend tag and its 886-LOC DirectWrite discovery
module as the base; graft phantty's per-codepoint fallback design — but upgrade its manual
`IDWriteFont::HasCharacter` collection walk to **`IDWriteFontFallback::MapCharacters`**
(the actual system fallback chain, locale-aware, the thing that makes CJK/emoji "just work"
like Windows), keeping phantty's negative cache so unfallbackable codepoints don't rescan.
Reject: winghostty's pure font-directory scanner (no fallback chain), and — for now — full
DWrite rasterization.

Why keep FreeType for rasterization: it's ghostty's cross-platform rasterizer (same glyph
pipeline as macOS/Linux ⇒ same atlas semantics, upstream-mergeable), HarfBuzz shaping keeps
ligatures, and DWrite *rasterization* (ClearType subpixel) is actively wrong over a
premultiplied-alpha transparent composition surface — AtlasEngine itself falls back to
grayscale AA in transparent contexts. Ship grayscale FreeType with gamma-correct blending;
leave a `directwrite` raster backend as a clearly-scoped future work item, and flag
**COLRv1 emoji** (Segoe UI Emoji's current format) as the concrete gap to close — FreeType
has COLRv1 APIs; ghostty's glyph pipeline needs to call them (today only CBDT bitmap emoji
render, which Segoe stopped being).

### A5. IO / PTY hardening

- **libxev IOCP:** cherry-pick winghostty's timer-completion fix (completed IOCP timers stay
  `.active` until their callback pops; resetting them from another callback corrupts the
  intrusive queue) — this is an upstream *libxev* PR, valuable independent of everything else.
- **Read path:** replace the naive 1 KiB blocking `ReadFile` loop with a 64 KiB
  double-buffered overlapped read (mirror the POSIX pipeline's structure), keeping the
  `CancelIoEx` shutdown path.
- **`getProcessInfo`:** implement via the ConPTY root-process handle + toplevel child
  enumeration (`NtQuerySystemInformation` process-tree walk, as WT's own close-confirmation
  effectively does). This unblocks `ghostty_surface_foreground_pid` → WT's "process is
  running" close warning.
- **Shell integration:** ship a PowerShell module (OSC 133 prompt marks + OSC 7 pwd + OSC
  9;4 progress) — trivial script work, unlocks ghostty's mark/jump features and WT's existing
  progress UI on the dominant Windows shell.

### A6. Governance: a patch series, not a squash-fork

The wintty lesson: a daily force-pushed single-commit branch made 8.7k LOC of good work
nearly un-cherry-pickable. Maintain the fork as an ordered, rebasable patch series
(one topic per patch: `init-wtf16`, `platform-win32`, `d3d11-backend`, `dwrite-discovery`,
`iocp-fixes`, `pty-hardening`), each written to upstream's stated PR-shape. Upstream the
infrastructure patches immediately (they merged deblasis's before); hold the renderer patch
warm for when upstream re-opens the door ("best in a fork *until we're ready*" — their
words). Coordinate with deblasis — same goals, established upstream relationship, and this
design is ~70% his proven decisions.

---

## Part B — The Windows Terminal side

### B1. The seam (unchanged from the earlier plan, now with a proven counterpart)

Promote `ControlCore.idl` + `ICoreState.idl` to an **`IControlCore`** WinRT interface; plug
the six `get_self<ControlCore>` leaks; `TermControl`/`ControlInteractivity` hold the
interface. The existing cascadia engine is implementation #1 and stays the default; this is
upstreamable to microsoft/terminal on its own merits (it is their own Process-Model-2.0
boundary).

### B2. `GhosttyControlCore` — the second implementation

A C++/WinRT class over `libghostty.dll`:

- **Rendering:** construct the surface with `composition = true`; call
  `ghostty_surface_get_swap_chain_handle()`; raise `SwapChainChanged` with it. TermControl's
  existing `_AttachDxgiSwapChainToXaml` → `SetSwapChainHandle` path runs **unchanged** —
  wintty already validated this exact binding (handle-not-object, survives ResizeBuffers,
  composites pre-activation) from WinUI 3.
- **Connection:** WT's `ITerminalConnection` stays the transport (`ConptyConnection`
  unmodified) and ghostty's own PTY is bypassed — bytes flow `TerminalOutput` →
  `ghostty_surface_vt_write`-equivalent, responses via the write callback → `WriteInput`.
  This keeps WT's defterm handoff, Azure connection, and packaged-COM machinery intact.
  (Alternative — let ghostty own ConPTY — rejected: it breaks defterm handoff and the
  connection abstraction that panes/persistence rely on.)
- **Input:** `TrySendKeyEvent`/`SendCharEvent` → `ghostty_surface_key`/`_text` with the
  pending-key pairing handled in-DLL (A2); mouse via `ControlInteractivity` → `_mouse_*`;
  scrollbar drags → viewport scroll; `UserScrollViewport` ↔ the `SCROLLBAR` action.
- **Actions → events:** the ~68 `GHOSTTY_ACTION_*` switch (macOS `Ghostty.Action.swift` and
  wintty's C# `GhosttyHost` are both templates): `SET_TITLE`→`TitleChanged`, `PWD`→
  `WorkingDirectory`, `PROGRESS_REPORT`→`TaskbarProgressChanged`, `RING_BELL`→`WarningBell`,
  `COLOR_CHANGE`→`BackgroundColorChanged`, `MOUSE_OVER_LINK`→hover trio, `OPEN_URL`→
  `OpenHyperlink`, clipboard callbacks→`WriteToClipboard`/paste request, `NEW_TAB`/`NEW_SPLIT`
  → return false initially (WT's own keybindings own those), `SCROLLBAR`→
  `ScrollPositionChanged`.
- **IME:** wire WT's TSF handler to `ghostty_surface_preedit` + `ghostty_surface_ime_point`.
  This *dissolves* the old `IRenderData::tsfPreview` coupling — ghostty renders its own
  preedit inline, which is strictly better than the bridge we'd otherwise build.
- **Settings:** an `IControlSettings`/`IControlAppearance` → `ghostty_config_t` translator
  (font face/size/weight/features, padding, cursor, colors, scrollback, opacity). Profile
  gains `"engine": "auto" | "cascadia" | "ghostty"`.
- **Search:** drive ghostty's search (`START_SEARCH`/`SEARCH_TOTAL`/`SEARCH_SELECTED`
  actions — wintty already ran a full search UI off these) behind the existing
  `Search(SearchRequest)`/`SearchResults` IDL; scrollbar pips from match-row read-back.
- **Selection/marks/read-back:** `SelectedText`, `SelectionInfo`, `ReadEntireBuffer`,
  `ScrollMarks` implemented over the A2 read-back exports + selection/mark actions.

### B3. Degradation ladder (WT's matrix, answered)

1. Real GPU → D3D11 hardware device.
2. RDP / no driver → same code path on **WARP** (automatic in A1's device creation).
3. Device removed → device-lost flag → rebuild device+swapchain, re-raise
   `SwapChainChanged` (the handle-based XAML binding makes this a clean re-attach).
4. Engine init fails outright → `RendererEnteredErrorState` → TermControl's existing error
   UI, and the profile can fall back to `"engine": "cascadia"`.

### B4. Accessibility (the honest hard part)

Reimplement `ITextProvider`/`ITextRangeProvider` over the read-back API instead of
`TextBuffer`. Not from scratch: **winghostty ships a working UIA implementation for
ghostty content** (`win32_uia/`, 7 files) — harvest its range/navigation semantics, re-home
them behind WT's `InteractivityAutomationPeer`. Ship gate for parity; prototype flag until
then.

### B5. Packaging

Engine DLL is self-contained (own CRT, MSVC ABI, x64+ARM64 — wintty/CI-proven). D3D11,
DXGI, DComp, and font-file access are appcontainer-clean API sets; validate MSIX API-set
compliance in the first spike (the one Phase-0 item that survives from the old plan).

---

## Harvest map (what each source contributes)

| Source | Take | Leave |
|---|---|---|
| deblasis PR #11886 | D3D11 module skeleton, composition swapchain approach, upstream-PR shape, merged CI/CRT infra | (nothing — it's the base) |
| wintty | Surface-mode union, dcomp handle export, platform tag, atomic resize, device-loss, gpu_data byte-parity rule, DWrite discovery backend, pending-key buffer, read-back exports, action-driven search UI, WinUI SwapChainPanel binding recipe | D3D12 itself; Present(1,0); full-grid uploads; squash-fork governance |
| winghostty | libxev IOCP timer fix (→ upstream libxev), frame-health plumbing, partial buffer uploads, startup diagnostics pattern, UIA implementation | exe-style `apprt.win32`; deletion of embedded API; legacy WGL; no-fallback stance; font-dir scanner |
| phantty | Per-codepoint fallback + negative cache design (upgraded to `IDWriteFontFallback`), modern-WGL bootstrap reference (unused if GL is skipped) | its standalone renderer; threadlocal GL state; fixed cell cap |
| AtlasEngine | Waitable swapchain, damage-gated present, ALLOW_TEARING, WARP fallback, grayscale-AA-over-transparency rule, D3D11 choice itself | (learnings only — its cell pipeline stays with the cascadia engine) |
| zcg / mite | Independent confirmation D3D11+DWrite works; mite as a clean-code reference (license unresolved — read, don't copy) | code (redundant with the above) |
| upstream ghostty | `generic.zig` contract, WebGL.zig as proof the abstraction takes new backends, embedded apprt, preedit rendering, `must_draw_from_app_thread` (kept in reserve) | — |

## Sequencing

1. **Fork + patch series bootstrap** (A6): upstream ghostty + `init-wtf16` +
   `platform-win32` + revived #11886 D3D11 skeleton rendering a solid-color surface into a
   test HWND, then into a WinUI SwapChainPanel via the dcomp handle. *(This is the whole
   Phase-0 spike: it proves the riskiest path end-to-end.)*
2. **Renderer completeness**: gpu_data parity, atlas, pipelines, HLSL, WARP, device-loss —
   validated against wintty's DX12 behavior side-by-side.
3. **Presentation policy** (A3) + font stack (A4) + IO hardening (A5) in parallel.
4. **WT seam** (B1) — can start day 1, independent.
5. **`GhosttyControlCore`** (B2): render+input+resize first, then actions/clipboard/IME,
   then search/marks/read-back, then UIA (B4).
6. **Upstreaming loop**: infra patches → libxev fix → font/PTY patches → renderer patch
   offered when upstream re-opens; `IControlCore` PR to microsoft/terminal.

The end state: Windows Terminal's shell, ghostty's engine, one `libghostty.dll` maintained
as a rebasable patch series that is simultaneously the best candidate for upstream ghostty's
official Windows renderer — and nothing in it that any single existing project would have to
be trusted for wholesale.
