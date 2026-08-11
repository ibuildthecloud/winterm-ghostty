# Documented diffs: where a ghostty pane differs from a cascadia one

Written 2026-08-06, at the end of Phase 6's implementation work. This is the list
PLAN's Phase 6 exit criteria demand: "documented diffs allowed" must not quietly
absorb an unimplemented feature, so every difference a user can reach is here,
with what causes it and what closing it would take.

**Scope.** Behaviour a user of a `"engine": "ghostty"` pane can observe. Internal
differences that produce identical behaviour are not diffs and are not listed.

**Each entry has a stable ID** (`GD-nn`). There is no issue tracker attached to this
repository yet — no git remote exists — so the criterion's "each with an issue
filed" is **not met**: the IDs are what an issue would be filed against, and are
stable so that filing them later does not require rewriting this file.

**Verified how**, per entry: `measured` means a check in
`scripts/smoke-harness.ps1` or a unit test covers it today; `read` means it is
known from the code and has not been exercised.

---

## Deferred at the Phase 6 readiness gate

These four were decided at the gate (2026-08-05) and are deferred by decision, not
by omission.

### GD-01 — Hyperlinks are not detected, hovered or clickable  ([#3](https://github.com/ibuildthecloud/winterm-ghostty/issues/3))

`GetHyperlink`, `HoveredUriText`, `HoveredCell` and `SetHoveredCell` all return
empty. A URL in output is plain text in a ghostty pane: no underline on hover, no
tooltip, no ctrl-click.

ghostty finds links itself (`Surface.linkAtPin`) and even selects them on
double-click, but nothing in the C API reads a link back out or reports one under
the pointer. Closing this needs a new libghostty entry point, which is exactly
what the gate ruled out of Phase 6. *Read.*

### GD-02 — `SelectCommand` / `SelectOutput` do nothing, and the context menu hides them  ([#4](https://github.com/ibuildthecloud/winterm-ghostty/issues/4))

WT can select the command or the output of the prompt under the cursor. ghostty's
`SemanticPrompt` is a `u2` — `none` / `prompt` / `prompt_continuation` — so it
records where prompts are and nothing about what a command or its output spans.
`ShouldShowSelectCommand`/`ShouldShowSelectOutput` return false so the menu items
do not appear, rather than appearing and doing nothing.

Widening `SemanticPrompt` touches row packing in ghostty and wants its own ADR.
*Read.*

### GD-03 — No scrollbar error pips, and no marks except prompts  ([#5](https://github.com/ibuildthecloud/winterm-ghostty/issues/5))

`ScrollMarks()` is empty and `AddMark`/`ClearMark`/`ClearAllMarks` do nothing.
`ScrollToMark` works — it maps to `jump_to_prompt` — so navigation between prompts
is there, but the scrollbar shows no mark pips and cannot show *error* pips at
all: exit codes have nowhere to live in a `u2`. Same ADR as GD-02. *Read.*

### GD-04 — Search: no regex, no case sensitivity, and no scrollbar pips for matches  ([#6](https://github.com/ibuildthecloud/winterm-ghostty/issues/6))

ghostty's needle is a plain `[]const u8`. The regex and case toggles are
**disabled and unchecked** in the search box on a ghostty pane rather than left
inert (`SearchSupportsRegex`, `SearchSupportsCaseSensitivity`), so nothing claims
to honour an option it ignores.

`SearchResultRows()` returns empty, so the scrollbar draws no pips for matches:
ghostty reports match *counts*, not positions, and the geometry never leaves its
renderer. A partial list would put pips in the wrong places, so empty is the
honest answer. Searching, counting and next/previous navigation all work.
*Measured* (smoke check "search counts matches and navigates them").

---

## Found while implementing Phase 6

### GD-05 — IME — **closed 2026-08-06**

Was: a ghostty pane never registered with TSF, so no preedit, no candidate
window, no IME at all.

Closed by making TSF stop reaching for a renderer. `IDataProvider::GetRenderer()`
became `SetComposition`/`ClearComposition`, so where the preedit goes is the
provider's business: cascadia writes it into its renderer exactly as before, a
ghostty pane hands it to `ghostty_surface_preedit`. `GetCursorPosition` and
`HandleOutput` now ask `IControlCore` rather than cascadia's core, which is what
puts the candidate window at the cursor and stops committed text being swallowed.

Verified by hand with the Japanese MS-IME: preedit at the cursor, candidate
window in the same place cascadia puts it, committed text reaching the shell -
and cascadia's own IME still working throughout, which is the regression check on
the shared refactor. It also removed ADR 0001's seventh and last `get_self`
escape.

