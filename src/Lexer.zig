const std = @import("std");
const Allocator = std.mem.Allocator;

const Token = @import("Token.zig");

gpa: Allocator,
source: []const u8,
current_char_idx: usize,
token: Token = .{
    .kind = .eof,
    .span = .{
        .start = 0,
        .end = 0,
    },
},

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

inline fn mkToken2(kind: Token.Kind, start: usize, len: usize) Token {
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

inline fn mkToken3(kind: Token.Kind, start: usize, end: usize) Token {
    return .{
        .kind = kind,
        .span = .{
            .start = @intCast(start),
            .end = @intCast(end),
        },
    };
}

// assumes the lexer is currently at either single or double quote
fn lexString(lexer: *const @This()) !Token {
    const quote: u8 = lexer.source[lexer.current_char_idx];
    var curr = lexer.current_char_idx + 1;

    while (curr < lexer.source.len) : (curr += 1) {
        switch (lexer.source[curr]) {
            '\\' => curr += 1, // skip escaped character
            quote => return mkToken3(.str, lexer.current_char_idx, curr + 1),
            '\n', '\r' => return error.UnexpectedNewline,
            else => {},
        }
    }

    return error.UnexpectedEOF;
}

// assumes the lexer is currently at A..Z | a..z | _
fn lexIdent(lexer: *const @This()) Token {
    const start = lexer.current_char_idx;
    var end = start + 1;

    while (true) : (end += 1) {
        if (end >= lexer.source.len) break;
        switch (lexer.source[end]) {
            '0'...'9', 'A'...'Z', 'a'...'z', '_' => {},
            _ => break,
        }
    }

    const ident = lexer.source[start..end];

    // smallest ident is 2 chars
    if (ident.len < 2) return mkToken2(.ident, start, ident.len);

    switch (ident[0]) {
        'a' => if (std.mem.eql(u8, ident, "and")) return mkToken2(.@"and", start, ident.len),
        'b' => if (std.mem.eql(u8, ident, "break")) return mkToken2(.@"break", start, ident.len),
        'd' => if (std.mem.eql(u8, ident, "do")) return mkToken2(.do, start, ident.len),
        'e' => if (std.mem.eql(u8, ident, "else")) {
            return mkToken2(.@"else", start, ident.len);
        } else if (std.mem.eql(u8, ident, "elseif")) {
            return mkToken2(.elseif, start, ident.len);
        } else if (std.mem.eql(u8, ident, "end")) {
            return mkToken2(.end, start, ident.len);
        },
        'f' => if (std.mem.eql(u8, ident, "false")) {
            return mkToken2(.false, start, ident.len);
        } else if (std.mem.eql(u8, ident, "for")) {
            return mkToken2(.@"for", start, ident.len);
        } else if (std.mem.eql(u8, ident, "function")) {
            return mkToken2(.function, start, ident.len);
        },
        'g' => if (std.mem.eql(u8, ident, "goto")) return mkToken2(.goto, start, ident.len),
        'i' => if (std.mem.eql(u8, ident, "if")) {
            return mkToken2(.@"if", start, ident.len);
        } else if (std.mem.eql(u8, ident, "in")) {
            return mkToken2(.in, start, ident.len);
        },
        'l' => if (std.mem.eql(u8, ident, "local")) return mkToken2(.local, start, ident.len),
        'n' => if (std.mem.eql(u8, ident, "nil")) {
            return mkToken2(.nil, start, ident.len);
        } else if (std.mem.eql(u8, ident, "not")) {
            return mkToken2(.not, start, ident.len);
        },
        'o' => if (std.mem.eql(u8, ident, "or")) return mkToken2(.@"or", start, ident.len),
        'r' => if (std.mem.eql(u8, ident, "repeat")) {
            return mkToken2(.repeat, start, ident.len);
        } else if (std.mem.eql(u8, ident, "return")) {
            return mkToken2(.@"return", start, ident.len);
        },
        't' => if (std.mem.eql(u8, ident, "then")) {
            return mkToken2(.then, start, ident.len);
        } else if (std.mem.eql(u8, ident, "true")) {
            return mkToken2(.true, start, ident.len);
        },
        'u' => if (std.mem.eql(u8, ident, "until")) return mkToken2(.until, start, ident.len),
        'w' => if (std.mem.eql(u8, ident, "while")) return mkToken2(.@"while", start, ident.len),
        _ => return mkToken2(.ident, start, ident.len),
    }
}

pub fn peekToken(lexer: *const @This()) !Token {
    const start = lexer.current_char_idx;

    if (start >= lexer.source.len) return mkToken2(.eof, start, 0);

    const char = lexer.source[start];
    if (char > std.math.maxInt(u7)) return error.NonAscii;

    const ascii_char: u7 = @intCast(char);
    const token: Token = switch (ascii_char) {
        // control characters (error)
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, '!', '$', '?', '@', '\\', '`', 0x7F => return error.InvalidChar,
        // TAB, LF, CR, space (whitespace)
        0x09, 0x0A, 0x0D, 0x20 => mkToken(.skip, start),
        // 0x22
        '"' => try lexer.lexString(),
        // 0x23
        '#' => mkToken(.hash, start),
        // 0x25
        '%' => mkToken(.percent, start),
        // 0x26
        '&' => mkToken(.amp, start),
        // 0x27
        '\'' => try lexer.lexString(),
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
        // 0x2D, TODO: support comments
        '-' => mkToken(.minus, start),
        // 0x2E
        '.' => if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != '.'))
            // "."
            mkToken(.dot, start)
        else if (((start + 2) >= lexer.source.len) or (lexer.source[start + 2] != '.'))
            // ".."
            mkToken2(.dot2, start, 2)
        else
            // "..."
            mkToken2(.dot3, start, 3),
        // 0x2F
        '/' => if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != '/'))
            // "/"
            mkToken(.slash, start)
        else
            // "//"
            mkToken2(.slash2, start, 2),
        // 0x30 ... 0x39
        '0'...'9' => {
            @panic("TODO: Lex numbers");
        },
        // 0x3A
        ':' => if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != ':'))
            // ":"
            mkToken(.colon, start)
        else
            // "::"
            mkToken2(.colon2, start, 2),
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
            mkToken2(.lte, start, 2)
        else
            // "<<"
            mkToken2(.shift_left, start, 2),
        // 0x3D
        '=' => if (((start + 1) >= lexer.source.len) or (lexer.source[start + 1] != '='))
            // "="
            mkToken(.eq, start)
        else
            // "=="
            mkToken2(.eq2, start, 2),
        // 0x3E
        '>' => if (((start + 1) >= lexer.source.len) or
            ((lexer.source[start + 1] != '=') and
                (lexer.source[start + 1] != '>')))
            // ">"
            mkToken(.rangle, start)
        else if (lexer.source[start + 1] == '=')
            // ">="
            mkToken2(.gte, start, 2)
        else
            // ">>"
            mkToken2(.shift_right, start, 2),
        // 0x41 ... 0x5A
        'A'...'Z', '_', 'a'...'z' => try lexer.lexIdent(),
        // 0x5B, TODO: long strings
        '[' => mkToken(.lbrack, start),
        // 0x5D
        ']' => mkToken(.rbrack, start),
        // 0x5E
        '^' => mkToken(.carrot, start),
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
            mkToken2(.tilde_eq, start, 2),
    };

    return token;
}
