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

## New in 0.2.11

### Typing from a phone or a remote desktop works

Typing into a ghostty pane over Remote Desktop — from the Windows App on Android, in the report this came from — could not produce a shifted character at all: `?` arrived as `/`, `A` as `a`, and `:` produced nothing. Every application, and nothing to do with the release it was found on: 0.2.2 does the same.

Two separate faults, both fixed ([KD-25](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)).

**A remote client sends the character, not the keystroke.** An on-screen keyboard cannot press a key on the machine's layout, so it injects the character itself. A ghostty pane read the character's code as if it were a physical key position — so a typed `A` sent what pressing F7 sends, and `:` sent nothing at all. Those events now carry their character through as text, including emoji and anything else outside the basic range.

**Modifiers were read a moment too late.** Windows Terminal asks which modifiers are held when the key event surfaces, which is slightly after the key itself. A person holds shift long enough that this never shows; a client that presses and releases shift around the key in one burst does not. A ghostty pane now tracks the modifier keys from the key events themselves, which arrive in order and cannot drift, and treats the system's answer as a floor rather than the truth.

A cascadia pane was correct on both, which is why this looked like a ghostty-only bug from the outside — it takes its text from the character Windows produced rather than looking the key up itself.

## New in 0.2.10

### Ctrl+D and Enter answer a pane whose process has exited

A pane whose child has exited prints the message it has always printed:

```
[process exited with code 56 (0x00000038)]
You can now close this terminal with Ctrl+D, or press Enter to restart.
```

On a ghostty pane neither key did anything, so the only way out was the mouse. Both now work: **Enter restarts the pane in place**, keeping the scrollback you just read the exit code from, and **Ctrl+D closes it**.

The message comes from the connection, which is shared, so it appeared on both engines and promised the same two things on both — only the cascadia pane kept the promise. Cascadia answers those keys from the *character* the key produced, a path a ghostty pane never reaches: the engine encodes Enter and Ctrl+D itself and reports the key handled, so no character event follows. A ghostty pane now answers on the key itself, before the engine sees it, and only while the connection is closed — both keys still go to the shell in a live pane ([KD-24](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)).

One limit worth knowing: a restarted ghostty pane does not clear terminal state the dead program left behind, because libghostty has no reset that spares the scrollback. A shell that exited normally leaves nothing behind, which is the case the message is about; a program killed while drawing full-screen could leave the new shell in a strange mode. Closing and opening the pane is the way out of that.

## New in 0.2.9

<!-- 0.2.8 was tagged and never released: its build died on a duplicated
     -Dfont-backend, fixed in the same commit that renumbered this. The tag
     is left in place rather than moved, because a pushed ref is not
     something this project rewrites. -->

The biggest release since 0.2.0, and most of it is a pane behaving like the cascadia pane beside it rather than nearly like it. (There is no 0.2.8: it was tagged, its build failed before publishing anything, and the tag was left where it was rather than moved.)

### The shell's working directory now reaches the terminal

Duplicating a tab, or splitting a pane, opens **where the shell actually is** instead of at the profile's `startingDirectory`. All three spellings work — `OSC 7` (a `file:` URI), ConEmu's `OSC 9;9` (a native path, which is what Windows shell integration emits), and iTerm2's `OSC 1337;CurrentDir`.

The sequences were always parsed; libghostty then dropped them, because its handler returned early on Windows with "unimplemented" before storing anything. Note that **nothing emits them by default** — PowerShell needs shell integration in your profile:

