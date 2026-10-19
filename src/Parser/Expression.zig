const std = @import("std");

const Parser = @import("../Parser.zig");
const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");
const Diagnostic = @import("../Diagnostic.zig");
// both the type and the functions over it, since the two do not sit in one place
const num = @import("../Number.zig");
const Number = num.Number;

const Function = @import("Function.zig");
const Table = @import("Table.zig");

// left binds against what came before, right against what comes after. The two
// differ only for the right associative `..` and `^`. Both sit above
// unary_priority, so `-2^2` is `-(2^2)`. Numbers are Lua's, from the priority
// table in lparser.c.
const Infix = struct {
    op: Ast.BinaryOperator,
    left: u8,
    right: u8,
};

const unary_priority: u8 = 12;

fn infix(kind: Token.Kind) ?Infix {
    return switch (kind) {
        .@"or" => .{ .op = .@"or", .left = 1, .right = 1 },
        .@"and" => .{ .op = .@"and", .left = 2, .right = 2 },
        .shift_left => .{ .op = .shift_left, .left = 3, .right = 3 },
        .shift_right => .{ .op = .shift_right, .left = 3, .right = 3 },
        .pipe => .{ .op = .bitwise_or, .left = 4, .right = 4 },
        .tilde => .{ .op = .bitwise_xor, .left = 5, .right = 5 },
        .amp => .{ .op = .bitwise_and, .left = 6, .right = 6 },
        .langle => .{ .op = .less_than, .left = 7, .right = 7 },
        .rangle => .{ .op = .greater_than, .left = 7, .right = 7 },
        .lte => .{ .op = .less_equal, .left = 7, .right = 7 },
        .gte => .{ .op = .greater_equal, .left = 7, .right = 7 },
        .eq2 => .{ .op = .equal, .left = 7, .right = 7 },
        .tilde_eq => .{ .op = .not_equal, .left = 7, .right = 7 },
        .dot2 => .{ .op = .concat, .left = 9, .right = 8 },
        .plus => .{ .op = .add, .left = 10, .right = 10 },
        .minus => .{ .op = .subtract, .left = 10, .right = 10 },
        .star => .{ .op = .multiply, .left = 11, .right = 11 },
        .percent => .{ .op = .modulo, .left = 11, .right = 11 },
        .slash => .{ .op = .divide, .left = 11, .right = 11 },
        .slash2 => .{ .op = .floor_divide, .left = 11, .right = 11 },
        .caret => .{ .op = .power, .left = 14, .right = 13 },
        else => null,
    };
}

fn unaryOp(kind: Token.Kind) ?Ast.UnaryOperator {
    return switch (kind) {
        .not => .not,
        .minus => .negation,
        .hash => .length,
        .tilde => .bitwise_not,
        else => null,
    };
}

// a full expression, `or` included
pub fn parseExpression(parser: *Parser) Parser.Error!Ast.Expression {
    return parseBinary(parser, 0);
}

// the caller has already read the leading simple expression, so the token
// being looked at is the one after it. peek is only a token deep, so a decision
// that depends on what follows a name cannot be made until the name is gone. A
// table field is the case: field() in lparser.c tells `name = value` from a
// list item by the `=` behind the name.
pub fn parseAfter(parser: *Parser, first: Ast.Expression) Parser.Error!Ast.Expression {
    return parseInfix(parser, try parseSuffixes(parser, first), 0);
}

// explist, the comma separated expression lists that local, assignment,
// return and the generic for all take
pub fn parseExpressionList(parser: *Parser) Parser.Error![]Ast.Expression {
    const allocator = parser.allocator();

    var list: std.ArrayList(Ast.Expression) = .empty;
    errdefer list.deinit(allocator);

    try list.append(allocator, try parseExpression(parser));
    while (try parser.eat(.comma)) {
        try list.append(allocator, try parseExpression(parser));
    }

    return list.toOwnedSlice(allocator);
}

// precedence climbing, where limit is the binding power of the loosest
// operator still allowed to bind, which is what a prefix operator passes down
// to its operand
fn parseBinary(parser: *Parser, limit: u8) Parser.Error!Ast.Expression {
    const first = if (unaryOp((try parser.peek()).kind)) |op| blk: {
        const op_token = try parser.next();

        // the operand of a prefix operator is a whole expression, so a chain of
        // them recurses through here rather than through `parseSimple`
        try parser.enter();
        defer parser.leave();

        const operand = try parseBinary(parser, unary_priority);

        break :blk Ast.Expression{ .unary = try parser.box(Ast.UnaryExpression, .{
            .span = Token.merge(op_token.span, spanOf(operand)),
            .operator = op,
            .operator_span = op_token.span,
            .expression = operand,
        }) };
    } else try parseSimple(parser);

    return parseInfix(parser, first, limit);
}

// the binary operators left to right onto first, stopping at the first whose
// binding power limit does not allow to bind
fn parseInfix(parser: *Parser, first: Ast.Expression, limit: u8) Parser.Error!Ast.Expression {
    var left = first;

    while (infix((try parser.peek()).kind)) |info| {
        if (info.left <= limit) break;

        const op_token = try parser.next();
        const right = try parseBinary(parser, info.right);

        // `left` goes into the node it is being wrapped by, so it has to be
        // read before the assignment rather than inside it
        const node = try parser.box(Ast.BinaryExpression, .{
            .span = Token.merge(spanOf(left), spanOf(right)),
            .left = left,
            .operator = info.op,
            .operator_span = op_token.span,
            .right = right,
        });
        left = .{ .binary = node };
    }

    return left;
}

