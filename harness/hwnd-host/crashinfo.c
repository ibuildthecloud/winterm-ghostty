#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dbghelp.h>
#include <stdio.h>

#include "crashinfo.h"

// A crash in libghostty arrives as a bare STATUS_ACCESS_VIOLATION exit code
// with nothing else to go on, and this machine has no cdb installed. dbghelp
// is always present, so the harness symbolizes itself: faulting address,
// module+offset, and a stack walk with whatever names the PDBs can supply.
//
// This runs inside a broken process, so it does the minimum and does not
// allocate through the CRT where it can be avoided.

static void print_frame(HANDLE proc, DWORD64 addr, int depth) {
    char sym_buf[sizeof(SYMBOL_INFO) + 512];
    SYMBOL_INFO *sym = (SYMBOL_INFO *)sym_buf;
    sym->SizeOfStruct = sizeof(SYMBOL_INFO);
    sym->MaxNameLen = 511;

    DWORD64 disp = 0;
    const char *name = "<no symbol>";
    if (SymFromAddr(proc, addr, &disp, sym)) name = sym->Name;

    // The module tells us *whose* code this is even when symbols are missing,
    // which is the first thing worth knowing.
    char mod[MAX_PATH] = "<unknown module>";
    IMAGEHLP_MODULE64 mi = {.SizeOfStruct = sizeof(mi)};
    DWORD64 base = SymGetModuleBase64(proc, addr);
    if (base && SymGetModuleInfo64(proc, base, &mi)) {
        strncpy_s(mod, sizeof(mod), mi.ModuleName, _TRUNCATE);
    }

    IMAGEHLP_LINE64 line = {.SizeOfStruct = sizeof(line)};
    DWORD line_disp = 0;
    if (SymGetLineFromAddr64(proc, addr, &line_disp, &line)) {
        fprintf(stderr, "  %2d  %s!%s+0x%llx  (%s:%lu)\n", depth, mod, name,
                (unsigned long long)disp, line.FileName, line.LineNumber);
    } else {
        fprintf(stderr, "  %2d  %s!%s+0x%llx  [%016llx]\n", depth, mod, name,
                (unsigned long long)disp, (unsigned long long)addr);
    }
}

static LONG WINAPI crash_filter(EXCEPTION_POINTERS *ep) {
    const EXCEPTION_RECORD *er = ep->ExceptionRecord;
    fprintf(stderr, "\n[crash] exception 0x%08lx at %016llx (thread %lu)\n",
            (unsigned long)er->ExceptionCode,
            (unsigned long long)(uintptr_t)er->ExceptionAddress,
            GetCurrentThreadId());

    if (er->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && er->NumberParameters >= 2) {
        const ULONG_PTR kind = er->ExceptionInformation[0];
        fprintf(stderr, "[crash] access violation: %s %016llx\n",
                kind == 0 ? "read from" : (kind == 1 ? "write to" : "execute at"),
                (unsigned long long)er->ExceptionInformation[1]);
    }

    const HANDLE proc = GetCurrentProcess();
    SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES);
    if (!SymInitialize(proc, NULL, TRUE)) {
        fprintf(stderr, "[crash] SymInitialize failed %lu\n", GetLastError());
        fflush(stderr);
        return EXCEPTION_EXECUTE_HANDLER;
    }

    // StackWalk64 mutates the context, so hand it a copy.
    CONTEXT ctx = *ep->ContextRecord;
    STACKFRAME64 frame = {0};
    frame.AddrPC.Offset = ctx.Rip;
    frame.AddrPC.Mode = AddrModeFlat;
    frame.AddrFrame.Offset = ctx.Rbp;
    frame.AddrFrame.Mode = AddrModeFlat;
    frame.AddrStack.Offset = ctx.Rsp;
    frame.AddrStack.Mode = AddrModeFlat;

    fprintf(stderr, "[crash] stack:\n");
    for (int depth = 0; depth < 48; depth++) {
        if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, proc, GetCurrentThread(),
                         &frame, &ctx, NULL, SymFunctionTableAccess64,
                         SymGetModuleBase64, NULL)) {
            break;
        }
        if (frame.AddrPC.Offset == 0) break;
        print_frame(proc, frame.AddrPC.Offset, depth);
    }

    // A dump as well, so a machine with a debugger can go further.
    const HANDLE file = CreateFileW(L"crash.dmp", GENERIC_WRITE, 0, NULL,
                                    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE) {
        MINIDUMP_EXCEPTION_INFORMATION mei = {
            .ThreadId = GetCurrentThreadId(),
            .ExceptionPointers = ep,
            .ClientPointers = FALSE,
        };
        if (MiniDumpWriteDump(proc, GetCurrentProcessId(), file,
                              MiniDumpWithIndirectlyReferencedMemory |
                                  MiniDumpWithDataSegs,
                              &mei, NULL, NULL)) {
            fprintf(stderr, "[crash] wrote crash.dmp\n");
        }
        CloseHandle(file);
    }

    fflush(stderr);
    return EXCEPTION_EXECUTE_HANDLER;
}

// Access violations inside libghostty do not always reach the unhandled
// filter - a Zig-side handler or an SEH frame in between can swallow them -
// so we also register a vectored handler, which sees the exception first.
// It only reports fatal codes and passes everything else along untouched.
static LONG WINAPI veh(EXCEPTION_POINTERS *ep) {
    switch (ep->ExceptionRecord->ExceptionCode) {
    case EXCEPTION_ACCESS_VIOLATION:
    case EXCEPTION_ILLEGAL_INSTRUCTION:
    case EXCEPTION_STACK_OVERFLOW:
    case EXCEPTION_INT_DIVIDE_BY_ZERO:
    case EXCEPTION_PRIV_INSTRUCTION:
        break;
    default:
        return EXCEPTION_CONTINUE_SEARCH;
    }

    static volatile LONG reported = 0;
    if (InterlockedExchange(&reported, 1)) return EXCEPTION_CONTINUE_SEARCH;

    fprintf(stderr, "[crash] (vectored handler)\n");
    crash_filter(ep);
    return EXCEPTION_CONTINUE_SEARCH;
}

void crashinfo_install(void) {
    SetUnhandledExceptionFilter(crash_filter);
    AddVectoredExceptionHandler(1, veh);
}
