const std = @import("std");

pub const Lexer = @import("Lexer.zig");
pub const Token = @import("Token.zig");

test "peekToken smoke" {
    var lexer = Lexer{ .source = "local x = \"hi\"", .current_char_idx = 0 };

    const first = try lexer.peekToken();
    try std.testing.expectEqual(Token.Kind.local, first.kind);
    try std.testing.expectEqual(@as(u32, 0), first.span.start);
    try std.testing.expectEqual(@as(u32, 5), first.span.end);
}

fn expectToken(source: []const u8, kind: Token.Kind, start: u32, end: u32) !void {
    const lexer = Lexer{ .source = source, .current_char_idx = 0 };

    const token = try lexer.peekToken();

    try std.testing.expectEqual(kind, token.kind);
    try std.testing.expectEqual(start, token.span.start);
    try std.testing.expectEqual(end, token.span.end);
}

fn expectErr(source: []const u8, expected: anyerror) !void {
    const lexer = Lexer{ .source = source, .current_char_idx = 0 };

    try std.testing.expectError(expected, lexer.peekToken());
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
    const nested = Lexer{ .source = "--[==[abc]==] y", .current_char_idx = 0 };
    const nested_span = (try nested.lexLong(2)).?;
    try std.testing.expectEqual(@as(u32, 2), nested_span.start);
    try std.testing.expectEqual(@as(u32, 13), nested_span.end);

    const flat = Lexer{ .source = "--[[abc]] y", .current_char_idx = 0 };
    const flat_span = (try flat.lexLong(2)).?;
    try std.testing.expectEqual(@as(u32, 2), flat_span.start);
    try std.testing.expectEqual(@as(u32, 9), flat_span.end);
}

test "lexLong returns null without a long bracket start" {
    const plain = Lexer{ .source = "--[abc", .current_char_idx = 0 };
    try std.testing.expect((try plain.lexLong(2)) == null);

    // `==` run that never reaches a `[`
    const dangling = Lexer{ .source = "--[==abc", .current_char_idx = 0 };
    try std.testing.expect((try dangling.lexLong(2)) == null);

    // not a bracket at all
    const not_bracket = Lexer{ .source = "--x", .current_char_idx = 0 };
    try std.testing.expect((try not_bracket.lexLong(2)) == null);

    // past the end of the source
    const past_end = Lexer{ .source = "--", .current_char_idx = 0 };
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
    const trailing = Lexer{ .source = "[[a]]b]] y", .current_char_idx = 9 };
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
    var lexer = Lexer{ .source = "local x = \"hi\"", .current_char_idx = 0 };

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
    var lexer = Lexer{ .source = "  -- c\n  x", .current_char_idx = 0 };

    const x = try lexer.nextToken();
    try std.testing.expectEqual(Token.Kind.ident, x.kind);
    try std.testing.expectEqual(@as(u32, 9), x.span.start);
    try std.testing.expectEqual(@as(u32, 10), x.span.end);
}

test "nextToken repeats eof without moving" {
    var lexer = Lexer{ .source = "x", .current_char_idx = 0 };
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
    var lexer = Lexer{ .source = "[[a]]b]] y", .current_char_idx = 9 };

    const y = try lexer.nextToken();
    try std.testing.expectEqual(Token.Kind.ident, y.kind);
    try std.testing.expectEqual(@as(u32, 9), y.span.start);
    try std.testing.expectEqual(@as(u32, 10), y.span.end);
    try std.testing.expectEqual(@as(usize, 10), lexer.current_char_idx);
}

test "nextToken leaves the cursor put on error" {
    var lexer = Lexer{ .source = "x $", .current_char_idx = 0 };
    _ = try lexer.nextToken();
    try std.testing.expectEqual(@as(usize, 1), lexer.current_char_idx);

    try std.testing.expectError(error.InvalidChar, lexer.nextToken());
    // the offending `$` is still there to be retried or reported on
    try std.testing.expectEqual(@as(usize, 1), lexer.current_char_idx);
}
