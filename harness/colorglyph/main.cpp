// What does TranslateColorGlyphRun actually hand back for a colour emoji?
//
// Why this exists: a ghostty pane and a cascadia pane draw the *same* emoji
// from the *same* file (seguiemj.ttf, one COLR table carrying both a v0 layer
// set and a v1 paint tree) in visibly different styles - flat in one, with
// gradients in the other. Both ask DirectWrite for the same set of glyph image
// formats, so the difference has to be in what comes back, or in what is done
// with it.
//
// This prints, for one codepoint, every run the enumerator produces: its image
// format, its palette index and its colour. A `COLR` run means DirectWrite has
// decomposed the glyph into v0 layers for the caller to draw. A
// `PREMULTIPLIED_B8G8R8A8` run means DirectWrite rasterized it itself, which is
// the only way a v1 paint tree - gradients and all - can reach a caller that
// never asked for COLR_PAINT_TREE.
//
// Usage: colorglyph.exe [codepoint-hex] [px-per-em]

#define NOMINMAX
#include <windows.h>
#include <d2d1.h>
#include <d2d1_3.h> // ID2D1DeviceContext4, for bitmap and SVG glyph runs
#include <dwrite_3.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <utility>
#include <vector>
#include <wincodec.h>

using Microsoft::WRL::ComPtr;

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "windowscodecs.lib")

#define CHECK(hr, what)                                                    \
    do {                                                                   \
        HRESULT _hr = (hr);                                                \
        if (FAILED(_hr)) {                                                 \
            std::printf("%s failed: 0x%08lx\n", what, (unsigned long)_hr); \
            return 1;                                                      \
        }                                                                  \
    } while (0)

static const char* FormatName(DWRITE_GLYPH_IMAGE_FORMATS f)
{
    switch (f) {
    case DWRITE_GLYPH_IMAGE_FORMATS_NONE: return "NONE";
    case DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE: return "TRUETYPE";
    case DWRITE_GLYPH_IMAGE_FORMATS_CFF: return "CFF";
    case DWRITE_GLYPH_IMAGE_FORMATS_COLR: return "COLR (v0 layers)";
    case DWRITE_GLYPH_IMAGE_FORMATS_SVG: return "SVG";
    case DWRITE_GLYPH_IMAGE_FORMATS_PNG: return "PNG";
    case DWRITE_GLYPH_IMAGE_FORMATS_JPEG: return "JPEG";
    case DWRITE_GLYPH_IMAGE_FORMATS_TIFF: return "TIFF";
    case DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8: return "PREMULTIPLIED_B8G8R8A8 (DWrite rasterized)";
    default: return "(mixed/unknown)";
    }
}

// The exact set our face asks for, and the exact set AtlasEngine asks for.
static constexpr DWRITE_GLYPH_IMAGE_FORMATS kOurs = static_cast<DWRITE_GLYPH_IMAGE_FORMATS>(
    DWRITE_GLYPH_IMAGE_FORMATS_COLR | DWRITE_GLYPH_IMAGE_FORMATS_SVG |
    DWRITE_GLYPH_IMAGE_FORMATS_PNG | DWRITE_GLYPH_IMAGE_FORMATS_JPEG |
    DWRITE_GLYPH_IMAGE_FORMATS_TIFF | DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8);

static constexpr DWRITE_GLYPH_IMAGE_FORMATS kAtlasEngine = static_cast<DWRITE_GLYPH_IMAGE_FORMATS>(
    DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE | DWRITE_GLYPH_IMAGE_FORMATS_CFF | kOurs);

static int Enumerate(IDWriteFactory4* f4, const DWRITE_GLYPH_RUN* run,
                     DWRITE_GLYPH_IMAGE_FORMATS formats, const char* label)
{
    ComPtr<IDWriteColorGlyphRunEnumerator1> e;
    const HRESULT hr = f4->TranslateColorGlyphRun({ 0, 0 }, run, nullptr, formats,
                                                  DWRITE_MEASURING_MODE_NATURAL, nullptr, 0, &e);
    if (hr == DWRITE_E_NOCOLOR) {
        std::printf("%-14s -> DWRITE_E_NOCOLOR (draw it as ordinary text)\n", label);
        return 0;
    }
    if (FAILED(hr) || !e) {
        std::printf("%-14s -> failed 0x%08lx\n", label, (unsigned long)hr);
        return 0;
    }

    std::printf("%-14s ->\n", label);
    int n = 0;
    for (;;) {
        BOOL has = FALSE;
        if (FAILED(e->MoveNext(&has)) || !has) break;
        const DWRITE_COLOR_GLYPH_RUN1* r = nullptr;
        if (FAILED(e->GetCurrentRun(&r)) || !r) break;
        std::printf("   run %2d: format=%-45s palette=%-6u colour=(%.2f %.2f %.2f %.2f) glyphs=%u\n",
                    n, FormatName(r->glyphImageFormat),
                    r->paletteIndex,
                    r->runColor.r, r->runColor.g, r->runColor.b, r->runColor.a,
                    r->glyphRun.glyphCount);
        n++;
        if (n > 64) { std::printf("   ... (stopping at 64)\n"); break; }
    }
    std::printf("   %d run(s) total\n", n);
    return n;
}

