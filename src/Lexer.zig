const std = @import("std");

const Token = @import("Token.zig");

pub const Error = error{
    UnexpectedEOF,
    UnexpectedNewline,
    InvalidChar,
    MalformedNumber,
};

source: []const u8,
current_char_idx: usize,

inline fn mkToken(kind: Token.Kind, start: usize) Token {
    const start32: u32 = @intCast(start);

    return .{
        .kind = kind,
        .span = .{
            .start = start32,
            .end = start32 + 1,
        },
    };
}

inline fn mkTokenLen(kind: Token.Kind, start: usize, len: usize) Token {
    const start32: u32 = @intCast(start);
    const len32: u32 = @intCast(len);

    return .{
        .kind = kind,
        .span = .{
            .start = start32,
            .end = start32 + len32,
        },
    };
}

inline fn mkTokenEnd(kind: Token.Kind, start: usize, end: usize) Token {
    return .{
        .kind = kind,
        .span = .{
            .start = @intCast(start),
            .end = @intCast(end),
        },
    };
}

// `start` points at either single or double quote
fn lexString(lexer: *const @This(), start: usize) Error!Token {
    const quote: u8 = lexer.source[start];
    var curr = start + 1;

    while (curr < lexer.source.len) : (curr += 1) {
        const c = lexer.source[curr];

        switch (c) {
            '\\' => curr += 1, // skip escaped character
            '\n', '\r' => return error.UnexpectedNewline,
            else => if (c == quote) return mkTokenEnd(.str, start, curr + 1),
        }
    }

    return error.UnexpectedEOF;
}

// `start` points at A..Z | a..z | _
fn lexIdent(lexer: *const @This(), start: usize) Token {
    var end = start + 1;

    while (true) : (end += 1) {
        if (end >= lexer.source.len) break;
        switch (lexer.source[end]) {
            '0'...'9', 'A'...'Z', 'a'...'z', '_' => {},
            else => break,
        }
    }

    const ident = lexer.source[start..end];

    // smallest keyword is 2 chars
    if (ident.len < 2) return mkTokenLen(.ident, start, ident.len);

    switch (ident[0]) {
        'a' => if (std.mem.eql(u8, ident, "and")) return mkTokenLen(.@"and", start, ident.len),
        'b' => if (std.mem.eql(u8, ident, "break")) return mkTokenLen(.@"break", start, ident.len),
        'd' => if (std.mem.eql(u8, ident, "do")) return mkTokenLen(.do, start, ident.len),
        'e' => if (std.mem.eql(u8, ident, "else")) {
            return mkTokenLen(.@"else", start, ident.len);
        } else if (std.mem.eql(u8, ident, "elseif")) {
            return mkTokenLen(.elseif, start, ident.len);
        } else if (std.mem.eql(u8, ident, "end")) {
            return mkTokenLen(.end, start, ident.len);
        },
        'f' => if (std.mem.eql(u8, ident, "false")) {
            return mkTokenLen(.false, start, ident.len);
        } else if (std.mem.eql(u8, ident, "for")) {
            return mkTokenLen(.@"for", start, ident.len);
        } else if (std.mem.eql(u8, ident, "function")) {
            return mkTokenLen(.function, start, ident.len);
        },
        'g' => if (std.mem.eql(u8, ident, "goto")) return mkTokenLen(.goto, start, ident.len),
        'i' => if (std.mem.eql(u8, ident, "if")) {
            return mkTokenLen(.@"if", start, ident.len);
        } else if (std.mem.eql(u8, ident, "in")) {
            return mkTokenLen(.in, start, ident.len);
        },
        'l' => if (std.mem.eql(u8, ident, "local")) return mkTokenLen(.local, start, ident.len),
        'n' => if (std.mem.eql(u8, ident, "nil")) {
            return mkTokenLen(.nil, start, ident.len);
        } else if (std.mem.eql(u8, ident, "not")) {
            return mkTokenLen(.not, start, ident.len);
        },
        'o' => if (std.mem.eql(u8, ident, "or")) return mkTokenLen(.@"or", start, ident.len),
        'r' => if (std.mem.eql(u8, ident, "repeat")) {
            return mkTokenLen(.repeat, start, ident.len);
        } else if (std.mem.eql(u8, ident, "return")) {
            return mkTokenLen(.@"return", start, ident.len);
        },
        't' => if (std.mem.eql(u8, ident, "then")) {
            return mkTokenLen(.then, start, ident.len);
        } else if (std.mem.eql(u8, ident, "true")) {
            return mkTokenLen(.true, start, ident.len);
        },
        'u' => if (std.mem.eql(u8, ident, "until")) return mkTokenLen(.until, start, ident.len),
        'w' => if (std.mem.eql(u8, ident, "while")) return mkTokenLen(.@"while", start, ident.len),
        else => {},
    }

    return mkTokenLen(.ident, start, ident.len);
}

