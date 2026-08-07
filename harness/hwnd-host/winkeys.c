#include "winkeys.h"
#include <string.h>

// The `keycode` field of ghostty_input_key_s is a *native* platform keycode,
// not a value from ghostty_input_key_e. libghostty resolves it against its own
// table (src/input/keycodes.zig), which on Windows stores the scan code:
//
//     //   USB     evdev    XKB     Win     Mac   Code
//     .{ 0x070004, 0x001e, 0x0026, 0x001e, 0x0000, "KeyA"      },
//     .{ 0x07002a, 0x000e, 0x0016, 0x000e, 0x0033, "Backspace" },
//     .{ 0x07004a, 0x0066, 0x006e, 0xe047, 0x0073, "Home"      },
//     .{ 0x070058, 0x0060, 0x0068, 0xe01c, 0x004c, "NumpadEnter" },
//
// so extended (E0-prefixed) keys carry 0xE0 in the high byte and everything
// else is the bare scan code. That is the whole mapping.
//
// An earlier version of this file carried its own scan-code -> key table and
// passed the enum value here. It never matched, so `physical_key` resolved to
// .unidentified for every key and only the text field did any work - which is
// why dropping control-character text made Backspace stop responding entirely
// rather than start behaving. Deleting that table also removes a second source
// of truth that could drift from ghostty's.
uint32_t winkeys_keycode(LPARAM lparam) {
    const uint32_t scancode = (uint32_t)((lparam >> 16) & 0xFF);
    const bool extended = ((lparam >> 24) & 1) != 0;
    return extended ? (0xE000u | scancode) : scancode;
}

ghostty_input_mods_e winkeys_mods(void) {
    int mods = GHOSTTY_MODS_NONE;
    // High bit means down; the low bit means toggled, which is what we want for
    // the lock keys and not for the others.
    if (GetKeyState(VK_LSHIFT) & 0x8000) mods |= GHOSTTY_MODS_SHIFT;
    if (GetKeyState(VK_RSHIFT) & 0x8000) mods |= GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_SHIFT_RIGHT;
    if (GetKeyState(VK_LCONTROL) & 0x8000) mods |= GHOSTTY_MODS_CTRL;
    if (GetKeyState(VK_RCONTROL) & 0x8000) mods |= GHOSTTY_MODS_CTRL | GHOSTTY_MODS_CTRL_RIGHT;
    if (GetKeyState(VK_LMENU) & 0x8000) mods |= GHOSTTY_MODS_ALT;
    if (GetKeyState(VK_RMENU) & 0x8000) mods |= GHOSTTY_MODS_ALT | GHOSTTY_MODS_ALT_RIGHT;
    if (GetKeyState(VK_LWIN) & 0x8000) mods |= GHOSTTY_MODS_SUPER;
    if (GetKeyState(VK_RWIN) & 0x8000) mods |= GHOSTTY_MODS_SUPER | GHOSTTY_MODS_SUPER_RIGHT;
    if (GetKeyState(VK_CAPITAL) & 0x0001) mods |= GHOSTTY_MODS_CAPS;
    if (GetKeyState(VK_NUMLOCK) & 0x0001) mods |= GHOSTTY_MODS_NUM;
    return (ghostty_input_mods_e)mods;
}

// Translate a key press to the text it produces, as UTF-8.
//
// ToUnicode is used rather than waiting for WM_CHAR so the text arrives with
// the key event ghostty is given, instead of as a separate message that would
// have to be correlated back to it.
//
// The 1<<2 flag is load-bearing: it tells ToUnicode not to modify kernel-side
// keyboard state. Without it, probing a dead key here consumes it and the
// following key silently loses its accent.
static int keyText(UINT vk, UINT scancode, const BYTE *kbd, char *out, int out_len) {
    WCHAR wbuf[8] = {0};
    const int n = ToUnicode(vk, scancode, kbd, wbuf, 8, 1 << 2);
    if (n <= 0) return 0;  // 0 = no translation, <0 = dead key
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, wbuf, n, out, out_len - 1, NULL, NULL);
    if (bytes <= 0) return 0;
    out[bytes] = '\0';

    // Drop control characters.
    //
    // ToUnicode translates Backspace to 0x08, Tab to 0x09, Enter to 0x0D,
    // Escape to 0x1B and ctrl+letter to 0x01-0x1A. None of those are "text":
    // they are keys whose terminal encoding ghostty owns, and which depend on
    // modes we know nothing about here (backspace-is-delete, the kitty
    // keyboard protocol, application cursor keys).
    //
    // Forwarding them is destructive rather than redundant, because
    // key_encode.zig short-circuits on a non-empty utf8 field -
    // `if (event.utf8.len > 0) return try writer.writeAll(event.utf8);` - so a
    // control character here *replaces* ghostty's encoding of the key. ghostty
    // guards the same hazard internally with isControlUtf8.
    for (int i = 0; i < bytes; i++) {
        const unsigned char c = (unsigned char)out[i];
        if (c < 0x20 || c == 0x7F) {
            out[0] = '\0';
            return 0;
        }
    }
    return bytes;
}