// only a name and a parenthesized expression take suffixes. A literal does
// not, so `("x").y` indexes into a string while `"x".y` is a syntax error.
fn parseSimple(parser: *Parser) Parser.Error!Ast.Expression {
    const token = try parser.peek();

    return switch (token.kind) {
        .nil => {
            _ = try parser.next();
            return .{ .nil = try parser.box(Ast.NilExpression, .{ .span = token.span }) };
        },
        .true, .false => {
            _ = try parser.next();
            return .{ .boolean = try parser.box(Ast.BooleanExpression, .{
                .span = token.span,
                .value = token.kind == .true,
            }) };
        },
        .decimal, .float => {
            _ = try parser.next();
            return .{ .number = try parser.box(Ast.NumberExpression, .{
                .span = token.span,
                .value = try parseNumber(parser, token),
            }) };
        },
        .str => {
            _ = try parser.next();
            return .{ .string = try parser.box(Ast.StringLiteral, try parseShortString(parser, token)) };
        },
        .long_str => {
            _ = try parser.next();
            return .{ .string = try parser.box(Ast.StringLiteral, try parseLongString(parser, token)) };
        },
        .dot3 => {
            _ = try parser.next();
            return .{ .vararg = try parser.box(Ast.VarargExpression, .{
                .span = token.span,
                .dots_span = token.span,
            }) };
        },
        .lcurly => {
            return .{ .table = try parser.box(Ast.TableConstructor, try Table.parseTableConstructor(parser)) };
        },
        .function => {
            _ = try parser.next();
            return .{ .function = try parser.box(Ast.FunctionExpression, try Function.parseFunctionExpression(parser, token.span)) };
        },
        .ident, .lparen => try parseSuffixed(parser),
        else => parser.fail(.expected_token, token, .expression),
    };
}

// a name or a parenthesized expression followed by every suffix that can hang
// off it: `.name`, `[index]`, `:` method and a call
pub fn parseSuffixed(parser: *Parser) Parser.Error!Ast.Expression {
    return parseSuffixedAfter(parser, try parser.next());
}

// the same, for a caller that already consumed the prefix token to look at it.
// An assignment target has to be checked rather than assumed, since `a, 1 = 2`
// puts anything after a comma and lparser.c reports it from primaryexp instead
// of treating it as a name.
pub fn parseSuffixedAfter(parser: *Parser, first: Token) Parser.Error!Ast.Expression {
    const expr = switch (first.kind) {
        .ident => Ast.Expression{ .variable = try parser.box(Ast.Variable, .{ .name = parser.ident(first) }) },
        .lparen => try parseParenthesized(parser, first),
        else => return parser.fail(.expected_token, first, .expression),
    };

    return parseSuffixes(parser, expr);
}

fn parseParenthesized(parser: *Parser, open: Token) Parser.Error!Ast.Expression {
    // `(x)` nests as deeply as the input likes
    try parser.enter();
    defer parser.leave();

    const inner = try parseExpression(parser);
    const close = try parser.expect(.rparen);

    return .{ .parenthesized = try parser.box(Ast.ParenthesizedExpression, .{
        .span = Token.merge(open.span, close.span),
        .open_paren_span = open.span,
        .expression = inner,
        .close_paren_span = close.span,
    }) };
}

fn parseSuffixes(parser: *Parser, first: Ast.Expression) Parser.Error!Ast.Expression {
    var expr = first;

    // each suffix wraps the expression it hangs off, so the wrapped one is
    // read before it is overwritten
    while (true) {
        switch ((try parser.peek()).kind) {
            .dot => {
                const dot = try parser.next();
                const name = try parser.expectIdent();

                const variable = try parser.box(Ast.Variable, .{ .field = .{
                    .span = Token.merge(spanOf(expr), name.span),
                    .object = expr,
                    .dot_span = dot.span,
                    .name = name,
                } });
                expr = .{ .variable = variable };
            },
            .lbrack => {
                const open = try parser.next();
                const index = try parseExpression(parser);
                const close = try parser.expect(.rbrack);

                const variable = try parser.box(Ast.Variable, .{ .index = .{
                    .span = Token.merge(spanOf(expr), close.span),
                    .object = expr,
                    .open_bracket_span = open.span,
                    .index = index,
                    .close_bracket_span = close.span,
                } });
                expr = .{ .variable = variable };
            },
            .colon => {
                const colon = try parser.next();
                const method = try parser.expectIdent();

                const call = try parseCall(parser, expr, colon, method);
                expr = .{ .function_call = call };
            },
            .lparen, .lcurly, .str, .long_str => {
                const call = try parseCall(parser, expr, null, null);
                expr = .{ .function_call = call };
            },
            else => return expr,
        }
    }
}

fn parseCall(
    parser: *Parser,
    object: Ast.Expression,
    colon: ?Token,
    method: ?Ast.Identifier,
) Parser.Error!*Ast.FunctionCall {
    const arguments = try parseArguments(parser, method != null);

    return parser.box(Ast.FunctionCall, .{
        .span = Token.merge(spanOf(object), argumentsSpan(arguments)),
        .expression = object,
        .colon_span = if (colon) |token| token.span else null,
        .method = method,
        .arguments = arguments,
    });
}

