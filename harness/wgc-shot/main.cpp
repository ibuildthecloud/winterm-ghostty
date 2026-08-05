// Capture a single window to PNG using Windows Graphics Capture.
//
// Why this exists: PrintWindow cannot see what the D3D11 backend renders. DXGI
// flip-model and DirectComposition surfaces are composited by DWM outside the
// window's GDI paint path, so PrintWindow returns the window brush no matter
// what the GPU drew. WGC captures the composed content and is scoped to a
// single window, which matters here - a full-screen grab (CopyFromScreen or
// DXGI Desktop Duplication) once captured an unrelated sign-in window with the
// user's credentials in it, so screen-scoped capture is off the table.
//
// Usage: wgc-shot.exe <pid> <out.png>

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wincodec.h>
#include <inspectable.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <stdio.h>
#include <string>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "dxgi.lib")

namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgdx = winrt::Windows::Graphics::DirectX;
namespace wgdx11 = winrt::Windows::Graphics::DirectX::Direct3D11;

#define HR(expr, what)                                                     \
    do {                                                                   \
        HRESULT _hr = (expr);                                              \
        if (FAILED(_hr)) {                                                 \
            fprintf(stderr, "FAIL %s hr=0x%08X\n", what, (unsigned)_hr);   \
            return 1;                                                      \
        }                                                                  \
    } while (0)

// Find the main top-level window for a process id.
struct FindCtx { DWORD pid; HWND hwnd; };
static BOOL CALLBACK findProc(HWND hwnd, LPARAM lp) {
    auto *ctx = reinterpret_cast<FindCtx *>(lp);
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != ctx->pid) return TRUE;
    if (!IsWindowVisible(hwnd)) return TRUE;
    if (GetWindow(hwnd, GW_OWNER) != nullptr) return TRUE;
    ctx->hwnd = hwnd;
    return FALSE;
}

