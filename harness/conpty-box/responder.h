// A terminal, as far as ConPTY is concerned.
//
// The box needs this to be faithful at all. ConPTY does not merely write at a
// terminal - it *asks it questions* and changes what it emits based on the
// answers. At our pin it waits for a DA1 reply before it starts (the upstream
// "ConPTY: Do not wait for DA1 on startup" landed after it), and it issues a
// cursor-position request on every sequence it does not recognise. A reader
// that answers nothing puts it in a regime no real pane is ever in, which is
// the most likely reason a payload known to corrupt in a pane replayed sixty
// times here without a mark.
//
// So this answers the way a terminal does, and tracks the cursor well enough to
// answer the one question whose *value* matters: where the cursor is. The DA1
// string is the one Windows Terminal itself returns (adaptDispatch.cpp).
//
// It is deliberately small: enough VT to follow the cursor, not a screen model.

#pragma once

#include <string>

namespace conptybox
{
    class Responder
    {
    public:
        Responder(int cols, int rows) :
            _cols{ cols }, _rows{ rows } {}

        // Feed everything ConPTY emitted; returns the bytes to write back into
        // the pty's input, which may be empty.
        std::string Consume(const std::string& chunk)
        {
            std::string reply;
            for (size_t i = 0; i < chunk.size(); i++)
            {
                const auto c = (unsigned char)chunk[i];

                if (_inEscape)
                {
                    _escape.push_back((char)c);
                    // A CSI ends on a final byte in 0x40..0x7E; an OSC on BEL or
                    // ST. Two-byte escapes end immediately.
                    if (_escape.size() == 1)
                    {
                        if (c != '[' && c != ']')
                        {
                            _inEscape = false;
                            _escape.clear();
                        }
                        continue;
                    }
                    if (_escape[0] == '[')
                    {
                        if (c >= 0x40 && c <= 0x7E)
                        {
                            Dispatch(_escape, reply);
                            _inEscape = false;
                            _escape.clear();
                        }
                    }
                    else // OSC
                    {
                        if (c == 0x07 || (c == '\\' && _escape.size() >= 2 && (unsigned char)_escape[_escape.size() - 2] == 0x1B))
                        {
                            _inEscape = false;
                            _escape.clear();
                        }
                    }
                    continue;
                }

                if (c == 0x1B)
                {
                    _inEscape = true;
                    _escape.clear();
                    continue;
                }

                // Cursor tracking for plain text. UTF-8 continuation bytes are
                // part of the character that already advanced it.
                if (c == '\r') { _col = 1; }
                else if (c == '\n') { _row = (std::min)(_rows, _row + 1); }
                else if (c == '\b') { _col = (std::max)(1, _col - 1); }
                else if (c >= 0x20 && (c < 0x80 || c >= 0xC0))
                {
                    if (_col < _cols) { _col++; }
                }
            }
            return reply;
        }

        int Row() const noexcept { return _row; }
        int Col() const noexcept { return _col; }

    private:
        static int Param(const std::string& body, const size_t which, const int fallback)
        {
            // body is the CSI without ESC[: parameters, then the final byte.
            size_t start = 0;
            if (!body.empty() && (body[0] == '?' || body[0] == '>' || body[0] == '=')) { start = 1; }
            size_t index = 0;
            int value = -1;
            for (size_t i = start; i < body.size(); i++)
            {
                const auto ch = body[i];
                if (ch >= '0' && ch <= '9')
                {
                    value = (value < 0 ? 0 : value) * 10 + (ch - '0');
                    continue;
                }
                if (ch == ';')
                {
                    if (index == which) { return value < 0 ? fallback : value; }
                    index++;
                    value = -1;
                    continue;
                }
                break; // the final byte
            }
            return index == which && value >= 0 ? value : fallback;
        }

        void Dispatch(const std::string& seq, std::string& reply)
        {
            const auto body = seq.substr(1);          // drop the '['
            if (body.empty()) { return; }
            const auto fin = body.back();
            const auto priv = body[0];

            switch (fin)
            {
            case 'H':
            case 'f':
                _row = (std::max)(1, (std::min)(_rows, Param(body, 0, 1)));
                _col = (std::max)(1, (std::min)(_cols, Param(body, 1, 1)));
                break;
            case 'G':
                _col = (std::max)(1, (std::min)(_cols, Param(body, 0, 1)));
                break;
            case 'd':
                _row = (std::max)(1, (std::min)(_rows, Param(body, 0, 1)));
                break;
            case 'A': _row = (std::max)(1, _row - Param(body, 0, 1)); break;
            case 'B': _row = (std::min)(_rows, _row + Param(body, 0, 1)); break;
            case 'C': _col = (std::min)(_cols, _col + Param(body, 0, 1)); break;
            case 'D': _col = (std::max)(1, _col - Param(body, 0, 1)); break;
            case 'c':
                // Device attributes. Exactly what Windows Terminal answers, so
                // ConPTY takes the same path it takes against a real pane.
                if (priv == '>') { reply += "\x1b[>0;10;1c"; }
                else { reply += "\x1b[?61;4;6;7;14;21;22;23;24;28;32;42c"; }
                break;
            case 'n':
                if (priv == '?')
                {
                    // DECDSR: extended cursor report.
                    if (Param(body, 0, 0) == 6)
                    {
                        reply += "\x1b[?" + std::to_string(_row) + ";" + std::to_string(_col) + ";1R";
                    }
                }
                else
                {
                    const auto what = Param(body, 0, 0);
                    if (what == 6)
                    {
                        // The answer whose *value* matters: ConPTY uses it to
                        // decide where it thinks the cursor is.
                        reply += "\x1b[" + std::to_string(_row) + ";" + std::to_string(_col) + "R";
                    }
                    else if (what == 5)
                    {
                        reply += "\x1b[0n";
                    }
                }
                break;
            case 'p':
                // DECRQM: report every mode as "not recognised", which is what a
                // terminal says for a mode it does not implement.
                if (body.size() >= 2 && body[body.size() - 2] == '$' && priv == '?')
                {
                    reply += "\x1b[?" + std::to_string(Param(body, 0, 0)) + ";0$y";
                }
                break;
            default:
                break;
            }
        }

        int _cols;
        int _rows;
        int _row{ 1 };
        int _col{ 1 };
        bool _inEscape{ false };
        std::string _escape;
    };
}