// Rasterize the glyph the way the face does and report its dominant colours,
// so a pane's pixels can be matched against a specific font file.
static HRESULT DominantColours(IWICImagingFactory* wic, ID2D1Factory* d2d, IDWriteFactory4* f4,
                               IDWriteFontFace* face, float emPx, UINT16 glyph);

int wmain(int argc, wchar_t** argv)
{
    const UINT32 cp = argc > 1 ? (UINT32)wcstoul(argv[1], nullptr, 16) : 0x1F600;
    const float emPx = argc > 2 ? (float)_wtof(argv[2]) : 22.0f;
    const wchar_t* fontFile = argc > 3 ? argv[3] : nullptr;

    CHECK(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED), "CoInitializeEx");

    ComPtr<IDWriteFactory> dw;
    CHECK(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                              (IUnknown**)dw.GetAddressOf()),
          "DWriteCreateFactory");
    ComPtr<IDWriteFactory4> f4;
    CHECK(dw.As(&f4), "IDWriteFactory4");

    // Resolve the emoji font the way the face's fallback does: ask DirectWrite,
    // then reopen the file it names.
    ComPtr<IDWriteFontCollection> coll;
    CHECK(dw->GetSystemFontCollection(&coll, FALSE), "GetSystemFontCollection");
    UINT32 index = 0;
    BOOL exists = FALSE;
    CHECK(coll->FindFamilyName(L"Segoe UI Emoji", &index, &exists), "FindFamilyName");
    if (!exists) { std::printf("Segoe UI Emoji not found\n"); return 1; }
    ComPtr<IDWriteFontFamily> fam;
    CHECK(coll->GetFontFamily(index, &fam), "GetFontFamily");
    ComPtr<IDWriteFont> font;
    CHECK(fam->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                    DWRITE_FONT_STYLE_NORMAL, &font),
          "GetFirstMatchingFont");
    ComPtr<IDWriteFontFace> face;
    CHECK(font->CreateFontFace(&face), "CreateFontFace");

    // A font file named on the command line replaces the system one. This is
    // how the bundled NotoColorEmoji.ttf gets measured: the collection adds it
    // as a fallback face on every non-macOS platform, so it - not the system
    // emoji font - is what a ghostty pane draws.
    if (fontFile) {
        ComPtr<IDWriteFontFile> file;
        CHECK(dw->CreateFontFileReference(fontFile, nullptr, &file), "CreateFontFileReference");
        IDWriteFontFile* files[] = { file.Get() };
        ComPtr<IDWriteFontFace> fileFace;
        CHECK(dw->CreateFontFace(DWRITE_FONT_FACE_TYPE_TRUETYPE, 1, files, 0,
                                 DWRITE_FONT_SIMULATIONS_NONE, &fileFace),
              "CreateFontFace(file)");
        face = fileFace;
        std::printf("using font file %ls\n", fontFile);
    }

    UINT16 glyph = 0;
    CHECK(face->GetGlyphIndices(&cp, 1, &glyph), "GetGlyphIndices");
    if (!glyph) { std::printf("no glyph for U+%04X\n", cp); return 1; }

    // Which DirectWrite is this, in interface terms? COLR_PAINT_TREE is only
    // nameable through IDWriteFactory8, and neither engine asks for it.
    ComPtr<IDWriteFactory8> f8;
    const bool haveF8 = SUCCEEDED(dw.As(&f8));
    std::printf("U+%04X glyph=%u at %.1f px/em, IDWriteFactory8 %s\n",
                cp, glyph, emPx, haveF8 ? "available" : "not available");

    DWRITE_GLYPH_RUN run{};
    run.fontFace = face.Get();
    run.fontEmSize = emPx;
    run.glyphCount = 1;
    run.glyphIndices = &glyph;

    Enumerate(f4.Get(), &run, kOurs, "ours");
    Enumerate(f4.Get(), &run, kAtlasEngine, "AtlasEngine");

    {
        ComPtr<IWICImagingFactory> wic;
        ComPtr<ID2D1Factory> d2d;
        if (SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                       IID_PPV_ARGS(&wic))) &&
            SUCCEEDED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.GetAddressOf()))) {
            DominantColours(wic.Get(), d2d.Get(), f4.Get(), face.Get(), emPx, glyph);
        }
    }

    // And which font does the *fallback* actually pick? This is the path the
    // face takes for a codepoint the primary font has no glyph for, and the
    // face then reopens whatever it names by file path.
    {
        ComPtr<IDWriteFactory2> f2;
        if (SUCCEEDED(dw.As(&f2))) {
            ComPtr<IDWriteFontFallback> fb;
            if (SUCCEEDED(f2->GetSystemFontFallback(&fb))) {
                wchar_t text[3]{};
                UINT32 len = 0;
                if (cp > 0xFFFF) {
                    const UINT32 v = cp - 0x10000;
                    text[0] = (wchar_t)(0xD800 + (v >> 10));
                    text[1] = (wchar_t)(0xDC00 + (v & 0x3FF));
                    len = 2;
                } else {
                    text[0] = (wchar_t)cp;
                    len = 1;
                }

                // A minimal text source over that one codepoint.
                struct Source : IDWriteTextAnalysisSource {
                    const wchar_t* t; UINT32 n; ULONG rc = 1;
                    HRESULT __stdcall QueryInterface(REFIID, void**) noexcept override { return E_NOINTERFACE; }
                    ULONG __stdcall AddRef() noexcept override { return ++rc; }
                    ULONG __stdcall Release() noexcept override { return --rc; }
                    HRESULT __stdcall GetTextAtPosition(UINT32 pos, const WCHAR** out, UINT32* outLen) noexcept override {
                        if (pos >= n) { *out = nullptr; *outLen = 0; return S_OK; }
                        *out = t + pos; *outLen = n - pos; return S_OK;
                    }
                    HRESULT __stdcall GetTextBeforePosition(UINT32, const WCHAR** out, UINT32* outLen) noexcept override {
                        *out = nullptr; *outLen = 0; return S_OK;
                    }
                    DWRITE_READING_DIRECTION __stdcall GetParagraphReadingDirection() noexcept override {
                        return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
                    }
                    HRESULT __stdcall GetLocaleName(UINT32, UINT32* len, const WCHAR** name) noexcept override {
                        *len = n; *name = nullptr; return S_OK;
                    }
                    HRESULT __stdcall GetNumberSubstitution(UINT32, UINT32* len, IDWriteNumberSubstitution** ns) noexcept override {
                        *len = n; *ns = nullptr; return S_OK;
                    }
                } src{};
                src.t = text; src.n = len;

                UINT32 mapped = 0;
                ComPtr<IDWriteFont> mappedFont;
                FLOAT sc = 1.0f;
                if (SUCCEEDED(fb->MapCharacters(&src, 0, len, coll.Get(), L"Cascadia Code",
                                                DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                                DWRITE_FONT_STRETCH_NORMAL, &mapped, &mappedFont, &sc)) &&
                    mappedFont) {
                    ComPtr<IDWriteFontFamily> mf;
                    if (SUCCEEDED(mappedFont->GetFontFamily(&mf))) {
                        ComPtr<IDWriteLocalizedStrings> names;
                        if (SUCCEEDED(mf->GetFamilyNames(&names))) {
                            wchar_t buf[128]{};
                            names->GetString(0, buf, 128);
                            std::printf("fallback for U+%04X -> family \"%ls\" (scale %.2f)\n", cp, buf, sc);
                        }
                    }
                    ComPtr<IDWriteFontFace> mfFace;
                    if (SUCCEEDED(mappedFont->CreateFontFace(&mfFace))) {
                        UINT32 fileCount = 0;
                        mfFace->GetFiles(&fileCount, nullptr);
                        std::printf("   files=%u, same face object as Segoe UI Emoji: %s\n",
                                    fileCount, mfFace.Get() == face.Get() ? "yes" : "no");
                    }
                } else {
                    std::printf("fallback for U+%04X -> nothing\n", cp);
                }
            }
        }
    }
    return 0;
}

