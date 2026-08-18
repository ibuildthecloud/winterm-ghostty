// Is our glyph atlas a raw coverage mask, or has Direct2D already corrected it?
//
// Why this exists: ghostty's cell-text shader assumes the grayscale atlas holds
// *coverage* - FreeType and CoreText both hand it one - and does every gamma
// step itself (`alpha-blending`, linear / linear-corrected). Our Windows face
// rasterizes with Direct2D instead, and sets only the antialias mode
// (font/face/directwrite.zig). If D2D's default text rendering params apply
// DirectWrite's gamma correction and contrast enhancement while drawing, then
// the atlas is not coverage, and the shader's correction lands on top of one
// that is already there - a deviation from upstream ghostty's model rather than
// a style choice.
//
// This draws one glyph the way our face does, then again through rendering
// params with gamma 1.0 and contrast 0 (what AtlasEngine asks for when it wants
// a raw mask), and prints both alpha histograms. Identical histograms mean D2D
// adds nothing on a transparent target and our atlas is already coverage.
//
// Usage: glyphmask.exe [font] [px-per-em] [codepoint]

#define NOMINMAX // windows.h's min/max macros eat std::min/std::max below
#include <windows.h>
#include <d2d1.h>
#include <d2d1helper.h>
#include <dwrite_3.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

using Microsoft::WRL::ComPtr;

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

#define CHECK(hr, what)                                                    \
    do {                                                                   \
        HRESULT _hr = (hr);                                                \
        if (FAILED(_hr)) {                                                 \
            std::printf("%s failed: 0x%08lx\n", what, (unsigned long)_hr); \
            return 1;                                                      \
        }                                                                  \
    } while (0)

// Rasterize one glyph into a fresh WIC bitmap and return its alpha plane.
// `params` may be null, which is exactly what our face does today.
static HRESULT RasterAlpha(IWICImagingFactory* wic,
                           ID2D1Factory* d2d,
                           IDWriteFontFace* face,
                           float emPx,
                           UINT16 glyph,
                           IDWriteRenderingParams* params,
                           UINT w,
                           UINT h,
                           float originX,
                           float originY,
                           std::vector<BYTE>& out)
{
    ComPtr<IWICBitmap> bmp;
    HRESULT hr = wic->CreateBitmap(w, h, GUID_WICPixelFormat32bppPBGRA,
                                   WICBitmapCacheOnLoad, &bmp);
    if (FAILED(hr)) return hr;

    // The same properties the face uses: software target, premultiplied BGRA,
    // 96 dpi so that a DIP is a pixel.
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_SOFTWARE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96.0f, 96.0f);

    ComPtr<ID2D1RenderTarget> rt;
    hr = d2d->CreateWicBitmapRenderTarget(bmp.Get(), &props, &rt);
    if (FAILED(hr)) return hr;

    ComPtr<ID2D1SolidColorBrush> brush;
    hr = rt->CreateSolidColorBrush(D2D1::ColorF(1.0f, 1.0f, 1.0f, 1.0f), &brush);
    if (FAILED(hr)) return hr;

    if (params) rt->SetTextRenderingParams(params);
    rt->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);

    DWRITE_GLYPH_RUN run{};
    run.fontFace = face;
    run.fontEmSize = emPx;
    run.glyphCount = 1;
    run.glyphIndices = &glyph;

    rt->BeginDraw();
    rt->Clear(D2D1::ColorF(0, 0.0f));
    rt->DrawGlyphRun(D2D1::Point2F(originX, originY), &run, brush.Get(),
                     DWRITE_MEASURING_MODE_NATURAL);
    hr = rt->EndDraw();
    if (FAILED(hr)) return hr;

    out.assign(size_t(w) * h, 0);
    std::vector<BYTE> px(size_t(w) * h * 4);
    WICRect rect{ 0, 0, (INT)w, (INT)h };
    hr = bmp->CopyPixels(&rect, w * 4, (UINT)px.size(), px.data());
    if (FAILED(hr)) return hr;
    for (size_t i = 0; i < out.size(); ++i) out[i] = px[i * 4 + 3];
    return S_OK;
}

static void Histogram(const char* label, const std::vector<BYTE>& a)
{
    size_t buckets[10]{};
    size_t inked = 0;
    double mass = 0;
    for (BYTE v : a) {
        if (v == 0) continue;
        inked++;
        mass += v / 255.0;
        buckets[std::min(int(v) * 10 / 256, 9)]++;
    }
    std::printf("%-24s inked=%5zu mass=%8.2f |", label, inked, mass);
    for (size_t b : buckets) std::printf(" %4zu", b);
    std::printf("\n");
}

