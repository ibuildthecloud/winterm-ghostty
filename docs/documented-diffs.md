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

### GD-01 — Hyperlinks are not detected, hovered or clickable

`GetHyperlink`, `HoveredUriText`, `HoveredCell` and `SetHoveredCell` all return
empty. A URL in output is plain text in a ghostty pane: no underline on hover, no
tooltip, no ctrl-click.

ghostty finds links itself (`Surface.linkAtPin`) and even selects them on
double-click, but nothing in the C API reads a link back out or reports one under
the pointer. Closing this needs a new libghostty entry point, which is exactly
what the gate ruled out of Phase 6. *Read.*

### GD-02 — `SelectCommand` / `SelectOutput` do nothing, and the context menu hides them

WT can select the command or the output of the prompt under the cursor. ghostty's
`SemanticPrompt` is a `u2` — `none` / `prompt` / `prompt_continuation` — so it
records where prompts are and nothing about what a command or its output spans.
`ShouldShowSelectCommand`/`ShouldShowSelectOutput` return false so the menu items
do not appear, rather than appearing and doing nothing.

Widening `SemanticPrompt` touches row packing in ghostty and wants its own ADR.
*Read.*

### GD-03 — No scrollbar error pips, and no marks except prompts

`ScrollMarks()` is empty and `AddMark`/`ClearMark`/`ClearAllMarks` do nothing.
`ScrollToMark` works — it maps to `jump_to_prompt` — so navigation between prompts
is there, but the scrollbar shows no mark pips and cannot show *error* pips at
all: exit codes have nowhere to live in a `u2`. Same ADR as GD-02. *Read.*

### GD-04 — Search: no regex, no case sensitivity, and no scrollbar pips for matches

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

### GD-05 — IME does not work at all

A ghostty pane is never registered with TSF, so there is no composition window,
no candidate window and no preedit. Typing through a CJK IME does nothing useful.

The cause is structural rather than missing plumbing: WT's TSF `Implementation`
reaches through `IDataProvider::GetRenderer()` and writes the preedit into WT's
own `renderData->tsfPreview`, dereferencing that renderer without a null check
(`src/tsf/Implementation.cpp:197`). A provider with no WT renderer to hand out
cannot merely return null — the control must not register at all.

Closing it is a known shape and not small: replace `GetRenderer()` on
`IDataProvider` with composition callbacks so TSF stops reaching for a renderer
(which would also remove ADR 0001's seventh and last `get_self` escape), route
the preedit to `ghostty_surface_preedit`, and answer `GetCursorPosition` from
`ghostty_surface_ime_point`, which already returns the cursor rect in DIPs with
the preedit width and padding accounted for.

**It also cannot be verified here.** The exit criterion asks for a CJK language
end-to-end including candidate-window placement, which needs an installed IME and
a human at the keyboard. *Read.*

### GD-13 — Double-clicking past the end of a line selects nothing

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

### GD-06 — Keyboard selection: no mark mode, no quick-edit

`ToggleMarkMode`, `SwitchSelectionEndpoint`, `ExpandSelectionToWord`,
`TryMarkModeKeybinding` and `SelectionMode` are all stubs, so shift+arrow
quick-edit and mark mode select nothing. ghostty has `adjust_selection` as a
binding action, which is the route this would take; nothing drives it yet.

This was assumed to be covered by the gate's "marks are prompt-level only"
decision and is not — that decision is about `SemanticPrompt`, and this is
unrelated. *Read.*

### GD-07 — Mouse reporting to the application is not wired

`IsVtMouseModeEnabled` returns false and `SendMouseEvent` returns "not handled",
so WT never routes mouse input down its VT path for a ghostty pane. Applications
that ask for mouse reporting may still see *some* events, because the pointer
positions the selection path sends reach ghostty and ghostty reports them itself
— but the wheel and the non-left buttons never arrive, and WT keeps treating
drags as selection while the application believes it has the mouse.

Neither half of that has been exercised. Worth measuring before designing: what
ghostty reports today may already be most of it. *Read.*

### GD-08 — Bracketed paste is always off

`BracketedPasteEnabled` returns false, so WT does not wrap a paste in
`ESC[200~`/`ESC[201~` and does not warn about multi-line pastes on the strength
of the terminal's own mode. ghostty tracks the mode internally and honours it for
its own paste path; the state is not exposed to an embedder. *Read.*

### GD-09 — Appearance beyond font and colours is not applied

`Opacity` is 1.0, `UseAcrylic` false, `AdjustOpacity` and `ToggleShaderEffects`
do nothing, and `ApplyAppearance`/`SetHighContrastMode`/the colour-scheme preview
calls are stubs. A ghostty pane ignores a profile's transparency, acrylic,
background image and custom shaders, and does not change appearance on focus.

Phase 7 owns presentation. Listed here because a user reading their profile
cannot tell which of its settings a ghostty pane honours. *Read.*

### GD-10 — Command history, quick fixes, completions and session persistence

`CommandHistory` returns null, `QuickFixesAvailable` false,
`UpdateQuickFixes`/`ClearQuickFix`/`PreviewInput`/`OpenCWD` do nothing, and
`PersistTo`/`RestoreFromPath` are empty — so a ghostty pane does not restore with
a saved session. All of these read WT's own semantic-prompt bookkeeping, which
GD-02's `u2` cannot supply. *Read.*

### GD-11 — `ColorSelection` does nothing

WT can tint a selection (used by "mark all matches"). ghostty has no equivalent
entry point. *Read.*

### GD-12 — `ClearBuffer` does nothing

Clear-buffer actions (clear viewport / scrollback / all) do nothing on a ghostty
pane. `clear_screen` exists as a binding action and covers screen+scrollback;
WT's three-way distinction does not map onto it exactly, which is why this was
left rather than half-wired. *Read.*

---

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
