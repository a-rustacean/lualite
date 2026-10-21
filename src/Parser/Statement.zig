const std = @import("std");

const Parser = @import("../Parser.zig");
const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");
const Diagnostic = @import("../Diagnostic.zig");

const Block = @import("Block.zig");
const Expression = @import("Expression.zig");
const Function = @import("Function.zig");

// one statement, or null at a token that ends the block instead. parseBlock
// stops on those before it gets here, so the null is a backstop.
pub fn parseStatement(parser: *Parser) Parser.Error!?Ast.Statement {
    const token = try parser.peek();

    // the block that owns these consumes them
    switch (token.kind) {
        .end, .@"else", .elseif, .until, .eof => return null,
        else => {},
    }

    // every form starts with a token of its own, so it is consumed here and
    // handed over rather than left for the form to reach past
    _ = try parser.next();

    return switch (token.kind) {
        .semicolon => .{ .empty = try parser.box(Ast.EmptyStatement, .{ .span = token.span }) },
        .local => try parseLocal(parser, token),
        .@"if" => try parseIf(parser, token),
        .@"while" => try parseWhile(parser, token),
        .repeat => try parseRepeat(parser, token),
        .@"for" => try parseFor(parser, token),
        .do => try parseDo(parser, token),
        .function => .{ .function_definition = try Function.parseFunctionDefinition(parser, token.span) },
        .@"break" => .{ .@"break" = try parser.box(Ast.BreakStatement, .{
            .span = token.span,
            .break_span = token.span,
        }) },
        .goto => try parseGoto(parser, token),
        .colon2 => try parseLabel(parser, token),
        .ident, .lparen => try parseAssignmentOrCall(parser, token),

        else => parser.fail(.expected_token, token, .statement),
    };
}

// return belongs to the block rather than to its statement list, since it has
// to be the last thing in there, so Block is the one that asks for it
pub fn parseReturn(parser: *Parser) Parser.Error!Ast.RetStatement {
    const return_token = try parser.expect(.@"return");

    // `return` on its own, and `return;`, both come back with nothing to send
    var expressions: []Ast.Expression = &.{};
    if (!try parser.check(.semicolon) and !try parser.atBlockEnd(&Block.block_ends)) {
        expressions = try parser.parseExpressionList();
    }

    const semicolon = if (try parser.check(.semicolon)) try parser.next() else null;

    const last_span = if (semicolon) |token|
        token.span
    else if (expressions.len == 0)
        return_token.span
    else
        Expression.spanOf(expressions[expressions.len - 1]);

    return .{
        .span = Token.merge(return_token.span, last_span),
        .return_span = return_token.span,
        .expressions = expressions,
        .semicolon_span = if (semicolon) |token| token.span else null,
    };
}

// `local Name {'<' Name '>'} {',' Name {'<' Name '>'}} ['=' explist]` and
// `local function Name body`, which share their first keyword
fn parseLocal(parser: *Parser, local: Token) Parser.Error!Ast.Statement {
    if (try parser.check(.function)) {
        const function_token = try parser.next();
        return .{ .local_function_definition = try Function.parseLocalFunctionDefinition(parser, local.span, function_token.span) };
    }

    const allocator = parser.allocator();

    var names: std.ArrayList(Ast.LocalName) = .empty;
    errdefer names.deinit(allocator);

    // the last name, and only the last name. A declaration runs on past it to
    // whatever was assigned, so this is not where the whole statement ends.
    var last_name_span = local.span;

    while (true) {
        const name = try parser.expectIdent();

        var attribute: ?Ast.Attribute = null;
        if (try parser.check(.langle)) attribute = try Function.parseAttribute(parser);

        last_name_span = if (attribute) |value| Token.merge(name.span, value.span) else name.span;
        try names.append(allocator, .{ .span = last_name_span, .name = name, .attribute = attribute });

        if (!try parser.eat(.comma)) break;
    }

    const equals = if (try parser.check(.eq)) try parser.next() else null;
    const expressions = if (equals != null)
        try parser.parseExpressionList()
    else
        try allocator.alloc(Ast.Expression, 0);

    // as for every other statement, the span runs from the first token of the
    // construct to the last, so it can be pointed at as one piece
    const last_span = if (expressions.len == 0)
        last_name_span
    else
        Expression.spanOf(expressions[expressions.len - 1]);

    return .{ .local_declaration = try parser.box(Ast.LocalDeclaration, .{
        .span = Token.merge(local.span, last_span),
        .local_span = local.span,
        .names = try names.toOwnedSlice(allocator),
        .equals_span = if (equals) |token| token.span else null,
        .expressions = expressions,
    }) };
}