// all three of `( ... )`, `{ ... }` and a string are open to a method call as
// well as a plain one. colon_only only decides how a call with nothing to open
// is reported: `:` promises an argument list so it names `(`, where a plain
// call just has no arguments to parse.
fn parseArguments(parser: *Parser, colon_only: bool) Parser.Error!Ast.Arguments {
    const token = try parser.peek();

    switch (token.kind) {
        .str => {
            _ = try parser.next();
            return .{ .string = try parseShortString(parser, token) };
        },
        .long_str => {
            _ = try parser.next();
            return .{ .string = try parseLongString(parser, token) };
        },
        .lcurly => return .{ .table = try Table.parseTableConstructor(parser) },
        .lparen => {
            const open = try parser.next();
            const expressions = try parseArgumentExpressions(parser);
            const close = try parser.expect(.rparen);

            return .{ .parenthesized = .{
                .span = Token.merge(open.span, close.span),
                .open_paren_span = open.span,
                .expressions = expressions,
                .close_paren_span = close.span,
            } };
        },
        else => if (colon_only)
            return parser.fail(.expected_token, token, .{ .token = .lparen })
        else
            return parser.fail(.expected_token, token, .arguments),
    }
}

fn parseArgumentExpressions(parser: *Parser) Parser.Error![]Ast.Expression {
    // a call nests as deeply as its arguments do, which `f(f(f(...` reaches
    // without ever entering a block
    try parser.enter();
    defer parser.leave();

    const allocator = parser.allocator();

    var list: std.ArrayList(Ast.Expression) = .empty;
    errdefer list.deinit(allocator);

    if (!try parser.check(.rparen)) {
        try list.append(allocator, try parseExpression(parser));
        while (try parser.eat(.comma)) {
            try list.append(allocator, try parseExpression(parser));
        }
    }

    return list.toOwnedSlice(allocator);
}

// the assignment-target view of an expression. Ast reaches index and field
// chains through Expression.variable, so anything assignable is a cast. A
// parenthesized or computed value is not a target, Lua wants a name, an index
// or a field.
pub fn toVariable(parser: *Parser, expr: Ast.Expression) Parser.Error!Ast.Variable {
    return switch (expr) {
        .variable => |variable| variable.*,
        else => parser.failSpan(.invalid_assignment_target, spanOf(expr)),
    };
}

pub fn spanOf(expr: Ast.Expression) Token.Span {
    return switch (expr) {
        .nil => |e| e.span,
        .boolean => |e| e.span,
        .number => |e| e.span,
        .string => |e| e.span,
        .vararg => |e| e.span,
        .variable => |e| switch (e.*) {
            .name => |name| name.span,
            .index => |index| index.span,
            .field => |field| field.span,
        },
        .unary => |e| e.span,
        .binary => |e| e.span,
        .function => |e| e.span,
        .table => |e| e.span,
        .parenthesized => |e| e.span,
        .function_call => |e| e.span,
    };
}

pub fn argumentsSpan(arguments: Ast.Arguments) Token.Span {
    return switch (arguments) {
        .parenthesized => |a| a.span,
        .table => |a| a.span,
        .string => |a| a.span,
    };
}

// A numeral as Lua would read it: an integer where it fits, else a float. The
// two spellings are not symmetrical, since a hex numeral wraps into an integer and
// a decimal one that overruns becomes a float, which is what
// `l_str2int` in lobject.c does.
fn parseNumber(parser: *Parser, token: Token) Parser.Error!Number {
    const text = parser.slice(token.span);
    if (num.parse(text)) |value| return value;
    return parser.fail(.expected_token, token, .expression);
}

// A short string, with raw as written and value with the escapes resolved.
//
// The lexer has only checked where the string ends, which `\z` changes and `\u`
// changes too. What each escape is allowed to be is decided here, the way
// `read_string` in llex.c decides it, and a bad one is reported rather than
// guessed at. The decoder carries on afterwards, so one bad escape costs the
// rest of its string rather than the rest of the chunk.

// the span of an escape as written, from its backslash to wherever it ended.
// `base` is where `raw` starts in the source, which is just past the opening
// quote, so an index into one is an offset into the other.
fn escapeSpan(base: u32, start: usize, end: usize) Token.Span {
    return .{
        .start = base + @as(u32, @intCast(start)),
        .end = base + @as(u32, @intCast(end)),
    };
}

fn parseShortString(parser: *Parser, token: Token) Parser.Error!Ast.StringLiteral {
    const allocator = parser.allocator();

    // the quotes are the span's first and last byte, and `raw` is between them
    const quoted = parser.slice(token.span);
    const raw = quoted[1 .. quoted.len - 1];
    const base = token.span.start + 1;

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            try value.append(allocator, raw[i]);
            i += 1;
            continue;
        }

        const start = i;
        i += 1; // the backslash
        if (i >= raw.len) break; // a trailing `\`, which the lexer should have rejected

        const escape = raw[i];
        i += 1;

        switch (escape) {
            'a' => try value.append(allocator, 0x07),
            'b' => try value.append(allocator, 0x08),
            'f' => try value.append(allocator, 0x0C),
            'n' => try value.append(allocator, '\n'),
            'r' => try value.append(allocator, '\r'),
            't' => try value.append(allocator, '\t'),
            'v' => try value.append(allocator, 0x0B),
            '\\', '"', '\'' => try value.append(allocator, escape),

            // `\<newline>` is a newline, which is how a long value is broken up.
            // A CR LF pair is one, since the source is text rather than bytes.
            '\n' => try value.append(allocator, '\n'),
            '\r' => {
                if (i < raw.len and raw[i] == '\n') i += 1;
                try value.append(allocator, '\n');
            },

            'x' => try parseHexEscape(parser, raw, &i, &value, start, base),
            'u' => try parseUnicodeEscape(parser, raw, &i, &value, start, base),
            '0'...'9' => try parseDecimalEscape(parser, raw, &i, &value, escape, start, base),

            'z' => {
                // zaps the span of whitespace that follows
                while (i < raw.len and Token.isSpace(raw[i])) i += 1;
            },

            else => {
                // Lua refuses rather than dropping the backslash, since there is
                // no telling what was meant
                try parser.report(.{
                    .kind = .invalid_escape_sequence,
                    .span = escapeSpan(base, start, i),
                    .name = raw[start..i],
                });
                try value.append(allocator, escape);
            },
        }
    }

    return .{
        .span = token.span,
        .raw = raw,
        .value = try value.toOwnedSlice(allocator),
    };
}