Left here rather than deleted because the entry is what the criterion was
tracked against, and because two things it cost are worth keeping: there were
**three** implementors of `IDataProvider`, not one (conhost's is not built by the
`terminal` project - only the package build catches it), and the first working
build crashed on the first keystroke because `ghostty_surface_preedit` needs the
16 MB `RunWithEngineStack` thread, not WT's 1 MB UI thread.

### GD-13 — Double-clicking past the end of a line selects nothing  ([#13](https://github.com/ibuildthecloud/winterm-ghostty/issues/13))

Double-click in the empty region to the right of a prompt or a line of output:
cascadia highlights the whitespace out to the edge of the pane, ghostty selects
nothing. Found by hand, 2026-08-06.

This is a buffer-model difference rather than a selection-rule one, and it is
narrower than it looks. Measured against the real engine on `aaa     bbb`:

| double-click target | cascadia | ghostty |
|---|---|---|
| space run **inside** written text | selects the run | selects the run (`cells 3+4`, five spaces) |
| region **past the end** of the line | selects to the pane edge | selects nothing |

Cascadia's text buffer pads every row to full width with real space characters,
so those cells are written and a run of them is a word made of delimiters.
ghostty leaves them empty, and `Screen.selectWord` refuses on purpose: "If our
cell is empty we can't select a word, because we can't select areas where the
screen is not yet written."

**Recommended: leave it.** What closing it buys is selecting and copying spaces
that do not exist; what it costs is either changing ghostty's double-click for
everyone against an explicit design decision (so, not upstreamable) or a third
config option and its plumbing. *Measured.*

### GD-06 — Keyboard selection: no mark mode, no quick-edit  ([#7](https://github.com/ibuildthecloud/winterm-ghostty/issues/7))

`ToggleMarkMode`, `SwitchSelectionEndpoint`, `ExpandSelectionToWord`,
`TryMarkModeKeybinding` and `SelectionMode` are all stubs, so shift+arrow
quick-edit and mark mode select nothing. ghostty has `adjust_selection` as a
binding action, which is the route this would take; nothing drives it yet.

This was assumed to be covered by the gate's "marks are prompt-level only"
decision and is not — that decision is about `SemanticPrompt`, and this is
unrelated. *Read.*

### GD-07 — Mouse reporting to the application — **implemented 2026-08-09**

Was: `IsVtMouseModeEnabled` returned false and `SendMouseEvent` returned "not
handled", so WT never routed mouse input down its VT path for a ghostty pane.

The entry predicted the symptom exactly — "applications that ask for mouse
reporting may still see *some* events, because the pointer positions the
selection path sends reach ghostty and ghostty reports them itself — but the
wheel and the non-left buttons never arrive" — and that is what a user
eventually measured with a raw crossterm probe: one physical click producing two
`Down` and one `Up`, and zero right-button events in a long session.

**Now implemented.** `IsVtMouseModeEnabled` answers from
`ghostty_surface_mouse_captured`, the same question ghostty asks itself when
deciding whether to report, so the two sides cannot disagree about the mode.
`SendMouseEvent` moves the pointer with modifiers, then dispatches press and
release for left, right and middle, and scroll on both axes.

The arbitration is not ours and did not need writing:
`ControlInteractivity::_canSendVTMouseInput` already chooses this path over
selection, and already implements the convention that holding shift suppresses
reporting so a user can always select. Both engines obey one rule because it is
the same code.

Worth keeping from the diagnosis: **the report's leading hypothesis was wrong in
an instructive way.** It reasoned from the bytes on the wire — crossterm enables
both urxvt (1015) and SGR (1006), so a terminal answering in both would double
every event — which is a good theory that fits the evidence, including why only
presses doubled. The actual cause was upstream of encoding entirely: the same
button was pressed twice at the ghostty layer, by two different call sites in
the selection path. Evidence that fits a hypothesis is not evidence for it.

### GD-08 — Bracketed paste is always off — **implemented 2026-08-11**  ([#8](https://github.com/ibuildthecloud/winterm-ghostty/issues/8))

Was: `BracketedPasteEnabled` returned a hardcoded false.

**The entry's mechanism was wrong, and that is the interesting part.** It said
WT "does not wrap a paste in `ESC[200~`/`ESC[201~`". WT does not, but libghostty
always has. `ghostty_surface_text` — the call `SendInput` has used since the
first ghostty pane — is documented as *"treated like a paste"*, and it is: it
reaches `completeClipboardPaste`, which frames the data whenever mode 2004 is
on. Pastes were never unframed. A wrap added on the WT side would have been the
*second* pair.

What false actually cost is everything WT decides *around* a paste. Three call
sites read this one property, all above the core, and all of them were deciding
as though every application were paste-blind:

