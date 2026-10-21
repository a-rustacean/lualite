const std = @import("std");

const Parser = @import("../Parser.zig");
const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");

const Statement = @import("Statement.zig");

// the tokens that can close a block. `else` and `elseif` terminate an if block
// specifically, but all of them end the run of statements parseBlock collects, so
// recovery needs the set.
pub const block_ends = [_]Token.Kind{ .end, .@"else", .elseif, .until };

// parses statements until one of terminators or end of file, leaving the
// terminator for the caller. A statement that fails does not abandon the block:
// the diagnostic is already recorded, so the block skips the rest of that
// statement and tries the next one. Allocation and reporter failures propagate.
pub fn parseBlock(parser: *Parser, terminators: []const Token.Kind) Parser.Error!Ast.Block {
    try parser.enter();
    defer parser.leave();

    const start: u32 = @intCast(parser.lexer.current_char_idx);

    var statements: std.ArrayList(Ast.Statement) = .empty;
    var ret_statement: ?Ast.RetStatement = null;
    var reported_after_return = false;

    while (!try parser.atBlockEnd(terminators)) {
        // `return` has to be the last statement of a block. Once one has been seen the
        // next statement is worth one diagnostic, but the block keeps parsing so
        // the rest of it is not torn up as well. The closer is the one the
        // construct waits for, which is what the reference's `check_match`
        // words the refusal as: `<eof>` for the chunk, `until` for a `repeat`,
        // `end` for everything else.
        if (ret_statement != null and !reported_after_return) {
            const closer: Token.Kind = if (parser.openBlock()) |open|
                if (open.keyword == .repeat) .until else .end
            else
                .eof;
            try parser.report(.{
                .kind = .statement_after_return,
                .span = (try parser.peek()).span,
                .found = (try parser.peek()).kind,
                .closer = closer,
            });
            reported_after_return = true;
        }

        if (try parser.check(.@"return")) {
            const ret = Statement.parseReturn(parser) catch |err| switch (err) {
                error.OutOfMemory, error.ReportFailed => return err,
                error.ParserFailed => {
                    try synchronize(parser);
                    continue;
                },
            };

            if (ret_statement == null) ret_statement = ret;
            continue;
        }

        // a token that closes a block where the block being parsed is not the one it
        // closes: something was left open, or the closer belongs to a construct
        // that is not there. Only end of file closes a chunk, so it is reported
        // and stepped over rather than taken as the end of the run.
        switch ((try parser.peek()).kind) {
            .end, .@"else", .elseif, .until => {
                const stray = try parser.next();
                try parser.report(.{
                    .kind = .unexpected_token,
                    .span = stray.span,
                    .found = stray.kind,
                });
                continue;
            },
            else => {},
        }

        const statement = Statement.parseStatement(parser) catch |err| switch (err) {
            error.OutOfMemory, error.ReportFailed => return err,
            error.ParserFailed => {
                try synchronize(parser);
                continue;
            },
        } orelse break;

        try statements.append(parser.allocator(), statement);
    }

    return .{
        .span = .{
            .start = start,
            .end = @intCast(parser.lexer.current_char_idx),
        },
        .statements = try statements.toOwnedSlice(parser.allocator()),
        .ret_statement = ret_statement,
    };
}

// skips the rest of a statement that failed to parse, stopping as soon as
// something that can begin a statement or close a block is next, without
// consuming it. Anything else is consumed.
pub fn synchronize(parser: *Parser) Parser.Error!void {
    while (true) {
        switch ((try parser.peek()).kind) {
            // nothing left to resynchronize on
            .eof => return,

            // an explicit statement end, or the end of the enclosing block
            .semicolon, .end, .@"else", .elseif, .until => return,

            // starts of every statement that is not a block of its own
            .ident,
            .colon2,
            .local,
            .do,
            .@"while",
            .repeat,
            .@"if",
            .@"for",
            .function,
            .@"return",
            .@"break",
            .goto,
            .lparen,
            => return,

            else => {},
        }

        _ = try parser.next();
    }
}
test "a block collects its statements in order" {
    var t = Parser.Test.init();
    defer t.deinit();

    // every `;` is kept as an empty statement of its own, so whatever built the tree
    // can put the source back the way it found it
    const chunk = try t.parse("local a = 1; local b = 2; a = b;");
    try t.expectClean();

    const statements = chunk.block.statements;
    try std.testing.expectEqual(@as(usize, 6), statements.len);
    try std.testing.expectEqual(std.meta.Tag(Ast.Statement).local_declaration, std.meta.activeTag(statements[0]));
    try std.testing.expectEqual(std.meta.Tag(Ast.Statement).empty, std.meta.activeTag(statements[1]));
    try std.testing.expectEqual(std.meta.Tag(Ast.Statement).local_declaration, std.meta.activeTag(statements[2]));
    try std.testing.expectEqual(std.meta.Tag(Ast.Statement).empty, std.meta.activeTag(statements[3]));
    try std.testing.expectEqual(std.meta.Tag(Ast.Statement).assignment, std.meta.activeTag(statements[4]));
    try std.testing.expectEqual(std.meta.Tag(Ast.Statement).empty, std.meta.activeTag(statements[5]));
    try std.testing.expect(chunk.block.ret_statement == null);
}

test "the block span runs from its first statement to the last" {
    var t = Parser.Test.init();
    defer t.deinit();

    const chunk = try t.parse("  local a = 1  ");
    try t.expectClean();

    // the block starts where it was opened, trailing whitespace included. The chunk
    // covers the whole source around it.
    try std.testing.expectEqual(@as(u32, 0), chunk.block.span.start);
    try std.testing.expectEqual(@as(u32, 13), chunk.block.span.end);
    try std.testing.expectEqual(@as(u32, 0), chunk.span.start);
    try std.testing.expectEqual(@as(u32, 15), chunk.span.end);
}

