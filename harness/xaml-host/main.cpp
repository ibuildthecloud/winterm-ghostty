// xaml-host: proves the Windows Terminal integration primitive.
//
// libghostty renders into a DirectComposition surface handle; this host binds
// that handle into a XAML SwapChainPanel with
// ISwapChainPanelNative2::SetSwapChainHandle. That is byte-for-byte what
// Windows Terminal already does in TermControl::_AttachDxgiSwapChainToXaml, so
// if this works, Phase 5 is plugging a different handle producer into an attach
// path WT already has.
//
// Deliberately **system XAML** (Windows.UI.Xaml) hosted in a XAML Island, not
// WinUI 3 (Microsoft.UI.Xaml). WT uses system XAML, and the
// ISwapChainPanelNative2 IIDs differ between the two stacks - proving the wrong
// one would prove nothing about our only target.
//
// Everything here comes from the Windows SDK; no NuGet packages.

#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellscalingapi.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Xaml.h>
#include <winrt/Windows.UI.Xaml.Controls.h>
#include <winrt/Windows.UI.Xaml.Hosting.h>
#include <windows.ui.xaml.hosting.desktopwindowxamlsource.h>
#include <windows.ui.xaml.media.dxinterop.h>

#include <cstdio>
#include <cstdint>

#include "ghostty.h"

using namespace winrt;
using namespace Windows::UI::Xaml;
using namespace Windows::UI::Xaml::Controls;
using namespace Windows::UI::Xaml::Hosting;

#define WM_GHOSTTY_WAKEUP     (WM_APP + 1)
#define WM_GHOSTTY_REATTACH   (WM_APP + 2)