| Reader | With the mode wrongly false |
|---|---|
| `TrimPaste` | trimmed trailing whitespace the application wanted kept |
| empty clipboard | sent nothing, where WT's own core calls the bare fencepost pair load-bearing |
| `warning.multiLinePaste: automatic` | warned on every multi-line paste, including into applications that had said they can tell a paste from typing |

**Now implemented.** `BracketedPasteEnabled` answers from
`ghostty_surface_bracketed_paste_enabled`, read under the renderer lock — the
same shape as `mouse_captured` in GD-07, so the embedder and ghostty cannot
disagree about the mode.

The empty-clipboard branch needed writing, and only became *reachable* now:
`TerminalPage` discards an empty paste outright when it believes the mode is
off, so the load-bearing empty paste never got as far as the core before.
libghostty returns early on zero-length input before its encoder runs, so
`PasteText` writes the bare pair straight to the connection.

Measured in a real ghostty pane with a raw-input probe, mode 2004 on and
`warning.multiLinePaste` set to `automatic`:

| Pasted | Received |
|---|---|
| `HELLO` | `<ESC>[200~HELLO<ESC>[201~` |
| `AAA\r\nBBB` | `<ESC>[200~AAA<CR><LF>BBB<ESC>[201~`, no warning dialog |
| *(empty clipboard)* | `<ESC>[200~<ESC>[201~` |

The multi-line paste arriving unattended is itself the evidence: under
`automatic` the dialog is raised exactly when the flag reads false, so nothing
blocking the paste means the flag is being read.

