# PR #11886 binary assets

`gh pr diff` renders binary blobs as `Binary files ... differ`, so the two pre-compiled
shaders in [`../pr-11886-d3d11.diff`](../pr-11886-d3d11.diff) are **not** recoverable from
that file. They are extracted here byte-exact from the PR's head commit so the archive is
complete even if GitHub drops the closed PR.

| File | Bytes | Notes |
|---|---|---|
| `cell_vs.cso` | 1836 | DXBC, `vs_5_0`, entry `VSMain` |
| `cell_ps.cso` | 612 | DXBC, `ps_5_0`, entry `PSMain` |

Source: `ghostty-org/ghostty` PR #11886 (CLOSED), head `bb8909dcba933025556378d2f323edc90b5bc929`
(2026-03-27), author deblasis, MIT. Also fetched into the `ghostty/` clone as the tag
`archive/pr-11886` — but that clone is gitignored, so this directory is the durable copy.

Rebuild from `src/renderer/shaders/hlsl/cell.hlsl` (present in the text diff) with:

```
fxc /T vs_5_0 /E VSMain /Fo cell_vs.cso cell.hlsl
fxc /T ps_5_0 /E PSMain /Fo cell_ps.cso cell.hlsl
```

Note the target profile: **SM 5.0 DXBC via `fxc`**, not SM 6 DXIL via `dxc`. This answers
the Phase 3 open question in `PLAN.md` about the D3D11 shader toolchain — see
`docs/sessions/0001-phase-0.md`.
