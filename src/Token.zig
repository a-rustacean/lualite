pub const Kind = enum(u8) {
    eof,

    // identifier
    ident,

    // keywords
    @"and",
    @"break",
    do,
    @"else",
    elseif,
    end,
    false,
    @"for",
    function,
    goto,
    @"if",
    in,
    local,
    nil,
    not,
    @"or",
    repeat,
    @"return",
    then,
    true,
    until,
    @"while",

    // Ops

    plus,
    minus,
    star,
    slash,
    slash2,
    percent,
    caret,
    amp,
    tilde,
    tilde_eq,
    pipe,
    shift_left,
    shift_right,
    eq,
    eq2,
    lte,
    gte,

    hash,
    dot,
    dot2,
    dot3,

    langle,
    lbrack,
    lcurly,
    lparen,

    rangle,
    rbrack,
    rcurly,
    rparen,

    colon,
    colon2,
    semicolon,

    comma,

    // numeric literals
    decimal,
    float,

    // string literal
    str,
    long_str,
};

pub const Span = struct {
    start: u32,
    end: u32,
};

// the smallest span covering both, which is what a node built out of several
// tokens needs
pub fn merge(a: Span, b: Span) Span {
    return .{
        .start = @min(a.start, b.start),
        .end = @max(a.end, b.end),
    };
}

// a span of no width at offset, for the tokens a construct implies rather than
// spells out
pub fn at(offset: u32) Span {
    return .{ .start = offset, .end = offset };
}

// TAB, VT, FF, LF, CR and space, the whitespace Lua counts as such. Both halves
// of `\z` need it: the lexer to know how far the escape reaches, and whoever
// decodes the string to know how much whitespace to drop.
pub fn isSpace(c: u8) bool {
    return switch (c) {
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20 => true,
        else => false,
    };
}

// the source text of a punctuator. The lexer's names are about the left and
// right of a pair, so the spelling is not always the tag.
pub fn punctuationText(kind: Kind) []const u8 {
    return switch (kind) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .slash2 => "//",
        .percent => "%",
        .caret => "^",
        .amp => "&",
        .tilde => "~",
        .tilde_eq => "~=",
        .pipe => "|",
        .shift_left => "<<",
        .shift_right => ">>",
        .eq => "=",
        .eq2 => "==",
        .lte => "<=",
        .gte => ">=",
        .hash => "#",
        .dot => ".",
        .dot2 => "..",
        .dot3 => "...",
        .langle => "<",
        .lbrack => "[",
        .lcurly => "{",
        .lparen => "(",
        .rangle => ">",
        .rbrack => "]",
        .rcurly => "}",
        .rparen => ")",
        .colon => ":",
        .colon2 => "::",
        .semicolon => ";",
        .comma => ",",
        .eof, .ident, .decimal, .float, .str, .long_str => unreachable,
        else => @tagName(kind),
    };
}

/// The token as an error message quotes it: a keyword or punctuator is spelled
/// as written, and the tokens whose text is the lexeme itself have no answer
/// here — the caller reaches for the source.
pub fn luaText(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .eof, .ident, .decimal, .float, .str, .long_str => null,
        else => punctuationText(kind),
    };
}

span: Span,
kind: Kind,
