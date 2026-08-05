// extpty: a ConPTY owned by the *host*, for exercising libghostty's external
// termio backend (ADR 0006).
//
// This is Windows Terminal's arrangement in miniature: we create the pseudo
// console and the child, we read its output and push it into the surface with
// ghostty_surface_write_pty_output, and libghostty hands us the terminal's
// input through the write_pty/resize_pty runtime callbacks. libghostty spawns
// nothing.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "ghostty.h"

// Start a pseudo console running `cmdline` at the given grid size, and a
// reader thread that feeds its output into `surface`. The surface must already
// exist and must have been created with GHOSTTY_IO_BACKEND_EXTERNAL.
bool extpty_start(ghostty_surface_t surface, const wchar_t *cmdline,
                  uint16_t cols, uint16_t rows);

// Send bytes to the child. Safe before extpty_start (dropped).
void extpty_write(const uint8_t *data, size_t len);

// Resize the pseudo console. Before extpty_start this only records the size,
// which is how the initial size from libghostty reaches CreatePseudoConsole:
// the surface sizes its grid while it initializes, before we have a pty.
void extpty_resize(uint16_t cols, uint16_t rows);

// Close the pty and wait for the reader thread. Safe to call twice.
void extpty_stop(void);