// The face's own drawing loop, condensed: bitmap runs through
// DrawColorBitmapGlyphRun, SVG through DrawSvgGlyphRun, COLR layers through
// DrawGlyphRun with the layer's palette colour.
static HRESULT DominantColours(IWICImagingFactory* wic, ID2D1Factory* d2d, IDWriteFactory4* f4,
                               IDWriteFontFace* face, float emPx, UINT16 glyph)
{
    DWRITE_FONT_METRICS fm{};
    face->GetMetrics(&fm);
    const float scale = emPx / (float)fm.designUnitsPerEm;
    const UINT w = (UINT)(emPx * 2 + 8), h = (UINT)(emPx * 2 + 8);
    const float ox = 4.0f, oy = 4.0f + fm.ascent * scale;

    ComPtr<IWICBitmap> bmp;
    HRESULT hr = wic->CreateBitmap(w, h, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &bmp);
    if (FAILED(hr)) return hr;

    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_SOFTWARE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
    ComPtr<ID2D1RenderTarget> rt;
    hr = d2d->CreateWicBitmapRenderTarget(bmp.Get(), &props, &rt);
    if (FAILED(hr)) return hr;
    ComPtr<ID2D1DeviceContext4> dc4;
    rt.As(&dc4);
    if (dc4) dc4->SetUnitMode(D2D1_UNIT_MODE_PIXELS);

    ComPtr<ID2D1SolidColorBrush> brush;
    hr = rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 1), &brush);
    if (FAILED(hr)) return hr;

    DWRITE_GLYPH_RUN run{};
    run.fontFace = face;
    run.fontEmSize = emPx;
    run.glyphCount = 1;
    run.glyphIndices = &glyph;

    ComPtr<IDWriteColorGlyphRunEnumerator1> e;
    const HRESULT thr = f4->TranslateColorGlyphRun({ ox, oy }, &run, nullptr, kOurs,
                                                   DWRITE_MEASURING_MODE_NATURAL, nullptr, 0, &e);

    rt->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    rt->BeginDraw();
    rt->Clear(D2D1::ColorF(0, 0.0f));
    if (SUCCEEDED(thr) && e) {
        for (;;) {
            BOOL has = FALSE;
            if (FAILED(e->MoveNext(&has)) || !has) break;
            const DWRITE_COLOR_GLYPH_RUN1* r = nullptr;
            if (FAILED(e->GetCurrentRun(&r)) || !r) break;
            const D2D1_POINT_2F o{ r->baselineOriginX, r->baselineOriginY };
            static constexpr auto bitmaps =
                DWRITE_GLYPH_IMAGE_FORMATS_PNG | DWRITE_GLYPH_IMAGE_FORMATS_JPEG |
                DWRITE_GLYPH_IMAGE_FORMATS_TIFF | DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8;
            if (dc4 && (r->glyphImageFormat & bitmaps)) {
                dc4->DrawColorBitmapGlyphRun(r->glyphImageFormat, o, &r->glyphRun, r->measuringMode);
            } else if (dc4 && (r->glyphImageFormat & DWRITE_GLYPH_IMAGE_FORMATS_SVG)) {
                dc4->DrawSvgGlyphRun(o, &r->glyphRun, brush.Get(), nullptr, r->measuringMode);
            } else {
                brush->SetColor(r->paletteIndex == 0xFFFF ? D2D1::ColorF(1, 1, 1, 1)
                                                          : D2D1::ColorF(r->runColor.r, r->runColor.g,
                                                                         r->runColor.b, r->runColor.a));
                rt->DrawGlyphRun(o, &r->glyphRun, brush.Get(), r->measuringMode);
            }
        }
    } else {
        rt->DrawGlyphRun(D2D1::Point2F(ox, oy), &run, brush.Get(), DWRITE_MEASURING_MODE_NATURAL);
    }
    hr = rt->EndDraw();
    if (FAILED(hr)) return hr;

    std::vector<BYTE> px(size_t(w) * h * 4);
    WICRect rect{ 0, 0, (INT)w, (INT)h };
    hr = bmp->CopyPixels(&rect, w * 4, (UINT)px.size(), px.data());
    if (FAILED(hr)) return hr;

    // Count opaque colours, most common first.
    std::map<UINT32, int> counts;
    for (size_t i = 0; i < px.size(); i += 4) {
        if (px[i + 3] < 250) continue;
        counts[(UINT32(px[i + 2]) << 16) | (UINT32(px[i + 1]) << 8) | px[i]]++;
    }
    std::vector<std::pair<UINT32, int>> v(counts.begin(), counts.end());
    std::sort(v.begin(), v.end(), [](auto& a, auto& b) { return a.second > b.second; });
    std::printf("rasterized: ");
    for (size_t i = 0; i < v.size() && i < 4; i++) {
        std::printf("#%06X x%d  ", v[i].first, v[i].second);
    }
    std::printf("\n");
    return S_OK;
}
