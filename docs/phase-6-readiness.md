# Phase 6 readiness — findings and recommendations

Prepared 2026-08-05 at the Phase 5→6 readiness step, against `ghostty/` on the `windows`
branch and `terminal/` @ `1c5648c7e`. Answers PLAN's "Open questions (resolve at
readiness)" for Phase 6. **Recommendations only — the readiness step is interactive, and
nothing here is settled until the human agrees.**

Everything below is read off the engine's actual API and source, not inferred from what
the phase text hoped for. Where the answer is "ghostty cannot do this", that is a finding
about scope, not a defect.

## The surface API is the budget

`ghostty_surface_*` is the whole of what an embedder can call. For Phase 6 the relevant
entries are:

| Need | What exists |
| --- | --- |
| Selection | `ghostty_surface_has_selection`, `ghostty_surface_read_selection` |
| Arbitrary text read-back | `ghostty_surface_read_text` (takes a `ghostty_selection_s`) |
| Everything else | `ghostty_surface_binding_action` — a *string* action, the route Phase 5 already used for `scroll_to_row` |

There is no C entry point for search, marks, hyperlinks or clipboard formats — but that is
not the same as those capabilities being absent. Most of them are reachable through a
binding action, with the result arriving as an *action* or a *callback*. Read the binding
list before concluding anything is missing; Q1 below is a worked example of getting that
wrong.

## Q1 — Clipboard fidelity: can read-back produce styled (HTML/RTF) copies?

**Corrected 2026-08-05, after this file first said no.** The first answer generalised from
one API to the whole capability and was wrong. Both statements below are true; only the
second one answers the question.

**Read-back is plain text.** `ghostty_surface_read_selection` and
`ghostty_surface_read_text` both return `ghostty_text_s`:

```c
typedef struct {
  double tl_px_x; double tl_px_y;
  uint32_t offset_start; uint32_t offset_len;
  const char* text; uintptr_t text_len;
} ghostty_text_s;
```

Text and geometry, no attributes. Nothing an HTML writer could consume.

**But copying is not read-back.** `src/input/Binding.zig` has:

```zig
copy_to_clipboard: CopyToClipboard,   // plain | vt | html | mixed  (default mixed)
```

and the styled result comes back through the *clipboard* callback, not the read API:

```c
typedef struct { const char *mime; const char *data; } ghostty_clipboard_content_s;
typedef void (*ghostty_runtime_write_clipboard_cb)(void*, ghostty_clipboard_e,
                                                   const ghostty_clipboard_content_s*,
                                                   size_t, bool);
```

An **array** of MIME-tagged representations — which is exactly the shape Windows Terminal
needs to put plain text and HTML on the clipboard together.

**So: HTML copy is available and cheap** (a binding action plus a callback already wired in
Phase 5). **RTF is not** — ghostty offers `plain`/`vt`/`html`/`mixed` and nothing else,
while WT's `CopyFormat` includes RTF.

**Recommendation:** HTML copy is in scope, since it falls inside the standing decision of
"nothing beyond what the engine supports". **RTF is the tracked gap**, not styled copy as a
whole. `vt` is a bonus WT has no equivalent for and can be ignored.

**Method note.** The wrong answer came from reading the read-back API, finding no
attributes, and concluding the capability was absent — without checking the other route to
the same capability. The binding-action surface had already been established as the way
things get done in this fork (`scroll_to_row` in Phase 5, search below), which is precisely
why it should have been checked first.

## Q2 — Search capability mapping

Better than the API list suggests, and worse than WT's contract.

**Drivable, via binding actions.** `src/input/Binding.zig` has `search: []const u8`,
`search_selection`, `navigate_search`, `start_search`, `end_search`. So Phase 5's
`scroll_to_row` trick generalises: WT's search box can drive ghostty's search.

**Results come back as actions**, not as return values: `GHOSTTY_ACTION_SEARCH_TOTAL` and
`GHOSTTY_ACTION_SEARCH_SELECTED`. That is an asynchronous shape, where WT's
`SearchResults` is synchronous — worth designing for rather than discovering.

**The capability gap is the needle.** `src/terminal/search/pagelist.zig`:

```zig
pub fn init(alloc, needle: []const u8, list: *PageList, start: *Node)
```

A plain byte-slice needle. **Literal, case-sensitive substring matching only.** No regex,
no case folding, anywhere in the search tree.

WT's `SearchRequest` carries regex and case-sensitivity toggles. The mapping is therefore:

| WT request | ghostty |
| --- | --- |
| literal, case-sensitive | supported |
| literal, case-insensitive | **unsupported** |
| regex | **unsupported** |

