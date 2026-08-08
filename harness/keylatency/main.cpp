// keylatency: keystroke-to-pixel latency, measured the same way for any terminal.
//
// Phase 7's latency criterion ("latency <= cascadia median") had no number for
// either engine, and the two obvious instruments answer the wrong question:
// PresentMon measures presentation cadence, and an in-app timestamp cannot
// compare two engines whose input paths are exactly what differs.
//
// So: send a real keystroke, then watch the screen until it changes.
//
//   t0    QueryPerformanceCounter, immediately before SendInput
//   t1    Direct3D11CaptureFrame::SystemRelativeTime of the first captured
//         frame whose watch region differs from the baseline
//
// Both are on the QPC timebase, so t1 - t0 is a real interval. It includes DWM
// composition, which is a bias - but the *same* bias for both engines, which is
// what makes the comparison fair even though the absolute number is not
// photon-to-pixel.
//
// Every round types the same character, walking along the prompt line. The
// tidier-looking alternation with Backspace silently produced no-op rounds.
//
// Caveat worth knowing: a keystroke also resets the cursor blink, so the first
// changed pixels may be the cursor rather than the glyph. That is still a
// response to the keystroke, which is what latency means here - but it means
// this measures "time to first visible response", not "time to glyph".

#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <d3d11.h>
#include <dxgi.h>

#include <cstdio>
#include <cstdint>
#include <algorithm>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "user32.lib")

namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgdx = winrt::Windows::Graphics::DirectX;
namespace wgdx11 = winrt::Windows::Graphics::DirectX::Direct3D11;

static void HR(HRESULT hr, const char *what) {
    if (FAILED(hr)) {
        fprintf(stderr, "FAIL %s hr=0x%08lX\n", what, static_cast<unsigned long>(hr));
        ExitProcess(1);
    }
}

// QPC ticks -> 100ns units since boot, which is the unit and epoch
// SystemRelativeTime uses.
static int64_t qpcTo100ns(int64_t ticks, int64_t freq) {
    // Split to avoid overflowing before the divide.
    return (ticks / freq) * 10000000 + ((ticks % freq) * 10000000) / freq;
}

static void forceForeground(HWND hwnd) {
    ShowWindow(hwnd, SW_RESTORE);
    for (int i = 0; i < 12 && GetForegroundWindow() != hwnd; i++) {
        DWORD fgPid = 0;
        const DWORD fgThread = GetWindowThreadProcessId(GetForegroundWindow(), &fgPid);
        AttachThreadInput(fgThread, GetCurrentThreadId(), TRUE);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        AttachThreadInput(fgThread, GetCurrentThreadId(), FALSE);
        Sleep(250);
    }
}

