# 0006 — Windows Terminal keeps ConPTY; ghostty gets an external-stream termio backend

Status: Accepted (2026-08-03, at the Phase 4→5 readiness step)

## Context

Both sides can own the PTY:

- **WT's connection layer** (`ITerminalConnection`, 33-line IDL: `WriteInput`, `Resize`,
  `Close`, `TerminalOutput` event) is a pure byte pipe with three shipping implementations
  (`ConptyConnection`, `AzureConnection`, `EchoConnection`). WT's default-terminal handoff
  (`CTerminalHandoff` — an existing ConPTY created by conhost is handed over via packaged
  COM), session persistence, and pane duplication are all built on it.
- **ghostty's termio** has exactly one backend (`exec`): it spawns the child and owns the
  PTY. wintty's fork runs this way — Zig owns ConPTY — which is fine for a standalone app
  but bypasses WT's connection machinery.

If ghostty owned the PTY inside WT: defterm handoff breaks (the ConPTY already exists and
is handed to WT as handles), the Azure connection can't work at all, and WT's
close-confirmation/persistence flows lose their process handle.

## Decision

WT's `ITerminalConnection` remains the transport. `ConptyConnection` is unmodified. The
ghostty fork gains a second termio backend — **`termio-external`** — where the embedder
feeds output bytes and receives input bytes through the C API instead of ghostty spawning
a child:

- `TerminalOutput(bytes)` → `ghostty_surface_write_pty_output(surface, ptr, len)`
  (backpressure-aware; feeds the same parse path as the read thread).
- ghostty's input encoding emits through the existing write callback →
  `ITerminalConnection.WriteInput`.
- Resize flows both ways: engine cell-metrics drive `Resize(rows, cols)` on the
  connection; the connection owns `ConptyResizePseudoConsole`.

`src/termio/backend.zig` already abstracts the backend (one variant today); this is the
second variant, and it is exactly what any embedder with host-owned IO needs — a
legitimate upstream patch, not a WT-ism.

## Alternatives rejected

- **ghostty owns ConPTY** (wintty's model): breaks defterm handoff and the
  Azure/persistence flows; duplicates the process-lifecycle machinery WT already has.
- **Pass the ConPTY/process handles into ghostty's exec backend**: entangles two owners
  with one kernel object across a DLL boundary; handoff still breaks (no process to spawn).
- **Byte-shuttle via a loopback pipe pair** (fake PTY between WT and ghostty's exec
  backend): an extra kernel-object hop and resize-ordering hazard to avoid writing the
  backend properly.

## Consequences

- The three `try_as<ConptyConnection>` leaks in WT (`ReparentWindow`, `ShowHide`,
  `ClearBuffer`) keep working unchanged, since the connection is untouched.
- `termio-external` is a new upstream patch in ADR 0004's series and the only piece of
  this ADR with real design risk (backpressure and the parse-thread boundary); it is
  scheduled early (Phase 5) to surface problems.
- ghostty features that read the child process directly (`foreground_pid`, `tty_name`)
  must route through the connection instead; WT already exposes `RootProcessHandle` for
  close-confirmation, so parity holds.
- UTF-16→UTF-8 conversion happens at the `GhosttyControlCore` boundary (WT connections
  emit UTF-16 chars; ghostty parses bytes).
