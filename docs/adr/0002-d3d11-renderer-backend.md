# 0002 — D3D11 as the ghostty GPU backend on Windows

Status: **Accepted** (2026-07-31, at the Phase 0 retro)

## Context

Upstream ghostty has no working GPU backend on Windows: Metal is Darwin-only and the
OpenGL backend is a compile-only stub for the embedded apprt requiring desktop GL 4.3.
Upstream's stated requirement (discussion #2563, maintainer, 2026-04-22): "a Direct3D-based
renderer with a similar performance and feature set as our Metal and OpenGL backends.
Whether we should support DirectX 11 or 12 is up for debate."

The backend plugs into `src/renderer/generic.zig`'s `Renderer(comptime GraphicsAPI)`
abstraction (~15-method contract, three first-party backends: Metal, OpenGL, WebGL).

Prior art evaluated:

- **deblasis upstream PR #11886** — ~2.4k LOC D3D11 infrastructure, composition-swapchain
  based, explicitly modeled on Windows Terminal. Closed 2026-03-27 by mitchellh on
  maintenance capacity, not quality ("best in a fork until we're ready"); its CI/CRT infra
  PRs were merged.
- **wintty** (same author) — mature ~8.7k LOC **D3D12** backend, in production, with the
  four-mode surface union and dcomp-handle export. No documented rationale for 12 over 11;
  the 11 version predates it and its DXGI/DComp/COM layers were "carried from DX11".
- **winghostty** — legacy-WGL OpenGL; explicitly no DirectX/ANGLE fallback; hard-fails on
  RDP/software rasterizer.
- Windows Terminal's **AtlasEngine** — chose D3D11 in 2021-22, seven years after D3D12
  shipped, with WARP fallback; the best-tuned Windows terminal renderer in existence.

Windows Terminal's compatibility matrix (RDP sessions, driverless VMs, hybrid GPUs, ARM64)
is a hard requirement for anything that ships inside it.

## Decision

Implement `src/renderer/D3D11.zig` + `src/renderer/d3d11/` against the `GraphicsAPI`
contract, at feature level 11_0, with `D3D_DRIVER_TYPE_WARP` fallback. Revive PR #11886 as
the base; port wintty's proven internal patterns (surface-mode union, atomic resize,
device-loss handling, byte-parity `gpu_data` rule) and winghostty's frame-health and
partial-upload mechanisms. Shaders in HLSL via the existing glslang/SPIRV-Cross path or
hand-authored (match whichever #11886 used).

## Alternatives rejected

- **D3D12** (wintty's code exists and is MIT): roughly double the code (fences, allocators,
  barriers, descriptor heaps, root signatures) as permanent bug-surface; weaker WARP
  ergonomics; a terminal cell grid exercises none of D3D12's win conditions (parallel
  command recording, bindless churn). D3D11 is not deprecation-risk: D3D11/12 are parallel
  current APIs on the same DXGI/WDDM foundation (D3D11on12 exists), and Microsoft has never
  removed a Direct3D version.
- **OpenGL/WGL** (winghostty's path): GL 4.3 floor is driver-luck on a legacy context and
  unavailable over RDP/software; winghostty's own error dialog is the cautionary tale.
- **ANGLE**: exposes GL ES, not desktop GL 4.3; would mean lowering ghostty's GL floor.
- **wgpu/Dawn/sokol abstraction**: zero upstream appetite (no such discussion exists);
  new heavyweight dependency; upstream's model is per-API backends behind `generic.zig`.

## Consequences

- WARP gives the RDP/software matrix nearly free; the degradation ladder in `DESIGN.md`
  depends on it.
- `gpu_data` structs and shaders are shared across backends, so a future D3D12 backend
  could slot in beside D3D11 (as Metal sits beside OpenGL) if a 12-only capability ever
  matters — this decision is not a one-way door.
- Presentation policy (waitable swapchain, damage-gated present, partial uploads) is the
  one component with no complete prior implementation anywhere; AtlasEngine
  (`AtlasEngine.r.cpp`) is the debugged reference to port from (MIT).
- Coordinate with deblasis: this design is substantially his proven decisions, and he holds
  the upstream relationship.
