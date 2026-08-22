// keylog - what the keyboard actually delivered, in order, with timings.
//
// Built for KD-25: `?` typed from the Windows App on Android arrived in a
// ghostty pane as `/`, and `A` as `a`. Two mechanisms produce exactly that and
// they need opposite fixes:
//
//   1. The client presses shift, sends the key and releases shift back to
//      back, and the modifier snapshot TermControl takes when XAML raises
//      KeyDown is taken after the release. Shift *is* in the event stream, so
//      tracking the stream fixes it.
//   2. The client never sends shift at all - it sends the base key and relies
//      on the character message alone. Nothing in the key stream says shift,
//      so only the character Windows produced can be trusted.
//
// A low-level hook sees the injected events themselves, before any window
// does, so it can tell those two apart and say how far apart the events were.
//
// Usage: keylog [logfile] [seconds]
//
// It logs every key on the desktop, so it is a probe to run deliberately and
// stop, not something to leave on.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <share.h>

#include <cstdio>
#include <string>

namespace
{
    FILE* g_log = nullptr;
    LARGE_INTEGER g_freq{};
    LARGE_INTEGER g_start{};
    HHOOK g_hook = nullptr;

    double now_ms()
    {
        LARGE_INTEGER t;
        QueryPerformanceCounter(&t);
        return static_cast<double>(t.QuadPart - g_start.QuadPart) * 1000.0 /
               static_cast<double>(g_freq.QuadPart);
    }

    // The name matters more than the number when reading the log back: the
    // question is "was shift held around this key", and 0xA0 does not answer
    // it at a glance.
    std::string vk_name(DWORD vk)
    {
        switch (vk)
        {
        case VK_SHIFT: return "SHIFT";
        case VK_LSHIFT: return "LSHIFT";
        case VK_RSHIFT: return "RSHIFT";
        case VK_CONTROL: return "CTRL";
        case VK_LCONTROL: return "LCTRL";
        case VK_RCONTROL: return "RCTRL";
        case VK_MENU: return "ALT";
        case VK_LMENU: return "LALT";
        case VK_RMENU: return "RALT";
        case VK_CAPITAL: return "CAPSLOCK";
        case VK_PACKET: return "PACKET";
        case VK_RETURN: return "ENTER";
        case VK_BACK: return "BACKSPACE";
        case VK_TAB: return "TAB";
        case VK_SPACE: return "SPACE";
        default: break;
        }

        char buf[32];
        if (vk >= 0x20 && vk < 0x7F)
        {
            std::snprintf(buf, sizeof(buf), "'%c'", static_cast<char>(vk));
        }
        else
        {
            std::snprintf(buf, sizeof(buf), "0x%02X", static_cast<unsigned>(vk));
        }
        return buf;
    }

    LRESULT CALLBACK hook_proc(int code, WPARAM wparam, LPARAM lparam)
    {
        if (code == HC_ACTION)
        {
            const auto* k = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
            const auto up = (wparam == WM_KEYUP || wparam == WM_SYSKEYUP);

            // What each flag means for the question being asked:
            //   INJECTED  the event came from SendInput, not hardware - which
            //             is what a remote desktop client produces
            //   PACKET    vkCode is VK_PACKET and scanCode carries a UTF-16
            //             unit: the client sent a character, not a key
            std::string flags;
            if (k->flags & LLKHF_INJECTED) { flags += " injected"; }
            if (k->flags & LLKHF_LOWER_IL_INJECTED) { flags += " lowIL"; }
            if (k->flags & LLKHF_EXTENDED) { flags += " extended"; }
            if (k->flags & LLKHF_ALTDOWN) { flags += " altdown"; }

            // The state a window would see if it asked at this instant, which
            // is the thing the ghostty pane got wrong.
            const auto shiftNow = (GetKeyState(VK_SHIFT) & 0x8000) != 0;

            std::fprintf(g_log,
                         "%9.2f ms  %-4s %-10s vk=0x%02X scan=0x%02X shiftState=%d%s\n",
                         now_ms(),
                         up ? "up" : "down",
                         vk_name(k->vkCode).c_str(),
                         static_cast<unsigned>(k->vkCode),
                         static_cast<unsigned>(k->scanCode),
                         shiftNow ? 1 : 0,
                         flags.c_str());
            std::fflush(g_log);
        }

        return CallNextHookEx(g_hook, code, wparam, lparam);
    }
}

int wmain(int argc, wchar_t** argv)
{
    const std::wstring path = argc > 1 ? argv[1] : L"keylog.txt";
    const auto seconds = argc > 2 ? _wtoi(argv[2]) : 60;

    // Shared, so the log can be read while the probe is still running - the
    // whole point is to look at it between keystrokes.
    g_log = _wfsopen(path.c_str(), L"w", _SH_DENYNO);
    if (!g_log)
    {
        std::fwprintf(stderr, L"cannot write %s\n", path.c_str());
        return 1;
    }

    QueryPerformanceFrequency(&g_freq);
    QueryPerformanceCounter(&g_start);

    g_hook = SetWindowsHookExW(WH_KEYBOARD_LL, hook_proc, GetModuleHandleW(nullptr), 0);
    if (!g_hook)
    {
        std::fwprintf(stderr, L"SetWindowsHookEx failed: %lu\n", GetLastError());
        return 1;
    }

    std::fprintf(g_log, "--- keylog, %d s ---\n", seconds);
    std::fflush(g_log);
    std::wprintf(L"keylog: watching for %d s, writing %s\n", seconds, path.c_str());

    // A low-level hook is called on the thread that installed it, and only
    // while that thread pumps messages.
    const auto deadline = GetTickCount64() + static_cast<ULONGLONG>(seconds) * 1000;
    MSG msg;
    for (;;)
    {
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (GetTickCount64() >= deadline) { break; }
        Sleep(10);
    }

    UnhookWindowsHookEx(g_hook);
    std::fprintf(g_log, "--- done ---\n");
    std::fclose(g_log);
    return 0;
}