// `\xNN`, exactly two hex digits, each of which Lua insists on
fn parseHexEscape(
    parser: *Parser,
    raw: []const u8,
    i: *usize,
    value: *std.ArrayList(u8),
    start: usize,
    base: u32,
) Parser.Error!void {
    var byte: u32 = 0;
    for (0..2) |_| {
        if (i.* >= raw.len or !isHexDigit(raw[i.*])) {
            // the escape stops at whatever is there, which may be the end of the
            // string rather than a character the reader can name
            const taken = @min(i.* + 1, raw.len);
            i.* = taken;
            try parser.report(.{
                .kind = .hex_digit_expected,
                .span = escapeSpan(base, start, taken),
                .name = raw[start..taken],
            });
            return;
        }

        byte = byte * 16 + hexValue(raw[i.*]);
        i.* += 1;
    }

    try value.append(parser.allocator(), @truncate(byte));
}

// `\u{XXXX}`, the code point as UTF-8. Lua allows anything up to 0x7FFFFFFF here,
// surrogates included, and it is `utf8.char` rather than this escape that
// refuses those.
fn parseUnicodeEscape(
    parser: *Parser,
    raw: []const u8,
    i: *usize,
    value: *std.ArrayList(u8),
    start: usize,
    base: u32,
) Parser.Error!void {
    if (i.* >= raw.len or raw[i.*] != '{') {
        try parser.report(.{
            .kind = .malformed_unicode_escape,
            .span = escapeSpan(base, start, i.*),
            .name = "missing '{'",
        });
        return;
    }
    i.* += 1;

    // at least one digit. Lua says the same about an empty `\u{}` as about one
    // with nothing usable behind the brace.
    if (i.* >= raw.len or !isHexDigit(raw[i.*])) {
        try parser.report(.{
            .kind = .hex_digit_expected,
            .span = escapeSpan(base, start, i.*),
            .name = raw[start..i.*],
        });
        return;
    }

    var code: u32 = 0;
    while (i.* < raw.len and isHexDigit(raw[i.*])) {
        // checked before the shift rather than after, which is how Lua keeps the
        // intermediate inside the range it compares it against
        if (code > (0x7FFFFFFF >> 4)) {
            try parser.report(.{
                .kind = .unicode_escape_too_large,
                .span = escapeSpan(base, start, i.* + 1),
                .name = raw[start .. i.* + 1],
                .value = code,
            });
            while (i.* < raw.len and isHexDigit(raw[i.*])) i.* += 1;
            return;
        }

        code = code * 16 + hexValue(raw[i.*]);
        i.* += 1;
    }

    if (i.* >= raw.len or raw[i.*] != '}') {
        try parser.report(.{
            .kind = .malformed_unicode_escape,
            .span = escapeSpan(base, start, i.*),
            .name = "missing '}'",
        });
        return;
    }
    i.* += 1;

    try appendUtf8(parser.allocator(), value, code);
}

// `\ddd`, up to three decimal digits and no more than 255
fn parseDecimalEscape(
    parser: *Parser,
    raw: []const u8,
    i: *usize,
    value: *std.ArrayList(u8),
    escape: u8,
    start: usize,
    base: u32,
) Parser.Error!void {
    var digits: u32 = escape - '0';
    var taken: usize = 1;

    while (taken < 3 and i.* < raw.len and isDigit(raw[i.*])) : (taken += 1) {
        digits = digits * 10 + (raw[i.*] - '0');
        i.* += 1;
    }

    // Lua reads all three digits and then refuses, rather than stopping short and
    // reading whatever is left of them as more of the string
    if (digits > 255) {
        try parser.report(.{
            .kind = .decimal_escape_too_large,
            .span = escapeSpan(base, start, i.*),
            .name = raw[start..i.*],
            .value = digits,
        });
        return;
    }

    try value.append(parser.allocator(), @truncate(digits));
}

// The code point as UTF-8, a transcription of `luaO_utf8esc`. It writes the
// continuation bytes backwards from the end of a buffer, each one taking six more
// bits, and stops when what is left fits in a lead byte. Surrogates are not
// refused, since `utf8.char` is where that is decided rather than here.
fn appendUtf8(allocator: std.mem.Allocator, value: *std.ArrayList(u8), code: u32) !void {
    var bytes: [6]u8 = undefined;
    var n: usize = 1;
    var x = code;

    if (x < 0x80) {
        bytes[bytes.len - 1] = @truncate(x);
    } else {
        // the most that still fits in a lead byte, narrowed by half each round
        var mfb: u32 = 0x3F;

        while (true) {
            bytes[bytes.len - n] = 0x80 | @as(u8, @truncate(x & 0x3F));
            n += 1;
            x >>= 6;
            mfb >>= 1;

            if (x <= mfb) break;
        }

        // ~mfb is the mask of the bits the lead byte takes, and doubling it is
        // where it sits in the byte
        bytes[bytes.len - n] = @as(u8, @truncate(~mfb << 1)) | @as(u8, @truncate(x));
    }

    try value.appendSlice(allocator, bytes[bytes.len - n ..]);
}

