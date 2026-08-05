// hwnd-host: a minimal Win32 host for libghostty.
//
// This is the Phase 1 deliverable: it drives libghostty's embedded C API far
// enough to prove the D3D11 backend creates a device, builds a swap chain for
// an HWND, and presents a resizable, DPI-correct surface - on hardware and on
// WARP.
//
// It is deliberately not a terminal. There is no input handling and no PTY;
// PLAN Phase 3 adds those. Keeping it this small means a failure here is
// unambiguously a libghostty failure.
//
// Force the software rasterizer with:
//     set GHOSTTY_D3D11_DRIVER=warp
//
// Show libghostty's own logs with:
//     set GHOSTTY_LOG=stderr
// They are OFF by default: src/global.zig defaults stderr logging to
// `build_config.app_runtime != .none`, and libghostty is built with
// -Dapp-runtime=none. Without this, log statements inside libghostty produce
// nothing, which is very easy to misread as the code not running at all.
//
// TWO WINDOWS ARE EXPECTED. This is a console-subsystem executable (it traces
// with fprintf), so Windows gives it a console window of its own alongside the
// terminal window. That empty console with a blinking cursor is NOT a leaked
// ConPTY/conhost for the child shell - the child is attached to our pseudo
// console correctly. Do not go hunting for a PTY bug because of it.
//
// Note also that PrintWindow cannot capture the terminal window's contents:
// the D3D11 backend presents through a flip-model/DirectComposition swap chain
// which DWM composites outside the GDI paint path. Use harness/wgc-shot, which
// captures via Windows Graphics Capture and is scoped to a single window.

// UNICODE selects the wide variants of the resource macros (IDC_ARROW and
// friends) so they match the *W APIs we call throughout.
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellscalingapi.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "extpty.h"
#include "ghostty.h"
#include "winkeys.h"

// Posted by wakeup_cb, which may be called from ghostty's own threads. All we
// may do off-thread is PostMessage; ghostty_app_tick must run on the thread
// that owns the app.
#define WM_GHOSTTY_WAKEUP (WM_APP + 1)

typedef struct {
    HWND hwnd;
    ghostty_app_t app;
    ghostty_surface_t surface;
} host_state;

static host_state g_state = {0};

// --- libghostty runtime callbacks -------------------------------------------

