# 0004 — Maintain the ghostty fork as an upstream-shaped patch series

Status: Proposed (2026-07-31)

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
- Tooling: `jj` or `git rebase`-maintained patch queue; each patch must build and pass
  `zig build test` on Windows independently.