// a long string taken whole, no escapes at all. Lua normalizes every line
// ending to LF and drops one initial line ending after the opening bracket.
fn parseLongString(parser: *Parser, token: Token) Parser.Error!Ast.StringLiteral {
    const text = parser.slice(token.span);

    // `[`, a run of `=`, `[`: the opening delimiter and its `]=]`, `]` mirror
    // are the same length, so one walk over the run sizes both
    var delimiter: usize = 1;
    while (delimiter < text.len and text[delimiter] == '=') : (delimiter += 1) {}
    delimiter += 1;

    const raw = text[delimiter .. text.len - delimiter];
    var start: usize = 0;
    if (raw.len != 0 and (raw[0] == '\r' or raw[0] == '\n')) {
        start = 1;
        if (raw[0] == '\r' and start < raw.len and raw[start] == '\n') start += 1;
    }

    const value_buf = try parser.allocator().alloc(u8, raw.len - start);
    var len: usize = 0;
    var i = start;
    while (i < raw.len) {
        if (raw[i] == '\r') {
            value_buf[len] = '\n';
            len += 1;
            i += 1;
            if (i < raw.len and raw[i] == '\n') i += 1;
        } else {
            value_buf[len] = raw[i];
            len += 1;
            i += 1;
        }
    }

    return .{
        .span = token.span,
        .raw = raw,
        .value = value_buf[0..len],
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexValue(c: u8) u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => unreachable,
    };
}
// rendering an expression back to source, so a test can state the shape of a
// tree on one line. This is how the precedence and associativity below stay
// readable.

fn unarySymbol(operator: Ast.UnaryOperator) []const u8 {
    return switch (operator) {
        .negation => "-",
        .not => "not",
        .length => "#",
        .bitwise_not => "~",
    };
}

fn binarySymbol(operator: Ast.BinaryOperator) []const u8 {
    return switch (operator) {
        .add => "+",
        .subtract => "-",
        .multiply => "*",
        .divide => "/",
        .floor_divide => "//",
        .modulo => "%",
        .power => "^",
        .bitwise_and => "&",
        .bitwise_or => "|",
        .bitwise_xor => "~",
        .shift_left => "<<",
        .shift_right => ">>",
        .concat => "..",
        .less_than => "<",
        .less_equal => "<=",
        .greater_than => ">",
        .greater_equal => ">=",
        .equal => "==",
        .not_equal => "~=",
        .@"and" => "and",
        .@"or" => "or",
    };
}

// written by render and written out before returning, so nothing holds it past
// that call
var render_buffer: [num.buffer_size]u8 = undefined;

fn render(writer: *std.Io.Writer, expr: Ast.Expression) anyerror!void {
    switch (expr) {
        .nil => try writer.writeAll("nil"),
        .boolean => |e| try writer.writeAll(if (e.value) "true" else "false"),
        // through the number's own printer, so an integer stays without a `.0` and
        // a float keeps the one Lua gives it
        .number => |e| try writer.writeAll(num.toBytes(e.value, &render_buffer) catch "?"),
        .string => |e| try writer.print("[\"{s}\"]", .{e.raw}),
        .vararg => try writer.writeAll("..."),
        .variable => |e| try renderVariable(writer, e.*),
        .unary => |e| {
            try writer.writeAll("(");
            try writer.writeAll(unarySymbol(e.operator));
            try writer.writeByte(' ');
            try render(writer, e.expression);
            try writer.writeByte(')');
        },
        .binary => |e| {
            try writer.writeByte('(');
            try render(writer, e.left);
            try writer.print(" {s} ", .{binarySymbol(e.operator)});
            try render(writer, e.right);
            try writer.writeByte(')');
        },
        .function => try writer.writeAll("function"),
        .table => |e| {
            try writer.writeAll("{");
            for (e.fields, 0..) |field, i| {
                if (i != 0) try writer.writeAll(", ");
                try render(writer, switch (field) {
                    .indexed => |indexed| indexed.value,
                    .named => |named| named.value,
                    .expression => |expression| expression.expression,
                });
            }
            try writer.writeAll("}");
        },
        .parenthesized => |e| {
            try writer.writeByte('(');
            try render(writer, e.expression);
            try writer.writeByte(')');
        },
        .function_call => |e| {
            try render(writer, e.expression);
            if (e.method) |method| try writer.print(":{s}", .{method.name});

            switch (e.arguments) {
                .parenthesized => try writer.writeByte('('),
                .table => try writer.writeByte('{'),
                .string => |string| {
                    try writer.writeByte('(');
                    try writer.print("[\"{s}\"]", .{string.raw});
                },
            }

            switch (e.arguments) {
                .parenthesized => |arguments| {
                    for (arguments.expressions, 0..) |argument, i| {
                        if (i != 0) try writer.writeAll(", ");
                        try render(writer, argument);
                    }
                    try writer.writeByte(')');
                },
                .table => |table| {
                    for (table.fields, 0..) |field, i| {
                        if (i != 0) try writer.writeAll(", ");
                        try render(writer, switch (field) {
                            .indexed => |indexed| indexed.value,
                            .named => |named| named.value,
                            .expression => |expression| expression.expression,
                        });
                    }
                    try writer.writeByte('}');
                },
                .string => try writer.writeByte(')'),
            }
        },
    }
}

