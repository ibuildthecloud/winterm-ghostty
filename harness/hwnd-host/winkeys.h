// Windows keyboard message -> ghostty key event translation.
//
// Kept separate from main.c because this table is the reusable part: the eventual
// Windows Terminal integration needs exactly this mapping, and it is the piece
// worth testing on its own.
#ifndef WINKEYS_H
#define WINKEYS_H

#include <windows.h>
#include "ghostty.h"
#include <stdbool.h>

// Translate a WM_KEY*/WM_SYSKEY* message into a ghostty key event.
//
// Returns false if the message should be ignored (a key we have no mapping for
// and which produced no text, or a dead key mid-composition).
bool winkeys_translate(UINT msg, WPARAM wparam, LPARAM lparam,
                       ghostty_input_key_s *out, char text_buf[8]);

// Map a Windows scan code (with its extended flag) to a ghostty physical key.
// Exposed for testing.
ghostty_input_key_e winkeys_scancode_to_key(UINT scancode, bool extended);

// Current modifier state, from the thread's keyboard state.
ghostty_input_mods_e winkeys_mods(void);

#endif
