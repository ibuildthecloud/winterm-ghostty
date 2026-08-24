// conpty-box - drive a ConPTY directly and judge what it emits.
//
// The reported failure (see docs/known-defects.md, KD-26) is a full-screen TUI
// frame, written to the pty in one large escape-dense write, arriving mangled:
// the frame lands a row low, stale rows survive underneath it, and tails of
// escape sequences are printed as literal text. It reproduces on our build and
// not on the shipping 1.24 terminal, with only OpenConsole.exe differing - so
// the suspect is the ConPTY host, which re-parses the application's output into
// its own buffer and re-emits VT.
//
// Two things make that hard to chase by hand, and this exists to remove both:
//
//   1. It needs a 293x80 window and a human to look at it. Here there is no
//      window at all: the pty is whatever size is asked for, and the answer is
//      the byte stream ConPTY produced.
//   2. It is a race - roughly half of identical runs are clean - so a single
//      run proves nothing either way. This runs the same payload N times and
//      reports how many failed.
//
// Usage:
//   conpty-box --host <dir> [--cols N] [--rows N] [--iterations N]
//              [--sgr N] [--keep <file>] [--verbose]
//   conpty-box --emit --cols N --rows N --sgr N        (internal: the child)
//
// --host is a directory holding conpty.dll and the OpenConsole.exe under test;
// conpty.dll looks for the host beside itself, which is what lets one harness
// binary test any build without relinking. Omit it to use whatever ConPTY the
// system provides.
//
// HOW THE JUDGEMENT WORKS, and why it needs no VT emulator:
//
// The payload's *text* is drawn from a deliberately tiny alphabet - the box
// characters, '#' and space - while carrying hundreds of SGR sequences and
// absolute cursor moves. A conformant ConPTY may re-encode the escape sequences
// however it likes, and may split or merge them, but it can never invent text
// that the application did not print. So any text byte outside that alphabet in
// what ConPTY emitted is proof that a sequence was mis-parsed and its tail
// printed - which is exactly the reported symptom, and it is checked with a
// state machine that only has to tell escape sequences from text.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "responder.h"

namespace
{
    // The ConPTY entry points, resolved from the conpty.dll under test rather
    // than linked, so the host being measured is a runtime choice.
    using PFN_CREATE = HRESULT(WINAPI*)(COORD, HANDLE, HANDLE, DWORD, void**);
    using PFN_CLOSE = void(WINAPI*)(void*);

    PFN_CREATE g_create = nullptr;
    PFN_CLOSE g_close = nullptr;

    struct Options
    {
        std::wstring host;
        int cols = 293;
        int rows = 80;
        int iterations = 40;
        int sgr = 700;
        // Write the frame in chunks of this many bytes, cutting wherever they
        // fall - including through the middle of an escape sequence. Zero means
        // one write per frame.
        //
        // This is the variable the report points at: the application writes
        // once, but the bytes reach the parser in arbitrary pieces, and a
        // parser that does not carry state across those boundaries prints the
        // tail of the sequence it lost. Their `chunked` mode, which never cuts
        // a sequence, never corrupts.
        int split = 0;
        // The flags WT passes: PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES (0x08) is
        // its default text measurement, and it decides how many cells a
        // character occupies - which is the difference between a row that fits
        // and a row that wraps. Creating the pty with 0 measures differently
        // from every real pane, so it is the default here too.
        unsigned int flags = 0x08;
        // Replay a captured pty stream instead of the generated frame. The
        // report ships one taken off a real session with script(1), and it is
        // the payload known to reproduce - the generated frame does not, in
        // sixty runs.
        std::wstring file;
        // Run this instead of the built-in writer. The real path has wsl.exe
        // relaying a Linux pty into the console, and that relay's chunking is
        // not the same as a Windows program's WriteFile - which is one of the
        // things that might matter.
        std::wstring exec;
        // Milliseconds to wait between reads of the pty's output. A real pane
        // renders what it reads, so ConPTY meets backpressure there; this box
        // drains instantly and it never does. If the fault is a race between
        // the host's parser and its VT renderer, backpressure is what exposes
        // it - so it is a knob rather than an assumption.
        int readDelay = 0;
        std::wstring keep;
        bool verbose = false;
        bool emit = false;
    };

