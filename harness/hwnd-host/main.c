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

#include "crashinfo.h"
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

// GHOSTTY_HARNESS_EXIT_MS's and GHOSTTY_HARNESS_INPUT's timers.
#define EXIT_TIMER_ID 1
#define INPUT_TIMER_ID 2

static char g_input[256] = {0};

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_TIMER:
        if (wp == EXIT_TIMER_ID) {
            KillTimer(hwnd, EXIT_TIMER_ID);
            PostQuitMessage(0);
        }
        else if (wp == INPUT_TIMER_ID) {
            KillTimer(hwnd, INPUT_TIMER_ID);
            if (g_state.surface && g_input[0]) {
                fprintf(stderr, "[hwnd-host] sending %zu bytes of synthetic input\n", strlen(g_input));
                fflush(stderr);
                ghostty_surface_text(g_state.surface, g_input, strlen(g_input));
            }
        }
        return 0;

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
    crashinfo_install();
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
    // GHOSTTY_HARNESS_CMD overrides the child, so an unattended run can use
    // something that prints and exits rather than an interactive shell.
    wchar_t child[512] = L"cmd.exe";
    {
        wchar_t buf[512];
        const DWORD n = GetEnvironmentVariableW(L"GHOSTTY_HARNESS_CMD", buf, 512);
        if (n > 0 && n < 512) wcsncpy_s(child, 512, buf, _TRUNCATE);
    }
    if (g_external && !extpty_start(g_state.surface, child, 0, 0)) {
        fprintf(stderr, "extpty_start failed\n");
        return 1;
    }

    ShowWindow(g_state.hwnd, SW_SHOW);

    // Unattended crash check: GHOSTTY_HARNESS_FEED=<file> pushes the file's
    // bytes straight down the path Windows Terminal uses - the parser, the
    // grapheme tables, the renderer - without needing a child that can be
    // persuaded to emit them. This is how a smoke run reproduces the
    // non-ASCII crash (see docs/sessions, patch 0024) without a keyboard.
    {
        char path[MAX_PATH];
        const DWORD n = GetEnvironmentVariableA("GHOSTTY_HARNESS_FEED", path, sizeof(path));
        if (n > 0 && n < sizeof(path)) {
            if (!g_external) {
                fprintf(stderr, "[hwnd-host] GHOSTTY_HARNESS_FEED needs GHOSTTY_HARNESS_EXTERNAL=1\n");
                return 2;
            }
            FILE *f = fopen(path, "rb");
            if (!f) {
                fprintf(stderr, "[hwnd-host] cannot open feed file %s\n", path);
                return 2;
            }
            static char feed[1 << 20];
            const size_t got = fread(feed, 1, sizeof(feed), f);
            fclose(f);
            fprintf(stderr, "[hwnd-host] feeding %zu bytes of pty output\n", got);
            fflush(stderr);
            ghostty_surface_write_pty_output(g_state.surface, (const uint8_t *)feed, got);
            ghostty_surface_render_now(g_state.surface);
            fprintf(stderr, "[hwnd-host] feed survived\n");
            fflush(stderr);

            // GHOSTTY_HARNESS_READBACK=1 reads the whole screen back out
            // through ghostty_surface_read_text. This is the exact selection
            // shape Windows Terminal's ReadEntireBuffer uses - SCREEN with
            // TOP_LEFT/BOTTOM_RIGHT coords, meaning the whole buffer without
            // having to know how big it is - so a smoke run can prove that
            // shape returns what was fed in.
            char rb[8];
            if (GetEnvironmentVariableA("GHOSTTY_HARNESS_READBACK", rb, sizeof(rb)) > 0 && rb[0] == '1') {
                ghostty_selection_s all = {0};
                all.top_left.tag = GHOSTTY_POINT_SCREEN;
                all.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT;
                all.bottom_right.tag = GHOSTTY_POINT_SCREEN;
                all.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT;
                all.rectangle = false;

                ghostty_text_s out = {0};
                if (!ghostty_surface_read_text(g_state.surface, all, &out)) {
                    fprintf(stderr, "[hwnd-host] readback FAILED\n");
                } else {
                    fprintf(stderr, "[hwnd-host] readback %zu bytes: ", out.text_len);
                    for (size_t i = 0; i < out.text_len; i++) {
                        const unsigned char c = (unsigned char)out.text[i];
                        if (c == '\n') fprintf(stderr, "<LF>");
                        else if (c < 0x20) fprintf(stderr, "<%02x>", c);
                        else fputc(c, stderr);
                    }
                    fprintf(stderr, "\n");
                    ghostty_surface_free_text(g_state.surface, &out);
                }
                fflush(stderr);
            }

            // GHOSTTY_HARNESS_SELECT=x1,y1,x2,y2 (in cells) drives exactly the
            // sequence Windows Terminal's GhosttyControlCore drives for a
            // drag-selection - mouse_pos, press, mouse_pos, then read the
            // selection back - and prints what ghostty says is selected.
            //
            // The point is the *sequence*, not the geometry. WT never reports
            // a button release outside VT mouse mode, so its core synthesises
            // one lazily; this proves the press/move/read order actually
            // produces a selection before that inference is trusted in a pane
            // nobody can drag a mouse in unattended.
            char sel[64];
            if (GetEnvironmentVariableA("GHOSTTY_HARNESS_SELECT", sel, sizeof(sel)) > 0) {
                int x1 = 0, y1 = 0, x2 = 0, y2 = 0;
                if (sscanf(sel, "%d,%d,%d,%d", &x1, &y1, &x2, &y2) == 4) {
                    const ghostty_surface_size_s size = ghostty_surface_size(g_state.surface);
                    const double cw = size.cell_width_px, ch = size.cell_height_px;
                    fprintf(stderr, "[hwnd-host] cell %.1fx%.1f px\n", cw, ch);

                    ghostty_surface_mouse_pos(g_state.surface, (x1 + 0.5) * cw, (y1 + 0.5) * ch, GHOSTTY_MODS_NONE);
                    ghostty_surface_mouse_button(g_state.surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE);
                    ghostty_surface_mouse_pos(g_state.surface, (x2 + 0.5) * cw, (y2 + 0.5) * ch, GHOSTTY_MODS_NONE);

                    fprintf(stderr, "[hwnd-host] has_selection=%d\n",
                            ghostty_surface_has_selection(g_state.surface) ? 1 : 0);

                    ghostty_text_s got = {0};
                    if (!ghostty_surface_read_selection(g_state.surface, &got)) {
                        fprintf(stderr, "[hwnd-host] read_selection FAILED\n");
                    } else {
                        fprintf(stderr, "[hwnd-host] selection %zu bytes: ", got.text_len);
                        for (size_t i = 0; i < got.text_len; i++) {
                            const unsigned char c = (unsigned char)got.text[i];
                            if (c == '\n') fprintf(stderr, "<LF>");
                            else if (c < 0x20) fprintf(stderr, "<%02x>", c);
                            else fputc(c, stderr);
                        }
                        fprintf(stderr, "\n");
                        ghostty_surface_free_text(g_state.surface, &got);
                    }

                    // The lazy release WT's core performs before the next
                    // selection. If this ever stops being a no-op for the
                    // selection state, the core's assumption is wrong.
                    ghostty_surface_mouse_button(g_state.surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE);
                    fprintf(stderr, "[hwnd-host] after release has_selection=%d\n",
                            ghostty_surface_has_selection(g_state.surface) ? 1 : 0);
                    fflush(stderr);
                }
            }
        }
    }

    // Unattended runs need to end by themselves. A timer rather than a sleep
    // so the message loop keeps running: the bugs worth catching here happen
    // on the render and IO paths, which need the loop pumping to reach.
    {
        char ms[32];
        const DWORD n = GetEnvironmentVariableA("GHOSTTY_HARNESS_EXIT_MS", ms, sizeof(ms));
        if (n > 0 && n < sizeof(ms)) {
            const UINT delay = (UINT)atoi(ms);
            if (delay > 0) SetTimer(g_state.hwnd, EXIT_TIMER_ID, delay, NULL);
        }
    }

    // Unattended round-trip check: GHOSTTY_HARNESS_INPUT=dir\r drives text
    // through the terminal's own encoder and out the write path, so an
    // automated run can prove input reaches the child without a keyboard.
    {
        const DWORD n = GetEnvironmentVariableA("GHOSTTY_HARNESS_INPUT",
                                                g_input, sizeof(g_input));
        if (n > 0 && n < sizeof(g_input)) {
            // Two-character "\r" in the environment is easier to pass than a
            // literal carriage return.
            char *cr = strstr(g_input, "\\r");
            if (cr) { cr[0] = '\r'; cr[1] = '\0'; }

            // On a timer rather than a sleep, and after the message loop is
            // running: typing into cmd.exe before it reaches a prompt only
            // proves the pipe buffers, and a sleep here would stop the loop -
            // which would hide exactly the repaint bugs this exists to catch.
            // GHOSTTY_HARNESS_INPUT_DELAY_MS moves it, so a capture can be
            // taken before the output it causes.
            UINT delay = 1500;
            char ms[32];
            const DWORD dn = GetEnvironmentVariableA("GHOSTTY_HARNESS_INPUT_DELAY_MS", ms, sizeof(ms));
            if (dn > 0 && dn < sizeof(ms) && atoi(ms) > 0) delay = (UINT)atoi(ms);
            SetTimer(g_state.hwnd, INPUT_TIMER_ID, delay, NULL);
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
