Windows Terminal, with [ghostty](https://github.com/ghostty-org/ghostty)'s engine behind the pane instead of the stock one — chosen per profile, in the same window, side by side with cascadia panes.

It is a **working fork, not a finished product**; read [Known issues](#known-issues) before installing.

<!-- {{VERSION}} is substituted by .github/workflows/release.yml at publish
     time. Edit this file for the *next* release; it is the notes source, not
     a historical record - past notes live on their own release pages. -->

## Install

Two ways. Full instructions: **[docs/install.md](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/install.md)**.

### Portable — no certificate, no admin, no install

```powershell
Expand-Archive .\winterm-ghostty-{{VERSION}}-x64-portable.zip -DestinationPath .
.\terminal-{{VERSION}}\WindowsTerminal.exe
```

Same build, just not installed. Settings live beside the exe, so deleting the folder removes every trace. What you give up is integration: no Start menu entry, no `wtg.exe` on PATH, no "Open in Terminal", and it cannot be your default terminal.

### MSIX — installed, and needs the certificate trusted once

Trust the certificate from an **elevated** PowerShell:

```powershell
Import-Certificate -FilePath .\winterm-ghostty-{{VERSION}}.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
```

then install (elevation not needed):

```powershell
Add-AppxPackage -Path .\winterm-ghostty-{{VERSION}}-x64.msix
```

If that fails with `0x80073CF3`, the `Microsoft.UI.Xaml.2.8` framework is missing. It is deliberately not shipped here — anyone installing this almost certainly has Windows Terminal already, which depends on the same framework, and Windows 11 preinstalls it. `winget install --id Microsoft.UI.Xaml.2.8` fixes it.

Launch **Terminal (ghostty)** from the Start menu, or `wtg.exe`.

Nothing switches engine by itself. Add `"engine": "ghostty"` to a profile — or to `profiles.defaults` — to opt in:

```jsonc
{
    "name": "Ubuntu",
    "engine": "ghostty"     // "cascadia" (default) or "ghostty"
}
```

To confirm a pane is really using it, open the search box (`Ctrl+Shift+F`): on a ghostty pane the regex and case toggles are greyed out.

## What works

Rendering, keyboard input (including IME), mouse, selection and clipboard, search, scrollback and marks, all six cursor shapes, Kitty graphics, and the terminal-size reports that image clients rely on. A pane drains its pty at roughly three quarters of cascadia's rate.

Everything above the pane — tabs, panes, settings, command palette, search box — is unaware of which engine it is holding.

## Installs beside Windows Terminal

Its own package identity (`WintermGhostty`), its own execution alias (`wtg.exe`), and its own COM class IDs — so it does not replace, rename or hijack anything belonging to a real Windows Terminal install, on any channel. Settings are separate too: this starts with defaults rather than importing yours.

## Known issues

- **No accessibility.** There is no UIA text provider on a ghostty pane, so **Narrator and NVDA cannot read one**. If you rely on a screen reader, keep those profiles on `"engine": "cascadia"`.
- **x64 only.** Zig 0.16.0 cannot target `aarch64-windows-msvc` at all, so there is no ARM64 build to ship.
- **[KD-06](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)** — with a ligating font, parking a block cursor on the first character of a ligature such as `--` makes the second half blink along with the cursor. Workaround: a font without that ligature, e.g. Consolas.
- **KD-04** — a pane in a background *window* keeps drawing a focused-looking blinking cursor, and keeps presenting frames to do it.
- **KD-05** — the Windows cursor-blink settings are ignored, including turning blinking off.

Each defect in `docs/known-defects.md` records what was measured rather than what was assumed, and what would tell the remaining hypotheses apart.

## Signing

The MSIX, when one is published, is signed with a **self-signed certificate** (`CN=Darren Shepherd`) — there is no paid publisher identity behind this, so Windows has no reason to trust it until you say so. `docs/install.md` explains what that grants and how to undo it. If you would rather not, the patch series in `ghostty-patches/` and `terminal-patches/` exists so you can build it yourself.

The portable ZIP is not signed and does not need to be - nothing installs it. Verify what you downloaded against `SHA256SUMS.txt`.

## Provenance

An unofficial fork of [microsoft/terminal](https://github.com/microsoft/terminal) and [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty), not affiliated with or endorsed by either. Both are MIT; so is this.

Built by [.github/workflows/release.yml](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/.github/workflows/release.yml) from the recorded upstream pins plus the tracked patch series — the inputs are all in git.