    // The payload. Shaped like a TUI frame and like the reproducer in the
    // report: a bordered box, a band of colour-dense rows near the top, blank
    // rows below erased with ECH, every row positioned absolutely.
    //
    // Every printable character here is in kAlphabet. That is the whole
    // contract the check below relies on.
    const char* const kBoxChars[] = { "\xe2\x95\xad", "\xe2\x95\xae", "\xe2\x95\xb0", "\xe2\x95\xaf", "\xe2\x94\x80", "\xe2\x94\x82" };

    std::string BuildFrame(const int cols, const int rows, const int targetSgr, const int n)
    {
        static const int hues[] = { 95, 105, 240, 245, 214, 220, 118, 46, 51, 39, 63, 135, 171, 201 };
        const auto bodyRows = (std::min)(20, (std::max)(1, rows - 4));
        const auto runs = (std::max)(1, targetSgr / (2 * bodyRows));
        const auto width = (std::max)(2, (cols - 2) / runs);

        std::string out;
        out.reserve(64 * 1024);
        char buf[64];

        out += "\x1b[H\x1b[38;5;95m";
        out += kBoxChars[0];
        for (auto i = 0; i < cols - 2; i++) { out += kBoxChars[4]; }
        out += kBoxChars[1];
        out += "\x1b[m";

        for (auto y = 2; y <= rows - 1; y++)
        {
            std::snprintf(buf, sizeof(buf), "\x1b[%d;1H", y);
            out += buf;
            out += "\x1b[38;5;95m";
            out += kBoxChars[5];
            out += "\x1b[m";

            if (y - 1 <= bodyRows)
            {
                auto x = 1;
                for (auto i = 0; i < runs && x < cols - 1; i++)
                {
                    const auto w = (std::min)(width, cols - 1 - x);
                    const auto hue = hues[(i + y + n) % (int)(sizeof(hues) / sizeof(hues[0]))];
                    std::snprintf(buf, sizeof(buf), "\x1b[38;5;%dm", hue);
                    out += buf;
                    // Text, and only from the alphabet: a run of '#'.
                    out.append((size_t)w, '#');
                    out += "\x1b[m";
                    x += w;
                }
                if (x < cols - 1)
                {
                    std::snprintf(buf, sizeof(buf), "\x1b[%dX", cols - 1 - x);
                    out += buf;
                }
            }
            else
            {
                std::snprintf(buf, sizeof(buf), "\x1b[%dX", cols - 2);
                out += buf;
            }

            std::snprintf(buf, sizeof(buf), "\x1b[%d;%dH", y, cols);
            out += buf;
            out += "\x1b[38;5;95m";
            out += kBoxChars[5];
            out += "\x1b[m";
        }

        std::snprintf(buf, sizeof(buf), "\x1b[%d;1H", rows);
        out += buf;
        out += "\x1b[38;5;95m";
        out += kBoxChars[2];
        for (auto i = 0; i < cols - 2; i++) { out += kBoxChars[4]; }
        out += kBoxChars[3];
        out += "\x1b[m";

        return out;
    }

