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

span: Span,
kind: Kind,