test "an empty block has no statements" {
    var t = Parser.Test.init();
    defer t.deinit();

    _ = try t.parse("");
    _ = try t.parse("   \n\t-- just a comment\n");
    try t.expectClean();
}

test "return belongs to the block rather than to its statements" {
    var t = Parser.Test.init();
    defer t.deinit();

    const chunk = try t.parse("local x = 1 return x");
    try t.expectClean();

    try std.testing.expectEqual(@as(usize, 1), chunk.block.statements.len);
    try std.testing.expect(chunk.block.ret_statement != null);
    try std.testing.expectEqual(@as(usize, 1), chunk.block.ret_statement.?.expressions.len);

    // with nothing to send, and with a semicolon after it
    const bare = try t.parse("function f() return end");
    const body = switch (bare.block.statements[0]) {
        .function_definition => |node| node.body,
        else => return error.NotAFunction,
    };
    try std.testing.expectEqual(@as(usize, 0), body.block.ret_statement.?.expressions.len);
    try std.testing.expect(body.block.ret_statement.?.semicolon_span == null);

    const semicolon = try t.parse("function f() return; end");
    const semicolon_body = switch (semicolon.block.statements[0]) {
        .function_definition => |node| node.body,
        else => return error.NotAFunction,
    };
    try std.testing.expect(semicolon_body.block.ret_statement.?.semicolon_span != null);
    try t.expectClean();
}

test "return sends a whole expression list" {
    var t = Parser.Test.init();
    defer t.deinit();

    const chunk = try t.parse("return 1, 2, 3");
    try t.expectClean();

    try std.testing.expectEqual(@as(usize, 3), chunk.block.ret_statement.?.expressions.len);
}

test "a statement after return is reported once and the block carries on" {
    var t = Parser.Test.init();
    defer t.deinit();

    const chunk = try t.parse("return 1 local x = 2 local y = 3");
    try t.expectKind(0, .statement_after_return);

    // recovery keeps going rather than treating the rest of the block as lost
    try std.testing.expectEqual(@as(usize, 2), chunk.block.statements.len);
    try std.testing.expectEqual(@as(usize, 1), t.errors().len);
}

test "a broken statement does not take the block with it" {
    var t = Parser.Test.init();
    defer t.deinit();

    // the `if` never gets its `end`, and the statements behind it still parse
    const chunk = try t.parse("local a = 1 if a then local b = 2 local c = 3");
    try t.expectKind(0, .expected_token);

    try std.testing.expectEqual(@as(usize, 1), t.errors().len);
    try std.testing.expectEqual(
        std.meta.Tag(Ast.Statement).local_declaration,
        std.meta.activeTag(chunk.block.statements[0]),
    );
}

test "recovery stops at the next statement" {
    var t = Parser.Test.init();
    defer t.deinit();

    // the right hand side of the first declaration is a `local`, which no expression
    // can start with, and the `local b = 2` behind it is a statement of its own
    // rather than a continuation of the broken one
    const chunk = try t.parse("local a = local b = 2");
    try t.expectKind(0, .expected_token);
    try t.expectExpected(0, .expression);
    try std.testing.expectEqual(@as(usize, 1), t.errors().len);

    try std.testing.expectEqual(@as(usize, 1), chunk.block.statements.len);
    try std.testing.expectEqual(
        std.meta.Tag(Ast.Statement).local_declaration,
        std.meta.activeTag(chunk.block.statements[0]),
    );
    try std.testing.expectEqualStrings("b", chunk.block.statements[0].local_declaration.names[0].name.name);
}

test "recovery inside a nested block leaves the outer one alone" {
    var t = Parser.Test.init();
    defer t.deinit();

    const chunk = try t.parse("do local a = 1 end local b = 2 local c = 3");
    try t.expectClean();

    try std.testing.expectEqual(@as(usize, 3), chunk.block.statements.len);
}

test "an unterminated block still reports where it stopped" {
    var t = Parser.Test.init();
    defer t.deinit();

    _ = try t.parse("if x then do");
    try t.expectKind(0, .expected_token);

    // both unclosed blocks report once, and neither invents a different kind
    // on the way out
    try std.testing.expectEqual(@as(usize, 2), t.errors().len);
    try t.expectKind(1, .expected_token);
}

test "synchronize always makes progress" {
    var t = Parser.Test.init();
    defer t.deinit();

    // nothing here can begin a statement, so synchronization runs to the end of the
    // source. The run has to terminate, and it has to have said something.
    const chunk = try t.parse("= = = = 1");
    try std.testing.expect(t.errors().len != 0);
    try std.testing.expectEqual(@as(usize, 0), chunk.block.statements.len);
}

test "a lexer failure and a syntax failure are reported in one pass" {
    var t = Parser.Test.init();
    defer t.deinit();

    // the lexer rejects `3a` and steps past it, which happens to leave the
    // next statement intact, so one diagnostic covers the whole run
    const chunk = try t.parse("local x = 3a local y = 2");

    try t.expectKind(0, .malformed_number);
    try std.testing.expectEqual(@as(usize, 1), t.errors().len);
    try std.testing.expectEqual(@as(usize, 2), chunk.block.statements.len);
    try std.testing.expectEqualStrings("y", chunk.block.statements[1].local_declaration.names[0].name.name);
}