    // The child: write the frames to stdout, each in a single write, the way
    // the application does. Nothing else - no shell, so nothing else can be
    // blamed for what comes out.
    int Emit(const Options& o)
    {
        // The payload is UTF-8, and a console interprets bytes in its output
        // code page - 437 by default, which turns every box character into
        // three of something else before ConPTY ever sees it. That mojibake
        // then trips the text check and looks exactly like the corruption being
        // hunted. A real UTF-8 application sets this too.
        SetConsoleOutputCP(CP_UTF8);

        const auto handle = GetStdHandle(STD_OUTPUT_HANDLE);

        // What did we actually get attached to? A pty gives a console whose
        // buffer is the pty's size; inheriting the parent's redirected stdout
        // gives a pipe and no console info at all. Written to a file because
        // stderr would go wherever stdout goes and prove nothing.
        if (const auto dbg = _wgetenv(L"CONPTY_BOX_CHILD_LOG"))
        {
            FILE* f = nullptr;
            if (_wfopen_s(&f, dbg, L"a") == 0 && f)
            {
                CONSOLE_SCREEN_BUFFER_INFO info{};
                const auto haveConsole = GetConsoleScreenBufferInfo(handle, &info) != 0;
                std::fprintf(f, "child: type=%lu console=%d size=%dx%d err=%lu\n",
                             GetFileType(handle), haveConsole ? 1 : 0,
                             info.dwSize.X, info.dwSize.Y, GetLastError());
                std::fclose(f);
            }
        }

        // A captured stream is written once, exactly as recorded.
        if (!o.file.empty())
        {
            FILE* f = nullptr;
            if (_wfopen_s(&f, o.file.c_str(), L"rb") != 0 || !f) { return 3; }
            std::string data;
            char rb[65536];
            size_t got = 0;
            while ((got = std::fread(rb, 1, sizeof(rb), f)) > 0) { data.append(rb, got); }
            std::fclose(f);

            if (o.split > 0)
            {
                for (size_t at = 0; at < data.size(); at += (size_t)o.split)
                {
                    const auto len = (DWORD)(std::min)((size_t)o.split, data.size() - at);
                    DWORD written = 0;
                    WriteFile(handle, data.data() + at, len, &written, nullptr);
                }
            }
            else
            {
                DWORD written = 0;
                WriteFile(handle, data.data(), (DWORD)data.size(), &written, nullptr);
            }
            Sleep(200);
            return 0;
        }

        for (auto n = 0; n < 3; n++)
        {
            const auto frame = BuildFrame(o.cols, o.rows, o.sgr, n);
            if (o.split > 0)
            {
                for (size_t at = 0; at < frame.size(); at += (size_t)o.split)
                {
                    const auto len = (DWORD)(std::min)((size_t)o.split, frame.size() - at);
                    DWORD written = 0;
                    WriteFile(handle, frame.data() + at, len, &written, nullptr);
                }
            }
            else
            {
                DWORD written = 0;
                WriteFile(handle, frame.data(), (DWORD)frame.size(), &written, nullptr);
            }
            Sleep(60);
        }
        return 0;
    }

    // Text bytes the payload can legitimately produce: '#', space, and the
    // UTF-8 bytes of the six box-drawing characters.
    bool AllowedTextByte(const unsigned char c)
    {
        if (c == '#' || c == ' ') { return true; }
        // Box drawing lives in U+2500..U+257F, which is E2 94/95 xx in UTF-8.
        if (c == 0xE2 || c == 0x94 || c == 0x95) { return true; }
        if (c >= 0x80 && c <= 0xBF) { return true; } // UTF-8 continuation
        if (c == '\r' || c == '\n') { return true; }
        return false;
    }

    // For a replayed capture the alphabet check cannot be used - the text is
    // whatever the session printed. The reported symptom has its own signature
    // though: a parser that consumed the ESC[ and printed the tail leaves a CSI
    // *body* in the stream as plain text. `[95m`, `;240m` and `291X` were the
    // fragments in the report.
    size_t CountOrphanCsi(const std::string& s, std::string& sample)
    {
        size_t hits = 0;
        for (size_t i = 0; i + 2 < s.size(); i++)
        {
            if (s[i] != '[') { continue; }
            if (i > 0 && (unsigned char)s[i - 1] == 0x1B) { continue; } // a real CSI
            size_t j = i + 1;
            while (j < s.size() && ((s[j] >= '0' && s[j] <= '9') || s[j] == ';')) { j++; }
            if (j == i + 1 || j >= s.size()) { continue; }              // needs parameters
            const auto fin = s[j];
            if (!((fin >= 'A' && fin <= 'Z') || (fin >= 'a' && fin <= 'z'))) { continue; }
            hits++;
            if (sample.empty())
            {
                const auto start = i > 10 ? i - 10 : 0;
                sample = s.substr(start, (std::min)((size_t)44, s.size() - start));
                for (auto& ch : sample)
                {
                    if ((unsigned char)ch == 0x1B) { ch = '@'; }
                    else if ((unsigned char)ch < 0x20) { ch = '.'; }
                }
            }
        }
        return hits;
    }

    struct Verdict
    {
        bool corrupt = false;
        std::string sample;
        size_t badBytes = 0;
    };

