# 0004 — Maintain the ghostty fork as an upstream-shaped patch series

Status: **Accepted** (2026-07-31, at the Phase 0 retro; patch list and build rule amended
there — see "Amendments from Phase 0" below)

## Context

Every existing ghostty-on-Windows effort made a fork-structure choice we can learn from:

- **winghostty** rebuilt ghostty as a Windows exe: deleted `apprt/embedded.zig` and
  `include/ghostty.h`, added a 37k-line `apprt/win32.zig` welded to its shell, and pinned
  to a pre-`std.Io` Zig, entangling every diff with a stdlib-era rollback. Its genuinely
  valuable pieces (libxev IOCP timer fix, frame-health plumbing) are hard to extract.
- **wintty** kept the embedded API (correct) but maintains its fork as a single squashed
  commit force-push-rebased daily — 8.7k LOC of good renderer work that cannot be
  cherry-picked as patches.
- **deblasis's upstream PR series** (#11803/#11782/#11839/#11856/#11886) is the model
  upstream itself endorsed: infrastructure PRs merged, renderer PR parked "in a fork until
  we're ready."

Upstream's Windows stance: libghostty already treats Windows as a build/test target;
maintainers want piecemeal incremental PRs; the renderer door is explicitly "until we're
ready," not "never."

## Decision

The ghostty fork is an **ordered, rebasable patch series against upstream `main`**, one
topic per patch, each written to upstream's stated PR shape:

0. `windows-build` — make `libghostty.dll` link at all on `x86_64-windows-msvc`: widen the
   `quirks_memset.zig` export guard to exclude the msvc ABI (it collides with
   libvcruntime's `memset`), and give `os/pipe.zig` `closeEnd`/`writeEnd` helpers so
   `termio/Exec.zig` stops passing Windows `HANDLE`s to `posix.system.close`/`write`.
   *Added at the Phase 0 retro — see Amendments below. Nothing downstream compiles into a
   DLL without it.*
1. `init-wtf16` — C API entry point accepts WTF-16 argv (upstream's own TODO).
2. `platform-win32` — `GHOSTTY_PLATFORM_WINDOWS` tag + `ghostty_platform_windows_s` +
   swap-chain accessors.
3. `d3d11-backend` — ADR 0002.
4. `termio-external` — ADR 0006.
5. `dwrite-discovery` — ADR 0005.
6. `iocp-fixes` — libxev timer-completion fix (also offered directly to mitchellh/libxev),
   PTY read-path hardening, `getProcessInfo`.
7. `winkeys` — WM_KEYDOWN/WM_CHAR pairing buffer (from wintty), read-back exports.

Only what upstream contracts require is changed; the embedded apprt and C API remain the
product surface (no exe-style apprt). Infrastructure patches are offered upstream
immediately; the renderer patch is kept rebased and offered when upstream reopens.

## Alternatives rejected

- **Squash fork / long-lived divergent branch** (wintty): unmaintainable and
  un-upstreamable, as demonstrated.
- **Exe-style `apprt.win32`** (winghostty): kills the embedded C API that Windows Terminal
  consumes; solves the wrong product.
- **Vendoring wintty's tree wholesale**: imports D3D12 (rejected in ADR 0002) and a
  governance structure we specifically want to avoid; we harvest its patterns instead.

## Consequences

- Tracking upstream `main` (Zig 0.16+, `std.Io`) is a recurring cost, bounded by keeping
  patches topical and small.
- The same artifact is simultaneously our engine and the standing candidate for upstream's
  official Windows renderer.
- Coordinate with deblasis early — shared goals, overlapping code heritage, and an
  established upstream relationship.
- Tooling: `jj` or `git rebase`-maintained patch queue; **each patch must leave the tree
  building (`zig build -Dapp-runtime=none`) and passing `zig build test` on Windows.**
  Patches are not required to be splittable into independently-building halves — see the
  amendment below.

## Amendments from Phase 0 (2026-07-31)

Three changes, all evidence-driven; the originals are struck through above rather than
deleted so the reasoning stays visible.

**1. `windows-build` added as patch 0.** The series assumed upstream libghostty already
built on Windows — it does not. At pin `4d605bf0`, `zig build test` passes 3061/55/0 but
`zig build -Dapp-runtime=none` fails to link. Patch 0 fixes it in 5 files (+80/−13) and
produces `ghostty-internal.dll`, an x64 PE with 231 exports including the `ghostty_*` C
API. Both halves read as genuine upstream bugs rather than port scaffolding — the memset
guard's own comment already says MSVC doesn't need the quirk, and `pipe()` returns
`HANDLE`s that callers were treating as file descriptors — so patch 0 is the **first**
candidate for the "offer infrastructure patches upstream immediately" path, ahead of
`init-wtf16`.

**2. The build rule now applies to patches, not to fragments of patches.** The original
wording ("each patch must build … independently") is unsatisfiable for an indivisible
topic. Patch 0 is the case in point: memset-only still fails on `close`/`write`, and
pipe-only still collides on `memset`. Neither half builds, so "one topic per patch" and
"each patch builds independently" contradicted each other. Both changes *are* one topic —
make libghostty link on Windows/MSVC — and one coherent upstream PR, which may still carry
two commits internally.

**3. Fork hosting: local only.** The `windows` branch stays on the dev machine with no
remote — nothing is pushed anywhere. The tracked, durable artifact is
`ghostty-patches/*.patch` in this repo, which is this ADR's model regardless: the fork is
always reproducible from *recorded upstream pin + exported patches*. Revisit if
collaboration with deblasis (PLAN Phase 9) actually starts.

**4. Attribution convention for harvested MIT code: per-file header note.** A comment at
the harvested code naming the project and license, plus a line in the commit message.
Chosen over a central `NOTICES` file because it travels with the code, survives rebases,
and reads naturally in an upstream PR. This closes the standing question in PLAN Phase 9.
Patch 0 is the first instance (wintty's pipe helpers).