fn renderVariable(writer: *std.Io.Writer, variable: Ast.Variable) anyerror!void {
    switch (variable) {
        .name => |name| try writer.writeAll(name.name),
        .field => |field| {
            try render(writer, field.object);
            try writer.print(".{s}", .{field.name.name});
        },
        .index => |index| {
            try render(writer, index.object);
            try writer.writeByte('[');
            try render(writer, index.index);
            try writer.writeByte(']');
        },
    }
}

// parses source as an expression and states the tree it came out as
fn expectTree(source: []const u8, expected: []const u8) !void {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression(source);
    try t.expectClean();

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, expr);

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

// the same, for input that is not valid Lua
fn expectTreeErr(source: []const u8, kind: Diagnostic.Error.Kind) !void {
    var t = Parser.Test.init();
    defer t.deinit();

    _ = t.parseExpression(source) catch {};

    // the parse recovers rather than stopping, so broken input can be reported
    // more than once and what matters is that it was among them
    for (t.errors()) |found| {
        if (@as(u8, @intFromEnum(found.kind)) == @as(u8, @intFromEnum(kind))) return;
    }

    return error.ExpectedDiagnosticMissing;
}

test "the precedence table follows lparser.c" {
    try expectTree("1 + 2 * 3", "(1 + (2 * 3))");
    try expectTree("1 * 2 + 3", "((1 * 2) + 3)");
    try expectTree("1 - 2 / 3 % 4", "(1 - ((2 / 3) % 4))");
    try expectTree("2^3^2", "(2 ^ (3 ^ 2))");
    try expectTree("a .. b .. c", "(a .. (b .. c))");
    try expectTree("a .. b + c", "(a .. (b + c))");
    try expectTree("1 + 2 .. \"x\"", "((1 + 2) .. [\"x\"])");
    try expectTree("a | b ~ c & d", "(a | (b ~ (c & d)))");
    // `==` outranks `<<` on the right, which is what lparser.c does with the
    // same numbers: `subexpr` recurses with the operator's right priority
    try expectTree("a << b < c", "(a << (b < c))");
    try expectTree("a >= b == c", "((a >= b) == c)");
    try expectTree("a or b and c", "(a or (b and c))");
    try expectTree("a and b or c", "((a and b) or c)");
    try expectTree("a == b ~= c", "((a == b) ~= c)");
}

test "everything but .. and ^ is left associative" {
    try expectTree("1 - 2 - 3", "((1 - 2) - 3)");
    try expectTree("1 / 2 / 3", "((1 / 2) / 3)");
    try expectTree("a and b and c", "((a and b) and c)");
    try expectTree("a or b or c", "((a or b) or c)");
    try expectTree("a < b < c", "((a < b) < c)");
}

test "a prefix operator binds looser than ^ but tighter than everything else" {
    try expectTree("-2^2", "(- (2 ^ 2))");
    try expectTree("2^-3", "(2 ^ (- 3))");
    try expectTree("-x * y", "((- x) * y)");
    try expectTree("#t + 1", "((# t) + 1)");
    try expectTree("~a & b", "((~ a) & b)");
    try expectTree("not a == b", "((not a) == b)");
    try expectTree("not not a", "(not (not a))");
    try expectTree("- - 1", "(- (- 1))");
}

test "every operator reaches the tree it names" {
    const operators = [_]struct { source: []const u8, op: Ast.BinaryOperator }{
        .{ .source = "a + b", .op = .add },
        .{ .source = "a - b", .op = .subtract },
        .{ .source = "a * b", .op = .multiply },
        .{ .source = "a / b", .op = .divide },
        .{ .source = "a // b", .op = .floor_divide },
        .{ .source = "a % b", .op = .modulo },
        .{ .source = "a ^ b", .op = .power },
        .{ .source = "a & b", .op = .bitwise_and },
        .{ .source = "a | b", .op = .bitwise_or },
        .{ .source = "a ~ b", .op = .bitwise_xor },
        .{ .source = "a << b", .op = .shift_left },
        .{ .source = "a >> b", .op = .shift_right },
        .{ .source = "a .. b", .op = .concat },
        .{ .source = "a < b", .op = .less_than },
        .{ .source = "a <= b", .op = .less_equal },
        .{ .source = "a > b", .op = .greater_than },
        .{ .source = "a >= b", .op = .greater_equal },
        .{ .source = "a == b", .op = .equal },
        .{ .source = "a ~= b", .op = .not_equal },
        .{ .source = "a and b", .op = .@"and" },
        .{ .source = "a or b", .op = .@"or" },
    };

    for (operators) |expected| {
        var t = Parser.Test.init();
        defer t.deinit();

        const expr = try t.parseExpression(expected.source);
        try t.expectClean();

        const binary = switch (expr) {
            .binary => |node| node,
            else => return error.NotABinaryExpression,
        };
        try std.testing.expectEqual(expected.op, binary.operator);
    }
}

test "numeral literals keep their value" {
    // rendered through the number's own printer, so an integer has no `.0` and a
    // float keeps the one Lua gives it
    try expectTree("1", "1");
    try expectTree("1.5", "1.5");
    try expectTree(".5", "0.5");
    try expectTree("1e2", "100.0");
    try expectTree("1E-2", "0.01");
    try expectTree("0x10", "16");
    try expectTree("0xff", "255");
    try expectTree("0x1p4", "16.0");
    try expectTree("0x.8", "0.5");
    try expectTree("0xA.8p1", "21.0");
    try expectTree("-0x10", "(- 16)");
}