fn parseIf(parser: *Parser, if_token: Token) Parser.Error!Ast.Statement {
    const blocks = parser.blockMark();
    parser.pushBlock(.@"if", if_token.span);
    errdefer parser.unwindBlocks(blocks);

    const allocator = parser.allocator();

    const condition = try parser.parseExpression();
    const then_token = try parser.expect(.then);
    // every closer ends the run of statements, the way `block_follow(ls, 1)`
    // stops the reference's `statlist` on all of them; the construct's own
    // `expect` is the one that words a mismatch as its missing closer
    const block = try Block.parseBlock(parser, &Block.block_ends);

    var elseif_clauses: std.ArrayList(Ast.ElseIfClause) = .empty;
    errdefer elseif_clauses.deinit(allocator);

    while ((try parser.peek()).kind == .elseif) {
        const elseif_token = try parser.next();
        const clause_condition = try parser.parseExpression();
        const clause_then = try parser.expect(.then);
        const clause_block = try Block.parseBlock(parser, &Block.block_ends);

        try elseif_clauses.append(allocator, .{
            .span = Token.merge(elseif_token.span, clause_block.span),
            .elseif_span = elseif_token.span,
            .condition = clause_condition,
            .then_span = clause_then.span,
            .block = clause_block,
        });
    }

    var else_clause: ?Ast.ElseClause = null;
    if ((try parser.peek()).kind == .@"else") {
        const else_token = try parser.next();
        const else_block = try Block.parseBlock(parser, &Block.block_ends);

        else_clause = .{
            .span = Token.merge(else_token.span, else_block.span),
            .else_span = else_token.span,
            .block = else_block,
        };
    }

    const end = try parser.expect(.end);

    return .{ .@"if" = try parser.box(Ast.IfStatement, .{
        .span = Token.merge(if_token.span, end.span),
        .if_span = if_token.span,
        .condition = condition,
        .then_span = then_token.span,
        .block = block,
        .elseif_clauses = try elseif_clauses.toOwnedSlice(allocator),
        .else_clause = else_clause,
        .end_span = end.span,
    }) };
}

fn parseWhile(parser: *Parser, while_token: Token) Parser.Error!Ast.Statement {
    const blocks = parser.blockMark();
    parser.pushBlock(.@"while", while_token.span);
    errdefer parser.unwindBlocks(blocks);

    const condition = try parser.parseExpression();
    const do_token = try parser.expect(.do);
    const block = try Block.parseBlock(parser, &Block.block_ends);
    const end = try parser.expect(.end);

    return .{ .@"while" = try parser.box(Ast.WhileStatement, .{
        .span = Token.merge(while_token.span, end.span),
        .while_span = while_token.span,
        .condition = condition,
        .do_span = do_token.span,
        .block = block,
        .end_span = end.span,
    }) };
}

// `repeat block until condition`, where the condition sits outside the block
// and can see everything the block declared
fn parseRepeat(parser: *Parser, repeat_token: Token) Parser.Error!Ast.Statement {
    const blocks = parser.blockMark();
    parser.pushBlock(.repeat, repeat_token.span);
    errdefer parser.unwindBlocks(blocks);

    // every closer ends the run of statements; the `until` below is the one
    // that words a mismatch
    const block = try Block.parseBlock(parser, &Block.block_ends);
    const until_token = try parser.expect(.until);
    const condition = try parser.parseExpression();

    return .{ .repeat = try parser.box(Ast.RepeatStatement, .{
        .span = Token.merge(repeat_token.span, Expression.spanOf(condition)),
        .repeat_span = repeat_token.span,
        .block = block,
        .until_span = until_token.span,
        .condition = condition,
    }) };
}

fn parseDo(parser: *Parser, do_token: Token) Parser.Error!Ast.Statement {
    const blocks = parser.blockMark();
    parser.pushBlock(.do, do_token.span);
    errdefer parser.unwindBlocks(blocks);

    const block = try Block.parseBlock(parser, &Block.block_ends);
    const end = try parser.expect(.end);

    return .{ .do = try parser.box(Ast.DoStatement, .{
        .span = Token.merge(do_token.span, end.span),
        .do_span = do_token.span,
        .block = block,
        .end_span = end.span,
    }) };
}

