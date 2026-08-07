#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

#include "extpty.h"

typedef struct {
    HPCON pc;
    HANDLE in_write;   // we write child input here
    HANDLE out_read;   // we read child output here
    HANDLE reader;
    PROCESS_INFORMATION pi;
    ghostty_surface_t surface;

    // The grid size, which libghostty tells us before the pty exists.
    uint16_t cols, rows;

    volatile LONG stopping;
} extpty_state;

static extpty_state g_pty = {0};

static void trace(const char *msg) {
    fprintf(stderr, "[extpty] %s\n", msg);
    fflush(stderr);
}

// GHOSTTY_HARNESS_TRACE_PTY=1 logs every write to the child. Off by default
// because it is one line per keystroke.
static bool trace_writes(void) {
    static int cached = -1;
    if (cached < 0) {
        char buf[8];
        cached = GetEnvironmentVariableA("GHOSTTY_HARNESS_TRACE_PTY", buf, sizeof(buf)) > 0 &&
                 buf[0] == '1';
    }
    return cached != 0;
}

// The whole point of the exercise: pty bytes in, on our thread, blocking for
// as long as libghostty needs them. When it blocks, we stop calling ReadFile,
// the ConPTY buffer fills, and the child throttles. No flow control of our own.
static DWORD WINAPI reader_main(LPVOID param) {
    (void)param;
    uint8_t buf[16 * 1024];
    for (;;) {
        DWORD n = 0;
        if (!ReadFile(g_pty.out_read, buf, sizeof(buf), &n, NULL) || n == 0) {
            // ERROR_BROKEN_PIPE here is the child exiting, which is normal.
            break;
        }
        if (InterlockedCompareExchange(&g_pty.stopping, 0, 0)) break;
        if (trace_writes()) {
            fprintf(stderr, "[extpty] read %lu bytes from child\n", (unsigned long)n);
            fflush(stderr);
        }
        ghostty_surface_write_pty_output(g_pty.surface, buf, (size_t)n);

        // Deliberately no render call here. Windows Terminal's control does
        // render after every write, because libghostty's wakeup coalesces and
        // a pane there could hold a stale frame; this harness does not, so it
        // keeps showing what libghostty does on its own. If the two ever
        // disagree - the harness repainting where WT does not - that
        // difference is the finding, and compensating here would hide it.
    }
    trace("reader thread exiting");
    return 0;
}

void extpty_resize(uint16_t cols, uint16_t rows) {
    g_pty.cols = cols;
    g_pty.rows = rows;
    if (!g_pty.pc) return;

    const COORD size = {(SHORT)cols, (SHORT)rows};
    const HRESULT hr = ResizePseudoConsole(g_pty.pc, size);
    if (FAILED(hr)) fprintf(stderr, "[extpty] ResizePseudoConsole 0x%08lx\n", (unsigned long)hr);
}

void extpty_write(const uint8_t *data, size_t len) {
    if (!g_pty.in_write) return;
    if (trace_writes()) {
        // Built into one buffer and written once. The reader thread traces to
        // the same stderr, and a line assembled with several fprintf calls
        // comes out interleaved with its lines - which makes the trace
        // unparseable exactly when something is going wrong enough to be
        // worth parsing.
        char line[256];
        int n = snprintf(line, sizeof(line), "[extpty] write %zu bytes to child:", len);
        const size_t shown = len < 32 ? len : 32;
        for (size_t i = 0; i < shown && n > 0 && (size_t)n < sizeof(line); i++) {
            n += snprintf(line + n, sizeof(line) - (size_t)n, " %02x", data[i]);
        }
        if (n > 0 && (size_t)n < sizeof(line)) {
            n += snprintf(line + n, sizeof(line) - (size_t)n, "%s\n", shown < len ? " ..." : "");
        }
        fputs(line, stderr);
        fflush(stderr);
    }

    size_t off = 0;
    while (off < len) {
        DWORD written = 0;
        const DWORD chunk = (DWORD)((len - off) > 0xFFFFFFFFull ? 0xFFFFFFFFul : (len - off));
        if (!WriteFile(g_pty.in_write, data + off, chunk, &written, NULL)) {
            fprintf(stderr, "[extpty] WriteFile failed %lu\n", GetLastError());
            return;
        }
        off += written;
    }
}

