Windows Terminal, with [ghostty](https://github.com/ghostty-org/ghostty)'s engine behind the pane instead of the stock one — chosen per profile, in the same window, side by side with cascadia panes.

It is a **working fork, not a finished product**; read [Known issues](#known-issues) before installing.

<!-- This is the notes SOURCE for the next release, not a historical record;
     past notes live on their own release pages. Version placeholders use
     double braces and are substituted by .github/workflows/release.yml at
     publish time - which is why this comment spells them out rather than
     writing one, since it would be rewritten too. -->

## Install

No installer — unzip and run. Full notes: **[docs/install.md](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/install.md)**.

```powershell
Expand-Archive .\winterm-ghostty-{{VERSION}}-x64-portable.zip -DestinationPath .
.\terminal-{{VERSION}}\WindowsTerminal.exe
```

No certificate to trust, no admin rights, no Developer Mode, nothing registered. Settings live beside the exe, so deleting the folder removes every trace.

What you give up is integration: no Start menu entry, no `wtg.exe` on PATH, no "Open in Terminal", and it cannot be set as your default terminal. Those need an installed package, which needs a signed one — see [Signing](#signing).

Nothing switches engine by itself. Add `"engine": "ghostty"` to a profile — or to `profiles.defaults` — to opt in:

```jsonc
{
    "name": "Ubuntu",
    "engine": "ghostty"     // "cascadia" (default) or "ghostty"
}
```

To confirm a pane is really using it, open the search box (`Ctrl+Shift+F`): on a ghostty pane the regex and case toggles are greyed out.

## Fixed since 0.2.2

- **Mouse input now reaches applications properly.** Mouse reporting was never implemented, so a full-screen application saw the selection machinery's side effects instead of its input: every press arrived twice, a single click sent no press at all, and the right button, middle button and wheel never arrived. Buttons, wheel and modifiers are now reported, and holding shift still selects text ([GD-07](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/documented-diffs.md)).

## Fixed in 0.2.2

- **`?` reached applications as `/`.** Only applications using the kitty keyboard protocol were affected; the modifiers a layout consumes to produce a character were not being reported, so `?` was encoded as its base key `/` plus a shift modifier ([KD-08](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)).
- **A ligature's second half blinked with the cursor.** With a ligating font, parking a block cursor on the first character of a ligature such as `--` made the other half flicker in antiphase. Moving the cursor now re-shapes the rows it leaves and enters ([KD-06](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)).

## What works

Rendering, keyboard input (including IME), mouse, selection and clipboard, search, scrollback and marks, all six cursor shapes, Kitty graphics, and the terminal-size reports that image clients rely on. A pane drains its pty at roughly three quarters of cascadia's rate.

Everything above the pane — tabs, panes, settings, command palette, search box — is unaware of which engine it is holding.

## Installs beside Windows Terminal

Its own package identity (`WintermGhostty`), its own execution alias (`wtg.exe`), and its own COM class IDs — so it does not replace, rename or hijack anything belonging to a real Windows Terminal install, on any channel. Settings are separate too: this starts with defaults rather than importing yours.

## Known issues

- **No accessibility.** There is no UIA text provider on a ghostty pane, so **Narrator and NVDA cannot read one**. If you rely on a screen reader, keep those profiles on `"engine": "cascadia"`.
- **x64 only.** Zig 0.16.0 cannot target `aarch64-windows-msvc` at all, so there is no ARM64 build to ship.
- **KD-04** — a pane in a background *window* keeps drawing a focused-looking blinking cursor, and keeps presenting frames to do it.
- **KD-05** — the Windows cursor-blink settings are ignored, including turning blinking off.

Each defect in `docs/known-defects.md` records what was measured rather than what was assumed, and what would tell the remaining hypotheses apart.

## Signing

**Nothing here is signed, and nothing needs to be.** A portable build is not installed, so Windows never asks who published it.

An MSIX *is* built, but it is not published: an MSIX must carry a valid signature to install at all, no signing certificate is configured for this repository, and shipping one nobody can install would be shipping a trap. If that changes, an installer comes back and this section changes with it.

Verify what you downloaded against `SHA256SUMS.txt`. Note the file is written with Windows line endings, so `sha256sum -c` may report "could not be read" — compare the hash by hand if so.

## Provenance

An unofficial fork of [microsoft/terminal](https://github.com/microsoft/terminal) and [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty), not affiliated with or endorsed by either. Both are MIT; so is this.

Built by [.github/workflows/release.yml](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/.github/workflows/release.yml) from the recorded upstream pins plus the tracked patch series — the inputs are all in git.
