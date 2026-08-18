# 0005 — DirectWrite discovery and rasterization, HarfBuzz shaping

Status: **Accepted** (2026-07-31, at the Phase 2→3 readiness step)

> Rewritten before acceptance. An earlier draft of this ADR chose *DirectWrite discovery
> with FreeType rasterization*. It was never accepted, and evidence gathered at the Phase 3
> readiness step reversed it. The reversal is recorded in "What changed and why" below,
> because the reasoning is the part worth keeping.

## Context

ghostty's font stack is pluggable at three independent layers — discovery, rasterization,
and shaping — selected by `src/font/backend.zig`:

```
coretext            CoreText for discovery, rendering, and shaping (macOS)
coretext_harfbuzz   CoreText for discovery and rendering, HarfBuzz for shaping
coretext_freetype   CoreText discovery, FreeType rendering, HarfBuzz shaping
fontconfig_freetype Fontconfig discovery, FreeType rendering (Linux default)
freetype_windows    FreeType rendering + a Windows font-directory scanner
```

Two facts from that enum drive this decision:

1. **ghostty already uses a platform-native rasterizer where one exists.** macOS defaults to
   `coretext` — CoreText for rendering, not FreeType. There is no sacred cross-platform
   FreeType path; FreeType is what platforms get when they have nothing better.
2. **Windows' current default is explicitly a placeholder.** `Backend.default()` returns
   `freetype_windows` with upstream's own comment: *"A future DirectWrite backend can
   replace this if needed."* Its discovery is a `C:\Windows\Fonts` directory scan with no
   system fallback chain.

### Colour emoji is a hard requirement, and it decides the rasterizer

Measured on the Phase 0/1/2 dev box (Windows 11 26200):

- `seguiemj.ttf` has a **COLR table, version 1**, ~7 MB, containing *both* a v1 paint tree
  (`baseGlyphListOffset` non-zero) and a complete **v0** layer set (3,372 base glyph
  records, 53,071 layer records).
- **No font shipped with Windows has a `CBDT` or `sbix` table** — checked across
  `C:\Windows\Fonts`. There is no bitmap colour emoji font on the platform.
- ghostty's FreeType binding does not expose `ftcolor` at all, so *no* COLR support exists
  in the current Zig glyph path.

FreeType can rasterize COLR v0 layers via `FT_Get_Color_Glyph_Layer`, but COLR v1 paint
trees (gradients, transforms, composites) would have to be rendered by hand. DirectWrite
implements all of it already.

### What AtlasEngine does

Windows Terminal's own renderer is the closest prior art, and its D3D11 backend is
architecturally what we are building:

- **Shaping**: `IDWriteTextAnalyzer1` — `AnalyzeScript`, `GetGlyphs`, `GetGlyphPlacements`.
- **Rasterization**: `CreateDxgiSurfaceRenderTarget` over the glyph atlas texture, so **D2D
  draws glyphs directly into the D3D11 atlas** with no CPU round-trip.
- **Colour glyphs**: `IDWriteFactory4::TranslateColorGlyphRun`, dispatching per
  `glyphImageFormat` to `DrawColorBitmapGlyphRun` / `DrawSvgGlyphRun` / `DrawGlyphRun`, with
  `paletteIndex == 0xffff` meaning "use the foreground brush".
- **Antialiasing**: configurable ClearType or grayscale, and it **forces grayscale for
  colour glyphs**. Its ClearType path uses `IDWriteGlyphRunAnalysis::CreateAlphaTexture`
  with dual-source blending.

Notably, AtlasEngine requests `DWRITE_GLYPH_IMAGE_FORMATS_COLR` on an `IDWriteFactory4` — it
never asks for COLR v1 paint trees. **Windows Terminal renders the v0 layers.**

## Decision

A **`directwrite_harfbuzz`** backend: DirectWrite for discovery *and* rasterization,
HarfBuzz for shaping. This mirrors the existing `coretext_harfbuzz` combination rather than
inventing a shape.