inline fn isDigit(c: u8) bool {
    return (c >= '0') and (c <= '9');
}

inline fn isHexDigit(c: u8) bool {
    return isDigit(c) or ((c >= 'a') and (c <= 'f')) or ((c >= 'A') and (c <= 'F'));
}

// same set as `lexIdent`'s first character
inline fn isAlpha(c: u8) bool {
    return ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or (c == '_');
}

inline fn isNumeralDigit(c: u8, hex: bool) bool {
    return if (hex) isHexDigit(c) else isDigit(c);
}

// hex numerals are marked with `p`/`P`, decimal ones with `e`/`E`
inline fn isExponentMark(c: u8, hex: bool) bool {
    return if (hex) (c == 'p') or (c == 'P') else (c == 'e') or (c == 'E');
}

// index of the first character at or after `i` that is not a numeral digit
fn digitRunEnd(source: []const u8, i: usize, hex: bool) usize {
    var end = i;

    while (end < source.len and isNumeralDigit(source[end], hex)) : (end += 1) {}

    return end;
}

// `start` points at a digit, or at `.` immediately followed by a digit.
//
// Handles Lua's numeral grammar:
//
//     digits ('.' digits?)? exponent?
//   | '.' digits exponent?
//   | '0' ('x' | 'X') hexdigits ('.' hexdigits?)? hexexponent?
//
// An exponent sign is only accepted directly after an exponent mark, so `1e-5`
// is a single numeral while `1-5` is a subtraction. The literal must hold at
// least one digit, and may not touch a `.` or a letter, which is what makes
// `0x`, `1e`, `3a` and `1..2` malformed.
fn lexNumber(lexer: *const @This(), start: usize) Error!Token {
    const source = lexer.source;

    var curr = start;
    var is_float = false;
    var hex = false;

    if (source[curr] == '.') {
        // `.5`, the caller already confirmed a digit follows the dot
        is_float = true;
        curr += 1;
    } else if ((source[curr] == '0') and (curr + 1 < source.len) and
        ((source[curr + 1] == 'x') or (source[curr + 1] == 'X')))
    {
        hex = true;
        curr += 2; // `0x`
    }

    const int_end = digitRunEnd(source, curr, hex);
    const int_digits = int_end - curr;
    curr = int_end;

    var digits = int_digits;

    // optional fractional part, the digits after the dot are optional
    if ((curr < source.len) and (source[curr] == '.')) {
        is_float = true;
        curr += 1;

        const frac_end = digitRunEnd(source, curr, hex);
        digits += frac_end - curr;
        curr = frac_end;
    }

    // optional exponent
    if ((curr < source.len) and isExponentMark(source[curr], hex)) {
        is_float = true;
        curr += 1;

        if ((curr < source.len) and ((source[curr] == '+') or (source[curr] == '-'))) {
            curr += 1;
        }

        const exp_end = digitRunEnd(source, curr, hex);
        if (exp_end == curr) return error.MalformedNumber;
        curr = exp_end;
    }

    // a second dot is never part of a numeral, so `1..2` is malformed
    if ((curr < source.len) and (source[curr] == '.')) return error.MalformedNumber;
    // a numeral touching a letter is malformed, e.g. `3a`
    if ((curr < source.len) and isAlpha(source[curr])) return error.MalformedNumber;
    // rejects `0x` and `0x.`
    if (digits == 0) return error.MalformedNumber;

    return mkTokenEnd(if (is_float) .float else .decimal, start, curr);
}

// tries to lex a long string/comment, if no start pattern found returns null
pub fn lexLong(lexer: *const @This(), start: usize) Error!?Token.Span {
    if (start + 1 >= lexer.source.len) return null;
    if (lexer.source[start] != '[') return null;

    const next_char = lexer.source[start + 1];

    switch (next_char) {
        '=' => {
            var eql_count: usize = 0;
            var open = start + 1;

            while (open < lexer.source.len and lexer.source[open] == '=') : (open += 1) {
                eql_count += 1;
            }

            if (open >= lexer.source.len or lexer.source[open] != '[') return null;

            // long start pattern confirmed

            var scan = open + 1;

            while (true) {
                // closing run is ']' followed by eql_count '=' followed by ']'
                if (scan + eql_count + 2 > lexer.source.len) return error.UnexpectedEOF;

                if (lexer.source[scan] == ']' and
                    std.mem.allEqual(u8, lexer.source[scan + 1 .. scan + eql_count + 1], '=') and
                    lexer.source[scan + eql_count + 1] == ']')
                {
                    return .{
                        .start = @intCast(start),
                        .end = @intCast(scan + eql_count + 2),
                    };
                }

                scan += 1;
            }
        },
        '[' => {
            if (std.mem.find(u8, lexer.source[(start + 2)..], "]]")) |idx| {
                const end = start + 2 + idx + 2;
                return .{
                    .start = @intCast(start),
                    .end = @intCast(end),
                };
            } else return error.UnexpectedEOF;
        },
        else => return null,
    }
}

