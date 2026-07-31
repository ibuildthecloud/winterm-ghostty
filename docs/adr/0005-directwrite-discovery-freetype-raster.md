# 0005 — DirectWrite discovery/fallback with FreeType rasterization

Status: Proposed (2026-07-31)

## Context

ghostty's font stack is pluggable via `src/font/backend.zig` (discovery/rasterization
split; HarfBuzz shaping throughout). Upstream's Windows default is `freetype_windows`, a
hand-rolled `C:\Windows\Fonts` directory scanner with no system fallback chain, carrying
upstream's own note: "A future DirectWrite backend can replace this if needed."

Prior art:

- **wintty** ships a `directwrite_freetype` backend: DirectWrite COM discovery (886 LOC),
  FreeType rasterization, HarfBuzz shaping. Fallback via collection walk.
- **phantty** does DirectWrite discovery + per-codepoint fallback with a negative cache,
  via manual `IDWriteFont::HasCharacter` walks.
- **Windows Terminal's AtlasEngine** is a full DWrite pipeline (analysis, ClearType-tuned
  gamma, dual-source blending) — and notably falls back to grayscale AA when rendering
  over transparent/composed surfaces, because ClearType subpixel blending is wrong over
  premultiplied alpha.
- Segoe UI Emoji is COLRv1 today; ghostty's FreeType glyph path renders CBDT bitmap emoji
  but not COLRv1.

## Decision

Base the Windows font backend on wintty's `directwrite_freetype` shape:

- **Discovery + fallback**: DirectWrite, upgraded to `IDWriteFontFallback::MapCharacters`
  (the real locale-aware system fallback chain) with phantty's negative-cache idea so
  unfallbackable codepoints don't rescan.
- **Rasterization**: FreeType, grayscale AA with gamma-correct blending.
- **Shaping**: HarfBuzz (unchanged; ligatures work).

## Alternatives rejected

- **Font-directory scanner** (upstream `freetype_windows`, winghostty): no system fallback
  chain — CJK/emoji "just working" is table stakes for a Windows Terminal engine.
- **DWrite rasterization now**: ClearType subpixel is actively wrong over the
  premultiplied-alpha composition surface (AtlasEngine's own lesson); it would also fork
  the glyph pipeline away from ghostty's cross-platform FreeType path, hurting
  upstream-mergeability. Deferred, not refused — AtlasEngine's `DWriteTextAnalysis.cpp` /
  `dwrite_helpers.*` are the reference if a `directwrite` raster backend is built later.
- **Manual HasCharacter collection walks** (phantty/wintty): reimplements what
  `IDWriteFontFallback` already does, worse and slower.

## Consequences

- Text is FreeType-rendered: subtly different hinting/gamma from DWrite-rendered Windows
  apps. Accepted for now; revisit condition is user-visible complaints after Phase 6.
- **COLRv1 emoji is a named work item** (FreeType has COLRv1 APIs; ghostty's rasterizer
  needs to call them) — without it, Segoe UI Emoji renders via fallback paths poorly.
- The discovery backend is a self-contained upstream patch (`dwrite-discovery` in
  ADR 0004's series), independent of the renderer.