**Recommendation:** wire search through the binding actions, and decide *how the
unsupported combinations degrade* before writing code — the three honest options are (a)
disable the toggles on a ghostty pane, (b) leave them enabled and silently ignore them,
(c) patch libghostty to accept search options. (b) is the one to rule out now: a case
toggle that does nothing is worse than one that is greyed out. Recommend (a) for the
phase, with (c) as a tracked follow-up.

## Q3 — Marks parity: are ghostty's OSC 133 semantics close enough?

**No, and the reason is structural.** `src/terminal/page.zig`:

```zig
pub const SemanticPrompt = enum(u2) {
    none = 0,
    prompt = 1,
    prompt_continuation = 2,
};
```

Two bits per row, three states. ghostty records **where prompts are** and nothing else. WT's
mark categories are prompt / command / output / error, and the last one needs OSC 133;D's
exit code, which has nowhere to live in a `u2`.

Consequences, concretely:

- **`scrollToMark` (prompt-to-prompt): feasible.** Prompt rows are exactly what is tracked.
- **`SelectOutput`: approximable** as "between this prompt row and the next", which is close
  to what it means, but it is an inference rather than a recorded boundary.
- **`SelectCommand`: weak.** The command is the tail of a prompt row; without a recorded
  command-start there is no reliable boundary.
- **Error marks / scrollbar error pips: not possible.** Exit codes are not stored.

**Recommendation:** ship prompt-level `scrollToMark`; keep `SelectCommand`/`SelectOutput`
**stubbed** for the phase and file the diff. Widening `SemanticPrompt` touches ghostty's
row packing — that is an upstream-shaped change and wants its own ADR, not a Phase 6
side-quest.

## Q4 — Which "stub initially" items graduate into this phase?

This one is a judgment call for the human, and Phase 5 informs it. The relevant learning is
that **every Phase 5 item that needed a new libghostty entry point cost a patch and a
rebuild cycle**, while everything reachable through an existing binding action or callback
was cheap. On that basis:

| Item | Cost shape | Recommendation |
| --- | --- | --- |
| Selection + copy-on-select | existing read-back API | **graduate** |
| HTML copy | `copy_to_clipboard:html`/`mixed` + the clipboard callback | **graduate** (see Q1's correction) |
| Search | existing binding actions, degraded toggles | **graduate**, with Q2's answer |
| Hyperlinks | needs hover/link read-back; not in the C API | defer |
| Marks (`scrollToMark`) | prompt-level only | **graduate, prompt-level** |
| `SelectCommand` / `SelectOutput` | needs a row-packing change | defer |
| Completions / quick fixes | cascadia-specific UI over cascadia data | defer |
| Persistence | not started anywhere | defer |
| IME | `ghostty_surface_preedit` / `ime_point` exist | **graduate** (it is an exit criterion) |

## Carried from Phase 5, for the retro

1. **`renderNow` compensates for an upstream shortcoming.** Windows Terminal renders after
   every write because libghostty's wakeup coalesces. The alternative is a patch making the
   wakeup's tail non-coalescing, upstream-shaped. Still open; it costs a render per batch
   today and nobody has measured what that costs.
2. **ghostty does not implement win32-input-mode.** ConPTY sends `ESC[?9001h` at startup
   (observed in the harness) and there is no `9001` anywhere in ghostty's source. Nothing
   has visibly broken, but WT's own engine does support it, so a ghostty pane and a
   cascadia pane are not receiving identical input contracts. Worth a deliberate look
   during interaction parity rather than a surprise later.
3. **`harness/hwnd-host/winkeys.c` is the reference implementation for Windows input.** It
   had the native-keycode rule and the control-character rule right since Phase 3, with the
   reasoning written next to them, and the Phase 5 control re-derived both and got them
   wrong. Phase 6 wires mouse input — read that file first.
4. **An unexplained observation, bounded but not closed.** During defterm testing a process
   showed two libghostty `renderer`/`io` pairs with only one ghostty pane visible. A later
   controlled measurement showed one pair per pane, so the mapping is 1:1 and this was
   likely two panes rather than a leak — but it was never fully accounted for. If surface
   count ever matters, measure rather than assume.

## Readiness verdict

Phase 6 is **not ready to start**. Q1–Q3 now have evidenced answers and Q4 has a
recommendation, but per the readiness bar the answers must be *recorded decisions* — in
PLAN or an ADR — not proposals in this file. The two that need a decision rather than a
rubber stamp:

- **Search degradation** (Q2): which of (a)/(b)/(c). This shapes the UI, so it wants
  deciding before code.
- **The scope table** (Q4): specifically whether hyperlinks stay deferred, since PLAN's
  Phase 6 text currently lists them as in-scope.

Phase 6's exit criteria also need sharpening: "a checklist pass of WT's terminal-aware
actions matches cascadia behavior (documented diffs allowed)" has no checklist attached.
The findings above are most of one, and it should be written into PLAN before execution so
that "documented diffs allowed" cannot quietly absorb an unimplemented feature.