pub fn peekToken(lexer: *const @This()) Error!Token {
    var start = lexer.current_char_idx;

    while (start < lexer.source.len) {
        const char = lexer.source[start];

        const token: Token = switch (char) {
            // control characters / non-ascii
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0xFF, '!', '$', '?', '@', '\\', '`' => return error.InvalidChar,
            // TAB, LF, CR, space (whitespace)
            0x09, 0x0A, 0x0D, 0x20 => {
                start += 1;
                continue;
            },
            // 0x22, 0x27
            '"', '\'' => try lexer.lexString(start),
            // 0x23
            '#' => mkToken(.hash, start),
            // 0x25
            '%' => mkToken(.percent, start),
            // 0x26
            '&' => mkToken(.amp, start),
            // 0x28
            '(' => mkToken(.lparen, start),
            // 0x29
            ')' => mkToken(.rparen, start),
            // 0x2A
            '*' => mkToken(.star, start),
            // 0x2B
            '+' => mkToken(.plus, start),
            // 0x2C
            ',' => mkToken(.comma, start),
            // 0x2D
            '-' => if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != '-'))
                // "-"
                mkToken(.minus, start)
            else if (try lexLong(lexer, start + 2)) |span| {
                start = span.end;
                continue;
            } else if (std.mem.findAny(u8, lexer.source[(start + 2)..], "\n\r")) |idx| {
                // "--" comment, up to but excluding the newline
                start = (start + 2) + idx + 1;
                continue;
            } else {
                // "--" comment running to the end of the source
                start = lexer.source.len;
                continue;
            },
            // 0x2E
            '.' => if (((start + 1) < lexer.source.len) and isDigit(lexer.source[start + 1]))
                // ".5", a leading dot numeral; `..` and `...` can never be
                // one since a digit is never a dot
                try lexer.lexNumber(start)
            else if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != '.'))
                // "."
                mkToken(.dot, start)
            else if (((start + 2) >= lexer.source.len) or (lexer.source[start + 2] != '.'))
                // ".."
                mkTokenLen(.dot2, start, 2)
            else
                // "..."
                mkTokenLen(.dot3, start, 3),
            // 0x2F
            '/' => if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != '/'))
                // "/"
                mkToken(.slash, start)
            else
                // "//"
                mkTokenLen(.slash2, start, 2),
            // 0x30 ... 0x39
            '0'...'9' => try lexer.lexNumber(start),
            // 0x3A
            ':' => if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != ':'))
                // ":"
                mkToken(.colon, start)
            else
                // "::"
                mkTokenLen(.colon2, start, 2),
            // 0x3B
            ';' => mkToken(.semicolon, start),
            // 0x3C
            '<' => if (((start + 1) >= lexer.source.len) or
                ((lexer.source[start + 1] != '=') and
                    (lexer.source[start + 1] != '<')))
                // "<"
                mkToken(.langle, start)
            else if (lexer.source[start + 1] == '=')
                // "<="
                mkTokenLen(.lte, start, 2)
            else
                // "<<"
                mkTokenLen(.shift_left, start, 2),
            // 0x3D
            '=' => if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != '='))
                // "="
                mkToken(.eq, start)
            else
                // "=="
                mkTokenLen(.eq2, start, 2),
            // 0x3E
            '>' => if (((start + 1) >= lexer.source.len) or
                ((lexer.source[start + 1] != '=') and
                    (lexer.source[start + 1] != '>')))
                // ">"
                mkToken(.rangle, start)
            else if (lexer.source[start + 1] == '=')
                // ">="
                mkTokenLen(.gte, start, 2)
            else
                // ">>"
                mkTokenLen(.shift_right, start, 2),
            // 0x41 ... 0x5A
            'A'...'Z', '_', 'a'...'z' => lexer.lexIdent(start),
            // 0x5B
            '[' => if (try lexLong(lexer, start)) |span|
                // "[[...]]" or "[==[...]==]"
                mkTokenEnd(.long_str, span.start, span.end)
            else
                // "["
                mkToken(.lbrack, start),
            // 0x5D
            ']' => mkToken(.rbrack, start),
            // 0x5E
            '^' => mkToken(.caret, start),
            // 0x7B
            '{' => mkToken(.lcurly, start),
            // 0x7C
            '|' => mkToken(.pipe, start),
            // 0x7D
            '}' => mkToken(.rcurly, start),
            // 0x7E
            '~' => if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != '='))
                // "~"
                mkToken(.tilde, start)
            else
                // "~="
                mkTokenLen(.tilde_eq, start, 2),
        };

        return token;
    }

    return mkTokenLen(.eof, start, 0);
}
