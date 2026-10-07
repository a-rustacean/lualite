const std = @import("std");
const Token = @import("Token.zig");

pub const Error = struct {
    pub const Kind = union(enum) {
        unexpected_eof,
        unexpected_newline,
        invalid_char,
        malformed_number,
    };

    kind: Kind,
    span: Token.Span,
};

pub const Reporter = struct {
    errors: std.ArrayList(Error) = .empty,
    gpa: std.mem.Allocator,

    pub fn report(reporter: *Reporter, kind: Error.Kind, span: Token.Span) !void {
        try reporter.errors.append(reporter.gpa, .{
            .kind = kind,
            .span = span,
        });
    }

    pub fn deinit(reporter: *Reporter) void {
        reporter.errors.deinit(reporter.gpa);
    }
};