// `for Name '=' exp ',' exp [',' exp] do block end` and
// `for namelist in explist do block end`, which the `=` or the `in` after the
// first name tells apart
fn parseFor(parser: *Parser, for_token: Token) Parser.Error!Ast.Statement {
    const first = try parser.expectIdent();

    if (try parser.check(.eq)) return parseNumericFor(parser, for_token, first);
    return parseGenericFor(parser, for_token, first);
}

fn parseNumericFor(parser: *Parser, for_token: Token, name: Ast.Identifier) Parser.Error!Ast.Statement {
    const blocks = parser.blockMark();
    parser.pushBlock(.@"for", for_token.span);
    errdefer parser.unwindBlocks(blocks);

    const equals = try parser.expect(.eq);
    const initial = try parser.parseExpression();
    const first_comma = try parser.expect(.comma);
    const limit = try parser.parseExpression();

    const second_comma = if (try parser.check(.comma)) try parser.next() else null;
    const step = if (second_comma != null) try parser.parseExpression() else null;

    const do_token = try parser.expect(.do);
    const block = try Block.parseBlock(parser, &Block.block_ends);
    const end = try parser.expect(.end);

    return .{ .numeric_for = try parser.box(Ast.ForStatement, .{
        .span = Token.merge(for_token.span, end.span),
        .for_span = for_token.span,
        .name = name,
        .equals_span = equals.span,
        .initial = initial,
        .first_comma_span = first_comma.span,
        .limit = limit,
        .second_comma_span = if (second_comma) |token| token.span else null,
        .step = step,
        .do_span = do_token.span,
        .block = block,
        .end_span = end.span,
    }) };
}

fn parseGenericFor(parser: *Parser, for_token: Token, first: Ast.Identifier) Parser.Error!Ast.Statement {
    const blocks = parser.blockMark();
    parser.pushBlock(.@"for", for_token.span);
    errdefer parser.unwindBlocks(blocks);

    const allocator = parser.allocator();

    var names: std.ArrayList(Ast.Identifier) = .empty;
    errdefer names.deinit(allocator);

    try names.append(allocator, first);
    while (try parser.eat(.comma)) {
        try names.append(allocator, try parser.expectIdent());
    }

    const in_token = try parser.expect(.in);
    const expressions = try parser.parseExpressionList();

    const do_token = try parser.expect(.do);
    const block = try Block.parseBlock(parser, &Block.block_ends);
    const end = try parser.expect(.end);

    return .{ .generic_for = try parser.box(Ast.ForInStatement, .{
        .span = Token.merge(for_token.span, end.span),
        .for_span = for_token.span,
        .names = try names.toOwnedSlice(allocator),
        .in_span = in_token.span,
        .expressions = expressions,
        .do_span = do_token.span,
        .block = block,
        .end_span = end.span,
    }) };
}

fn parseGoto(parser: *Parser, goto_token: Token) Parser.Error!Ast.Statement {
    const name = try parser.expectIdent();

    return .{ .goto = try parser.box(Ast.GotoStatement, .{
        .span = Token.merge(goto_token.span, name.span),
        .goto_span = goto_token.span,
        .name = name,
    }) };
}

fn parseLabel(parser: *Parser, open: Token) Parser.Error!Ast.Statement {
    const name = try parser.expectIdent();
    const close = try parser.expect(.colon2);

    // `labelstat` in lparser.c stops on the token after the closing `::` —
    // skipping any `;` or `::` statements behind it — and its refusals name
    // that line. One peek is the same token wherever a run of no-ops is not
    // in the way, which is nearly always
    const after = try parser.peek();

    return .{ .label = try parser.box(Ast.Label, .{
        .span = Token.merge(open.span, close.span),
        .open_span = open.span,
        .name = name,
        .close_span = close.span,
        .after_span = after.span,
    }) };
}

