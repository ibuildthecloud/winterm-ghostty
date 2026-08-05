# libghostty.dll never runs its C++ static initializers

Found 2026-08-04, during Phase 5, from a user report that `wsl aptitude` crashed the
harness. Status: **fixed** — patch 0024, `1fe550675`. This was a defect in upstream's
Windows DLL startup, not in anything Phase 5 added.

## Symptom

Any non-ASCII byte in terminal output crashes the process with
`STATUS_ACCESS_VIOLATION` reading address `0x78`. `aptitude` was incidental — it draws
box-drawing characters. The minimal repro is:

```powershell
$env:GHOSTTY_HARNESS_INPUT = 'wsl -e printf "\342\224\200\342\224\200\n"\r'   # U+2500 U+2500
.\harness\hwnd-host\hwnd-host.exe
```

ASCII-only sessions are unaffected, which is why a shell prompt, `dir`, and every earlier
smoke test looked healthy.

## Stack

From the harness's own symbolizing crash handler (`harness/hwnd-host/crashinfo.c`), with
`ghostty.pdb` copied next to the exe by `build.ps1`:

```
[crash] access violation: read from 0000000000000078
  0  simdutf::convert_utf8_to_utf32_with_errors   (pkg/simdutf/vendor/simdutf.cpp:11450)
  1  ghostty::N_AVX2::DecodeUTF8                  (src/simd/vt.cpp:175)
  2  ghostty::N_AVX2::DecodeNonAsciiUntilControlSeq
  3  ghostty::N_AVX2::DecodeUTF8UntilControlSeqImpl
  ...
  7  utf8DecodeUntilControlSeq                    (src/simd/vt.zig:27)
  8  processOutputLocked                          (src/termio/Termio.zig:692)
  9  threadMainWindows                            (src/termio/Exec.zig:1795)
```

Line 11450 is `get_default_implementation()->convert_utf8_to_utf32_with_errors(...)`. A
fault reading `0x78` off a virtual dispatch is a **zeroed vtable pointer**: the object
exists in `.bss` but its constructor never ran. The SIMD decoder only reaches simdutf for
non-ASCII input, which is exactly the observed trigger.

## Root cause

`_DllMainCRTStartup` in MSVC's CRT does three things: bring up vcrt, bring up acrt, then
`_initterm` over the image's static-initializer tables (`.CRT$XI*` for C, `.CRT$XC*` for
C++ constructors). Zig's DLL entry point does none of it; upstream's `DllMain` in
`src/main_c.zig` restores the first two by calling `__vcrt_initialize` and
`__acrt_initialize`, and stops there.

The tables are in **our image**, not in the CRT, so no amount of CRT bootstrapping runs
them. Every namespace-scope C++ global in `libghostty.dll` therefore has a zeroed vptr.

Upstream's comment on that `DllMain` names "C++ constructors in glslang" as motivation,
so the gap is known in principle — but the code as written cannot close it.

## What was measured

Bracket markers in `.CRT$XCA`/`.CRT$XCZ`, walking between them:

```
[crtinit] range 7ffd769497a8..7ffd76949830 = 136 bytes, 15 entries (not called)
```

15 non-null entries in a 136-byte range. The markers bracket a real, plausibly-sized
table — the walk is not wandering through unrelated `.rdata`.

## The fix

MSVC's `__scrt_dllmain_crt_process_attach` does five things; upstream's `DllMain` did the
first two:

1. `__vcrt_initialize()`
2. `__acrt_initialize()`
3. **`__scrt_dllmain_before_initialize_c()`** — initializes the module's onexit tables
4. `_initterm_e(__xi_a, __xi_z)`, then `__scrt_dllmain_after_initialize_c()`
5. `_initterm(__xc_a, __xc_z)` — the C++ constructors

Step 3 is the one that makes the difference, and none of this needed inventing: the static
CRT already links `__xi_a`/`__xi_z`/`__xc_a`/`__xc_z`, `_initterm`, `_initterm_e` and both
`__scrt_dllmain_*_initialize_c` helpers into the image. The fix references them instead of
synthesizing markers.

Verified against `wsl aptitude`, box-drawing `printf`, and CJK, on both the exec and the
external backends. `zig build test`: 3089 pass, 58 skip, 0 fail.

## Why the first two attempts failed (and what actually told us)

Both hand-rolled walks died in `LoadLibrary` with `STATUS_HEAP_CORRUPTION`. The reason was
step 3, not double-initialization:

