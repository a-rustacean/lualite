const std = @import("std");

const lualite = @import("lualite");

pub fn main(init: std.process.Init) !void {
    const lexer = lualite.Lexer{
        .current_char_idx = 0,
        .gpa = init.gpa,
        .source = "~=",
    };
    const token = try lexer.peakToken();
    std.debug.assert(token.?.kind == .tilde_eq);
}
