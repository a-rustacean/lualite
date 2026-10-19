const std = @import("std");

const Parser = @import("../Parser.zig");
const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");

const Block = @import("Block.zig");

// `function Name {'.' Name} [':' Name] body`, which binds a name in the
// enclosing scope
pub fn parseFunctionDefinition(parser: *Parser, function_span: Token.Span) Parser.Error!*Ast.FunctionDefinition {
    const name = try parseFunctionName(parser);
    var body = try parseFunctionBody(parser, .function, function_span);
    if (name.method) |method| {
        const parameters = parser.allocator().alloc(Ast.Parameter, body.parameters.len + 1) catch return error.OutOfMemory;
        parameters[0] = .{ .span = method.span, .name = .{ .span = method.span, .name = "self" } };
        @memcpy(parameters[1..], body.parameters);
        body.parameters = parameters;
    }

    return parser.box(Ast.FunctionDefinition, .{
        .span = Token.merge(function_span, body.span),
        .function_span = function_span,
        .name = name,
        .body = body,
    });
}

// `local function Name body`, which unlike `function Name` binds the name before
// the body is parsed, so it can call itself
pub fn parseLocalFunctionDefinition(
    parser: *Parser,
    local_span: Token.Span,
    function_span: Token.Span,
) Parser.Error!*Ast.LocalFunctionDefinition {
    const name = try parser.expectIdent();

    // `local function` is opened by the pair of them, so a missing `end` names
    // the whole phrase and points back at the `local`
    const body = try parseFunctionBodyOpening(parser, .local, local_span, "local function");

    return parser.box(Ast.LocalFunctionDefinition, .{
        .span = Token.merge(local_span, body.span),
        .local_span = local_span,
        .function_span = function_span,
        .name = name,
        .body = body,
    });
}

// `function body`, the anonymous form
pub fn parseFunctionExpression(parser: *Parser, function_span: Token.Span) Parser.Error!Ast.FunctionExpression {
    const body = try parseFunctionBody(parser, .function, function_span);

    return .{
        .span = Token.merge(function_span, body.span),
        .function_span = function_span,
        .body = body,
    };
}

// `( ... ) block end`, shared by all three forms
pub fn parseFunctionBody(parser: *Parser, keyword: Token.Kind, keyword_span: Token.Span) Parser.Error!Ast.FunctionBody {
    return parseFunctionBodyOpening(parser, keyword, keyword_span, null);
}

// the same, for the form whose opening keyword does not name it well. `local
// function` is opened by two words, not one.
pub fn parseFunctionBodyOpening(
    parser: *Parser,
    keyword: Token.Kind,
    keyword_span: Token.Span,
    phrase: ?[]const u8,
) Parser.Error!Ast.FunctionBody {
    const blocks = parser.blockMark();
    parser.pushBlockPhrase(keyword, keyword_span, phrase);
    // expect(.end) pops the block it closes, so this covers the paths that fail
    // before reaching it and nothing else. A plain defer would pop twice.
    errdefer parser.unwindBlocks(blocks);

    const open = try parser.expect(.lparen);
    const parameters = try parseParameters(parser);
    const block = try Block.parseBlock(parser, &Block.block_ends);
    const end = try parser.expect(.end);

    return .{
        .span = Token.merge(open.span, end.span),
        .open_paren_span = open.span,
        .parameters = parameters.names,
        .vararg = parameters.vararg,
        .close_paren_span = parameters.close_paren_span,
        .block = block,
        .end_span = end.span,
    };
}

// `Name {'.' Name} [':' Name]`. The method is a parameter of the function it
// names, so `function a:b()` declares both `a` and the hidden `self`.
fn parseFunctionName(parser: *Parser) Parser.Error!Ast.FunctionName {
    var fields: std.ArrayList(Ast.Identifier) = .empty;
    errdefer fields.deinit(parser.allocator());

    const first = try parser.expectIdent();

    while (try parser.eat(.dot)) {
        try fields.append(parser.allocator(), try parser.expectIdent());
    }

    var colon_span: ?Token.Span = null;
    var method: ?Ast.Identifier = null;

    if (try parser.check(.colon)) {
        colon_span = (try parser.next()).span;
        method = try parser.expectIdent();
    }

    return .{
        .span = if (method) |m| Token.merge(first.span, m.span) else if (fields.items.len == 0)
            first.span
        else
            fields.items[fields.items.len - 1].span,
        .first = first,
        .fields = try fields.toOwnedSlice(parser.allocator()),
        .colon_span = colon_span,
        .method = method,
    };
}

// `<const>` or `<close>`, the attributes a local can carry
pub fn parseAttribute(parser: *Parser) Parser.Error!Ast.Attribute {
    const open = try parser.expect(.langle);
    const name = try parser.expectIdent();
    const close = try parser.expect(.rangle);

    return .{
        .span = Token.merge(open.span, close.span),
        .open_span = open.span,
        .name = name,
        .close_span = close.span,
    };
}

const Parameters = struct {
    names: []Ast.Parameter,
    vararg: ?Ast.VarargParameter,
    close_paren_span: Token.Span,
};

