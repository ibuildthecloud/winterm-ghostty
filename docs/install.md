# Installing

An **unofficial fork of [Windows Terminal](https://github.com/microsoft/terminal)**
whose panes can render with [ghostty](https://github.com/ghostty-org/ghostty)'s engine
instead of the stock one, chosen per profile. Not affiliated with or endorsed by
Microsoft or the ghostty project. Both upstreams are MIT; so is this.

## Before you start

- **x64 Windows 10 2004 (19041) or later.** No ARM64 build — Zig 0.16.0 cannot target
  `aarch64-windows-msvc` at all (a stdlib bug, not ours), so there is nothing to ship.
- **You will be trusting a self-signed certificate.** There is no paid publisher
  identity behind this, so Windows has no reason to trust the package until you tell it
  to. Read [What trusting the certificate means](#what-trusting-the-certificate-means)
  before you do it — that section is the honest version, not reassurance.
- It installs **alongside** Windows Terminal rather than replacing it. Different package
  identity, different execution alias, separate settings.

## Install

Download from the [latest release](https://github.com/ibuildthecloud/winterm-ghostty/releases/latest):

| file | what it is |
|---|---|
| `winterm-ghostty-<version>-x64.msix` | the application |
| `winterm-ghostty-<version>.cer` | the public certificate the package is signed with |
| `SHA256SUMS.txt` | checksums |

Check what you downloaded:

```powershell
Get-FileHash .\winterm-ghostty-*-x64.msix -Algorithm SHA256 | Format-List
Get-Content .\SHA256SUMS.txt
```

Trust the certificate — **this step needs an elevated PowerShell**, the rest does not:

```powershell
Import-Certificate -FilePath .\winterm-ghostty-<version>.cer `
    -CertStoreLocation Cert:\LocalMachine\TrustedPeople
```

Install:

```powershell
Add-AppxPackage -Path .\winterm-ghostty-<version>-x64.msix
```

Then launch **Terminal (ghostty)** from the Start menu, or run `wtg.exe`.

### If that fails with 0x80073CF3

That code means a missing framework dependency, and it does not say which one. It is
almost always `Microsoft.UI.Xaml.2.8`.

The release does not ship that framework, on the assumption that anyone installing this
already has Windows Terminal — which depends on the same framework — and that Windows 11
preinstalls it. If that assumption does not hold for you, install the framework first:

```powershell
winget install --id Microsoft.UI.Xaml.2.8
```

or take `Microsoft.UI.Xaml.2.8.appx` (x64) out of the
[Microsoft.UI.Xaml NuGet package](https://www.nuget.org/packages/Microsoft.UI.Xaml/2.8.4)
and `Add-AppxPackage` it. It is Microsoft-signed either way, so you can verify it
against the Microsoft root rather than trusting us for it.

## Turn the ghostty engine on

Installing does not switch anything by itself — every profile still uses the stock
engine until told otherwise. That is deliberate: it means a bad frame is always one
setting away from being ruled out.

Open settings (`Ctrl+,`) → **Open JSON file**, and add `"engine": "ghostty"` to a
profile:

```jsonc
{
    "name": "Ubuntu",
    "engine": "ghostty"
}
```

Or to `profiles.defaults` to make it the default for every profile:

```jsonc
"profiles": {
    "defaults": {
        "engine": "ghostty"
    }
}
```

Accepted values are `"cascadia"` (the default, the stock engine) and `"ghostty"`.
An unrecognised value falls back to `cascadia` with a warning rather than refusing to
load your settings.

**To tell which engine a pane is actually using**, open the search box (`Ctrl+Shift+F`):
on a ghostty pane the regex and case-sensitivity toggles are greyed out. Do not go by
whether `ghostty-internal.dll` is loaded in the process — it will be loaded if *any*
profile could use it.

## What trusting the certificate means

`Import-Certificate ... -CertStoreLocation Cert:\LocalMachine\TrustedPeople` tells your
machine that software signed by the holder of that key may be installed. Specifically:

- It applies to **that certificate only**, not to a certificate authority, so it cannot
  be used to vouch for anything else.
- `TrustedPeople` is scoped to app installation. It is not `Root`; do not put it there.
- Anyone holding the matching private key could sign a package your machine would then
  install without complaint. The private key for this one is not published, but you are
  taking that on trust — which is exactly the property a real code-signing identity
  would remove.

If you would rather not, the alternative is to
[build from source](../README.md#building) — the whole point of the patch series in
`ghostty-patches/` and `terminal-patches/` is that you can reproduce this yourself.

To remove the trust later:

```powershell
Get-ChildItem Cert:\LocalMachine\TrustedPeople |
    Where-Object Subject -eq 'CN=Darren Shepherd' | Remove-Item
```

## Uninstall

```powershell
Get-AppxPackage WintermGhostty | Remove-AppxPackage
```

Settings live in `%LOCALAPPDATA%\Packages\WintermGhostty_*\LocalState\` and are left
behind by design; delete that folder to remove them too.

## Living beside a real Windows Terminal

Mostly fine, with one wrinkle worth knowing before you install.

**Separate, and stays separate:**

- Package identity is `WintermGhostty`, not `WindowsTerminalDev`, so this installs
  beside Windows Terminal rather than replacing it.
- The execution alias is `wtg.exe`, so `wt.exe` and `wtd.exe` keep pointing at whatever
  they pointed at before.
- Settings are per-package. **Your existing Windows Terminal settings are not
  imported** — this starts with defaults, and changes here do not affect your normal
  Terminal.

**Shared, and this is the wrinkle:** the COM class IDs for the shell extension, the
"Open in Terminal" context menu and default-terminal handoff are inherited unchanged
from upstream. If you also have **Windows Terminal Dev** installed, both packages
register the same CLSIDs and whichever registered last wins. So "Open in Terminal" and
the default-terminal setting may resolve to this fork rather than your Dev build, or the
reverse. Stable and Preview Windows Terminal use different CLSIDs and are unaffected.

Uninstalling this package restores whatever was there before.

## Known issues

This is a working fork, not a finished product. The engine is real and interactive, and
these are the things it is known to get wrong:

- **[KD-06](known-defects.md#kd-06)** — with a ligating font (Cascadia Code), parking a
  block cursor on the first character of a ligature such as `--` makes the second half
  blink with the cursor. Workaround: a font without that ligature, e.g. Consolas.
- **[KD-04](known-defects.md#kd-04)** — a ghostty pane in a background *window* keeps
  drawing a focused-looking blinking cursor, and keeps presenting frames to do it.
- **[KD-05](known-defects.md#kd-05)** — the Windows cursor-blink settings are ignored,
  including turning blinking off, which is often an accessibility setting.
- **Accessibility is not implemented.** There is no UIA text provider on a ghostty pane,
  so **Narrator and NVDA cannot read one**. Use the stock engine if you rely on a screen
  reader. This is Phase 8 work and is not done.

The full list, with what was measured rather than assumed, is in
[known-defects.md](known-defects.md).
