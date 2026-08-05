# libghostty.dll never runs its C++ static initializers

Found 2026-08-04, during Phase 5, from a user report that `wsl aptitude` crashed the
harness. Status: **root cause established, fix not landed.** This is a defect in the
current fork (and, as far as the evidence goes, in upstream's Windows DLL story), not in
anything Phase 5 added.

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

## Why the obvious fix does not work yet

Calling those 15 entries at `DLL_PROCESS_ATTACH`, right after `__acrt_initialize()`:

| Attempt | Result |
|---|---|
| Walk `.CRT$XI*` then `.CRT$XC*` (the CRT's own order) | `STATUS_HEAP_CORRUPTION` at DLL load |
| Walk `.CRT$XC*` only | `STATUS_HEAP_CORRUPTION` at DLL load |

Both die during `LoadLibrary`, before `main` runs — nothing is printed at all. Note the
access violation *is* gone, so the constructors do run; something in running them is
unsafe.

The likely reason is in the link command: this build links the **static** CRT
(`-llibvcruntime -llibucrt`), so the CRT's *own* initializer entries live in the same
table. `__acrt_initialize()` has already performed that work, and running the table then
initializes the CRT a second time. Heap corruption at load is consistent with that.

Unverified — it is the leading hypothesis, not a measured conclusion.

## Where to pick up

1. Identify which of the 15 entries belong to the CRT (compare addresses against
   `libucrt`/`libvcruntime` contributions in the map file; `zig build` can emit one).
   If the CRT's entries can be skipped, the walk becomes safe.
2. Or drop `__vcrt_initialize`/`__acrt_initialize` and let the tables do all of it — the
   static CRT's own initializers are present, which is the arrangement `_initterm`
   expects. Cheap to test, one build.
3. Or side-step the CRT question by making the simdutf dispatch object function-local
   (compiler-emitted lazy guard, no `.CRT$XC*` entry). Narrower, but only fixes the
   globals we know about, and there are 15.
4. A debugger would end this quickly. There is no `cdb` on this machine — only
   `dbghelp.dll`. Installing the Debugging Tools for Windows feature of the SDK is
   probably worth it before attempt 1.

The attempted patch is saved outside the repo (session scratchpad,
`crt-init-attempt.patch`); it is small enough to retype from this document.

## Consequences to fold in at the retro

- **Phase 3's record needs checking.** `PLAN.md` states CJK, kana and colour emoji were
  verified rendering in this harness on 2026-08-02. That cannot be simultaneously true
  with "the first non-ASCII byte faults", so either the verification is misrecorded or
  the defect appeared after it. Whether the crash reproduces at the Phase 3 commit is the
  test; nothing in the patch series touches `src/simd/`, `pkg/` or `build.zig`, which
  argues for the former.
- **The harness now has a crash handler** (`crashinfo.c`) and `build.ps1` copies the
  matching `ghostty.pdb` out of the Zig cache. Without both, this crash reports as
  `ghostty_init+0x1395` — the nearest *export*, which is actively misleading.
- **ASCII-only smoke tests hid this for two phases.** Any future "it renders" criterion
  should include a non-ASCII line.