namespace {

struct HostState {
    HWND hwnd{};
    HWND island{};
    ghostty_app_t app{};
    ghostty_surface_t surface{};
    DesktopWindowXamlSource xamlSource{nullptr};
    SwapChainPanel panel{nullptr};
    HANDLE boundHandle{};
};

HostState g;

void trace(const char* msg) {
    std::fprintf(stderr, "[xaml-host] %s\n", msg);
    std::fflush(stderr);
}

// --- the whole point of this harness ---------------------------------------

// Mirrors TermControl::_AttachDxgiSwapChainToXaml.
void attachSwapChain() {
    if (!g.surface || !g.panel) return;

    auto handle = static_cast<HANDLE>(ghostty_surface_get_swap_chain_handle(g.surface));
    if (handle == nullptr) {
        trace("no swap chain handle yet");
        return;
    }
    if (handle == g.boundHandle) return; // already bound to this one

    auto native = g.panel.as<ISwapChainPanelNative2>();
    winrt::check_hresult(native->SetSwapChainHandle(handle));
    g.boundHandle = handle;

    std::fprintf(stderr, "[xaml-host] bound swap chain handle %p\n", handle);
    std::fflush(stderr);
}

// --- libghostty runtime callbacks -------------------------------------------

void wakeup_cb(void*) {
    if (g.hwnd) PostMessageW(g.hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
}

bool action_cb(ghostty_app_t, ghostty_target_s, ghostty_action_s action) {
    if (action.tag == GHOSTTY_ACTION_SWAP_CHAIN_CHANGED) {
        // The device was rebuilt and our handle is stale. Marshal to the UI
        // thread; XAML must not be touched from anywhere else.
        if (g.hwnd) PostMessageW(g.hwnd, WM_GHOSTTY_REATTACH, 0, 0);
        return true;
    }
    return false;
}

bool read_clipboard_cb(void*, ghostty_clipboard_e, void*) { return false; }
void confirm_read_clipboard_cb(void*, const char*, void*, ghostty_clipboard_request_e) {}
void write_clipboard_cb(void*, ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool) {}
void close_surface_cb(void*, bool) { PostQuitMessage(0); }

// --- window -----------------------------------------------------------------

double scaleForWindow(HWND hwnd) {
    UINT dpi = GetDpiForWindow(hwnd);
    if (dpi == 0) dpi = USER_DEFAULT_SCREEN_DPI;
    return static_cast<double>(dpi) / USER_DEFAULT_SCREEN_DPI;
}

void layout() {
    if (!g.hwnd) return;
    RECT rc{};
    if (!GetClientRect(g.hwnd, &rc)) return;
    const auto w = rc.right - rc.left;
    const auto h = rc.bottom - rc.top;
    if (w <= 0 || h <= 0) return; // minimized

    if (g.island) {
        SetWindowPos(g.island, nullptr, 0, 0, w, h, SWP_NOZORDER | SWP_SHOWWINDOW);
    }
    if (g.surface) {
        // In composition mode there is no window for libghostty to measure, so
        // this call is the only thing that sizes the swap chain.
        ghostty_surface_set_size(g.surface, static_cast<uint32_t>(w), static_cast<uint32_t>(h));
    }
}

LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_GHOSTTY_WAKEUP:
        if (g.app) ghostty_app_tick(g.app);
        return 0;

    case WM_GHOSTTY_REATTACH:
        trace("swap chain changed, re-attaching");
        g.boundHandle = nullptr; // force a re-bind
        attachSwapChain();
        return 0;

    case WM_SIZE:
        layout();
        return 0;

    case WM_DPICHANGED: {
        const RECT* suggested = reinterpret_cast<const RECT*>(lp);
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
                     suggested->right - suggested->left,
                     suggested->bottom - suggested->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        if (g.surface) {
            const auto scale = scaleForWindow(hwnd);
            ghostty_surface_set_content_scale(g.surface, scale, scale);
        }
        layout();
        return 0;
    }

    case WM_SETFOCUS:
        // Hand focus to the island so XAML behaves normally.
        if (g.island) SetFocus(g.island);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

} // namespace

int run();

int main() {
    // C++/WinRT turns failed HRESULTs into exceptions, and an unhandled one
    // fail-fasts (0xC0000409) with no message at all. Catching it is the
    // difference between a diagnosis and a guess.
    try {
        return run();
    } catch (winrt::hresult_error const& e) {
        std::fprintf(stderr, "[xaml-host] hresult_error 0x%08X: %ls\n",
                     static_cast<unsigned>(e.code()), e.message().c_str());
        std::fflush(stderr);
        return 1;
    } catch (std::exception const& e) {
        std::fprintf(stderr, "[xaml-host] exception: %s\n", e.what());
        std::fflush(stderr);
        return 1;
    }
}

int run() {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    trace("start");

    // XAML islands require an STA.
    init_apartment(apartment_type::single_threaded);

    const wchar_t* cmdline = GetCommandLineW();
    if (ghostty_init_w(static_cast<uintptr_t>(wcslen(cmdline)),
                       reinterpret_cast<const uint16_t*>(cmdline)) != 0) {
        trace("ghostty_init_w failed");
        return 1;
    }

    ghostty_config_t config = ghostty_config_new();
    if (!config) { trace("ghostty_config_new failed"); return 1; }
    ghostty_config_load_cli_args(config);
    ghostty_config_finalize(config);

    ghostty_runtime_config_s runtime{};
    runtime.userdata = nullptr;
    runtime.supports_selection_clipboard = false;
    runtime.wakeup_cb = wakeup_cb;
    runtime.action_cb = action_cb;
    runtime.read_clipboard_cb = read_clipboard_cb;
    runtime.confirm_read_clipboard_cb = confirm_read_clipboard_cb;
    runtime.write_clipboard_cb = write_clipboard_cb;
    runtime.close_surface_cb = close_surface_cb;

    g.app = ghostty_app_new(&runtime, config);
    if (!g.app) { trace("ghostty_app_new failed"); return 1; }
    trace("ghostty_app_new ok");

    const HINSTANCE inst = GetModuleHandleW(nullptr);
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"GhosttyXamlHost";
    if (!RegisterClassExW(&wc)) { trace("RegisterClassExW failed"); return 1; }

    g.hwnd = CreateWindowExW(0, wc.lpszClassName, L"libghostty xaml-host",
                             WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                             1024, 640, nullptr, nullptr, inst, nullptr);
    if (!g.hwnd) { trace("CreateWindowExW failed"); return 1; }

    trace("window created; initializing WindowsXamlManager");
    // Bring up system XAML in this thread, then host it in our window.
    auto xamlManager = WindowsXamlManager::InitializeForCurrentThread();
    trace("WindowsXamlManager initialized");

    g.xamlSource = DesktopWindowXamlSource{};
    auto sourceNative = g.xamlSource.as<IDesktopWindowXamlSourceNative>();
    winrt::check_hresult(sourceNative->AttachToWindow(g.hwnd));
    winrt::check_hresult(sourceNative->get_WindowHandle(&g.island));
    trace("XAML island attached");

    g.panel = SwapChainPanel{};
    g.xamlSource.Content(g.panel);

    // CompositionScale is XAML's view of the DPI/transform applied to the
    // panel. It is not always the same as the window DPI - a scaled parent
    // transform changes it - so the panel is the authority for the renderer.
    g.panel.CompositionScaleChanged([](auto&& sender, auto&&) {
        if (!g.surface) return;
        const auto sx = sender.CompositionScaleX();
        const auto sy = sender.CompositionScaleY();
        std::fprintf(stderr, "[xaml-host] composition scale %.2f x %.2f\n", sx, sy);
        std::fflush(stderr);
        ghostty_surface_set_content_scale(g.surface, sx, sy);
    });

    ghostty_surface_config_s sc = ghostty_surface_config_new();
    sc.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
    sc.platform.windows.hwnd = nullptr;
    sc.platform.windows.composition = true;   // <- the mode under test
    sc.platform.windows.shared_texture.enabled = false;
    sc.scale_factor = scaleForWindow(g.hwnd);

    trace("calling ghostty_surface_new (composition mode)");
    g.surface = ghostty_surface_new(g.app, &sc);
    if (!g.surface) { trace("ghostty_surface_new failed - see the log"); return 1; }
    trace("ghostty_surface_new ok");

    layout();
    attachSwapChain();

    ShowWindow(g.hwnd, SW_SHOW);

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        // Give XAML first refusal on the message, or keyboard and focus
        // handling inside the island misbehave.
        BOOL handled = FALSE;
        if (auto sourceNative2 = g.xamlSource.as<IDesktopWindowXamlSourceNative2>()) {
            if (SUCCEEDED(sourceNative2->PreTranslateMessage(&msg, &handled)) && handled) {
                continue;
            }
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    ghostty_surface_free(g.surface);
    ghostty_app_free(g.app);
    return 0;
}