static int savePng(const wchar_t *path, BYTE *data, UINT w, UINT h, UINT stride) {
    IWICImagingFactory *wic = nullptr;
    HR(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                        IID_PPV_ARGS(&wic)), "WICImagingFactory");
    IWICBitmapEncoder *enc = nullptr;
    HR(wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &enc), "CreateEncoder");
    IWICStream *stream = nullptr;
    HR(wic->CreateStream(&stream), "CreateStream");
    HR(stream->InitializeFromFilename(path, GENERIC_WRITE), "InitializeFromFilename");
    HR(enc->Initialize(stream, WICBitmapEncoderNoCache), "encoder Initialize");
    IWICBitmapFrameEncode *frame = nullptr;
    HR(enc->CreateNewFrame(&frame, nullptr), "CreateNewFrame");
    HR(frame->Initialize(nullptr), "frame Initialize");
    HR(frame->SetSize(w, h), "SetSize");
    WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
    HR(frame->SetPixelFormat(&fmt), "SetPixelFormat");
    HR(frame->WritePixels(h, stride, stride * h, data), "WritePixels");
    HR(frame->Commit(), "frame Commit");
    HR(enc->Commit(), "encoder Commit");
    return 0;
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: wgc-shot <pid|hwnd:N> <out.png>\n");
        return 2;
    }
    // A process can own several visible top-level windows - Windows Terminal
    // has one per window plus the settings UI - and "whichever EnumWindows
    // reaches first" is then a coin toss. hwnd:N targets one exactly.
    HWND explicitHwnd = nullptr;
    DWORD pid = 0;
    if (wcsncmp(argv[1], L"hwnd:", 5) == 0) {
        explicitHwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(_wtoi64(argv[1] + 5)));
    } else {
        pid = _wtoi(argv[1]);
    }

    winrt::init_apartment(winrt::apartment_type::multi_threaded);

    if (!wgc::GraphicsCaptureSession::IsSupported()) {
        fprintf(stderr, "FAIL Windows Graphics Capture not supported\n");
        return 1;
    }

    FindCtx ctx{ pid, explicitHwnd };
    if (!ctx.hwnd) {
        EnumWindows(findProc, reinterpret_cast<LPARAM>(&ctx));
    }
    if (!ctx.hwnd) { fprintf(stderr, "FAIL no visible window for pid %lu\n", pid); return 1; }

    wchar_t title[256] = {};
    GetWindowTextW(ctx.hwnd, title, 255);
    wprintf(L"capturing hwnd=%p title=\"%s\"\n", ctx.hwnd, title);

    // D3D device for the capture frame pool.
    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    HR(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                         D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                         D3D11_SDK_VERSION, &device, nullptr, &context),
       "D3D11CreateDevice");
    IDXGIDevice *dxgi = nullptr;
    HR(device->QueryInterface(IID_PPV_ARGS(&dxgi)), "QI IDXGIDevice");
    winrt::com_ptr<::IInspectable> inspectable;
    HR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, inspectable.put()),
       "CreateDirect3D11DeviceFromDXGIDevice");
    auto rtDevice = inspectable.as<wgdx11::IDirect3DDevice>();

    // GraphicsCaptureItem for this window, via the interop factory.
    auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem,
                                                 ::IGraphicsCaptureItemInterop>();
    wgc::GraphicsCaptureItem item{ nullptr };
    HR(interop->CreateForWindow(
           ctx.hwnd, winrt::guid_of<wgc::GraphicsCaptureItem>(),
           winrt::put_abi(item)),
       "CreateForWindow");

    auto size = item.Size();
    auto pool = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
        rtDevice, wgdx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
    auto session = pool.CreateCaptureSession(item);

    // Suppress the yellow capture border where the OS supports it, so the
    // saved image is exactly the window content.
    try {
        session.IsBorderRequired(false);
    } catch (...) {
        // Older builds do not expose this; harmless.
    }
    session.StartCapture();

    // The first frame or two can arrive before the app has drawn, so take a
    // few and keep the last.
    wgc::Direct3D11CaptureFrame frame{ nullptr };
    for (int i = 0; i < 120; i++) {
        auto f = pool.TryGetNextFrame();
        if (f) { frame = f; if (i > 8) break; }
        Sleep(16);
    }
    if (!frame) { fprintf(stderr, "FAIL no frame captured\n"); return 1; }

    auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::
                                         IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<ID3D11Texture2D> tex;
    HR(access->GetInterface(IID_PPV_ARGS(tex.put())), "GetInterface ID3D11Texture2D");

    D3D11_TEXTURE2D_DESC desc{};
    tex->GetDesc(&desc);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    winrt::com_ptr<ID3D11Texture2D> staging;
    HR(device->CreateTexture2D(&desc, nullptr, staging.put()), "CreateTexture2D staging");
    context->CopyResource(staging.get(), tex.get());

    D3D11_MAPPED_SUBRESOURCE mapped{};
    HR(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped), "Map staging");

    int rc = savePng(argv[2], static_cast<BYTE *>(mapped.pData),
                     desc.Width, desc.Height, mapped.RowPitch);
    if (rc == 0) {
        // Summarise so the result is checkable without opening the image.
        BYTE *p = static_cast<BYTE *>(mapped.pData);
        size_t nonBg = 0, total = 0;
        for (UINT y = 0; y < desc.Height; y += 2) {
            for (UINT x = 0; x < desc.Width; x += 2) {
                BYTE *px = p + y * mapped.RowPitch + x * 4;
                total++;
                // Anything that is not the dark terminal background.
                if (!(px[0] == 0x34 && px[1] == 0x2C && px[2] == 0x28)) nonBg++;
            }
        }
        wprintf(L"saved %s  %ux%u  non-background samples: %zu / %zu\n",
                argv[2], desc.Width, desc.Height, nonBg, total);
    }
    context->Unmap(staging.get(), 0);
    return rc;
}