```
_DllMainCRTStartup → handler → runInitTable → atexit → _register_onexit_function
  → _recalloc_base(block = 0x0000000050000061)  ← garbage
     → ntdll!RtlSetUserValueHeap → access violation
```

The first C++ entry in the table is the standard library's `initlocks`, and it calls
`atexit` immediately. With `module_local_atexit_table_initialized = false`, the CRT
reallocs an uninitialized `_onexit_table_t`.

**The static-CRT double-init theory recorded here earlier was wrong.** It was plausible —
the `.CRT$XI*` table really is five `__acrt_initialize_*` entries — but it was reasoned
from the link command, never measured, and it sent the investigation the wrong way. What
settled it was installing a debugger (`winget install Microsoft.WinDbg`, which ships
`cdb.exe`, no admin required) and asking:

```
dps ghostty_internal!crt_xc_a L12     # every entry, by name
x ghostty_internal!*onexit*           # module_local_atexit_table_initialized = false
x ghostty_internal!__scrt_dllmain*    # the helper that was missing
kp 30                                 # the stack the fast-fail had been hiding
```

Fifteen minutes of debugger beat two hours of hypothesis. That is the lesson worth keeping.

## What the failed attempts looked like

Calling those 15 entries at `DLL_PROCESS_ATTACH`, right after `__acrt_initialize()`:

| Attempt | Result |
|---|---|
| Walk `.CRT$XI*` then `.CRT$XC*` (the CRT's own order) | `STATUS_HEAP_CORRUPTION` at DLL load |
| Walk `.CRT$XC*` only | `STATUS_HEAP_CORRUPTION` at DLL load |

Both died during `LoadLibrary`, before `main` ran — nothing printed at all. The access
violation *was* gone, so the constructors were running; the missing onexit-table step is
what made running them unsafe. Neither attempt was wrong about *what* to run, only about
what has to happen first.

For the record, the table the debugger printed:

| `.CRT$XC*` entry | Owner |
|---|---|
| `std::…'initlocks'` ×2, `'init_atexit'`, `std::'_Fac_tidy_reg'`, `std::'classic_locale'`, four `std::…::id` facets | C++ standard library |
| `_GLOBAL__sub_I_simdutf.cpp` | **simdutf — the one whose absence caused the crash** |
| `_GLOBAL__sub_I_{GlslangToSpv,Initialize,SpvBuilder,SpvPostProcess,InReadableOrder}.cpp` | glslang / SPIRV |

`.CRT$XI*` is five entries, all `__acrt_initialize_{stdio,fma3,fmode,timeset}` and
`initialize_multibyte`.

## Consequences to fold in at the retro

- **Phase 3's record is still unreconciled, and it is not a documentation slip.** The
  claim is that CJK, kana and colour emoji rendered live on 2026-08-02, and the fixture
  it used — `harness/hwnd-host/fallback-test.bat`, `chcp 65001` then `type` of a UTF-8
  file — pushes non-ASCII through the pty, i.e. straight through the code path that
  faulted. So it genuinely exercised the crash and reported a pass.

  Re-run of that same fixture after the fix: passes, with
  `found codepoint 0x4E2D in fallback face=Malgun Gothic` in the log.

  What is *not* established is how it passed in August. Nothing in the patch series
  touches `src/simd/`, `pkg/` or `build.zig`, and the `DllMain` shim predates Phase 3, so
  "the defect was always there" and "Phase 3 really did render CJK" cannot both hold as
  stated. The most plausible reconciliation is build mode — an optimized build can
  constant-initialize what a Debug build leaves to a dynamic initializer, and Phase 3 did
  not record which optimize level it verified under. **That is a hypothesis, deliberately
  not asserted; it is the same reasoning-from-source that this file already caught once.**
  Settling it costs one rebuild at the Phase 3 commit in each of Debug and ReleaseFast.
  Worth doing at the retro, because the answer determines whether other Phase 3 results
  carry an unrecorded build-mode dependency.
- **The harness now has a crash handler** (`crashinfo.c`) and `build.ps1` copies the
  matching `ghostty.pdb` out of the Zig cache. Without both, this crash reports as
  `ghostty_init+0x1395` — the nearest *export*, which is actively misleading.
- **ASCII-only smoke tests hid this for two phases.** Any future "it renders" criterion
  should include a non-ASCII line.