bool extpty_start(ghostty_surface_t surface, const wchar_t *cmdline,
                  uint16_t cols, uint16_t rows) {
    g_pty.surface = surface;

    // Zero means "use whatever libghostty already told us", which is the
    // normal path: the surface sizes its grid during init, before we exist.
    if (cols == 0) cols = g_pty.cols;
    if (rows == 0) rows = g_pty.rows;
    if (cols == 0 || rows == 0) { cols = 80; rows = 24; }
    g_pty.cols = cols;
    g_pty.rows = rows;

    HANDLE in_read = NULL, out_write = NULL;
    if (!CreatePipe(&in_read, &g_pty.in_write, NULL, 0) ||
        !CreatePipe(&g_pty.out_read, &out_write, NULL, 0)) {
        trace("CreatePipe failed");
        return false;
    }

    const COORD size = {(SHORT)cols, (SHORT)rows};
    HRESULT hr = CreatePseudoConsole(size, in_read, out_write, 0, &g_pty.pc);
    if (FAILED(hr)) {
        fprintf(stderr, "[extpty] CreatePseudoConsole 0x%08lx\n", (unsigned long)hr);
        return false;
    }

    // ConPTY duplicates both of these; ours must go or the child never sees
    // EOF and our reader never sees a broken pipe on exit.
    CloseHandle(in_read);
    CloseHandle(out_write);

    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    STARTUPINFOEXW si = {0};
    si.StartupInfo.cb = sizeof(si);
    si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attr_size);
    if (!si.lpAttributeList ||
        !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size) ||
        !UpdateProcThreadAttribute(si.lpAttributeList, 0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   g_pty.pc, sizeof(g_pty.pc), NULL, NULL)) {
        trace("proc thread attribute setup failed");
        return false;
    }

    // CreateProcessW may write to the command line, so it cannot be a literal.
    wchar_t cmd[512];
    wcsncpy_s(cmd, 512, cmdline, _TRUNCATE);

    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE,
                        EXTENDED_STARTUPINFO_PRESENT, NULL, NULL,
                        &si.StartupInfo, &g_pty.pi)) {
        fprintf(stderr, "[extpty] CreateProcessW failed %lu\n", GetLastError());
        return false;
    }

    DeleteProcThreadAttributeList(si.lpAttributeList);
    HeapFree(GetProcessHeap(), 0, si.lpAttributeList);

    g_pty.reader = CreateThread(NULL, 0, reader_main, NULL, 0, NULL);
    if (!g_pty.reader) { trace("CreateThread failed"); return false; }

    // The pid is worth printing: if the child dies straight away, the pty is
    // still there rendering an empty screen, which looks exactly like a
    // renderer bug until you go looking for the process.
    fprintf(stderr, "[extpty] started %ux%u, child pid %lu\n", cols, rows,
            (unsigned long)g_pty.pi.dwProcessId);
    fflush(stderr);
    return true;
}

void extpty_stop(void) {
    if (InterlockedExchange(&g_pty.stopping, 1)) return;

    // Closing the pseudo console drops the child's handles, which ends the
    // child, which breaks our read pipe and lets the reader thread finish.
    if (g_pty.pc) { ClosePseudoConsole(g_pty.pc); g_pty.pc = NULL; }
    if (g_pty.reader) {
        WaitForSingleObject(g_pty.reader, 2000);
        CloseHandle(g_pty.reader);
        g_pty.reader = NULL;
    }
    if (g_pty.in_write) { CloseHandle(g_pty.in_write); g_pty.in_write = NULL; }
    if (g_pty.out_read) { CloseHandle(g_pty.out_read); g_pty.out_read = NULL; }
    if (g_pty.pi.hProcess) { CloseHandle(g_pty.pi.hProcess); g_pty.pi.hProcess = NULL; }
    if (g_pty.pi.hThread) { CloseHandle(g_pty.pi.hThread); g_pty.pi.hThread = NULL; }
}