// `[namelist [',' '...'] | '...']`, closing on the `)` so the body knows where
// the parameter list ended
fn parseParameters(parser: *Parser) Parser.Error!Parameters {
    const allocator = parser.allocator();

    var names: std.ArrayList(Ast.Parameter) = .empty;
    errdefer names.deinit(allocator);

    var vararg: ?Ast.VarargParameter = null;

    // `()`
    if (try parser.check(.rparen)) {
        const close = try parser.next();
        return .{
            .names = try names.toOwnedSlice(allocator),
            .vararg = null,
            .close_paren_span = close.span,
        };
    }

    // `(...)`
    if (try parser.check(.dot3)) {
        const dots = try parser.next();
        const close = try parser.expect(.rparen);
        vararg = .{ .span = dots.span, .dots_span = dots.span };

        return .{
            .names = try names.toOwnedSlice(allocator),
            .vararg = vararg,
            .close_paren_span = close.span,
        };
    }

    while (true) {
        const name = try parser.expectIdent();
        try names.append(allocator, .{ .span = name.span, .name = name });

        if (!try parser.eat(.comma)) break;

        // `(a, ...)`: the vararg can only come last
        if (try parser.check(.dot3)) {
            const dots = try parser.next();
            vararg = .{ .span = dots.span, .dots_span = dots.span };
            break;
        }
    }

    const close = try parser.expect(.rparen);

    return .{
        .names = try names.toOwnedSlice(allocator),
        .vararg = vararg,
        .close_paren_span = close.span,
    };
}
// the body of a function definition, only valid while the arena the caller
// handed over is alive, hence Test as an argument rather than one built here
fn parseBody(t: *Parser.Test, source: []const u8) !Ast.FunctionBody {
    const statement = try t.parseStatement(source);
    try t.expectClean();

    return switch (statement) {
        .function_definition => |node| node.body,
        else => error.NotAFunctionDefinition,
    };
}

test "an empty parameter list" {
    var t = Parser.Test.init();
    defer t.deinit();

    const body = try parseBody(&t, "function f() end");

    try std.testing.expectEqual(@as(usize, 0), body.parameters.len);
    try std.testing.expect(body.vararg == null);
    try std.testing.expectEqual(@as(u32, 10), body.open_paren_span.start);
    try std.testing.expectEqual(@as(u32, 11), body.close_paren_span.start);
    try std.testing.expectEqual(@as(u32, 13), body.end_span.start);
}

test "a named parameter list" {
    var t = Parser.Test.init();
    defer t.deinit();

    const body = try parseBody(&t, "function f(a, b, c) end");

    try std.testing.expectEqual(@as(usize, 3), body.parameters.len);
    try std.testing.expectEqualStrings("a", body.parameters[0].name.name);
    try std.testing.expectEqualStrings("c", body.parameters[2].name.name);
    try std.testing.expect(body.vararg == null);
}

test "a vararg can stand alone or close the list" {
    var t = Parser.Test.init();
    defer t.deinit();

    const alone = try parseBody(&t, "function f(...) end");
    try std.testing.expectEqual(@as(usize, 0), alone.parameters.len);
    try std.testing.expectEqual(@as(u32, 11), alone.vararg.?.dots_span.start);
    try std.testing.expectEqual(@as(u32, 14), alone.vararg.?.span.end);

    const trailing = try parseBody(&t, "function f(a, b, ...) end");
    try std.testing.expectEqual(@as(usize, 2), trailing.parameters.len);
    try std.testing.expect(trailing.vararg != null);
    try std.testing.expectEqual(@as(u32, 17), trailing.vararg.?.dots_span.start);
}

test "the body span covers the parentheses and the end" {
    var t = Parser.Test.init();
    defer t.deinit();

    const body = try parseBody(&t, "function f(a) return a end");

    try std.testing.expectEqual(@as(u32, 10), body.span.start);
    try std.testing.expectEqual(@as(u32, 26), body.span.end);
    try std.testing.expectEqual(body.span.start, body.open_paren_span.start);
    try std.testing.expectEqual(body.span.end, body.end_span.end);
}

test "a body holds its own block" {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement("function f() local x = 1 return x end");
    try t.expectClean();

    const body = switch (statement) {
        .function_definition => |node| node.body,
        else => return error.NotAFunctionDefinition,
    };

    try std.testing.expectEqual(@as(usize, 1), body.block.statements.len);
    try std.testing.expect(body.block.ret_statement != null);
}

test "a function expression is anonymous" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("function(x) return x end");
    try t.expectClean();

    const function_expression = switch (expr) {
        .function => |node| node,
        else => return error.NotAFunctionExpression,
    };

    try std.testing.expectEqual(@as(usize, 1), function_expression.body.parameters.len);
    try std.testing.expectEqual(@as(u32, 7), function_expression.function_span.start);
}

test "an attribute is a bracketed name" {
    const attribute = try parseAttributeForTest("<const>");

    try std.testing.expectEqualStrings("const", attribute.name.name);
    try std.testing.expectEqual(@as(u32, 0), attribute.open_span.start);
    try std.testing.expectEqual(@as(u32, 1), attribute.name.span.start);
    try std.testing.expectEqual(@as(u32, 6), attribute.close_span.start);
    try std.testing.expectEqual(@as(u32, 7), attribute.span.end);
}

fn parseAttributeForTest(source: []const u8) !Ast.Attribute {
    var t = Parser.Test.init();
    defer t.deinit();

    var parser = Parser.fromSource(source, &t.arena, &t.reporter);
    const attribute = try parseAttribute(&parser);
    try t.expectClean();

    return attribute;
}

test "an attribute that is not a name is refused" {
    var t = Parser.Test.init();
    defer t.deinit();

    var parser = Parser.fromSource("<1>", &t.arena, &t.reporter);
    try std.testing.expectError(error.ParserFailed, parseAttribute(&parser));
    try t.expectKind(0, .expected_token);
}