int wmain(int argc, wchar_t** argv)
{
    const wchar_t* family = argc > 1 ? argv[1] : L"Cascadia Code";
    const float emPx = argc > 2 ? (float)_wtof(argv[2]) : 14.6667f;
    const UINT32 cp = argc > 3 ? (UINT32)_wtoi(argv[3]) : UINT32('e');

    CHECK(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED), "CoInitializeEx");

    ComPtr<IWICImagingFactory> wic;
    CHECK(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                           IID_PPV_ARGS(&wic)),
          "WICImagingFactory");

    ComPtr<ID2D1Factory> d2d;
    CHECK(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.GetAddressOf()),
          "D2D1CreateFactory");

    ComPtr<IDWriteFactory1> dw;
    CHECK(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory1),
                              (IUnknown**)dw.GetAddressOf()),
          "DWriteCreateFactory");

    ComPtr<IDWriteFontCollection> coll;
    CHECK(dw->GetSystemFontCollection(&coll, FALSE), "GetSystemFontCollection");
    UINT32 index = 0;
    BOOL exists = FALSE;
    CHECK(coll->FindFamilyName(family, &index, &exists), "FindFamilyName");
    if (!exists) {
        std::printf("font not found\n");
        return 1;
    }
    ComPtr<IDWriteFontFamily> fam;
    CHECK(coll->GetFontFamily(index, &fam), "GetFontFamily");
    ComPtr<IDWriteFont> font;
    CHECK(fam->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                    DWRITE_FONT_STYLE_NORMAL, &font),
          "GetFirstMatchingFont");
    ComPtr<IDWriteFontFace> face;
    CHECK(font->CreateFontFace(&face), "CreateFontFace");

    UINT16 glyph = 0;
    CHECK(face->GetGlyphIndices(&cp, 1, &glyph), "GetGlyphIndices");
    if (!glyph) {
        std::printf("no glyph for U+%04X\n", cp);
        return 1;
    }

    DWRITE_FONT_METRICS fm{};
    face->GetMetrics(&fm);
    const float scale = emPx / (float)fm.designUnitsPerEm;
    const UINT w = (UINT)(emPx * 2 + 8);
    const UINT h = (UINT)(emPx * 2 + 8);
    const float ox = 4.0f;
    const float oy = 4.0f + fm.ascent * scale;

    // What the system hands an application that asks for nothing - our face.
    ComPtr<IDWriteRenderingParams> def;
    CHECK(dw->CreateRenderingParams(&def), "CreateRenderingParams");
    ComPtr<IDWriteRenderingParams1> def1;
    CHECK(def.As(&def1), "IDWriteRenderingParams1");
    std::printf("system params: gamma=%.3f contrast=%.3f grayscaleContrast=%.3f "
                "cleartypeLevel=%.3f mode=%d\n",
                def1->GetGamma(), def1->GetEnhancedContrast(),
                def1->GetGrayscaleEnhancedContrast(), def1->GetClearTypeLevel(),
                (int)def1->GetRenderingMode());

    // AtlasEngine's "give me a raw mask" params: gamma 1.0, contrast 0.
    ComPtr<IDWriteRenderingParams1> linear;
    CHECK(dw->CreateCustomRenderingParams(1.0f, 0.0f, 0.0f, def1->GetClearTypeLevel(),
                                          def1->GetPixelGeometry(), def1->GetRenderingMode(),
                                          &linear),
          "CreateCustomRenderingParams");

    std::vector<BYTE> aDefault, aLinear;
    CHECK(RasterAlpha(wic.Get(), d2d.Get(), face.Get(), emPx, glyph, nullptr, w, h, ox, oy, aDefault),
          "raster (default params)");
    CHECK(RasterAlpha(wic.Get(), d2d.Get(), face.Get(), emPx, glyph, linear.Get(), w, h, ox, oy, aLinear),
          "raster (linear params)");

    std::printf("glyph U+%04X of %ls at %.4f px/em, %ux%u bitmap\n", cp, family, emPx, w, h);
    Histogram("d2d default params", aDefault);
    Histogram("d2d gamma=1 contrast=0", aLinear);

    size_t differing = 0;
    int maxDelta = 0;
    for (size_t i = 0; i < aDefault.size(); ++i) {
        const int d = (int)aDefault[i] - (int)aLinear[i];
        if (d) {
            differing++;
            maxDelta = std::max(maxDelta, d < 0 ? -d : d);
        }
    }
    std::printf("differing pixels: %zu, max delta: %d\n", differing, maxDelta);
    std::printf("%s\n", differing == 0
                            ? "=> D2D adds nothing on a transparent target; the atlas is raw coverage."
                            : "=> D2D's defaults change the mask; the atlas is NOT raw coverage.");
    return 0;
}