// The two spellings are not symmetrical, which is what `l_str2int` in lobject.c
// says: a hex numeral wraps into an integer and a decimal one that overruns
// becomes a float.
test "a numeral out of range reads the way Lua reads it" {
    try expectTree("0xffffffffffffffff", "-1");
    try expectTree("0x10000000000000000", "0");
    try expectTree("9223372036854775807", "9223372036854775807");
    try expectTree("9223372036854775808", "9.2233720368548e+18");
    try expectTree("-9223372036854775809", "(- 9.2233720368548e+18)");
}

test "short strings decode their escapes" {
    try expectTree("\"\\a\\b\\f\\n\\r\\t\\v\"", "[\"\\a\\b\\f\\n\\r\\t\\v\"]");
    try expectTree("'single'", "[\"single\"]");

    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("\"a\\nb\\t\\65\\x42\"");
    try t.expectClean();

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };

    // \ddd and \xNN are both plain bytes
    try std.testing.expectEqualStrings("a\nb\tAB", string.value);
    try std.testing.expectEqualStrings("a\\nb\\t\\65\\x42", string.raw);
}

// Lua refuses an escape it does not know rather than dropping the backslash,
// since there is no telling what was meant. The decoder reports it and carries
// on, so the rest of the string is still decoded.
test "an unknown escape is refused rather than decoded" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("\"a\\qb\"");
    try t.expectCount(1);
    try t.expectKind(0, .invalid_escape_sequence);

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("aqb", string.value);
}

test "a decimal escape over 255 is refused" {
    var t = Parser.Test.init();
    defer t.deinit();

    // Lua reads all three digits and then refuses, rather than stopping short and
    // reading what is left of them as more of the string
    const expr = try t.parseExpression("\"\\300\"");
    try t.expectCount(1);
    try t.expectKind(0, .decimal_escape_too_large);

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("", string.value);
}

test "255 is the largest decimal escape" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("\"\\255\\0\"");
    try t.expectClean();

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings(&[_]u8{ 0xFF, 0x00 }, string.value);
}

test "a hex escape needs exactly two digits" {
    var t = Parser.Test.init();
    defer t.deinit();

    _ = try t.parseExpression("\"\\x4\"");
    try t.expectCount(1);
    try t.expectKind(0, .hex_digit_expected);
}

test "a \\u{...} escape decodes to UTF-8" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("\"\\u{1F600}\\u{41}\\u{0}\"");
    try t.expectClean();

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };

    // one byte, four bytes, then a NUL
    const expected = [_]u8{ 0xF0, 0x9F, 0x98, 0x80, 'A', 0x00 };
    try std.testing.expectEqualSlices(u8, &expected, string.value);
}

test "a \\u escape refuses what Lua refuses" {
    // each in a reporter of its own, since the checks are about one shape each
    {
        var t = Parser.Test.init();
        defer t.deinit();

        // no brace
        _ = try t.parseExpression("\"\\u41\"");
        try t.expectCount(1);
        try t.expectKind(0, .malformed_unicode_escape);
    }
    {
        var t = Parser.Test.init();
        defer t.deinit();

        // no closing brace
        _ = try t.parseExpression("\"\\u{41\"");
        try t.expectCount(1);
        try t.expectKind(0, .malformed_unicode_escape);
    }
    {
        var t = Parser.Test.init();
        defer t.deinit();

        // nothing at all between the braces
        _ = try t.parseExpression("\"\\u{}\"");
        try t.expectCount(1);
        try t.expectKind(0, .hex_digit_expected);
    }
    {
        var t = Parser.Test.init();
        defer t.deinit();

        // past the largest code point
        _ = try t.parseExpression("\"\\u{80000000}\"");
        try t.expectCount(1);
        try t.expectKind(0, .unicode_escape_too_large);
    }
}

test "a \\u escape encodes at the length the code point needs" {
    // the lengths Lua's own encoder gives, checked against what it prints
    const cases = [_]struct { code: []const u8, len: usize }{
        .{ .code = "80", .len = 2 },
        .{ .code = "7FF", .len = 2 },
        .{ .code = "800", .len = 3 },
        .{ .code = "FFFF", .len = 3 },
        .{ .code = "10000", .len = 4 },
        .{ .code = "D800", .len = 3 },
        .{ .code = "7FFFFFFF", .len = 6 },
    };

    for (cases) |case| {
        var t = Parser.Test.init();
        defer t.deinit();

        const expr = try t.parseExpression(
            try std.fmt.allocPrint(t.arena.allocator(), "\"\\u{{{s}}}\"", .{case.code}),
        );
        try t.expectClean();

        const string = switch (expr) {
            .string => |node| node,
            else => return error.NotAString,
        };
        try std.testing.expectEqual(case.len, string.value.len);
    }
}

test "the largest code point a \\u escape accepts is 0x7FFFFFFF" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("\"\\u{7FFFFFFF}\"");
    try t.expectClean();

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };

    // six bytes, and a surrogate is allowed here even though utf8.char refuses
    // one, since it is the escape that is being tested
    try std.testing.expectEqual(@as(usize, 6), string.value.len);
    try std.testing.expectEqual(@as(u8, 0xFD), string.value[0]);
}

