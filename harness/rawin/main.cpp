// rawin - show the bytes a terminal actually sends to its child.
//
// Built for GD-15 (#15): a `sendInput` action carrying an escape sequence was
// arriving with every ESC replaced by a space and the whole thing framed as a
// bracketed paste, because GhosttyControlCore::SendInput went through
// libghostty's *paste* entry point. Screenshots cannot show that - the pane
// looks the same either way, since what changed is what the child received.
// This reads the child end and names each byte.
//
// Usage: rawin [logfile] [seconds]
//   logfile  where to append the decoded stream (default rawin.log)
//   seconds  how long to read before exiting (default 60)
//
// It turns DEC mode 2004 (bracketed paste) on for itself, so a paste is
// expected to arrive fenceposted and anything else is expected not to.
//
// Console mode matters as much as the reading: without
// ENABLE_VIRTUAL_TERMINAL_INPUT the host translates the stream into
// INPUT_RECORDs and the raw bytes never reach us, and with ENABLE_LINE_INPUT
// nothing arrives until Enter.

#include <windows.h>

#include <share.h>

#include <cstdio>
#include <cstdlib>
#include <string>

namespace
{
    // Printable-ASCII stays itself; everything else gets a name, because
    // "<ESC>" in a log is legible and 0x1b is not.
    std::string describe(unsigned char b)
    {
        switch (b)
        {
        case 0x00: return "<NUL>";
        case 0x07: return "<BEL>";
        case 0x08: return "<BS>";
        case 0x09: return "<TAB>";
        case 0x0a: return "<LF>";
        case 0x0d: return "<CR>";
        case 0x1b: return "<ESC>";
        case 0x20: return " ";
        case 0x7f: return "<DEL>";
        default: break;
        }

        if (b > 0x20 && b < 0x7f)
        {
            return std::string(1, static_cast<char>(b));
        }

        char buf[16];
        // Control characters are the whole point of this tool - Ctrl+C is 0x03
        // and the paste encoder turns it into a space, so it has to be visible
        // as itself rather than folded in with the printable range.
        std::snprintf(buf, sizeof(buf), "<0x%02X>", b);
        return buf;
    }
}

int main(int argc, char** argv)
{
    const char* logPath = argc > 1 ? argv[1] : "rawin.log";
    const int seconds = argc > 2 ? std::atoi(argv[2]) : 60;

    const auto in = GetStdHandle(STD_INPUT_HANDLE);
    const auto out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (in == INVALID_HANDLE_VALUE || out == INVALID_HANDLE_VALUE)
    {
        std::fprintf(stderr, "no std handles\n");
        return 1;
    }

    DWORD savedIn = 0;
    DWORD savedOut = 0;
    GetConsoleMode(in, &savedIn);
    GetConsoleMode(out, &savedOut);

    // Raw: no line buffering, no echo, no Ctrl+C handling (we want to *see*
    // 0x03), and VT input so bytes arrive as bytes.
    DWORD rawIn = savedIn;
    rawIn &= ~static_cast<DWORD>(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
    rawIn |= ENABLE_VIRTUAL_TERMINAL_INPUT;
    SetConsoleMode(in, rawIn);
    SetConsoleMode(out, savedOut | ENABLE_VIRTUAL_TERMINAL_PROCESSING);

    // Ask for bracketed paste. A correct terminal frames pastes after this and
    // leaves everything else alone; the bug being chased framed everything.
    std::printf("\x1b[?2004h");
    std::fflush(stdout);

    // _fsopen with _SH_DENYNO, not fopen: the log has to be readable *while*
    // the probe is still running, because the run is driven from another
    // process that wants to see the bytes as they land rather than after a
    // timeout expires.
    FILE* log = _fsopen(logPath, "a", _SH_DENYNO);
    if (!log)
    {
        std::fprintf(stderr, "cannot open %s\n", logPath);
        return 1;
    }

    std::fprintf(log, "--- rawin start, mode 2004 on, %d s ---\n", seconds);
    std::fflush(log);
    std::printf("rawin: reading for %d s, logging to %s\r\n", seconds, logPath);
    std::printf("rawin: bracketed paste requested (mode 2004 on)\r\n");
    std::fflush(stdout);

    const auto deadline = GetTickCount64() + static_cast<ULONGLONG>(seconds) * 1000;

    // A line is flushed per read rather than per byte: one read is one write
    // from the terminal, so the grouping itself is evidence - a paste arrives
    // as one chunk with its fenceposts.
    while (GetTickCount64() < deadline)
    {
        const auto remaining = deadline - GetTickCount64();
        if (WaitForSingleObject(in, static_cast<DWORD>(remaining > 500 ? 500 : remaining)) != WAIT_OBJECT_0)
        {
            continue;
        }

        char buf[4096];
        DWORD read = 0;
        if (!ReadFile(in, buf, sizeof(buf), &read, nullptr) || read == 0)
        {
            continue;
        }

        std::string decoded;
        for (DWORD i = 0; i < read; ++i)
        {
            decoded += describe(static_cast<unsigned char>(buf[i]));
        }

        std::fprintf(log, "recv[%lu]: %s\n", read, decoded.c_str());
        std::fflush(log);
        std::printf("recv[%lu]: %s\r\n", read, decoded.c_str());
        std::fflush(stdout);
    }

    std::fprintf(log, "--- rawin end ---\n");
    std::fclose(log);

    std::printf("\x1b[?2004l");
    std::printf("rawin: done\r\n");
    std::fflush(stdout);

    SetConsoleMode(in, savedIn);
    SetConsoleMode(out, savedOut);
    return 0;
}
