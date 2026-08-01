#include "winkeys.h"
#include <string.h>

// ghostty's key enum follows the W3C uievents-code spec, whose values name
// *physical* key positions rather than the characters they produce. Windows
// scan codes are also physical, so the mapping is scan code -> key and does not
// depend on the active keyboard layout. Mapping from VK codes instead would be
// wrong on any non-US layout: VK_OEM_1 is `;` on US and `ü` on German, but the
// physical key is Semicolon either way, and that is what ghostty wants.
//
// These are PS/2 scan code set 1, which is what Windows reports in lParam bits
// 16-23. Codes not listed produce UNIDENTIFIED, which ghostty tolerates - such
// a key can still deliver text.
static const ghostty_input_key_e k_scancode[0x80] = {
    [0x01] = GHOSTTY_KEY_ESCAPE,
    [0x02] = GHOSTTY_KEY_DIGIT_1,
    [0x03] = GHOSTTY_KEY_DIGIT_2,
    [0x04] = GHOSTTY_KEY_DIGIT_3,
    [0x05] = GHOSTTY_KEY_DIGIT_4,
    [0x06] = GHOSTTY_KEY_DIGIT_5,
    [0x07] = GHOSTTY_KEY_DIGIT_6,
    [0x08] = GHOSTTY_KEY_DIGIT_7,
    [0x09] = GHOSTTY_KEY_DIGIT_8,
    [0x0A] = GHOSTTY_KEY_DIGIT_9,
    [0x0B] = GHOSTTY_KEY_DIGIT_0,
    [0x0C] = GHOSTTY_KEY_MINUS,
    [0x0D] = GHOSTTY_KEY_EQUAL,
    [0x0E] = GHOSTTY_KEY_BACKSPACE,
    [0x0F] = GHOSTTY_KEY_TAB,
    [0x10] = GHOSTTY_KEY_Q,
    [0x11] = GHOSTTY_KEY_W,
    [0x12] = GHOSTTY_KEY_E,
    [0x13] = GHOSTTY_KEY_R,
    [0x14] = GHOSTTY_KEY_T,
    [0x15] = GHOSTTY_KEY_Y,
    [0x16] = GHOSTTY_KEY_U,
    [0x17] = GHOSTTY_KEY_I,
    [0x18] = GHOSTTY_KEY_O,
    [0x19] = GHOSTTY_KEY_P,
    [0x1A] = GHOSTTY_KEY_BRACKET_LEFT,
    [0x1B] = GHOSTTY_KEY_BRACKET_RIGHT,
    [0x1C] = GHOSTTY_KEY_ENTER,
    [0x1D] = GHOSTTY_KEY_CONTROL_LEFT,
    [0x1E] = GHOSTTY_KEY_A,
    [0x1F] = GHOSTTY_KEY_S,
    [0x20] = GHOSTTY_KEY_D,
    [0x21] = GHOSTTY_KEY_F,
    [0x22] = GHOSTTY_KEY_G,
    [0x23] = GHOSTTY_KEY_H,
    [0x24] = GHOSTTY_KEY_J,
    [0x25] = GHOSTTY_KEY_K,
    [0x26] = GHOSTTY_KEY_L,
    [0x27] = GHOSTTY_KEY_SEMICOLON,
    [0x28] = GHOSTTY_KEY_QUOTE,
    [0x29] = GHOSTTY_KEY_BACKQUOTE,
    [0x2A] = GHOSTTY_KEY_SHIFT_LEFT,
    [0x2B] = GHOSTTY_KEY_BACKSLASH,
    [0x2C] = GHOSTTY_KEY_Z,
    [0x2D] = GHOSTTY_KEY_X,
    [0x2E] = GHOSTTY_KEY_C,
    [0x2F] = GHOSTTY_KEY_V,
    [0x30] = GHOSTTY_KEY_B,
    [0x31] = GHOSTTY_KEY_N,
    [0x32] = GHOSTTY_KEY_M,
    [0x33] = GHOSTTY_KEY_COMMA,
    [0x34] = GHOSTTY_KEY_PERIOD,
    [0x35] = GHOSTTY_KEY_SLASH,
    [0x36] = GHOSTTY_KEY_SHIFT_RIGHT,
    [0x37] = GHOSTTY_KEY_NUMPAD_MULTIPLY,
    [0x38] = GHOSTTY_KEY_ALT_LEFT,
    [0x39] = GHOSTTY_KEY_SPACE,
    [0x3A] = GHOSTTY_KEY_CAPS_LOCK,
    [0x3B] = GHOSTTY_KEY_F1,
    [0x3C] = GHOSTTY_KEY_F2,
    [0x3D] = GHOSTTY_KEY_F3,
    [0x3E] = GHOSTTY_KEY_F4,
    [0x3F] = GHOSTTY_KEY_F5,
    [0x40] = GHOSTTY_KEY_F6,
    [0x41] = GHOSTTY_KEY_F7,
    [0x42] = GHOSTTY_KEY_F8,
    [0x43] = GHOSTTY_KEY_F9,
    [0x44] = GHOSTTY_KEY_F10,
    [0x45] = GHOSTTY_KEY_NUM_LOCK,
    [0x46] = GHOSTTY_KEY_SCROLL_LOCK,
    [0x47] = GHOSTTY_KEY_NUMPAD_7,
    [0x48] = GHOSTTY_KEY_NUMPAD_8,
    [0x49] = GHOSTTY_KEY_NUMPAD_9,
    [0x4A] = GHOSTTY_KEY_NUMPAD_SUBTRACT,
    [0x4B] = GHOSTTY_KEY_NUMPAD_4,
    [0x4C] = GHOSTTY_KEY_NUMPAD_5,
    [0x4D] = GHOSTTY_KEY_NUMPAD_6,
    [0x4E] = GHOSTTY_KEY_NUMPAD_ADD,
    [0x4F] = GHOSTTY_KEY_NUMPAD_1,
    [0x50] = GHOSTTY_KEY_NUMPAD_2,
    [0x51] = GHOSTTY_KEY_NUMPAD_3,
    [0x52] = GHOSTTY_KEY_NUMPAD_0,
    [0x53] = GHOSTTY_KEY_NUMPAD_DECIMAL,
    [0x56] = GHOSTTY_KEY_INTL_BACKSLASH,
    [0x57] = GHOSTTY_KEY_F11,
    [0x58] = GHOSTTY_KEY_F12,
    [0x64] = GHOSTTY_KEY_F13,
    [0x65] = GHOSTTY_KEY_F14,
    [0x66] = GHOSTTY_KEY_F15,
    [0x67] = GHOSTTY_KEY_F16,
    [0x68] = GHOSTTY_KEY_F17,
    [0x69] = GHOSTTY_KEY_F18,
    [0x6A] = GHOSTTY_KEY_F19,
    [0x6B] = GHOSTTY_KEY_F20,
    [0x6C] = GHOSTTY_KEY_F21,
    [0x6D] = GHOSTTY_KEY_F22,
    [0x6E] = GHOSTTY_KEY_F23,
    [0x76] = GHOSTTY_KEY_F24,
    [0x70] = GHOSTTY_KEY_KANA_MODE,
    [0x73] = GHOSTTY_KEY_INTL_RO,
    [0x79] = GHOSTTY_KEY_CONVERT,
    [0x7B] = GHOSTTY_KEY_NON_CONVERT,
    [0x7D] = GHOSTTY_KEY_INTL_YEN,
};