static void sendKey(WORD vk) {
    INPUT in[2] = {};
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wVk = vk;
    in[1] = in[0];
    in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, in, sizeof(INPUT));
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 2) {
        fprintf(stderr,
                "usage: keylatency hwnd:N [rounds] [x y w h]\n"
                "  watches a region for the first change after a keystroke.\n"
                "  region defaults to a strip across the top of the client area.\n");
        return 2;
    }
    const HWND hwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(_wtoi64(argv[1] + 5)));
    if (!IsWindow(hwnd)) { fprintf(stderr, "FAIL not a window\n"); return 1; }
    const int rounds = argc > 2 ? _wtoi(argv[2]) : 20;

    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    if (!wgc::GraphicsCaptureSession::IsSupported()) {
        fprintf(stderr, "FAIL Windows Graphics Capture not supported\n");
        return 1;
    }

    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    HR(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                         D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                         D3D11_SDK_VERSION, &device, nullptr, &context),
       "D3D11CreateDevice");
    IDXGIDevice *dxgi = nullptr;
    HR(device->QueryInterface(IID_PPV_ARGS(&dxgi)), "QI IDXGIDevice");
    winrt::com_ptr<::IInspectable> inspectable;
    HR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, inspectable.put()), "FromDXGIDevice");
    auto rtDevice = inspectable.as<wgdx11::IDirect3DDevice>();

    auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem,
                                                 ::IGraphicsCaptureItemInterop>();
    wgc::GraphicsCaptureItem item{ nullptr };
    HR(interop->CreateForWindow(hwnd, winrt::guid_of<wgc::GraphicsCaptureItem>(),
                                winrt::put_abi(item)),
       "CreateForWindow");

    const auto size = item.Size();
    // Default watch region: a strip across the top of the content, below the
    // tab bar. Wide enough to contain the prompt and whatever is typed after
    // it, short enough that copying it per frame is cheap.
    int rx = argc > 6 ? _wtoi(argv[3]) : 8;
    int ry = argc > 6 ? _wtoi(argv[4]) : 60;
    int rw = argc > 6 ? _wtoi(argv[5]) : std::min(760, size.Width - 16);
    int rh = argc > 6 ? _wtoi(argv[6]) : 120;
    printf("window %dx%d, watching %d,%d %dx%d, %d rounds\n",
           size.Width, size.Height, rx, ry, rw, rh, rounds);

    auto pool = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
        rtDevice, wgdx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
    auto session = pool.CreateCaptureSession(item);
    try { session.IsBorderRequired(false); } catch (...) {}
    session.StartCapture();

    // Small staging texture: only the watch region is copied back per frame,
    // which is what makes polling at frame rate affordable.
    D3D11_TEXTURE2D_DESC sd{};
    sd.Width = rw; sd.Height = rh; sd.MipLevels = 1; sd.ArraySize = 1;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.Usage = D3D11_USAGE_STAGING; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    winrt::com_ptr<ID3D11Texture2D> staging;
    HR(device->CreateTexture2D(&sd, nullptr, staging.put()), "CreateTexture2D staging");

    int64_t freq = 0;
    QueryPerformanceFrequency(reinterpret_cast<LARGE_INTEGER *>(&freq));

    // Checksum of the watch region in a captured frame. Returns false if no
    // frame was available.
    auto grab = [&](uint64_t *sumOut, int64_t *timeOut) -> bool {
        auto f = pool.TryGetNextFrame();
        if (!f) return false;
        auto access = f.Surface().as<::Windows::Graphics::DirectX::Direct3D11::
                                         IDirect3DDxgiInterfaceAccess>();
        winrt::com_ptr<ID3D11Texture2D> tex;
        if (FAILED(access->GetInterface(IID_PPV_ARGS(tex.put())))) return false;

        D3D11_BOX box{};
        box.left = rx; box.top = ry; box.front = 0;
        box.right = rx + rw; box.bottom = ry + rh; box.back = 1;
        context->CopySubresourceRegion(staging.get(), 0, 0, 0, 0, tex.get(), 0, &box);

        D3D11_MAPPED_SUBRESOURCE m{};
        if (FAILED(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &m))) return false;
        uint64_t sum = 0;
        for (int y = 0; y < rh; y++) {
            const auto *row = static_cast<const uint8_t *>(m.pData) + y * m.RowPitch;
            // Every 4th pixel: enough to notice one changed glyph cell, a
            // quarter of the work.
            for (int x = 0; x < rw; x += 4) {
                const uint32_t px = *reinterpret_cast<const uint32_t *>(row + x * 4);
                sum = sum * 1099511628211ull ^ px;
            }
        }
        context->Unmap(staging.get(), 0);
        *sumOut = sum;
        *timeOut = f.SystemRelativeTime().count();
        return true;
    };

    forceForeground(hwnd);
    if (GetForegroundWindow() != hwnd) {
        fprintf(stderr, "FAIL target never became foreground - refusing to type\n");
        return 1;
    }
    Sleep(700);

    std::vector<double> results;
    for (int r = 0; r < rounds; r++) {
        // Settle: drain frames until the region stops changing, so the
        // baseline is a still screen and not the tail of the last round.
        uint64_t base = 0; int64_t t = 0;
        int stable = 0;
        for (int i = 0; i < 400 && stable < 6; i++) {
            uint64_t s = 0;
            if (grab(&s, &t)) { stable = (s == base) ? stable + 1 : 0; base = s; }
            Sleep(4);
        }

        int64_t t0 = 0;
        QueryPerformanceCounter(reinterpret_cast<LARGE_INTEGER *>(&t0));
        const int64_t t0_100ns = qpcTo100ns(t0, freq);
        // Always the same key. Alternating with Backspace looked tidier - the
        // screen returns to its start each round - but a Backspace at a prompt
        // that is already empty changes nothing, and those rounds were recorded
        // as "no change detected" rather than as the no-ops they were. Typing
        // the same character repeatedly just walks along the line, which is
        // inside the watch strip either way.
        sendKey('X');

        bool got = false;
        for (int i = 0; i < 600; i++) {  // ~2.4s ceiling
            uint64_t s = 0; int64_t ft = 0;
            if (grab(&s, &ft) && s != base) {
                const double ms = double(ft - t0_100ns) / 10000.0;
                if (ms >= 0 && ms < 2000) {
                    results.push_back(ms);
                    printf("  round %2d: %.1f ms\n", r + 1, ms);
                    got = true;
                }
                break;
            }
            Sleep(1);
        }
        if (!got) printf("  round %2d: no change detected\n", r + 1);
    }

    if (results.empty()) { fprintf(stderr, "FAIL no measurements\n"); return 1; }
    std::sort(results.begin(), results.end());
    const double median = results[results.size() / 2];
    printf("\nn=%zu  min %.1f  median %.1f  max %.1f ms\n",
           results.size(), results.front(), median, results.back());
    return 0;
}
