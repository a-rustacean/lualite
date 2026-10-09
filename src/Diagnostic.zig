const std = @import("std");
const Token = @import("Token.zig");

pub const Error = struct {
    pub const Kind = union(enum) {
        // lexer
        unexpected_eof,
        unexpected_newline,
        invalid_char,
        malformed_number,

        // parser
        // something in particular was wanted here, `expected` says what
        expected_token,
        // nothing at all could have gone here
        unexpected_token,
        invalid_assignment_target,
        statement_after_return,
        nesting_too_deep,
    };

    // what the parser wanted where it stopped. A token is named as itself, the
    // rest stand for a class of thing that spans several tokens.
    pub const Expected = union(enum) {
        token: Token.Kind,
        expression,
        statement,
        arguments,
    };

    kind: Kind,
    span: Token.Span,
    // only expected_token sets this
    expected: ?Expected = null,
    // the token that was there instead
    found: ?Token.Kind = null,
    // set when what was wanted is a closer, and where the block it should have
    // closed was opened
    opened_at: ?Token.Span = null,
    // how to name that block, recorded rather than looked up later since the
    // parse has moved on and the block is closed
    opened_name: []const u8 = "",
};

pub const Reporter = struct {
    errors: std.ArrayList(Error) = .empty,
    gpa: std.mem.Allocator,

    pub fn report(reporter: *Reporter, diagnostic: Error) !void {
        try reporter.errors.append(reporter.gpa, diagnostic);
    }

    pub fn deinit(reporter: *Reporter) void {
        reporter.errors.deinit(reporter.gpa);
    }
};