// a backslash before a newline is a newline, which is how a long value is broken
// up, and a CR LF pair is one newline rather than two
test "a backslash before a newline is a newline" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("\"a\\\nb\"");
    try t.expectClean();

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("a\nb", string.value);
}

test "a backslash before a CRLF is one newline" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("\"a\\\r\nb\"");
    try t.expectClean();

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("a\nb", string.value);
}

test "\\z skips the whitespace behind it" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("\"a\\z \t  b\"");
    try t.expectClean();

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("ab", string.value);
}

test "\\z reaches past a newline" {
    var t = Parser.Test.init();
    defer t.deinit();

    // the escape stands for whatever whitespace follows it, so the string is
    // still one token: the lexer has to skip as far as the decoder does
    const expr = try t.parseExpression("\"a\\z\n   b\"");
    try t.expectClean();

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("ab", string.value);
}

test "a long string has no escapes and drops its first newline" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("[[a\\nb]]");
    try t.expectClean();

    const string = switch (expr) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("a\\nb", string.value);

    const with_newline = switch (try t.parseExpression("[==[\nline]\n]==]")) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("line]\n", with_newline.value);

    const crlf = switch (try t.parseExpression("[[\r\nx]]")) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("x", crlf.value);
}

test "long strings normalize CR, LF, and CRLF everywhere" {
    var t = Parser.Test.init();
    defer t.deinit();

    const normalized = switch (try t.parseExpression("[=[a\r\nb\rc\nd]=]")) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("a\nb\nc\nd", normalized.value);

    const initial_cr = switch (try t.parseExpression("[=[\rfirst]=]")) {
        .string => |node| node,
        else => return error.NotAString,
    };
    try std.testing.expectEqualStrings("first", initial_cr.value);
}

test "a suffixed expression chains every suffix" {
    try expectTree("a", "a");
    try expectTree("a.b.c", "a.b.c");
    try expectTree("a[1]", "a[1]");
    try expectTree("a[b][c]", "a[b][c]");
    try expectTree("a.b[c].d", "a.b[c].d");
    try expectTree("f()", "f()");
    try expectTree("f(1, 2)", "f(1, 2)");
    try expectTree("f().g", "f().g");
    try expectTree("f{1, k = 2}", "f{1, 2}");
    try expectTree("f\"s\"", "f([\"s\"])");
    try expectTree("f[[s]]", "f([\"s\"])");
    try expectTree("a:b()", "a:b()");
    try expectTree("a.b:c(1):d()", "a.b:c(1):d()");
    try expectTree("a():b()", "a():b()");
    try expectTree("(a).b", "(a).b");
    try expectTree("(\"x\").y", "([\"x\"]).y");
}

test "a literal takes no suffix" {
    // the suffix is read as the start of the next thing, so what the parser
    // complains about is the statement it cannot begin
    try expectTreeErr("\"x\".y", .expected_token);
    try expectTreeErr("{1}.y", .expected_token);
    try expectTreeErr("1[2]", .expected_token);
}

test "a method call takes its arguments in any of the three spellings" {
    try expectTree("a:b(\"s\")", "a:b([\"s\"])");
    try expectTree("a:b\"s\"", "a:b([\"s\"])");
    try expectTree("a:b[[s]]", "a:b([\"s\"])");
    try expectTree("a:b{1}", "a:b{1}");
    // the string and table spellings stop after one argument, as `funcargs`
    // does, so `f "a", "b"` is the tail of a list no call is there to read
    try expectTree("s:gsub \"p\"", "s:gsub([\"p\"])");
}

test "a method call with nothing to open still wants a `(`" {
    try expectTreeErr("a:b", .expected_token);
}

test "the remaining expression forms" {
    try expectTree("nil", "nil");
    try expectTree("true", "true");
    try expectTree("false", "false");
    try expectTree("...", "...");
    try expectTree("function(x) return x end", "function");
    try expectTree("{1, k = 2, [3] = 4}", "{1, 2, 4}");
}

test "an expression list runs to the end of the statement" {
    var t = Parser.Test.init();
    defer t.deinit();

    const chunk = try t.parse("local a, b, c = 1, 2");
    try t.expectClean();

    const declaration = switch (chunk.block.statements[0]) {
        .local_declaration => |node| node,
        else => return error.NotALocalDeclaration,
    };
    try std.testing.expectEqual(@as(usize, 3), declaration.names.len);
    try std.testing.expectEqual(@as(usize, 2), declaration.expressions.len);
}

test "only a name, a field or an index can be assigned to" {
    // a name, a field and an index all reach through `Expression.variable`
    for ([_]struct { source: []const u8, tag: std.meta.Tag(Ast.Variable) }{
        .{ .source = "a", .tag = .name },
        .{ .source = "a.b", .tag = .field },
        .{ .source = "a[1]", .tag = .index },
        .{ .source = "a.b[c]", .tag = .index },
    }) |target| {
        var t = Parser.Test.init();
        defer t.deinit();

        var parser = Parser.fromSource(target.source, &t.arena, &t.reporter);
        const variable = try parser.toVariable(try parser.parseSuffixed());
        try t.expectClean();

        try std.testing.expectEqual(target.tag, std.meta.activeTag(variable));
    }

    // a computed value is not a target, and a suffix chain never reaches one
    var t = Parser.Test.init();
    defer t.deinit();

    var parser = Parser.fromSource("f()", &t.arena, &t.reporter);
    try std.testing.expectError(error.ParserFailed, parser.toVariable(try parser.parseExpression()));
    try t.expectKind(0, .invalid_assignment_target);
}