The same probe run turned up
[GD-15](#gd-15--sendinput-cannot-send-an-escape-sequence--15), which is not this
bug and predates it.

### GD-09 — Appearance beyond font and colours is not applied  ([#9](https://github.com/ibuildthecloud/winterm-ghostty/issues/9))

`Opacity` is 1.0, `UseAcrylic` false, `AdjustOpacity` and `ToggleShaderEffects`
do nothing, and `ApplyAppearance`/`SetHighContrastMode`/the colour-scheme preview
calls are stubs. A ghostty pane ignores a profile's transparency, acrylic,
background image and custom shaders, and does not change appearance on focus.

Phase 7 owns presentation. Listed here because a user reading their profile
cannot tell which of its settings a ghostty pane honours. *Read.*

### GD-10 — Command history, quick fixes, completions and session persistence  ([#10](https://github.com/ibuildthecloud/winterm-ghostty/issues/10))

`CommandHistory` returns null, `QuickFixesAvailable` false,
`UpdateQuickFixes`/`ClearQuickFix`/`PreviewInput`/`OpenCWD` do nothing, and
`PersistTo`/`RestoreFromPath` are empty — so a ghostty pane does not restore with
a saved session. All of these read WT's own semantic-prompt bookkeeping, which
GD-02's `u2` cannot supply. *Read.*

### GD-11 — `ColorSelection` does nothing  ([#11](https://github.com/ibuildthecloud/winterm-ghostty/issues/11))

WT can tint a selection (used by "mark all matches"). ghostty has no equivalent
entry point. *Read.*

### GD-12 — `ClearBuffer` does nothing  ([#12](https://github.com/ibuildthecloud/winterm-ghostty/issues/12))

Clear-buffer actions (clear viewport / scrollback / all) do nothing on a ghostty
pane. `clear_screen` exists as a binding action and covers screen+scrollback;
WT's three-way distinction does not map onto it exactly, which is why this was
left rather than half-wired. *Read.*

### GD-15 — `sendInput` cannot send an escape sequence — **implemented 2026-08-11**  ([#15](https://github.com/ibuildthecloud/winterm-ghostty/issues/15))

Was: `GhosttyControlCore::SendInput` called `ghostty_surface_text`, which is
libghostty's **paste** entry point. That is right for `PasteText` and wrong for
everything else that reaches it, because `input/paste.zig` deliberately does two
things to pasted data — xterm's behaviour, and correct for a paste:

- every ESC, DEL, NUL, BS and the terminal's own control characters
  (Ctrl+C, Ctrl+Z, Ctrl+S, …) is **replaced with a space**, so that pasted text
  cannot inject commands;
- the data is **framed in `ESC[200~`/`ESC[201~`** when mode 2004 is on.

A paste wants both. A `sendInput` action wants neither: it is the user
deliberately sending bytes, and its whole purpose is usually the escape
sequence. Broadcast input (`RawWriteString`) and any character that falls
through to `SendCharEvent` take the same path.

Measured, with a `sendInput` action carrying `\e[31mREDTEXT\e[0m` into a
ghostty pane running a raw-input probe with mode 2004 on:

| | |
|---|---|
| sent | `<ESC>[31mREDTEXT<ESC>[0m` |
| received | `<ESC>[200~ [31mREDTEXT [0m<ESC>[201~` |

Both ESCs gone to spaces, and the action framed as a paste it never was. So on
a ghostty pane a `sendInput` action can send literal text and nothing else.

This is **not** GD-08 and does not depend on it — the ESC stripping happens
whether or not mode 2004 is on. It was found by the probe run that verified
GD-08, having been there since `SendInput` was first written.

**Now implemented.** `SendInput` and `SendCharEvent` write through
`WriteToConnection` — the literal byte path libghostty's external termio backend
already calls to reach WT's conpty. `PasteText` keeps `ghostty_surface_text` and
is now its only caller, which is what that entry point was always for.

**The open question is answered, and the answer was in cascadia rather than in
libghostty.** Past the encoder itself, `completeClipboardPaste` does exactly one
thing a direct write would skip: a scroll-to-bottom. That is the paste's
behaviour, not this path's — cascadia does not snap the viewport for `SendInput`
either, because `TrySnapOnInput` sits on the key and paste paths only
(`ControlCore::PasteText`, `Terminal::SendKeyEvent`). So not scrolling here is
the parity behaviour, not an omission, and both paths now match cascadia.

Measured in a real ghostty pane against `harness/rawin`, a probe that prints the
bytes the child receives, with mode 2004 on:

| Fired | Received |
|---|---|
| `sendInput` `<ESC>[31mREDTEXT<ESC>[0m` | `<ESC>[31mREDTEXT<ESC>[0m` |
| `sendInput` `AA<0x03>BB` | `AA<0x03>BB` |
| ctrl+v, unbound — so a char event | `<0x16>` |
| typing `xy` | `x`, `y` |
| paste of `HELLO` | `<ESC>[200~HELLO<ESC>[201~` |

The first row is the bug. The last is the regression check: a real paste is
still filtered and still framed, so GD-08 is untouched. The third is the
accidental one — with `ctrl+v` unbound in the profile under test the keystroke
reaches the child as a character event, and 0x16 arriving as itself rather than
as a space is the `SendCharEvent` half of the same fix.

**`harness/rawin` is the durable part.** Both GD-08 and GD-15 were found and
settled by watching the byte stream at the child, and neither is visible in a
screenshot — the pane looks identical whether the ESC survived or not. The probe
turns DEC 2004 on for itself, puts the console in raw VT-input mode, and names
every byte it reads.

---

## Permanent, by upstream decision

### GD-14 — Sixel graphics are not supported and never will be  ([#14](https://github.com/ibuildthecloud/winterm-ghostty/issues/14))

A cascadia pane renders sixel images; a ghostty pane ignores the sequence
entirely. This is not a gap waiting on an upstream release, and advancing the
pin will never close it.

ghostty has **no sixel implementation at all**. At pin `4d605bf0` the string
"sixel" appears exactly twice in the whole repository, and both are the same
thing — the DA1 feature *code* `4`, in `src/terminal/device_attributes.zig:53`
and its C mirror `include/ghostty/vt/device.h:38`. There is no decoder and no
pixel path, and the default DA1 response advertises only `.ansi_color`, so
ghostty does not claim the capability either.

Upstream has decided against it
([discussion #2496](https://github.com/ghostty-org/ghostty/discussions/2496)):
sixel has many unspecified edge cases, libsixel is not suited to drop-in
adoption, the performance cost is unclear, and the Kitty graphics protocol —
which ghostty does implement — was designed to solve the problem sixel forces on
clients, where a partially clipped image must be re-encoded to the visible
region.

Cascadia's implementation is `src/terminal/parser/SixelParser.cpp`, dispatched
through `adaptDispatch`, so the capability really is present on one side of the
seam and absent on the other.

**Closing it** would mean writing a sixel decoder against a protocol upstream
has rejected, and carrying it as a fork patch forever. Not recommended. The
honest fix is that this is documented and that an application probing DA1 gets a
truthful answer, which it does.

*Read* — verified from both engines' sources, not by displaying an image.

> Related, and **not** yet verified: ghostty does not implement the Kitty
> protocol's *animation frames*. Whether anything a user runs depends on that is
> unknown here.

## Not diffs, though they look like ones

- **`ForegroundColor`/`BackgroundColor` return constants.** They feed WT's
  tab/title colouring, and the pane's real colours come from the profile through
  the settings translator. A profile with a scheme is drawn correctly; only WT's
  derived chrome colour is generic. Worth fixing, not user-visible as a terminal
  difference.
- **RTF copy.** Neither engine offers it here: WT's own RTF path is not on this
  interface. Recorded at the gate as a gap in ghostty; it is not a difference
  between the two panes.
- **`IsBufferRowInViewport`** is implemented and correct, from the scrollbar
  action's own numbers.
