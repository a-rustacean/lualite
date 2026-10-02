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
