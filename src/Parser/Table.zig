const std = @import("std");

const Parser = @import("../Parser.zig");
const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");

const Expression = @import("Expression.zig");

// `{ ... }`, either as an expression or as the argument of a `f{ ... }` call
pub fn parseTableConstructor(parser: *Parser) Parser.Error!Ast.TableConstructor {
    // a constructor nests as deeply as the input likes
    try parser.enter();
    defer parser.leave();

    const allocator = parser.allocator();

    const open = try parser.expect(.lcurly);

    var fields: std.ArrayList(Ast.TableField) = .empty;
    errdefer fields.deinit(allocator);

    while (!try parser.check(.rcurly)) {
        if ((try parser.peek()).kind == .eof) {
            return parser.fail(.expected_token, try parser.peek(), .{ .token = .rcurly });
        }

        try fields.append(allocator, try parseField(parser));

        // a separator may be left off after the last field
        if (!try parser.eat(.comma) and !try parser.eat(.semicolon)) break;
    }

    const close = try parser.expect(.rcurly);

    return .{
        .span = Token.merge(open.span, close.span),
        .open_brace_span = open.span,
        .fields = try fields.toOwnedSlice(allocator),
        .close_brace_span = close.span,
    };
}

fn parseField(parser: *Parser) Parser.Error!Ast.TableField {
    switch ((try parser.peek()).kind) {
        // `[key] = value`
        .lbrack => {
            const open = try parser.next();
            const key = try parser.parseExpression();
            const close = try parser.expect(.rbrack);
            const equals = try parser.expect(.eq);
            const value = try parser.parseExpression();

            return .{ .indexed = .{
                .span = Token.merge(open.span, Expression.spanOf(value)),
                .open_bracket_span = open.span,
                .key = key,
                .close_bracket_span = close.span,
                .equals_span = equals.span,
                .value = value,
            } };
        },
        // `name = value`, or else a list item that happens to begin with a name.
        // field() in lparser.c tells the two apart by the `=` behind the name, and
        // peek is only a token deep, so the name is taken first and the rest of
        // the expression is read from wherever it turns out to lead.
        .ident => {
            const name_token = try parser.next();
            const name = parser.ident(name_token);

            if (try parser.check(.eq)) {
                const equals = try parser.next();
                const value = try parser.parseExpression();

                return .{ .named = .{
                    .span = Token.merge(name.span, Expression.spanOf(value)),
                    .name = name,
                    .equals_span = equals.span,
                    .value = value,
                } };
            }

            const variable = try parser.box(Ast.Variable, .{ .name = name });
            return listField(try Expression.parseAfter(parser, .{ .variable = variable }));
        },
        else => {},
    }

    // a list item is a whole expression, so `{ 1 }`, `{ f() }` and
    // `{ "x" .. y }` all parse as themselves
    return listField(try parser.parseExpression());
}

// a field with no name of its own, which is what everything in a constructor
// that is not `name = value` or `[key] = value` comes back as
fn listField(value: Ast.Expression) Ast.TableField {
    return .{ .expression = .{
        .span = Expression.spanOf(value),
        .expression = value,
    } };
}

// the constructor is only valid while the caller's arena is, so the harness is
// passed in rather than built here
fn parseTableWith(t: *Parser.Test, source: []const u8) !Ast.TableConstructor {
    const expr = try t.parseExpression(source);
    try t.expectClean();

    return switch (expr) {
        .table => |node| node.*,
        else => error.NotATable,
    };
}

test "an empty constructor" {
    var t = Parser.Test.init();
    defer t.deinit();

    const table = try parseTableWith(&t, "{}");

    try std.testing.expectEqual(@as(usize, 0), table.fields.len);
    try std.testing.expectEqual(@as(u32, 7), table.open_brace_span.start);
    try std.testing.expectEqual(@as(u32, 8), table.close_brace_span.start);
    try std.testing.expectEqual(@as(u32, 7), table.span.start);
    try std.testing.expectEqual(@as(u32, 9), table.span.end);
}