// either `suffixedexp '=' explist` or a call, the only two things a statement
// starting with a name or a `(` can be. Both are decided by the one token
// after the expression, which is why it is parsed once and only looked at later.
fn parseAssignmentOrCall(parser: *Parser, first: Token) Parser.Error!Ast.Statement {
    const expr = try parser.parseSuffixedAfter(first);

    if (!try parser.check(.eq) and !try parser.check(.comma)) {
        return .{ .function_call = try expectCall(parser, expr) };
    }

    const allocator = parser.allocator();

    var variables: std.ArrayList(Ast.Variable) = .empty;
    errdefer variables.deinit(allocator);

    const first_span = Expression.spanOf(expr);
    try variables.append(allocator, try parser.toVariable(expr));

    while (try parser.eat(.comma)) {
        const target = try parser.parseSuffixed();
        try variables.append(allocator, try parser.toVariable(target));
    }

    const equals = try parser.expect(.eq);
    const expressions = try parser.parseExpressionList();

    return .{ .assignment = try parser.box(Ast.AssignmentStatement, .{
        .span = Token.merge(
            first_span,
            if (expressions.len == 0) equals.span else Expression.spanOf(expressions[expressions.len - 1]),
        ),
        .variables = try variables.toOwnedSlice(allocator),
        .equals_span = equals.span,
        .expressions = expressions,
    }) };
}

// anything that is not an assignment has to be a call. exprstat in lparser.c
// insists the last thing read was an argument list, and a name, a field or an
// index on its own never is one, so `print` and `a.b` are syntax errors.
fn expectCall(parser: *Parser, expr: Ast.Expression) Parser.Error!*Ast.FunctionCall {
    const span = Expression.spanOf(expr);

    return switch (expr) {
        .function_call => |call| call,
        else => {
            // `exprstat` in lparser.c insists on a VCALL, and the `near` a
            // message carries is the token the parser stopped on rather than
            // any part of the expression
            const stopped = try parser.peek();
            parser.report(.{
                .kind = .unexpected_token,
                .span = span,
                .stopped = stopped,
            }) catch return error.ReportFailed;
            return error.ParserFailed;
        },
    };
}
fn expectStatement(source: []const u8, expected: std.meta.Tag(Ast.Statement)) !void {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement(source);
    try t.expectClean();

    try std.testing.expectEqual(expected, std.meta.activeTag(statement));
}

// the diagnostic source produces. Recovery can report a broken statement more
// than once, so the first one is the one that matters.
fn expectRejected(source: []const u8, kind: Diagnostic.Error.Kind) !void {
    var t = Parser.Test.init();
    defer t.deinit();

    _ = t.parseStatement(source) catch {};
    try t.expectKind(0, kind);
}

test "an empty statement" {
    try expectStatement(";", .empty);
}

test "a local declaration" {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement("local x");
    try t.expectClean();

    const declaration = switch (statement) {
        .local_declaration => |node| node,
        else => return error.NotALocalDeclaration,
    };

    try std.testing.expectEqual(@as(usize, 1), declaration.names.len);
    try std.testing.expectEqualStrings("x", declaration.names[0].name.name);
    try std.testing.expect(declaration.names[0].attribute == null);
    try std.testing.expect(declaration.equals_span == null);
    try std.testing.expectEqual(@as(usize, 0), declaration.expressions.len);

    const many = try t.parseStatement("local a, b = 1, 2");
    const pair = switch (many) {
        .local_declaration => |node| node,
        else => return error.NotALocalDeclaration,
    };
    try std.testing.expectEqual(@as(usize, 2), pair.names.len);
    try std.testing.expectEqual(@as(usize, 2), pair.expressions.len);
    try std.testing.expect(pair.equals_span != null);
}

test "a local declaration carries attributes" {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement("local x <const>, y <close> = 1");
    try t.expectClean();

    const declaration = switch (statement) {
        .local_declaration => |node| node,
        else => return error.NotALocalDeclaration,
    };

    try std.testing.expectEqualStrings("const", declaration.names[0].attribute.?.name.name);
    try std.testing.expectEqual(@as(u32, 8), declaration.names[0].attribute.?.open_span.start);
    try std.testing.expectEqualStrings("close", declaration.names[1].attribute.?.name.name);
    try std.testing.expectEqual(@as(u32, 26), declaration.names[1].span.end);
}

test "a local function binds its name before the body" {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement("local function f(x) return x end");
    try t.expectClean();

    const definition = switch (statement) {
        .local_function_definition => |node| node,
        else => return error.NotALocalFunction,
    };

    try std.testing.expectEqualStrings("f", definition.name.name);
    try std.testing.expectEqual(@as(usize, 1), definition.body.parameters.len);
    try std.testing.expectEqualStrings("x", definition.body.parameters[0].name.name);
    try std.testing.expect(definition.body.vararg == null);
    try std.testing.expectEqualStrings("x", definition.body.block.ret_statement.?.expressions[0].variable.name.name);
}

