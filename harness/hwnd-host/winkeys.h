// Windows keyboard message -> ghostty key event translation.
//
// Kept separate from main.c because this is the reusable part: the eventual
// Windows Terminal integration needs exactly this, and it is worth testing on
// its own.
#ifndef WINKEYS_H
#define WINKEYS_H

#include <windows.h>
#include "ghostty.h"
#include <stdbool.h>

// Translate a WM_KEY*/WM_SYSKEY* message into a ghostty key event.
//
// `text_buf` backs the event's `text` pointer and must outlive the call to
// ghostty_surface_key. Returns false if the message carries nothing useful.
bool winkeys_translate(UINT msg, WPARAM wparam, LPARAM lparam,
                       ghostty_input_key_s *out, char text_buf[8]);

// Build the key event a keystroke that types `ch` on the current layout would
// produce, without needing the key to actually be pressed. Everything except
// where the keyboard state came from is shared with winkeys_translate, so this
// is a faithful probe of the translation and not a second implementation.
//
// Returns false if the character is unreachable on the current layout.
bool winkeys_synthesize(WCHAR ch, ghostty_input_key_s *out, char text_buf[8]);

// The native keycode ghostty expects on Windows, built from a message's lParam.
// Exposed for testing.
uint32_t winkeys_keycode(LPARAM lparam);

// Current modifier state, from the thread's keyboard state.
ghostty_input_mods_e winkeys_mods(void);

#endif
