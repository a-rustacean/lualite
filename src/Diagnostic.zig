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

        // semantic analysis, which needs a name and so sets `name`
        break_outside_loop,
        undefined_label,
        duplicate_label,
        goto_into_local_scope,
        assign_to_const,
        vararg_outside_function,
        unknown_attribute,
        multiple_close_variables,
        too_many_locals,
        too_many_upvalues,

        // a string escape the decoder will not accept. `name` is the escape as
        // written and `value` is what it asked for, where there is a number
        invalid_escape_sequence,
        decimal_escape_too_large,
        hex_digit_expected,
        unicode_escape_too_large,
        // `\u` without its `{`, or a `\u{...}` without its `}`
        malformed_unicode_escape,
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
    // the name the semantic checks talk about, and where it was written. Set
    // only by those checks, and it borrows from the source
    name: []const u8 = "",
    name_span: ?Token.Span = null,
    // what a string escape asked for, where that is a number: the value of a
    // `\ddd`, a `\xNN` or the code point of a `\u{...}`
    value: ?u32 = null,
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

    // How many diagnostics to keep before dropping the rest. A chunk is refused
    // either way, and rendering every one of the tens of thousands a pathological
    // file can produce costs far more than reading the first few tells you. The
    // count of what was dropped is kept so a caller can say so rather than let a
    // short list pass for the whole truth.
    max: usize = default_max,
    dropped: usize = 0,

    pub const default_max: usize = 100;

    // Reports until the cap, then counts what it drops. The error set is unchanged
    // on purpose: a refused chunk is refused either way, and nothing downstream
    // depends on there being one error per problem.
    pub fn report(reporter: *Reporter, diagnostic: Error) !void {
        if (reporter.errors.items.len >= reporter.max) {
            reporter.dropped += 1;
            return;
        }

        try reporter.errors.append(reporter.gpa, diagnostic);
    }

    // whether anything was dropped, which a caller should not report a full list
    // without mentioning
    pub fn truncated(reporter: *const Reporter) bool {
        return reporter.dropped != 0;
    }

    pub fn deinit(reporter: *Reporter) void {
        reporter.errors.deinit(reporter.gpa);
    }
};