test "a function definition names what it binds" {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement("function a.b.c:d() end");
    try t.expectClean();

    const definition = switch (statement) {
        .function_definition => |node| node,
        else => return error.NotAFunctionDefinition,
    };

    try std.testing.expectEqualStrings("a", definition.name.first.name);
    try std.testing.expectEqual(@as(usize, 2), definition.name.fields.len);
    try std.testing.expectEqualStrings("b", definition.name.fields[0].name);
    try std.testing.expectEqualStrings("c", definition.name.fields[1].name);
    try std.testing.expectEqualStrings("d", definition.name.method.?.name);
    try std.testing.expectEqual(@as(u32, 14), definition.name.colon_span.?.start);
    // the method is a hidden parameter of the body
    try std.testing.expectEqual(@as(usize, 1), definition.body.parameters.len);
    try std.testing.expectEqualStrings("self", definition.body.parameters[0].name.name);
}

test "a function definition without a method" {
    try expectStatement("function f() end", .function_definition);
    try expectStatement("function a.b() end", .function_definition);
}

test "the block statements" {
    try expectStatement("do end", .do);
    try expectStatement("while x do end", .@"while");
    try expectStatement("repeat until x", .repeat);
    try expectStatement("if x then end", .@"if");
    try expectStatement("for i = 1, 2 do end", .numeric_for);
    try expectStatement("for k in pairs(t) do end", .generic_for);
    try expectStatement("for k, v in next, t do end", .generic_for);
}

test "an if takes elseif clauses and one else" {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement("if a then x() elseif b then y() elseif c then z() else w() end");
    try t.expectClean();

    const conditional = switch (statement) {
        .@"if" => |node| node,
        else => return error.NotAnIf,
    };

    try std.testing.expectEqual(@as(usize, 2), conditional.elseif_clauses.len);
    try std.testing.expectEqualStrings("b", conditional.elseif_clauses[0].condition.variable.name.name);
    try std.testing.expectEqualStrings("c", conditional.elseif_clauses[1].condition.variable.name.name);
    try std.testing.expect(conditional.else_clause != null);
    try std.testing.expectEqual(@as(usize, 1), conditional.block.statements.len);
    try std.testing.expectEqual(@as(usize, 1), conditional.elseif_clauses[0].block.statements.len);
    try std.testing.expectEqual(@as(usize, 1), conditional.else_clause.?.block.statements.len);

    const bare = try t.parseStatement("if a then end");
    const bare_if = switch (bare) {
        .@"if" => |node| node,
        else => return error.NotAnIf,
    };
    try std.testing.expectEqual(@as(usize, 0), bare_if.elseif_clauses.len);
    try std.testing.expect(bare_if.else_clause == null);
}

test "a repeat condition sits outside its block" {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement("repeat local x = 1 until x");
    try t.expectClean();

    const repeat = switch (statement) {
        .repeat => |node| node,
        else => return error.NotARepeat,
    };

    try std.testing.expectEqual(@as(usize, 1), repeat.block.statements.len);
    try std.testing.expectEqualStrings("x", repeat.condition.variable.name.name);
}

test "a numeric for takes an optional step" {
    var t = Parser.Test.init();
    defer t.deinit();

    const plain = switch (try t.parseStatement("for i = 1, 10 do end")) {
        .numeric_for => |node| node,
        else => return error.NotANumericFor,
    };
    try std.testing.expectEqualStrings("i", plain.name.name);
    try std.testing.expect(plain.second_comma_span == null);
    try std.testing.expect(plain.step == null);

    const stepped = switch (try t.parseStatement("for i = 10, 1, -1 do end")) {
        .numeric_for => |node| node,
        else => return error.NotANumericFor,
    };
    try std.testing.expect(stepped.second_comma_span != null);
    try std.testing.expectEqual(Ast.UnaryOperator.negation, stepped.step.?.unary.operator);
    try t.expectClean();
}

test "a generic for names what it iterates over" {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement("for k, v in next, t do end");
    try t.expectClean();

    const generic = switch (statement) {
        .generic_for => |node| node,
        else => return error.NotAGenericFor,
    };

    try std.testing.expectEqual(@as(usize, 2), generic.names.len);
    try std.testing.expectEqualStrings("k", generic.names[0].name);
    try std.testing.expectEqualStrings("v", generic.names[1].name);
    try std.testing.expectEqual(@as(usize, 2), generic.expressions.len);
}

