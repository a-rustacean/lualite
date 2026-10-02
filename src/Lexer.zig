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

/// Span of the input that caused the last error, set by `fail`. Only
/// meaningful right after a call returned an `Error`.
err_span: Token.Span = .{ .start = 0, .end = 0 },

/// Records where the failure happened and returns `e` unchanged, so call
/// sites keep using `try` while the offset stays recoverable.
fn fail(self: *@This(), e: Error, start: usize, end: usize) Error {
    self.err_span = .{
        .start = @intCast(start),
        .end = @intCast(end),
    };

    return e;
}

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
fn lexString(lexer: *@This(), start: usize) Error!Token {
    const quote: u8 = lexer.source[start];
    var curr = start + 1;

    while (curr < lexer.source.len) : (curr += 1) {
        const c = lexer.source[curr];

        switch (c) {
            '\\' => curr += 1, // skip escaped character
            '\n', '\r' => return lexer.fail(error.UnexpectedNewline, curr, curr + 1),
            else => if (c == quote) return mkTokenEnd(.str, start, curr + 1),
        }
    }

    return lexer.fail(error.UnexpectedEOF, start, lexer.source.len);
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
fn lexNumber(lexer: *@This(), start: usize) Error!Token {
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
        if (exp_end == curr) return lexer.fail(error.MalformedNumber, start, curr);
        curr = exp_end;
    }

    // a second dot is never part of a numeral, so `1..2` is malformed
    if ((curr < source.len) and (source[curr] == '.')) return lexer.fail(error.MalformedNumber, start, curr);
    // a numeral touching a letter is malformed, e.g. `3a`
    if ((curr < source.len) and isAlpha(source[curr])) return lexer.fail(error.MalformedNumber, start, curr);
    // rejects `0x` and `0x.`
    if (digits == 0) return lexer.fail(error.MalformedNumber, start, curr);

    return mkTokenEnd(if (is_float) .float else .decimal, start, curr);
}

// tries to lex a long string/comment, if no start pattern found returns null
fn lexLong(lexer: *@This(), start: usize) Error!?Token.Span {
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

            var cursor = open + 1;

            while (true) {
                // closing run is ']' followed by eql_count '=' followed by ']'
                if (cursor + eql_count + 2 > lexer.source.len) return lexer.fail(error.UnexpectedEOF, start, lexer.source.len);

                if (lexer.source[cursor] == ']' and
                    std.mem.allEqual(u8, lexer.source[cursor + 1 .. cursor + eql_count + 1], '=') and
                    lexer.source[cursor + eql_count + 1] == ']')
                {
                    return .{
                        .start = @intCast(start),
                        .end = @intCast(cursor + eql_count + 2),
                    };
                }

                cursor += 1;
            }
        },
        '[' => {
            if (std.mem.find(u8, lexer.source[(start + 2)..], "]]")) |idx| {
                const end = start + 2 + idx + 2;
                return .{
                    .start = @intCast(start),
                    .end = @intCast(end),
                };
            } else return lexer.fail(error.UnexpectedEOF, start, lexer.source.len);
        },
        else => return null,
    }
}

/// Lexes the token at `current_char_idx` without consuming it. Whitespace and
/// comments are skipped, so on failure `err_span` points at the offending
/// input rather than at the cursor.
pub fn peekToken(lexer: *@This()) Error!Token {
    return lexer.scan(lexer.current_char_idx);
}

/// Lexes the token at `current_char_idx` and consumes it by moving the cursor
/// to the end of its span. Past the last token this is a no-op, so calling it
/// again just re-yields `.eof`.
pub fn nextToken(lexer: *@This()) Error!Token {
    const token = try lexer.scan(lexer.current_char_idx);
    lexer.current_char_idx = token.span.end;
    return token;
}

