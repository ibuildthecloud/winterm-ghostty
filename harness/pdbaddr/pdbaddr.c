// pdbaddr: turn a module + RVA into a function name and source line.
//
// Windows Error Reporting gives a faulting module and a fault offset and
// nothing else, and this machine has no debugger installed - so a crash
// report was a dead end. DbgHelp will read the PDB next to the DLL and
// answer the only question that matters: which function.
//
//     pdbaddr <module.dll> <rva-hex>
//
// The RVA is the "Fault offset" from the Application event log entry, or
// anything else expressed relative to the module base.
//
// Sibling of harness/hwnd-host/crashinfo.c, which symbolizes a *live* stack
// through the same API. This one needs no process: SymLoadModuleEx maps the
// image at a base of our choosing and every lookup is base + rva.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dbghelp.h>
#include <stdio.h>
#include <stdlib.h>

#pragma comment(lib, "dbghelp.lib")

// Arbitrary, and never mapped for real - DbgHelp only needs somewhere to put
// the module so that base + rva is unambiguous.
#define FAKE_BASE 0x10000000ULL

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: pdbaddr <module> <rva-hex> [<rva-hex>...]\n");
        return 2;
    }

    const HANDLE proc = GetCurrentProcess();

    // The PDB is looked for beside the module, so hand DbgHelp that directory
    // explicitly rather than relying on _NT_SYMBOL_PATH - and no deferred
    // loads, so a missing PDB is a failure here rather than a wrong answer
    // later. Without this the lookups silently fall back to the export table
    // and report whichever exported symbol happens to precede the address.
    char search[MAX_PATH * 4] = {0};
    {
        strncpy_s(search, sizeof(search), argv[1], _TRUNCATE);
        char *slash = strrchr(search, '\\');
        if (!slash) slash = strrchr(search, '/');
        if (slash) *slash = '\0'; else search[0] = '\0';

        const char *extra = getenv("_NT_SYMBOL_PATH");
        if (extra && *extra) {
            strncat_s(search, sizeof(search), ";", _TRUNCATE);
            strncat_s(search, sizeof(search), extra, _TRUNCATE);
        }
    }

    SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME);
    if (!SymInitialize(proc, search[0] ? search : NULL, FALSE)) {
        fprintf(stderr, "SymInitialize failed: %lu\n", GetLastError());
        return 1;
    }

    const DWORD64 base = SymLoadModuleEx(proc, NULL, argv[1], NULL,
                                         FAKE_BASE, 0, NULL, 0);
    if (!base) {
        fprintf(stderr, "SymLoadModuleEx(%s) failed: %lu\n", argv[1], GetLastError());
        return 1;
    }

    IMAGEHLP_MODULE64 info = {0};
    info.SizeOfStruct = sizeof(info);
    if (SymGetModuleInfo64(proc, base, &info)) {
        // "SymNone" here means the PDB was not found, and every answer below
        // would be a nearby export rather than the real function.
        fprintf(stderr, "[pdbaddr] symbols: %d (%s)\n", (int)info.SymType, info.LoadedPdbName);
    }

    for (int i = 2; i < argc; i++) {
        const DWORD64 rva = strtoull(argv[i], NULL, 16);
        const DWORD64 addr = base + rva;

        char buf[sizeof(SYMBOL_INFO) + MAX_SYM_NAME * sizeof(TCHAR)] = {0};
        SYMBOL_INFO *sym = (SYMBOL_INFO *)buf;
        sym->SizeOfStruct = sizeof(SYMBOL_INFO);
        sym->MaxNameLen = MAX_SYM_NAME;

        DWORD64 disp = 0;
        printf("%s+0x%llx  ", argv[1], (unsigned long long)rva);
        if (SymFromAddr(proc, addr, &disp, sym)) {
            printf("%s + 0x%llx", sym->Name, (unsigned long long)disp);
        } else {
            printf("<no symbol: %lu>", GetLastError());
        }

        IMAGEHLP_LINE64 line = {0};
        line.SizeOfStruct = sizeof(line);
        DWORD line_disp = 0;
        if (SymGetLineFromAddr64(proc, addr, &line_disp, &line)) {
            printf("\n    %s:%lu", line.FileName, line.LineNumber);
        }
        printf("\n");
    }

    SymCleanup(proc);
    return 0;
}