test "break, goto and a label" {
    var t = Parser.Test.init();
    defer t.deinit();

    const break_statement = switch (try t.parseStatement("break")) {
        .@"break" => |node| node,
        else => return error.NotABreak,
    };
    try std.testing.expectEqual(break_statement.span.start, break_statement.break_span.start);

    const goto_statement = switch (try t.parseStatement("goto continue")) {
        .goto => |node| node,
        else => return error.NotAGoto,
    };
    try std.testing.expectEqualStrings("continue", goto_statement.name.name);
    try std.testing.expectEqual(@as(u32, 0), goto_statement.goto_span.start);

    const label = switch (try t.parseStatement("::continue::")) {
        .label => |node| node,
        else => return error.NotALabel,
    };
    try std.testing.expectEqualStrings("continue", label.name.name);
    try std.testing.expectEqual(@as(u32, 0), label.open_span.start);
    try std.testing.expectEqual(@as(u32, 12), label.close_span.end);
    try t.expectClean();
}

test "assignment takes as many targets as it is given" {
    var t = Parser.Test.init();
    defer t.deinit();

    const statement = try t.parseStatement("a, b.c, d[1] = 1, 2");
    try t.expectClean();

    const assignment = switch (statement) {
        .assignment => |node| node,
        else => return error.NotAnAssignment,
    };

    try std.testing.expectEqual(@as(usize, 3), assignment.variables.len);
    try std.testing.expectEqual(std.meta.Tag(Ast.Variable).name, std.meta.activeTag(assignment.variables[0]));
    try std.testing.expectEqual(std.meta.Tag(Ast.Variable).field, std.meta.activeTag(assignment.variables[1]));
    try std.testing.expectEqual(std.meta.Tag(Ast.Variable).index, std.meta.activeTag(assignment.variables[2]));
    try std.testing.expectEqual(@as(u32, 13), assignment.equals_span.start);
    try std.testing.expectEqual(@as(usize, 2), assignment.expressions.len);
}

test "a statement that is not an assignment is a call" {
    var t = Parser.Test.init();
    defer t.deinit();

    const call = switch (try t.parseStatement("f(1)")) {
        .function_call => |node| node,
        else => return error.NotACall,
    };
    try std.testing.expectEqualStrings("f", call.expression.variable.name.name);
    try std.testing.expect(call.method == null);
    try t.expectClean();
}

test "only a call can be a statement of its own" {
    // `exprstat` in lparser.c insists on a VCALL, which a name, a field or an
    // index never reaches: none of them has an argument list
    for ([_][]const u8{ "print", "a.b", "a[b]", "(a).b", "(a)" }) |source| {
        try expectRejected(source, .unexpected_token);
    }
}

test "a call keeps the method it was written with" {
    var t = Parser.Test.init();
    defer t.deinit();

    const call = switch (try t.parseStatement("a:b(1)")) {
        .function_call => |node| node,
        else => return error.NotACall,
    };

    try std.testing.expectEqualStrings("b", call.method.?.name);
    try std.testing.expectEqual(@as(u32, 1), call.colon_span.?.start);
    try std.testing.expectEqualStrings("a", call.expression.variable.name.name);
}

test "what cannot be assigned to" {
    try expectRejected("f() = 1", .invalid_assignment_target);
    try expectRejected("1 = x", .expected_token);
    try expectRejected("a, f() = 1, 2", .invalid_assignment_target);

    // anything can follow the comma, so each target is checked rather than assumed
    // to be a name or a `(`
    try expectRejected("a, 1 = 2", .expected_token);
    try expectRejected("a, \"x\" = 1, 2", .expected_token);
    try expectRejected("a, {1} = 1", .expected_token);

    // a parenthesized expression is a value, but the field hanging off it is
    // still a field, so only the parenthesized form on its own is refused
    try expectRejected("(a) = 1", .invalid_assignment_target);
    try expectStatement("(a).b = 1", .assignment);
}

test "what cannot start a statement" {
    for ([_][]const u8{ "= 1", "then", "]", ")", "and" }) |source| {
        try expectRejected(source, .expected_token);
    }
}

test "the tokens that close a block are not statements" {
    var t = Parser.Test.init();
    defer t.deinit();

    for ([_][]const u8{ "end", "else", "elseif", "until", "" }) |source| {
        var parser = Parser.fromSource(source, &t.arena, &t.reporter);
        try std.testing.expect((try parseStatement(&parser)) == null);
    }

    // and nothing is reported for them
    try t.expectClean();
}