// The E0-prefixed set. Windows signals these with the extended bit in lParam.
// Several share a scan code with an unextended key - 0x1C is Enter but
// E0 0x1C is the numpad's Enter - so the extended flag has to be consulted or
// the numpad and the arrow cluster collapse onto the main keys.
static ghostty_input_key_e extendedKey(UINT scancode) {
    switch (scancode) {
    case 0x1C: return GHOSTTY_KEY_NUMPAD_ENTER;
    case 0x1D: return GHOSTTY_KEY_CONTROL_RIGHT;
    case 0x35: return GHOSTTY_KEY_NUMPAD_DIVIDE;
    case 0x37: return GHOSTTY_KEY_PRINT_SCREEN;
    case 0x38: return GHOSTTY_KEY_ALT_RIGHT;
    case 0x46: return GHOSTTY_KEY_PAUSE;   // Ctrl+Break reports here
    case 0x47: return GHOSTTY_KEY_HOME;
    case 0x48: return GHOSTTY_KEY_ARROW_UP;
    case 0x49: return GHOSTTY_KEY_PAGE_UP;
    case 0x4B: return GHOSTTY_KEY_ARROW_LEFT;
    case 0x4D: return GHOSTTY_KEY_ARROW_RIGHT;
    case 0x4F: return GHOSTTY_KEY_END;
    case 0x50: return GHOSTTY_KEY_ARROW_DOWN;
    case 0x51: return GHOSTTY_KEY_PAGE_DOWN;
    case 0x52: return GHOSTTY_KEY_INSERT;
    case 0x53: return GHOSTTY_KEY_DELETE;
    case 0x5B: return GHOSTTY_KEY_META_LEFT;
    case 0x5C: return GHOSTTY_KEY_META_RIGHT;
    case 0x5D: return GHOSTTY_KEY_CONTEXT_MENU;
    case 0x5E: return GHOSTTY_KEY_POWER;
    default:   return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

ghostty_input_key_e winkeys_scancode_to_key(UINT scancode, bool extended) {
    if (extended) return extendedKey(scancode);
    if (scancode < 0x80) return k_scancode[scancode];
    return GHOSTTY_KEY_UNIDENTIFIED;
}

ghostty_input_mods_e winkeys_mods(void) {
    int mods = GHOSTTY_MODS_NONE;
    // High bit set means down; low bit means toggled, which is what we want
    // for the lock keys and not for the others.
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
// ToUnicode is used rather than waiting for WM_CHAR so that the text arrives
// with the key event ghostty is given, instead of as a separate message that
// would have to be correlated back to it.
//
// The 1<<2 flag is important: it tells ToUnicode not to modify the kernel-side
// keyboard state. Without it, probing a dead key here consumes it, and the
// following key would lose its accent.
static int keyText(UINT vk, UINT scancode, const BYTE *kbd, char *out, int out_len) {
    WCHAR wbuf[8] = {0};
    const int n = ToUnicode(vk, scancode, kbd, wbuf, 8, 1 << 2);
    if (n <= 0) return 0;  // 0 = no translation, <0 = dead key
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, wbuf, n, out, out_len - 1, NULL, NULL);
    if (bytes <= 0) return 0;
    out[bytes] = '\0';
    return bytes;
}

bool winkeys_translate(UINT msg, WPARAM wparam, LPARAM lparam,
                       ghostty_input_key_s *out, char text_buf[8]) {
    const bool down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
    const UINT vk = (UINT)wparam;
    const UINT scancode = (UINT)((lparam >> 16) & 0xFF);
    const bool extended = ((lparam >> 24) & 1) != 0;
    const bool was_down = ((lparam >> 30) & 1) != 0;

    memset(out, 0, sizeof(*out));
    text_buf[0] = '\0';

    out->action = !down          ? GHOSTTY_ACTION_RELEASE
                  : was_down     ? GHOSTTY_ACTION_REPEAT
                                 : GHOSTTY_ACTION_PRESS;
    out->mods = winkeys_mods();
    out->keycode = (uint32_t)winkeys_scancode_to_key(scancode, extended);
    out->composing = false;

    if (down) {
        BYTE kbd[256];
        if (GetKeyboardState(kbd)) {
            // Text for the key as actually modified.
            keyText(vk, scancode, kbd, text_buf, 8);
            out->text = text_buf[0] ? text_buf : NULL;

            // The unshifted codepoint is what key bindings match against, so
            // it has to ignore Shift and the lock keys - otherwise ctrl+shift+c
            // would not match a binding written against `c`.
            BYTE plain[256];
            memcpy(plain, kbd, sizeof(plain));
            plain[VK_SHIFT] = plain[VK_LSHIFT] = plain[VK_RSHIFT] = 0;
            plain[VK_CONTROL] = plain[VK_LCONTROL] = plain[VK_RCONTROL] = 0;
            plain[VK_MENU] = plain[VK_LMENU] = plain[VK_RMENU] = 0;
            plain[VK_CAPITAL] = 0;
            char unshifted[8] = {0};
            if (keyText(vk, scancode, plain, unshifted, 8) > 0) {
                out->unshifted_codepoint = (uint32_t)(unsigned char)unshifted[0];
                // Only meaningful for ASCII; a multi-byte result is left at 0
                // rather than reported as a mangled codepoint.
                if ((unsigned char)unshifted[0] >= 0x80) out->unshifted_codepoint = 0;
            }
        }
    }

    // A key we cannot name and which produced no text carries no information.
    return out->keycode != GHOSTTY_KEY_UNIDENTIFIED || text_buf[0] != '\0';
}