```powershell
function prompt {
  $p = $executionContext.SessionState.Path.CurrentLocation
  "$([char]27)]9;9;`"$p`"$([char]27)\PS $p$('>' * ($nestedPromptLevel + 1)) "
}
```

### Links

Ctrl+hover underlines a URL, shows the same tooltip a cascadia pane shows, and ctrl+click opens it — for URLs found in output and for `OSC 8` hyperlinks an application marks itself. The profile's `detectURLs` is honoured, so turning it off leaves a URL as plain text on both engines.

One difference worth knowing: ghostty previews a link only while ctrl is held, where cascadia underlines an `OSC 8` link on a plain hover.

### Desktop notifications

`OSC 777;notify;title;body` raises a toast, with the same rate limit and the same "don't notify me about the pane I'm looking at" rule as a cascadia pane. It is gated on the profile's `compatibility.allowOSC777`, which is **off by default** — a program gets to interrupt you only if you said it may.

### Two settings a ghostty pane was ignoring

- **`compatibility.allowOSC52`** — the switch that decides whether a program running in the pane may put text on your clipboard. It was never forwarded, so a pane wrote the clipboard even when you had turned that off. It now refuses, and refusing it does not cost you your own copy.
- **Padding.** A pane was inset by Windows Terminal's `padding` *and* again by ghostty's own default, so ghostty panes sat 4 px further in than cascadia ones at 150% scale. Padded once now.

### Text and colour

- **Intense text is brightened, not emboldened.** `intenseTextStyle` is forwarded, so bold-looking output no longer draws heavier strokes than the cascadia pane under the same profile, and bright text is bright.
- **Colour emoji are no longer washed out and flat** — the glyph atlas was not sRGB, so every colour came back lightened.
- **Glyphs are sharper.** The atlas held a gamma-corrected mask where the shader expected coverage.
- **A font *list* now names all its families.** `"fontFace": "Cascadia Code, Segoe UI Emoji"` was searched for as one family literally called that, found nothing, and silently fell back to the bundled font — so a profile's font was quietly ignored.

### The crash reported against 0.2.7.0

A ghostty pane could take the whole terminal down. It was reported from use against the 0.2.7.0 portable build, and 0.2.7's symbols are what made it readable: the dump names every frame, and it is a read of freed heap memory inside the renderer.

The cause was ours, not the engine's — Windows Terminal was calling a synchronous render from the UI thread (on losing focus with an IME composition open, among others) while the render thread was already in the middle of a frame. That call has been removed outright rather than serialised, so there is no longer a second thread to race. The older heap-corruption crash that could not be symbolised is presumed to be the same bug; it has not been seen since, but "presumed" is the honest word until it has been reproduced and shown gone.

## New in 0.2.7

- **The engine ships debuggable.** 0.2.6 published symbols but the engine had none: `-Dstrip` defaults to on for a fast release, and in ghostty's build it also sets `unwind_tables = .none` — so `ghostty-internal.dll` carried neither a PDB nor the tables a debugger needs to walk a stack out of it. That is why the crash dump behind [KD-11's neighbour KD-12](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md) showed one real frame and then nonsense. The release build now passes `-Dstrip=false`, and the packaging step **fails** rather than publishing a build whose engine cannot be debugged.

## New in 0.2.6

- **Every release now ships its own symbols**, as `winterm-ghostty-{{VERSION}}-x64-symbols.zip`. (In 0.2.6 these covered everything *except* the engine — see 0.2.7.) You do not need them to run anything — they exist so that a crash can be *read*. If this build dies on you, Windows keeps a full dump (see below), and with these symbols that dump names the function and source line rather than an address in a stripped DLL.

  Each PDB is paired to its binary by CodeView GUID, not by filename, and `SYMBOLS.txt` inside the ZIP lists every signature so a debugger's match can be checked rather than assumed.

### If it crashes, this is what to send

Nothing is reported anywhere — there is no telemetry in this build, and the engine's own crash reporter is compiled out on Windows. A crash is invisible unless you say so.

Windows keeps the evidence locally:

- `%LOCALAPPDATA%\CrashDumps\WindowsTerminal.exe.<pid>.dmp` — a full dump, if [LocalDumps](https://learn.microsoft.com/windows/win32/wer/collecting-user-mode-dumps) is enabled on the machine (it is not on by default).
- `%ProgramData%\Microsoft\Windows\WER\ReportArchive\AppCrash_WindowsTerminal.*` — the WER report.
- Application event log, IDs **1000** (faulting module and offset) and **1001** (the bucket).

The event-log line alone is useful: it names the faulting module and the offset within it, which the matching symbols ZIP turns into a function.

## Fixed in 0.2.5

- **Alt+drag block-selects.** Windows Terminal's block selection did nothing on a ghostty pane — alt+drag drew the ordinary linear selection, because the modifier the engine reads for a rectangular selection was never sent to it. Alt at the click now makes the drag a block one, and holds for the whole drag, as it does on a cascadia pane ([KD-11](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)).

## Fixed in 0.2.4

- **A pane's diagnostics can no longer hold up the window.** The engine traces to the debugger channel, and that channel is machine-wide: if anything on the machine has attached to it and stopped draining — a debugger that was killed, a tool that exited badly — every write to it blocks for ten seconds. A pane traced about forty lines while it started, on the UI thread, so a terminal could take minutes to appear. The traces now go out on their own thread ([KD-09](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)).
- **A terminal in the background no longer looks focused.** A window that came up behind another one — one launched from a script while you work elsewhere — gave its pane a blinking, focused-looking cursor that never went away, told the application it had focus, and woke the GPU renderer twice a second for the rest of the window's life. A pane is now focused only when its window is genuinely in front ([KD-04](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)).
- **A `sendInput` action can send an escape sequence again.** Non-paste writes went through the engine's *paste* entry point, which replaces every ESC and control character with a space and frames the result as a paste — so a `sendInput` binding carrying an escape sequence sent spaces where the escapes should have been, and broadcast input did the same. Those writes are now literal; a real paste is still filtered and framed ([GD-15](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/documented-diffs.md)).
- **Pastes are no longer treated as if every application were paste-blind.** The engine had always framed a paste in `ESC[200~`/`ESC[201~` correctly, but WT itself did not know the application had asked for it — so it trimmed pasted text that should have been left alone, dropped an empty paste that shells use to detect a paste at all, and raised the multi-line paste warning even for applications that can tell a paste from typing ([GD-08](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/documented-diffs.md)).

## Fixed in 0.2.3

- **Mouse input now reaches applications properly.** Mouse reporting was never implemented, so a full-screen application saw the selection machinery's side effects instead of its input: every press arrived twice, a single click sent no press at all, and the right button, middle button and wheel never arrived. Buttons, wheel and modifiers are now reported, and holding shift still selects text ([GD-07](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/documented-diffs.md)).

## Fixed in 0.2.2

- **`?` reached applications as `/`.** Only applications using the kitty keyboard protocol were affected; the modifiers a layout consumes to produce a character were not being reported, so `?` was encoded as its base key `/` plus a shift modifier ([KD-08](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)).
- **A ligature's second half blinked with the cursor.** With a ligating font, parking a block cursor on the first character of a ligature such as `--` made the other half flicker in antiphase. Moving the cursor now re-shapes the rows it leaves and enters ([KD-06](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/docs/known-defects.md)).

## What works

Rendering, keyboard input (including IME), mouse, selection and clipboard, search, scrollback and marks, all six cursor shapes, Kitty graphics, links (hover, tooltip, ctrl+click), the working directory a shell reports, desktop notifications, the taskbar progress bar, and the terminal-size reports that image clients rely on. A pane drains its pty at roughly three quarters of cascadia's rate.

Everything above the pane — tabs, panes, settings, command palette, search box — is unaware of which engine it is holding.

## Installs beside Windows Terminal

Its own package identity (`WintermGhostty`), its own execution alias (`wtg.exe`), and its own COM class IDs — so it does not replace, rename or hijack anything belonging to a real Windows Terminal install, on any channel. Settings are separate too: this starts with defaults rather than importing yours.

## Known issues

- **No accessibility.** There is no UIA text provider on a ghostty pane, so **Narrator and NVDA cannot read one**. If you rely on a screen reader, keep those profiles on `"engine": "cascadia"`.
- **x64 only.** Zig 0.16.0 cannot target `aarch64-windows-msvc` at all, so there is no ARM64 build to ship.
- **KD-05** — the Windows cursor-blink settings are ignored, including turning blinking off. A focused ghostty pane blinks at a fixed 600 ms and presents a frame for each blink, where a cascadia pane obeys the system setting.
- **KD-10** — a focused pane presents twice a second for its cursor blink, but the drawn cursor barely toggles: measured at ten blink wakes with the pixels unchanged. The blink is not reaching the screen, which also means those presents are buying nothing.
- **No shell-integration marks.** `OSC 133` prompt marks are tracked by the engine but not surfaced, so the scrollbar marks, "scroll to previous command" and command history are empty on a ghostty pane. Setting a shell's working directory (new in 0.2.9) works; the rest of shell integration does not yet.
- **Two `compatibility.*` switches are still ignored**: `allowDECNKM` (which defaults *off*, so a ghostty pane differs there for everyone) and `kittyKeyboardMode` in its off direction. Both need a setting libghostty does not have yet.

Each defect in `docs/known-defects.md` records what was measured rather than what was assumed, and what would tell the remaining hypotheses apart.

## Signing

**Nothing here is signed, and nothing needs to be.** A portable build is not installed, so Windows never asks who published it.

An MSIX *is* built, but it is not published: an MSIX must carry a valid signature to install at all, no signing certificate is configured for this repository, and shipping one nobody can install would be shipping a trap. If that changes, an installer comes back and this section changes with it.

Verify what you downloaded against `SHA256SUMS.txt`. Note the file is written with Windows line endings, so `sha256sum -c` may report "could not be read" — compare the hash by hand if so.

## Provenance

An unofficial fork of [microsoft/terminal](https://github.com/microsoft/terminal) and [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty), not affiliated with or endorsed by either. Both are MIT; so is this.

Built by [.github/workflows/release.yml](https://github.com/ibuildthecloud/winterm-ghostty/blob/main/.github/workflows/release.yml) from the recorded upstream pins plus the tracked patch series — the inputs are all in git.