    // Walk the emitted stream, skipping escape sequences, and check that every
    // byte that lands as *text* is one the payload could have printed. Only
    // enough VT parsing to tell those apart - CSI, OSC, and the two-byte
    // escapes - which is all the question needs.
    Verdict Judge(const std::string& s)
    {
        Verdict v;
        size_t i = 0;
        while (i < s.size())
        {
            const auto c = (unsigned char)s[i];
            if (c == 0x1B)
            {
                if (i + 1 >= s.size()) { break; }
                const auto k = (unsigned char)s[i + 1];
                if (k == '[')
                {
                    i += 2;
                    while (i < s.size() && (unsigned char)s[i] >= 0x20 && (unsigned char)s[i] <= 0x3F) { i++; }
                    if (i < s.size()) { i++; } // the final byte
                }
                else if (k == ']')
                {
                    i += 2;
                    while (i < s.size())
                    {
                        if ((unsigned char)s[i] == 0x07) { i++; break; }
                        if ((unsigned char)s[i] == 0x1B && i + 1 < s.size() && s[i + 1] == '\\') { i += 2; break; }
                        i++;
                    }
                }
                else
                {
                    i += 2;
                }
                continue;
            }

            if (c < 0x20 && c != '\r' && c != '\n' && c != 0x09)
            {
                // A stray control byte is not text we printed either, but it is
                // not the signature being hunted; skip it.
                i++;
                continue;
            }

            if (!AllowedTextByte(c))
            {
                v.corrupt = true;
                v.badBytes++;
                if (v.sample.size() < 60)
                {
                    const auto start = i > 8 ? i - 8 : 0;
                    v.sample = s.substr(start, (std::min)((size_t)40, s.size() - start));
                    for (auto& ch : v.sample)
                    {
                        if ((unsigned char)ch == 0x1B) { ch = '@'; }
                        else if ((unsigned char)ch < 0x20) { ch = '.'; }
                    }
                }
            }
            i++;
        }
        return v;
    }

