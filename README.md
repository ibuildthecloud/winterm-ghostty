# winterm-ghostty

Windows Terminal's shell, with [ghostty](https://github.com/ghostty-org/ghostty)'s engine
behind the pane instead of cascadia's — selectable per profile, in the same window, side by
side with the stock engine.

```jsonc
{
    "name": "ghostty test",
    "commandline": "cmd.exe",
    "engine": "ghostty"     // "cascadia" (default) or "ghostty"
}
```

A pane with `"engine": "ghostty"` is drawn by `libghostty.dll` through a new Direct3D 11
backend, into the same XAML `SwapChainPanel` cascadia uses. Everything above the pane —
tabs, panes, settings, the command palette, the search box — is unaware of which engine it
is holding.

**Status: Phase 6 of 9 complete.** Rendering, input, selection, clipboard, search, marks
and IME all work. Performance and packaging do not yet. See
[Where it stands](#where-it-stands).

---

## What this repository is, and is not

This repo holds the **documentation, the test harnesses, the build scripts and the ghostty
patch series**. It does *not* contain the two forks — they are separate clones, gitignored
here:

| | |
|---|---|
| `ghostty/` | fork of `ghostty-org/ghostty`, branch `windows`. **Reconstructable from this repo**: pinned upstream commit + the 31 patches in `ghostty-patches/` (ADR 0004). |
| `terminal/` | fork of `microsoft/terminal`. **Not reconstructable from this repo** — see the warning below. |

> [!WARNING]
> **The Windows Terminal fork is not published here.** It is 39 commits on top of
> `microsoft/terminal` at pin `ca7996296`, and this repository exports no patches for it.
> Without those commits there is no `engine` setting, no `IControlCore` seam and no
> `GhosttyControlCore` — so **you cannot build a working Windows Terminal from this repo
> alone.** Publishing that fork, or adding a `terminal-patches/` export beside
> `ghostty-patches/`, is outstanding work.

Everything else — why the design is what it is, what was measured, what is knowingly
different from cascadia — is in `docs/`.

## Layout

```
PROCESS.md            how sessions are run; the contract each one works under
PLAN.md               the phase plan and its status ledger
DESIGN.md             target architecture, upstream pins, threading model
docs/adr/             decisions, and the alternatives that were rejected
docs/sessions/        one report per session: what was built, what was not, what broke
docs/documented-diffs.md   every way a ghostty pane differs from a cascadia one
docs/selection-geometry.md both engines' selection rules, measured
docs/manual-validation.md  the checks that still need a human
ghostty-patches/      the fork as an ordered, rebasable patch series
harness/              small hosts and tools that exercise libghostty directly
scripts/              build, test, patch-export and rebase wrappers
```

## Building

### Prerequisites

Native Windows — not WSL.

- **Visual Studio 2026** with the components in `terminal/.vsconfig` (MSVC v145). VS 2022
  works too; Windows Terminal's build selects v145 when `VisualStudioVersion >= 18.0`.
- **Windows SDK** ≥ 10.0.26100.8249, including `dxc`.
- **Zig 0.16.0** — pinned by ghostty's `build.zig.zon`. You do not need to install it:
  `scripts/zigenv.ps1` downloads it into `tools/` on first use.
- A GPU, or WARP. Both are supported and both were tested.

### 1. The forks

```powershell
git clone https://github.com/ibuildthecloud/winterm-ghostty
cd winterm-ghostty

# ghostty, reconstructed from the pin plus the patch series
git clone https://github.com/ghostty-org/ghostty
git -C ghostty checkout -b windows 4d605bf0d819df901a0332bbb320dc849fdd82e4
git -C ghostty am ../ghostty-patches/*.patch

# Windows Terminal - see the warning above; the fork's commits are not here
git clone https://github.com/microsoft/terminal
git -C terminal checkout ca7996296a48322c1c7310af59d4ee2949421679
```

### 2. libghostty

```powershell
.\scripts\build-ghostty.ps1            # libghostty.dll + a synthesized import library
.\scripts\build-ghostty.ps1 -Test      # zig build test: 3096 pass, 58 skip
```

> `zig build test` passing is **not** evidence that the library builds. The test build
> compiles a different module set — it excludes the C API, among other things — and has
> twice passed while `build-ghostty.ps1` failed. Always run both.

### 3. Windows Terminal

```powershell
.\scripts\build-terminal.ps1 -Project terminal        # the app
.\scripts\build-terminal.ps1 -Project package -Deploy # register the dev package
Start-Process "shell:appsFolder\WindowsTerminalDev_8wekyb3d8bbwe!App"
```

The first build needs a NuGet restore, which the script does unless you pass `-NoRestore`.
If a build dies with a wall of `Cannot open include file: 'Xxx.g.h'`, the XAML codegen was
left half-written by an out-of-memory build — `-CleanCodegen` clears it.

Then add a profile with `"engine": "ghostty"` and open it.

## Testing

```powershell
# Unit tests - run the suites individually; a bare Invoke-OpenConsoleTests hangs
cd terminal; Import-Module .\tools\OpenConsole.psm1
foreach ($t in 'terminalCore','unitSettingsModel','unitControl','terminalApp') {
    Invoke-OpenConsoleTests -Test $t
}                                        # 54 / 159 / 62 / 51

.\scripts\build-ghostty.ps1 -Test        # 3096 pass, 58 skip
.\harness\hwnd-host\build.ps1 -NoRun
.\scripts\smoke-harness.ps1              # 9 checks
```

`smoke-harness.ps1` is the interesting one. It drives `harness/hwnd-host` — a minimal Win32
host for libghostty, the same shape Windows Terminal's control presents — and covers the
seam that neither side's unit tests can see: non-ASCII output not crashing the process, a
pixel drag selecting the characters cascadia would select, a copy carrying colours as well
as text, search counting and navigating, and output actually reaching the screen.

**It cannot see a pixel Windows Terminal draws.** Everything above measures what *ghostty*
did. Bugs in the XAML painted over the pane — selection markers, for one — are invisible to
it, and `docs/manual-validation.md` carries what still needs a human.

## Where it stands

| Phase | |
|---|---|
| 0–5 | toolchain, D3D11 backend, fonts, the `IControlCore` seam, a working pane |
| **6** | **interaction parity — complete**: selection, clipboard (plain + HTML), search, prompt marks, IME |
| 7 | presentation & performance — **not started**. Throughput measured 2.9× slower than cascadia at Phase 3 and has not been re-measured since. |
| 8 | accessibility & packaging — **not started**. UIA/Narrator, MSIX, ARM64. |
| 9 | upstreaming — ongoing |

`docs/documented-diffs.md` lists every remaining behavioural difference with what causes it
and what closing it would cost. The ones you would notice daily: no hyperlink hover or
ctrl-click, bracketed paste always off, mouse reporting unwired, no keyboard selection.

## How this project is run

Each phase is one largely-unattended agent session against the contract in `PROCESS.md`,
with a human gate between phases. Every session ends with a report in `docs/sessions/`
saying what worked, what did not, and what was left unmet — including the failures. The
patch series in `ghostty-patches/` is the reviewable artifact of the ghostty fork: one
commit per topic, each building and passing tests on its own (ADR 0004).

If you read one thing beyond this file, make it a session report — they are written to be
read after the fact by someone who was not there.

## Licence and provenance

**No licence file yet.** This repository is derived from MIT-licensed sources —
[ghostty](https://github.com/ghostty-org/ghostty),
[Windows Terminal](https://github.com/microsoft/terminal), and pipe helpers harvested from
[wintty](https://github.com/deblasis/wintty) — and carries per-file attribution where code
was taken (ADR 0004). A licence needs choosing before this is useful to anyone else.
