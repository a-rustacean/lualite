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