test "the three kinds of field" {
    var t = Parser.Test.init();
    defer t.deinit();

    const table = try parseTableWith(&t, "{1, name = 2, [key] = 3}");
    try std.testing.expectEqual(@as(usize, 3), table.fields.len);

    try std.testing.expectEqual(std.meta.Tag(Ast.TableField).expression, std.meta.activeTag(table.fields[0]));
    try std.testing.expectEqualStrings("name", table.fields[1].named.name.name);
    try std.testing.expectEqualStrings("key", table.fields[2].indexed.key.variable.name.name);
}

test "a separator is a comma or a semicolon, and the last one may be left off" {
    var t = Parser.Test.init();
    defer t.deinit();

    for ([_][]const u8{ "{1, 2, 3}", "{1; 2; 3}", "{1, 2, 3,}", "{1, 2, 3;}", "{1, 2, 3}" }) |source| {
        const table = try parseTableWith(&t, source);
        try std.testing.expectEqual(@as(usize, 3), table.fields.len);
    }
}

test "a bare name is a value, not a field" {
    var t = Parser.Test.init();
    defer t.deinit();

    const table = try parseTableWith(&t, "{a}");

    const field = table.fields[0].expression;
    try std.testing.expectEqualStrings("a", field.expression.variable.name.name);
}

test "a list item is a whole expression, not just a name" {
    var t = Parser.Test.init();
    defer t.deinit();

    // without an `=` behind it the name is only where the expression starts
    for ([_][]const u8{ "{a.b}", "{a[b]}", "{f()}", "{a:gsub \"p\"}" }) |source| {
        const table = try parseTableWith(&t, source);
        try std.testing.expectEqual(std.meta.Tag(Ast.TableField).expression, std.meta.activeTag(table.fields[0]));
    }

    // including the operators, which bind onto the name like anywhere else
    const table = try parseTableWith(&t, "{a + 1, b .. c}");
    try std.testing.expectEqual(@as(usize, 2), table.fields.len);
    try std.testing.expectEqual(std.meta.Tag(Ast.Expression).binary, std.meta.activeTag(table.fields[0].expression.expression));
    try std.testing.expectEqual(std.meta.Tag(Ast.Expression).binary, std.meta.activeTag(table.fields[1].expression.expression));
}

test "only a bare name can be the name of a field" {
    // `recfield` in lparser.c reads a name or a single `[...]`, so a suffix or
    // a second index is not one
    var t = Parser.Test.init();
    defer t.deinit();

    for ([_][]const u8{ "{a.b = 1}", "{[1][2] = 3}", "{[k]}" }) |source| {
        _ = t.parseExpression(source) catch {};
    }

    try t.expectKind(0, .expected_token);
}

test "an indexed field needs its equals sign" {
    var t = Parser.Test.init();
    defer t.deinit();

    _ = t.parseExpression("{[k]}") catch {};
    try t.expectKind(0, .expected_token);
}

test "constructors nest" {
    var t = Parser.Test.init();
    defer t.deinit();

    const table = try parseTableWith(&t, "{ a = { b = { 1 } } }");
    const inner = table.fields[0].named.value.table;
    const innermost = inner.fields[0].named.value.table;

    try std.testing.expectEqual(@as(usize, 1), innermost.fields.len);
}

test "a constructor as the argument of a call" {
    var t = Parser.Test.init();
    defer t.deinit();

    const expr = try t.parseExpression("f{1}");

    const call = switch (expr) {
        .function_call => |node| node,
        else => return error.NotACall,
    };
    try std.testing.expectEqual(@as(usize, 1), call.arguments.table.fields.len);
}

test "an unclosed constructor is reported where it ran out" {
    var t = Parser.Test.init();
    defer t.deinit();

    _ = t.parseExpression("{1, 2") catch {};
    try t.expectKind(0, .expected_token);
    try std.testing.expectEqual(Token.Kind.rcurly, t.errors()[0].expected.?.token);
}