- **Discovery + fallback**: DirectWrite, using `IDWriteFontFallback::MapCharacters` (the
  real locale-aware system fallback chain) with a negative cache so unfallbackable
  codepoints are not rescanned.
- **Rasterization**: DirectWrite/Direct2D, drawing into the glyph atlas via
  `CreateDxgiSurfaceRenderTarget` as AtlasEngine does. **Grayscale AA only.**
- **Colour glyphs**: `TranslateColorGlyphRun` with AtlasEngine's format dispatch and
  palette-index rule. This yields COLR v0, COLR v1, SVG, PNG and bitmap emoji from the
  platform implementation, with no glyph-format work of our own.
- **Shaping**: HarfBuzz, unchanged from every other ghostty platform.

## Alternatives rejected

- **FreeType rasterization** (this ADR's earlier draft). Its two arguments do not survive
  scrutiny. It claimed DWrite raster would "fork the glyph pipeline away from ghostty's
  cross-platform FreeType path" — but macOS already renders with CoreText, so a native
  Windows rasterizer *follows* the architecture rather than forking it. It also claimed
  ClearType subpixel is wrong over a premultiplied-alpha composition surface, which is
  true but is an argument against *subpixel AA*, not against DirectWrite: D2D renders
  grayscale perfectly well, and AtlasEngine itself falls back to grayscale when composing.
  Keeping FreeType would additionally leave colour emoji as permanent bespoke work.
- **COLR v0 layers in FreeType** (expose `ftcolor`, composite layers with palette colours).
  Genuinely viable and more upstreamable — it would render Segoe UI Emoji on par with
  AtlasEngine, since both would use the v0 data. Rejected because it solves only one glyph
  format: SVG-in-OpenType and COLR v1 gradients would remain gaps, and text would still not
  match the platform. It is the better option *only* if DirectWrite rasterization proves
  unworkable, and is recorded here as the fallback.
- **DirectWrite shaping** (following AtlasEngine all the way). AtlasEngine shapes with
  DWrite because it has no alternative. ghostty has HarfBuzz working on every platform and
  a named backend for native-render-plus-HarfBuzz. Adopting DWrite shaping would be a much
  larger change with real risk of ligature/cluster divergence from ghostty elsewhere.
- **ClearType via `CreateAlphaTexture` + dual-source blending** (AtlasEngine's other path).
  Wrong over our premultiplied composition surface, and it would constrain the renderer's
  blend state for a benefit we cannot use.
- **Bundling a CBDT colour emoji font** (e.g. Noto). Works with the existing bitmap path
  and no new code, but Windows ships no CBDT font, so it means overriding the system emoji
  font — users would get Android-style emoji in a Windows terminal.
- **Font-directory scanner** (upstream `freetype_windows`, winghostty): no system fallback
  chain. CJK and emoji "just working" is table stakes for a Windows Terminal engine.

## Consequences

- **Text will match other Windows applications**, which the FreeType draft explicitly gave
  up. This removes the "revisit if users complain about hinting/gamma" clause entirely.
- **Colour emoji stops being a tracked gap.** On par with AtlasEngine for Segoe UI Emoji
  (both render v0 layers), and ahead of it for SVG glyph formats. Neither renders COLR v1
  gradients today; requesting `DWRITE_GLYPH_IMAGE_FORMATS_COLR_PAINT_TREE` via
  `IDWriteFactory8` is a separable later upgrade that would put us *ahead* of WT.
- **The glyph atlas becomes a D2D-rendered DXGI surface**, not a CPU-uploaded texture. This
  obsoletes the `Texture.replaceRegion`/`UpdateSubresource` path written in Phase 1, which
  has never executed — cheap to change now, since nothing depends on it.
- **D2D/D3D11 interop is new machinery**: a `ID2D1Factory`, a device context over the atlas
  surface, and correct BeginDraw/EndDraw sequencing against a texture the D3D11 renderer
  also samples. AtlasEngine's `BackendD3D` is the reference.
- **Less upstreamable than a FreeType COLR implementation.** A DirectWrite face benefits
  only Windows, whereas COLR-in-FreeType would benefit every ghostty platform. Accepted
  deliberately: the project's target is Windows Terminal, and upstream's own comment invites
  a DirectWrite backend.
- **More new code than the FreeType draft** — glyph metrics, rasterization, and the atlas
  path all become DirectWrite-shaped. This is a schedule cost paid in Phase 3.
- The backend remains a self-contained upstream patch (`dwrite-discovery` in ADR 0004's
  series), independent of the renderer patches.

## What changed and why

The earlier draft optimized for reaching a working Windows font stack quickly, and FreeType
does that. Three pieces of evidence, gathered while deciding the colour-emoji approach,
inverted the trade:

1. **`Backend.default()` shows Windows' FreeType default is a stopgap** and macOS already
   uses a native rasterizer — so "stay on FreeType for consistency" described a consistency
   that does not exist.
2. **Segoe UI Emoji is COLR v1 and Windows ships no bitmap emoji font**, so FreeType meant
   building colour-glyph support ourselves, permanently, for one platform.
3. **AtlasEngine demonstrates the whole pipeline** — including the DXGI-surface atlas trick
   — so the DirectWrite path is a port of proven code rather than new design.

## Amendment, 2026-08-18 — the bundled Noto font wins, and this ADR did not know it

**DECISION-NEEDED.** This ADR rejected "Bundling a CBDT colour emoji font (e.g.
Noto)" on the grounds that it "means overriding the system emoji font — users
would get Android-style emoji in a Windows terminal". That is what ships, and
not because anyone bundled anything: **upstream already does it.**

`SharedGridSet.zig:358` adds `font.embedded.emoji` — `res/NotoColorEmoji.ttf`,
CBDT bitmaps — to the collection as a fallback face on every non-macOS platform.
macOS is the exception because the block above it discovers Apple Color Emoji
and adds it first. Collection faces are consulted before DirectWrite's system
fallback, so on Windows the bundled Noto answers first and Segoe UI Emoji is
never reached for any codepoint Noto covers.

Measured with `harness/colorglyph`, U+1F600 at 22 px/em, against the two panes'
own pixels:

| | dominant colours | matches |
|---|---|---|
| Segoe UI Emoji, 6 COLR v0 layer runs | `#FFB02E #BB1D80 #FFFFFF #402A32` | the **cascadia** pane |
| bundled NotoColorEmoji.ttf, 1 PNG run | `#FDE030 #422B0D #F8C52C #F9CD2D` | the **ghostty** pane |

Exact match on both sides, pixel counts included.

**What this does and does not invalidate.** The decision — DirectWrite discovery
and rasterization, HarfBuzz shaping — stands, and the colour-glyph machinery is
still what draws every emoji Noto does not cover, plus SVG and COLR symbol
fonts. What is wrong is this ADR's claim that the DirectWrite path means users
see *Segoe UI Emoji*: they do not, and the "on par with AtlasEngine for Segoe UI
Emoji" consequence is not what ships.

**Decided 2026-08-18, by the user: keep it.** A ghostty pane draws the bundled
Noto emoji, exactly as upstream ghostty does on every non-macOS platform. The
alternative - mirroring the macOS block so Windows discovers "Segoe UI Emoji"
and adds it ahead of the bundled font - was considered and rejected on the
standing rule for this engine: match upstream ghostty, and treat only real
defects and real deviations from it as things to fix. So the rejection of
"bundling a CBDT colour emoji font" in the alternatives above no longer
describes what this project wants; it describes what this ADR assumed before
anyone looked.

A user who wants Windows emoji has a per-profile lever and needs no code change:
naming the font as a list puts the system font ahead of the bundled one.

```json
"font": { "face": "Cascadia Code, Segoe UI Emoji" }
```

Measured: that draws #FFB02E / #BB1D80 emoji in a ghostty pane, the same as the
cascadia pane beside it. It only works because the translator forwards a font
list as one entry per family, which was itself broken until
[KD-17](../known-defects.md).