    // One pty, one child, one payload. Returns what ConPTY emitted.
    bool RunOnce(const Options& o, std::string& captured)
    {
        HANDLE inRead = nullptr, inWrite = nullptr, outRead = nullptr, outWrite = nullptr;
        SECURITY_ATTRIBUTES sa{ sizeof(sa), nullptr, TRUE };
        if (!CreatePipe(&inRead, &inWrite, &sa, 0)) { return false; }
        if (!CreatePipe(&outRead, &outWrite, &sa, 0)) { return false; }

        void* hpc = nullptr;
        const COORD size{ (SHORT)o.cols, (SHORT)o.rows };
        const auto hr = g_create(size, inRead, outWrite, o.flags, &hpc);
        if (FAILED(hr))
        {
            std::fprintf(stderr, "ConptyCreatePseudoConsole failed: 0x%08lx\n", (unsigned long)hr);
            return false;
        }

        // The child is this same binary in --emit mode: no shell, no profile,
        // nothing between the payload and the pty.
        wchar_t self[MAX_PATH];
        GetModuleFileNameW(nullptr, self, MAX_PATH);
        wchar_t cmd[1024];
        if (!o.exec.empty())
        {
            std::swprintf(cmd, 1024, L"%s", o.exec.c_str());
        }
        else if (!o.file.empty())
        {
            std::swprintf(cmd, 1024, L"\"%s\" --emit --split %d --file \"%s\"", self, o.split, o.file.c_str());
        }
        else
        {
            std::swprintf(cmd, 1024, L"\"%s\" --emit --cols %d --rows %d --sgr %d --split %d", self, o.cols, o.rows, o.sgr, o.split);
        }

        STARTUPINFOEXW si{};
        si.StartupInfo.cb = sizeof(si);
        // STARTF_USESTDHANDLES with all three handles left null. Without it the
        // child takes the parent's standard handles - and with this running
        // under a script, those are pipes, so the child wrote to the script's
        // stdout and the pty captured nothing. It looked exactly like a clean
        // run. This is what ConptyConnection::_LaunchAttachedClient does, and
        // the reason is the same.
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        SIZE_T attrSize = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &attrSize);
        std::vector<char> attrBuf(attrSize);
        si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)attrBuf.data();
        if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attrSize))
        {
            std::fprintf(stderr, "InitializeProcThreadAttributeList failed: %lu\n", GetLastError());
            g_close(hpc);
            return false;
        }
        // Without this the child inherits *our* console and writes there
        // instead of into the pty - which looks like a working run producing no
        // output, so it is checked rather than assumed.
        if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, 0x00020016 /* PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE */,
                                       hpc, sizeof(hpc), nullptr, nullptr))
        {
            std::fprintf(stderr, "UpdateProcThreadAttribute(PSEUDOCONSOLE) failed: %lu\n", GetLastError());
            g_close(hpc);
            return false;
        }

        PROCESS_INFORMATION pi{};
        const auto ok = CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE,
                                       EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr,
                                       &si.StartupInfo, &pi);
        // Our copies of the pty's ends are done with; ConPTY holds its own.
        CloseHandle(inRead);
        CloseHandle(outWrite);
        if (!ok)
        {
            std::fprintf(stderr, "CreateProcess failed: %lu\n", GetLastError());
            g_close(hpc);
            return false;
        }

        // Read until the child is gone and the pipe is drained. Closing the
        // pseudoconsole is what ends the stream.
        std::string out;
        char buf[8192];
        DWORD read = 0;
        HANDLE waits[1] = { pi.hProcess };
        // Answer ConPTY's questions the way a pane does - see responder.h. It
        // waits for DA1 before it starts at this pin, so a silent reader is not
        // a slow terminal, it is a different code path.
        conptybox::Responder responder{ o.cols, o.rows };
        const auto answer = [&](const std::string& chunk) {
            const auto reply = responder.Consume(chunk);
            if (!reply.empty())
            {
                DWORD wrote = 0;
                WriteFile(inWrite, reply.data(), (DWORD)reply.size(), &wrote, nullptr);
            }
        };
        for (;;)
        {
            DWORD avail = 0;
            if (!PeekNamedPipe(outRead, nullptr, 0, nullptr, &avail, nullptr)) { break; }
            if (avail > 0)
            {
                if (o.readDelay > 0) { Sleep((DWORD)o.readDelay); }
                if (!ReadFile(outRead, buf, (DWORD)(std::min)((size_t)sizeof(buf), (size_t)avail), &read, nullptr) || read == 0) { break; }
                out.append(buf, read);
                answer(std::string{ buf, read });
                continue;
            }
            if (WaitForMultipleObjects(1, waits, FALSE, 20) == WAIT_OBJECT_0)
            {
                // Child gone: one last drain, then stop.
                Sleep(150);
                if (PeekNamedPipe(outRead, nullptr, 0, nullptr, &avail, nullptr) && avail > 0)
                {
                    if (ReadFile(outRead, buf, (DWORD)(std::min)((size_t)sizeof(buf), (size_t)avail), &read, nullptr) && read > 0)
                    {
                        out.append(buf, read);
                        answer(std::string{ buf, read });
                        continue;
                    }
                }
                break;
            }
        }

        g_close(hpc);
        WaitForSingleObject(pi.hProcess, 2000);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        CloseHandle(outRead);
        CloseHandle(inWrite);
        DeleteProcThreadAttributeList(si.lpAttributeList);

        captured = std::move(out);
        return true;
    }
}

