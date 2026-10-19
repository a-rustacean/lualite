pub const Lexer = @import("Lexer.zig");
pub const Token = @import("Token.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const Ast = @import("Ast.zig");
pub const Collector = @import("Collector.zig");
pub const VM = @import("VM.zig");
pub const Parser = @import("Parser.zig");
pub const Semantic = @import("Semantic.zig");
pub const Number = @import("Number.zig");
pub const Object = @import("Object.zig");
pub const Str = @import("Str.zig");
pub const Table = @import("Table.zig");
pub const Value = @import("Value.zig");

test {
    _ = @import("Lexer.zig");
    _ = @import("Parser.zig");
    _ = @import("Semantic.zig");
    _ = @import("Number.golden.zig");
    _ = @import("Object.zig");
    _ = @import("Collector.zig");
    _ = @import("VM.zig");
    _ = @import("Str.zig");
    _ = @import("Table.zig");
    _ = @import("Value.zig");
}