fn scan(lexer: *@This(), from: usize) Error!Token {
    var start = from;

    while (start < lexer.source.len) {
        const char = lexer.source[start];

        const token: Token = switch (char) {
            // control characters / non-ascii
            0x00...0x08, 0x0E...0x1F, 0x7F...0xFF, '!', '$', '?', '@', '\\', '`' => return lexer.fail(error.InvalidChar, start, start + 1),
            // TAB, VT, FF, LF, CR, space (whitespace)
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20 => {
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
                // "[". Lua 5.4 raises `invalid long string delimiter` for an
                // `=`-run that never reaches a second `[`, e.g. `[==`; we
                // report the bracket instead and leave that diagnostic to
                // the parser.
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

fn expectToken(source: []const u8, kind: Token.Kind, start: u32, end: u32) !void {
    var lexer = @This(){ .source = source, .current_char_idx = 0 };

    const token = try lexer.peekToken();

    try std.testing.expectEqual(kind, token.kind);
    try std.testing.expectEqual(start, token.span.start);
    try std.testing.expectEqual(end, token.span.end);
}

fn expectErr(source: []const u8, expected: Error) !void {
    var lexer = @This(){ .source = source, .current_char_idx = 0 };

    try std.testing.expectError(expected, lexer.peekToken());
}

test "peekToken smoke" {
    var lexer = @This(){ .source = "local x = \"hi\"", .current_char_idx = 0 };

    const first = try lexer.peekToken();
    try std.testing.expectEqual(Token.Kind.local, first.kind);
    try std.testing.expectEqual(@as(u32, 0), first.span.start);
    try std.testing.expectEqual(@as(u32, 5), first.span.end);
}

test "line comment runs to end of line" {
    // `-- x` is a comment, `y` is the first real token
    try expectToken("-- x\ny", .ident, 5, 6);
    try expectToken("-- x\ry", .ident, 5, 6);
    try expectToken("-- x\n\ny", .ident, 6, 7);
}

test "line comment to eof" {
    try expectToken("--x", .eof, 3, 3);
    try expectToken("-- x", .eof, 4, 4);
}

test "single dash is not a comment" {
    try expectToken("- x", .minus, 0, 1);
    try expectToken("-", .minus, 0, 1);
    try expectToken("--", .eof, 2, 2);
}

test "long comment --[[...]]" {
    try expectToken("--[[abc]] y", .ident, 10, 11);
    try expectToken("--[[]] y", .ident, 7, 8);
    try expectToken("--[[a\nb]] y", .ident, 10, 11);
    try expectToken("--[[a]]b", .ident, 7, 8);
}

test "long comment --[=[...]=]" {
    try expectToken("--[=[abc]=] y", .ident, 12, 13);
    try expectToken("--[=[]=] y", .ident, 9, 10);
}

test "long comment --[==[...]==]" {
    try expectToken("--[==[abc]==] y", .ident, 14, 15);
    try expectToken("--[==[a]==b]==] y", .ident, 16, 17);
}

test "long comment with higher nesting level" {
    // the closer must match the level: `]===]`, not `]==]`
    try expectToken("--[===[a]]==]===] y", .ident, 18, 19);
}

test "long comment span covers the whole bracket" {
    var nested = @This(){ .source = "--[==[abc]==] y", .current_char_idx = 0 };
    const nested_span = (try nested.lexLong(2)).?;
    try std.testing.expectEqual(@as(u32, 2), nested_span.start);
    try std.testing.expectEqual(@as(u32, 13), nested_span.end);

    var flat = @This(){ .source = "--[[abc]] y", .current_char_idx = 0 };
    const flat_span = (try flat.lexLong(2)).?;
    try std.testing.expectEqual(@as(u32, 2), flat_span.start);
    try std.testing.expectEqual(@as(u32, 9), flat_span.end);
}

test "lexLong returns null without a long bracket start" {
    var plain = @This(){ .source = "--[abc", .current_char_idx = 0 };
    try std.testing.expect((try plain.lexLong(2)) == null);

    // `==` run that never reaches a `[`
    var dangling = @This(){ .source = "--[==abc", .current_char_idx = 0 };
    try std.testing.expect((try dangling.lexLong(2)) == null);

    // not a bracket at all
    var not_bracket = @This(){ .source = "--x", .current_char_idx = 0 };
    try std.testing.expect((try not_bracket.lexLong(2)) == null);

    // past the end of the source
    var past_end = @This(){ .source = "--", .current_char_idx = 0 };
    try std.testing.expect((try past_end.lexLong(2)) == null);
}

test "unterminated long comment is UnexpectedEOF" {
    try expectErr("--[[abc", error.UnexpectedEOF);
    try expectErr("--[[", error.UnexpectedEOF);
    try expectErr("--[=[abc", error.UnexpectedEOF);
    try expectErr("--[==[abc", error.UnexpectedEOF);
    // closer present but at the wrong nesting level
    try expectErr("--[===[abc]==]", error.UnexpectedEOF);
}

test "bracket that is not long is a line comment" {
    // `[a` is not a long bracket, so the whole line is commented out
    try expectToken("--[abc] y", .eof, 9, 9);
    try expectToken("--]==] y", .eof, 8, 8);
    // ...up to the newline
    try expectToken("--[abc\ny", .ident, 7, 8);
}

test "lone opening bracket still lexes" {
    try expectToken("[", .lbrack, 0, 1);
    try expectToken("[ ", .lbrack, 0, 1);
}

test "long string [[...]]" {
    try expectToken("[[abc]]", .long_str, 0, 7);
    try expectToken("[[]]", .long_str, 0, 4);
    // a lone `]` is content, only `]]` closes
    try expectToken("[[a]b]]", .long_str, 0, 7);
    // newlines are content, so long strings can span lines
    try expectToken("[[a\nb]]", .long_str, 0, 7);
    // no escape processing, the backslash is just a byte
    try expectToken("[[a\\nb]]", .long_str, 0, 8);
}

test "long string closes at the first `]]`" {
    // everything past the literal is separate code
    try expectToken("[[a]]b]]", .long_str, 0, 5);

    // peekToken only ever returns the first token, so point a lexer past
    // the literal to check what follows it
    var trailing = @This(){ .source = "[[a]]b]] y", .current_char_idx = 9 };
    const after = try trailing.peekToken();
    try std.testing.expectEqual(Token.Kind.ident, after.kind);
    try std.testing.expectEqual(@as(u32, 9), after.span.start);
    try std.testing.expectEqual(@as(u32, 10), after.span.end);
}

test "long string [==[...]==]" {
    try expectToken("[==[abc]==]", .long_str, 0, 11);
    try expectToken("[=[abc]=]", .long_str, 0, 9);
    try expectToken("[=[]=]", .long_str, 0, 6);
    try expectToken("[==[]==]", .long_str, 0, 8);
    // brackets of a different level are ordinary content
    try expectToken("[==[[a]]]==]", .long_str, 0, 12);
}

test "long string with higher nesting level" {
    // the closer must match the level: `]===]`, not `]==]`
    try expectToken("[===[a]]==]===]", .long_str, 0, 15);
    // same for level 2: `]==b]==]` is content, `]==]` closes
    try expectToken("[==[a]==b]==]", .long_str, 0, 13);
}

test "unterminated long string is UnexpectedEOF" {
    try expectErr("[[abc", error.UnexpectedEOF);
    try expectErr("[[", error.UnexpectedEOF);
    try expectErr("[=[abc", error.UnexpectedEOF);
    try expectErr("[==[abc", error.UnexpectedEOF);
    // closer present but at the wrong nesting level
    try expectErr("[===[abc]==]", error.UnexpectedEOF);
}

test "bracket that does not open a long string is lbrack" {
    // nothing follows the bracket
    try expectToken("[ ", .lbrack, 0, 1);
    // indexing and table literals still lex
    try expectToken("[1]", .lbrack, 0, 1);
    try expectToken("[a[b]]", .lbrack, 0, 1);
    try expectToken("[]]", .lbrack, 0, 1);
    // an `=` run that never reaches a `[`
    try expectToken("[==]", .lbrack, 0, 1);
    try expectToken("[==", .lbrack, 0, 1);
}

test "integer numerals" {
    try expectToken("42", .decimal, 0, 2);
    try expectToken("0", .decimal, 0, 1);
    // leading zeros are decimal, not octal
    try expectToken("007", .decimal, 0, 3);
    try expectToken("  12  ", .decimal, 2, 4);
    // a sign is never part of a numeral
    try expectToken("1+x", .decimal, 0, 1);
    try expectToken("1-x", .decimal, 0, 1);
    try expectToken("1--c\nx", .decimal, 0, 1);
}

test "fractional numerals" {
    try expectToken("4.2", .float, 0, 3);
    try expectToken("0.5", .float, 0, 3);
    // trailing dot with no digits is still a float
    try expectToken("1.", .float, 0, 2);
    try expectToken("1.5+x", .float, 0, 3);
}

test "leading dot numerals" {
    try expectToken(".5", .float, 0, 2);
    try expectToken(".5+x", .float, 0, 2);
    try expectToken(".5e2", .float, 0, 4);
}

test "dot that does not start a numeral" {
    // a dot is only part of a numeral when a digit follows it
    try expectToken(".", .dot, 0, 1);
    try expectToken(".a", .dot, 0, 1);
    try expectToken("..", .dot2, 0, 2);
    try expectToken("...", .dot3, 0, 3);
    try expectToken("..5", .dot2, 0, 2);
}

test "exponent numerals" {
    try expectToken("1e10", .float, 0, 4);
    try expectToken("1E10", .float, 0, 4);
    try expectToken("1e+10", .float, 0, 5);
    try expectToken("1e-5", .float, 0, 4);
    try expectToken("1.5e-3", .float, 0, 6);
    try expectToken(".5E+1", .float, 0, 5);
}

test "hex numerals" {
    try expectToken("0xff", .decimal, 0, 4);
    try expectToken("0XFF", .decimal, 0, 4);
    // `E` is a hex digit here, not an exponent mark
    try expectToken("0xE", .decimal, 0, 3);
    try expectToken("0x1.8", .float, 0, 5);
    try expectToken("0x1p4", .float, 0, 5);
    try expectToken("0x1P-4", .float, 0, 6);
    try expectToken("0x.1p1", .float, 0, 6);
    // the `+` ends the numeral, only `p` may be followed by a sign
    try expectToken("0xe+1", .decimal, 0, 3);
    // `e` is a hex digit, not an exponent mark, so it stays in the literal
    try expectToken("0x1.5e2", .float, 0, 7);
}

test "malformed numbers" {
    // numeral touching a letter
    try expectErr("3a", error.MalformedNumber);
    try expectErr("1_", error.MalformedNumber);
    try expectErr("0xg", error.MalformedNumber);
    // `..` is concatenation, not part of the numeral
    try expectErr("1..2", error.MalformedNumber);
    // no digits after the prefix or the exponent mark
    try expectErr("0x", error.MalformedNumber);
    try expectErr("0x.", error.MalformedNumber);
    try expectErr("1e", error.MalformedNumber);
    try expectErr("1e+", error.MalformedNumber);
    try expectErr("1p4", error.MalformedNumber);
    // only one exponent mark is allowed
    try expectErr("1e5e5", error.MalformedNumber);
}

test "vertical tab and form feed are whitespace" {
    // Lua's llex lists `\f` and `\v` as spaces alongside TAB, LF and CR
    try expectToken("a\x0Bb", .ident, 0, 1);
    try expectToken("a\x0Cb", .ident, 0, 1);
    try expectToken("\x0Bb", .ident, 1, 2);
    try expectToken("\x0Cb", .ident, 1, 2);
    // a run of them is skipped like any other whitespace
    try expectToken("\x0B\x0Cx", .ident, 2, 3);
    try expectToken("\x0C\x0Bx", .ident, 2, 3);
}

test "nextToken consumes the token" {
    var lexer = @This(){ .source = "local x = \"hi\"", .current_char_idx = 0 };

    const local = try lexer.nextToken();
    try std.testing.expectEqual(Token.Kind.local, local.kind);
    try std.testing.expectEqual(@as(usize, 5), lexer.current_char_idx);

    const x = try lexer.nextToken();
    try std.testing.expectEqual(Token.Kind.ident, x.kind);
    try std.testing.expectEqual(@as(u32, 6), x.span.start);
    try std.testing.expectEqual(@as(u32, 7), x.span.end);
    try std.testing.expectEqual(@as(usize, 7), lexer.current_char_idx);

    try std.testing.expectEqual(Token.Kind.eq, (try lexer.nextToken()).kind);

    const str = try lexer.nextToken();
    try std.testing.expectEqual(Token.Kind.str, str.kind);
    try std.testing.expectEqual(@as(u32, 10), str.span.start);
    try std.testing.expectEqual(@as(u32, 14), str.span.end);
    try std.testing.expectEqual(@as(usize, 14), lexer.current_char_idx);

    try std.testing.expectEqual(Token.Kind.eof, (try lexer.nextToken()).kind);
}

test "nextToken skips whitespace and comments" {
    var lexer = @This(){ .source = "  -- c\n  x", .current_char_idx = 0 };

    const x = try lexer.nextToken();
    try std.testing.expectEqual(Token.Kind.ident, x.kind);
    try std.testing.expectEqual(@as(u32, 9), x.span.start);
    try std.testing.expectEqual(@as(u32, 10), x.span.end);
}

test "nextToken repeats eof without moving" {
    var lexer = @This(){ .source = "x", .current_char_idx = 0 };
    _ = try lexer.nextToken();
    try std.testing.expectEqual(@as(usize, 1), lexer.current_char_idx);

    const first = try lexer.nextToken();
    const second = try lexer.nextToken();

    try std.testing.expectEqual(Token.Kind.eof, first.kind);
    try std.testing.expectEqual(first.kind, second.kind);
    try std.testing.expectEqual(first.span.start, second.span.start);
    try std.testing.expectEqual(@as(usize, 1), lexer.current_char_idx);
}

test "nextToken from mid source" {
    var lexer = @This(){ .source = "[[a]]b]] y", .current_char_idx = 9 };

    const y = try lexer.nextToken();
    try std.testing.expectEqual(Token.Kind.ident, y.kind);
    try std.testing.expectEqual(@as(u32, 9), y.span.start);
    try std.testing.expectEqual(@as(u32, 10), y.span.end);
    try std.testing.expectEqual(@as(usize, 10), lexer.current_char_idx);
}

test "nextToken leaves the cursor put on error" {
    var lexer = @This(){ .source = "x $", .current_char_idx = 0 };
    _ = try lexer.nextToken();
    try std.testing.expectEqual(@as(usize, 1), lexer.current_char_idx);

    try std.testing.expectError(error.InvalidChar, lexer.nextToken());
    // the offending `$` is still there to be retried or reported on
    try std.testing.expectEqual(@as(usize, 1), lexer.current_char_idx);
}

test "err_span points at the failure" {
    // an unterminated string spans the opening quote to the end
    var str = @This(){ .source = "\"abc", .current_char_idx = 0 };
    try std.testing.expectError(error.UnexpectedEOF, str.peekToken());
    try std.testing.expectEqual(@as(u32, 0), str.err_span.start);
    try std.testing.expectEqual(@as(u32, 4), str.err_span.end);

    // the newline that ended the string, not the whole token
    var newline = @This(){ .source = "\"a\nb\"", .current_char_idx = 0 };
    try std.testing.expectError(error.UnexpectedNewline, newline.peekToken());
    try std.testing.expectEqual(@as(u32, 2), newline.err_span.start);
    try std.testing.expectEqual(@as(u32, 3), newline.err_span.end);

    // the numeral scanned so far
    var numeral = @This(){ .source = "0x", .current_char_idx = 0 };
    try std.testing.expectError(error.MalformedNumber, numeral.peekToken());
    try std.testing.expectEqual(@as(u32, 0), numeral.err_span.start);
    try std.testing.expectEqual(@as(u32, 2), numeral.err_span.end);

    // the unterminated long bracket, from `[` to the end
    var long = @This(){ .source = "--[=[abc", .current_char_idx = 0 };
    try std.testing.expectError(error.UnexpectedEOF, long.peekToken());
    try std.testing.expectEqual(@as(u32, 2), long.err_span.start);
    try std.testing.expectEqual(@as(u32, 8), long.err_span.end);
}

test "invalid characters" {
    // control characters, LF and CR excepted
    try expectErr("\x00", error.InvalidChar);
    try expectErr("\x01x", error.InvalidChar);
    try expectErr("\x08", error.InvalidChar);
    try expectErr("\x0E", error.InvalidChar);
    try expectErr("\x1F", error.InvalidChar);
    try expectErr("\x7F", error.InvalidChar);
    // non-ascii
    try expectErr("\x80", error.InvalidChar);
    try expectErr("\xFF", error.InvalidChar);
    // printable ascii that starts no Lua token
    try expectErr("!", error.InvalidChar);
    try expectErr("$", error.InvalidChar);
    try expectErr("?", error.InvalidChar);
    try expectErr("@", error.InvalidChar);
    try expectErr("\\", error.InvalidChar);
    try expectErr("`", error.InvalidChar);
    // the span is the single offending byte
    var lexer = @This(){ .source = "x $", .current_char_idx = 2 };
    try std.testing.expectError(error.InvalidChar, lexer.peekToken());
    try std.testing.expectEqual(@as(u32, 2), lexer.err_span.start);
    try std.testing.expectEqual(@as(u32, 3), lexer.err_span.end);
}