int wmain(int argc, wchar_t** argv)
{
    Options o;
    for (auto i = 1; i < argc; i++)
    {
        const std::wstring a{ argv[i] };
        const auto next = [&]() { return i + 1 < argc ? argv[++i] : L""; };
        if (a == L"--host") { o.host = next(); }
        else if (a == L"--cols") { o.cols = _wtoi(next()); }
        else if (a == L"--rows") { o.rows = _wtoi(next()); }
        else if (a == L"--iterations") { o.iterations = _wtoi(next()); }
        else if (a == L"--sgr") { o.sgr = _wtoi(next()); }
        else if (a == L"--split") { o.split = _wtoi(next()); }
        else if (a == L"--flags") { o.flags = (unsigned int)wcstoul(next(), nullptr, 0); }
        else if (a == L"--file") { o.file = next(); }
        else if (a == L"--exec") { o.exec = next(); }
        else if (a == L"--read-delay") { o.readDelay = _wtoi(next()); }
        else if (a == L"--keep") { o.keep = next(); }
        else if (a == L"--verbose") { o.verbose = true; }
        else if (a == L"--emit") { o.emit = true; }
    }

    if (o.emit) { return Emit(o); }

    // A child created with PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE still takes its
    // standard handles from the parent when those are inheritable - and when
    // this runs with its output redirected (a pipe, as any script does), the
    // child then writes to that pipe instead of into the pty. It looks like a
    // working run that captured nothing.
    //
    // Microsoft's ConPTY sample never hits this because its parent owns a real
    // console. Dropping the inherit flag is what makes the pty the child's only
    // way out; measured with GetFileType in the child, which reported a pipe
    // before and a console after.
    for (const auto id : { STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE })
    {
        if (const auto h = GetStdHandle(id); h && h != INVALID_HANDLE_VALUE)
        {
            SetHandleInformation(h, HANDLE_FLAG_INHERIT, 0);
        }
    }

    HMODULE conpty = nullptr;
    if (!o.host.empty())
    {
        auto dll = o.host;
        if (dll.back() != L'\\') { dll += L'\\'; }
        dll += L"conpty.dll";
        conpty = LoadLibraryW(dll.c_str());
        if (!conpty)
        {
            std::fwprintf(stderr, L"cannot load %s (%lu)\n", dll.c_str(), GetLastError());
            return 2;
        }
        // Prove which host will be used: conpty.dll takes the OpenConsole.exe
        // beside itself, and a missing one silently falls back to the inbox
        // conhost - which would measure Windows rather than the build asked for.
        auto exe = o.host;
        if (exe.back() != L'\\') { exe += L'\\'; }
        exe += L"OpenConsole.exe";
        if (GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES)
        {
            std::fwprintf(stderr, L"no OpenConsole.exe in %s - it would fall back to the inbox conhost\n", o.host.c_str());
            return 2;
        }
        std::wprintf(L"host: %s\n", exe.c_str());
    }
    else
    {
        conpty = LoadLibraryW(L"kernel32.dll");
        std::wprintf(L"host: system conhost (kernel32 ConPTY)\n");
    }

    g_create = (PFN_CREATE)GetProcAddress(conpty, "CreatePseudoConsole");
    g_close = (PFN_CLOSE)GetProcAddress(conpty, "ClosePseudoConsole");
    if (!g_create || !g_close)
    {
        std::fprintf(stderr, "ConPTY entry points not found\n");
        return 2;
    }

    std::wprintf(L"pty %dx%d, %d iterations, ~%d SGR/frame\n", o.cols, o.rows, o.iterations, o.sgr);

    auto failures = 0;
    for (auto i = 0; i < o.iterations; i++)
    {
        std::string captured;
        if (!RunOnce(o, captured))
        {
            std::fprintf(stderr, "run %d did not complete\n", i);
            return 2;
        }

        auto v = Judge(captured);
        if (!o.file.empty())
        {
            // Replay mode: the alphabet is the session's, so judge on the
            // orphaned-CSI signature instead.
            v = Verdict{};
            v.badBytes = CountOrphanCsi(captured, v.sample);
            v.corrupt = v.badBytes > 0;
        }
        if (v.corrupt)
        {
            failures++;
            if (o.verbose || failures == 1)
            {
                std::printf("  run %2d: CORRUPT (%zu stray text bytes) near: %s\n",
                            i, v.badBytes, v.sample.c_str());
            }
            if (!o.keep.empty())
            {
                FILE* f = nullptr;
                if (_wfopen_s(&f, o.keep.c_str(), L"wb") == 0 && f)
                {
                    std::fwrite(captured.data(), 1, captured.size(), f);
                    std::fclose(f);
                    o.keep.clear(); // keep the first failure only
                }
            }
        }
        else if (o.verbose)
        {
            std::printf("  run %2d: clean (%zu bytes)\n", i, captured.size());
        }
    }

    std::printf("%d/%d runs corrupt\n", failures, o.iterations);
    // Exit code is the verdict, so `git bisect run` can use this directly:
    // 0 = good (no corruption), 1 = bad.
    return failures > 0 ? 1 : 0;
}