// Fill in `text` and `unshifted_codepoint` from a keyboard state. Shared by the
// live path and the synthesized one so a probe cannot drift from what a real
// keystroke produces.
static void fillText(UINT vk, UINT scancode, const BYTE *kbd,
                     ghostty_input_key_s *out, char text_buf[8]) {
    keyText(vk, scancode, kbd, text_buf, 8);
    out->text = text_buf[0] ? text_buf : NULL;

    // The unshifted codepoint is what key bindings match against, so it
    // has to ignore Shift and the lock keys - otherwise ctrl+shift+c
    // would fail to match a binding written against `c`.
    BYTE plain[256];
    memcpy(plain, kbd, 256);
    plain[VK_SHIFT] = plain[VK_LSHIFT] = plain[VK_RSHIFT] = 0;
    plain[VK_CONTROL] = plain[VK_LCONTROL] = plain[VK_RCONTROL] = 0;
    plain[VK_MENU] = plain[VK_LMENU] = plain[VK_RMENU] = 0;
    plain[VK_CAPITAL] = 0;
    char unshifted[8] = {0};
    if (keyText(vk, scancode, plain, unshifted, 8) > 0 &&
        (unsigned char)unshifted[0] < 0x80) {
        out->unshifted_codepoint = (uint32_t)(unsigned char)unshifted[0];
    }
}

bool winkeys_synthesize(WCHAR ch, ghostty_input_key_s *out, char text_buf[8]) {
    memset(out, 0, sizeof(*out));
    text_buf[0] = '\0';

    // VkKeyScanW answers "which key, with which modifiers, types this
    // character on the current layout" - the inverse of what a keystroke does,
    // which is what lets a probe name a character rather than a scan code.
    const SHORT vks = VkKeyScanW(ch);
    if (vks == -1) return false;
    const UINT vk = (UINT)(vks & 0xFF);
    const int shift_state = (vks >> 8) & 0xFF;
    const UINT scancode = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
    if (scancode == 0) return false;

    BYTE kbd[256] = {0};
    if (shift_state & 1) kbd[VK_SHIFT] = kbd[VK_LSHIFT] = 0x80;
    if (shift_state & 2) kbd[VK_CONTROL] = kbd[VK_LCONTROL] = 0x80;
    if (shift_state & 4) kbd[VK_MENU] = kbd[VK_LMENU] = 0x80;

    out->action = GHOSTTY_ACTION_PRESS;
    out->keycode = scancode;
    out->composing = false;
    int mods = GHOSTTY_MODS_NONE;
    if (shift_state & 1) mods |= GHOSTTY_MODS_SHIFT;
    if (shift_state & 2) mods |= GHOSTTY_MODS_CTRL;
    if (shift_state & 4) mods |= GHOSTTY_MODS_ALT;
    out->mods = (ghostty_input_mods_e)mods;

    fillText(vk, scancode, kbd, out, text_buf);
    return true;
}

bool winkeys_translate(UINT msg, WPARAM wparam, LPARAM lparam,
                       ghostty_input_key_s *out, char text_buf[8]) {
    const bool down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
    const UINT vk = (UINT)wparam;
    const UINT scancode = (UINT)((lparam >> 16) & 0xFF);
    const bool was_down = ((lparam >> 30) & 1) != 0;

    memset(out, 0, sizeof(*out));
    text_buf[0] = '\0';

    out->action = !down      ? GHOSTTY_ACTION_RELEASE
                  : was_down ? GHOSTTY_ACTION_REPEAT
                             : GHOSTTY_ACTION_PRESS;
    out->mods = winkeys_mods();
    out->keycode = winkeys_keycode(lparam);
    out->composing = false;

    if (down) {
        BYTE kbd[256];
        if (GetKeyboardState(kbd)) {
            fillText(vk, scancode, kbd, out, text_buf);
        }
    }

    // Every key with a scan code is worth forwarding: ghostty resolves it to a
    // physical key and encodes it, whether or not it produced text.
    return out->keycode != 0 || text_buf[0] != '\0';
}