static void wakeup_cb(void *userdata) {
    (void)userdata;
    if (g_state.hwnd) PostMessageW(g_state.hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
}

static bool action_cb(ghostty_app_t app, ghostty_target_s target,
                      ghostty_action_s action) {
    (void)app;
    (void)target;
    // Returning false means "not handled". A real embedder maps these to tab
    // titles, clipboard, bells and so on; the harness ignores all of them.
    (void)action;
    return false;
}

static bool read_clipboard_cb(void *userdata, ghostty_clipboard_e loc,
                              void *state) {
    (void)userdata; (void)loc; (void)state;
    return false;
}

static void confirm_read_clipboard_cb(void *userdata, const char *str,
                                      void *state,
                                      ghostty_clipboard_request_e req) {
    (void)userdata; (void)str; (void)state; (void)req;
}

static void write_clipboard_cb(void *userdata, ghostty_clipboard_e loc,
                               const ghostty_clipboard_content_s *content,
                               size_t content_len, bool confirm) {
    (void)userdata; (void)loc; (void)content; (void)content_len; (void)confirm;
}

static void close_surface_cb(void *userdata, bool process_alive) {
    (void)userdata; (void)process_alive;
    PostQuitMessage(0);
}

// --- external termio (ADR 0006) ----------------------------------------------
//
// Set GHOSTTY_HARNESS_EXTERNAL=1 to run the surface on the external backend:
// this harness owns the ConPTY and the child, exactly as Windows Terminal's
// connection layer does, and libghostty spawns nothing. An environment
// variable rather than a flag because ghostty_config_load_cli_args parses our
// command line and would reject an argument it does not know.
static bool g_external = false;

// Both of these arrive on libghostty's IO thread.
static void write_pty_cb(void *userdata, const uint8_t *data, size_t len) {
    (void)userdata;
    extpty_write(data, len);
}

static void resize_pty_cb(void *userdata, uint16_t cols, uint16_t rows) {
    (void)userdata;
    extpty_resize(cols, rows);
}

// --- Window ------------------------------------------------------------------

static double scale_for_window(HWND hwnd) {
    // GetDpiForWindow is per-monitor aware and is what we want; it needs the
    // per-monitor-v2 DPI awareness set at startup to return anything but 96.
    UINT dpi = GetDpiForWindow(hwnd);
    if (dpi == 0) dpi = USER_DEFAULT_SCREEN_DPI;
    return (double)dpi / (double)USER_DEFAULT_SCREEN_DPI;
}

static void push_size(void) {
    if (!g_state.surface) return;
    RECT rc;
    if (!GetClientRect(g_state.hwnd, &rc)) return;
    const uint32_t w = (uint32_t)(rc.right - rc.left);
    const uint32_t h = (uint32_t)(rc.bottom - rc.top);
    // Windows sends 0x0 on minimize; libghostty has no use for it and the swap
    // chain cannot be resized to zero.
    if (w == 0 || h == 0) return;
    ghostty_surface_set_size(g_state.surface, w, h);
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_GHOSTTY_WAKEUP:
        if (g_state.app) ghostty_app_tick(g_state.app);
        return 0;

    case WM_SIZE:
        push_size();
        return 0;

    case WM_DPICHANGED: {
        // lParam is the suggested new window rect; honouring it is what keeps
        // the window physically the same size across a monitor change.
        const RECT *suggested = (const RECT *)lp;
        SetWindowPos(hwnd, NULL, suggested->left, suggested->top,
                     suggested->right - suggested->left,
                     suggested->bottom - suggested->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        if (g_state.surface) {
            const double scale = scale_for_window(hwnd);
            ghostty_surface_set_content_scale(g_state.surface, scale, scale);
            push_size();
        }
        return 0;
    }

    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(hwnd, &ps);
        if (g_state.surface) ghostty_surface_draw(g_state.surface);
        EndPaint(hwnd, &ps);
        return 0;
    }

    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYUP: {
        if (!g_state.surface) break;

        ghostty_input_key_s ev;
        char text[8];
        if (winkeys_translate(msg, wp, lp, &ev, text)) {
            ghostty_surface_key(g_state.surface, ev);
            // The shell's response arrives on the IO thread, so ask for a
            // repaint rather than assuming this frame already reflects it.
            InvalidateRect(hwnd, NULL, FALSE);
        }

        // WM_SYSKEYDOWN must still reach DefWindowProc for Alt+F4 and the
        // window menu; swallowing it entirely makes the window unclosable by
        // keyboard. Alt-modified keys the terminal wants are already handled
        // above, and passing this along additionally is harmless.
        if (msg == WM_SYSKEYDOWN || msg == WM_SYSKEYUP) break;
        return 0;
    }

    // Text is derived from the key event via ToUnicode, so WM_CHAR would be a
    // duplicate. Swallow it, but let WM_SYSCHAR through so the window menu
    // still works.
    case WM_CHAR:
        return 0;

    // The swap chain owns the pixels; letting GDI erase first causes a visible
    // flash on resize.
    case WM_ERASEBKGND:
        return 1;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// --- main ---------------------------------------------------------------------

// Unbuffered breadcrumbs. Startup failures in libghostty tend to be fatal
// signals rather than error returns, so buffered output would be lost.
static void trace(const char *msg) {
    fprintf(stderr, "[hwnd-host] %s\n", msg);
    fflush(stderr);
}

int main(void) {
    trace("start");
    {
        char buf[8];
        g_external = GetEnvironmentVariableA("GHOSTTY_HARNESS_EXTERNAL", buf, sizeof(buf)) > 0 &&
                     buf[0] == '1';
        if (g_external) trace("io_backend=external (this host owns the ConPTY)");
    }
    // Must precede window creation, or GetDpiForWindow reports 96 forever and
    // the DPI-correctness criterion is untestable.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // ghostty_init on Windows takes the WTF-16 command line, not argv.
    const wchar_t *cmdline = GetCommandLineW();
    if (ghostty_init_w((uintptr_t)wcslen(cmdline), (const uint16_t *)cmdline) != 0) {
        fprintf(stderr, "ghostty_init_w failed\n");
        return 1;
    }

    trace("ghostty_init_w ok");

    ghostty_config_t config = ghostty_config_new();
    if (!config) { fprintf(stderr, "ghostty_config_new failed\n"); return 1; }
    trace("ghostty_config_new ok");
    // Honour ghostty's own CLI flags, so the harness can be pointed at a
    // specific configuration without a config file. `--background=ff0000` is
    // the quickest proof that what is on screen really comes from libghostty.
    ghostty_config_load_cli_args(config);
    ghostty_config_finalize(config);
    trace("ghostty_config_finalize ok");

    ghostty_runtime_config_s runtime = {
        .userdata = NULL,
        .supports_selection_clipboard = false,
        .wakeup_cb = wakeup_cb,
        .action_cb = action_cb,
        .read_clipboard_cb = read_clipboard_cb,
        .confirm_read_clipboard_cb = confirm_read_clipboard_cb,
        .write_clipboard_cb = write_clipboard_cb,
        .close_surface_cb = close_surface_cb,
        .write_pty_cb = write_pty_cb,
        .resize_pty_cb = resize_pty_cb,
    };

    g_state.app = ghostty_app_new(&runtime, config);
    if (!g_state.app) { fprintf(stderr, "ghostty_app_new failed\n"); return 1; }
    trace("ghostty_app_new ok");

    const HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSEXW wc = {
        .cbSize = sizeof(wc),
        .style = CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = wnd_proc,
        .hInstance = inst,
        .hCursor = LoadCursorW(NULL, IDC_ARROW),
        .lpszClassName = L"GhosttyHwndHost",
    };
    if (!RegisterClassExW(&wc)) { fprintf(stderr, "RegisterClassExW failed\n"); return 1; }

    g_state.hwnd = CreateWindowExW(
        0, wc.lpszClassName, L"libghostty hwnd-host",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1024, 640,
        NULL, NULL, inst, NULL);
    if (!g_state.hwnd) { fprintf(stderr, "CreateWindowExW failed\n"); return 1; }

    RECT rc;
    GetClientRect(g_state.hwnd, &rc);

    ghostty_surface_config_s surface_config = ghostty_surface_config_new();
    surface_config.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
    surface_config.platform.windows.hwnd = g_state.hwnd;
    surface_config.platform.windows.composition = false;
    surface_config.platform.windows.shared_texture.enabled = false;
    surface_config.scale_factor = scale_for_window(g_state.hwnd);
    if (g_external) surface_config.io_backend = GHOSTTY_IO_BACKEND_EXTERNAL;

    trace("calling ghostty_surface_new");
    g_state.surface = ghostty_surface_new(g_state.app, &surface_config);
    if (!g_state.surface) {
        fprintf(stderr, "ghostty_surface_new failed - see the log for the reason\n");
        return 1;
    }
    trace("ghostty_surface_new ok");

    push_size();

    // After the surface exists, so the reader thread has something to feed,
    // and after push_size, so the grid size resize_pty_cb recorded is the one
    // the surface actually ended up with rather than its initial guess.
    if (g_external && !extpty_start(g_state.surface, L"cmd.exe", 0, 0)) {
        fprintf(stderr, "extpty_start failed\n");
        return 1;
    }

    ShowWindow(g_state.hwnd, SW_SHOW);

    // Unattended round-trip check: GHOSTTY_HARNESS_INPUT=dir\r drives text
    // through the terminal's own encoder and out the write path, so an
    // automated run can prove input reaches the child without a keyboard.
    {
        char input[256];
        const DWORD n = GetEnvironmentVariableA("GHOSTTY_HARNESS_INPUT", input, sizeof(input));
        if (n > 0 && n < sizeof(input)) {
            // Let the child get to a prompt first; typing into cmd.exe before
            // it is reading only proves the pipe buffers.
            Sleep(1500);
            // Two-character "\r" in the environment is easier to pass than a
            // literal carriage return.
            char *cr = strstr(input, "\\r");
            if (cr) { cr[0] = '\r'; cr[1] = '\0'; }
            fprintf(stderr, "[hwnd-host] sending %zu bytes of synthetic input\n", strlen(input));
            fflush(stderr);
            ghostty_surface_text(g_state.surface, input, strlen(input));
        }
    }

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    // Before the surface, because the reader thread calls into it.
    extpty_stop();
    ghostty_surface_free(g_state.surface);
    ghostty_app_free(g_state.app);
    return 0;
}
