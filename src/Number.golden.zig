const std = @import("std");

const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const num = @import("Number.zig");
const Number = num.Number;

// A test fixture, and deliberately not part of the runtime.
//
// `Number.golden.lua` is run by a reference Lua 5.4 and what it prints is kept in
// `Number.golden.txt`. This file runs the same lines through lualite's own
// `Number` and compares, which is what makes the number rules Lua's rather than a
// reading of `lobject.c`.
//
// The evaluator below knows literals and operators and nothing else, which is
// enough because the golden file is written to stay inside that. It is thrown
// away once there is a VM to run the real thing; the compiler in Phase 4 is a
// different program that happens to start from the same tree.

const golden_source = @embedFile("Number.golden.lua");
const golden_output = @embedFile("Number.golden.txt");

/// What this can go wrong with while evaluating. The golden file turns the first
/// few into the lines it expects to raise, and the last into a failure saying the
/// two files have drifted apart.
const Error = error{
    /// a value the operation does not take, which in Lua is a type error
    BadOperand,
    /// an operand that should have become a number and did not
    NotANumber,
    /// from `Number`
    DivideByZero,
    NoIntegerRepresentation,
    /// the golden file and this file disagree about what one of its lines is
    MalformedCase,
};

const Value = union(enum) {
    nil,
    boolean: bool,
    number: Number,
    string: []const u8,

    fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nil => "nil",
            .boolean => "boolean",
            .number => |n| if (n.isInt()) "integer" else "float",
            .string => "string",
        };
    }

    /// `tostring` for the types that have a representation here
    fn toText(v: Value, buffer: []u8) Error![]const u8 {
        return switch (v) {
            .string => |s| s,
            .boolean => |b| if (b) "true" else "false",
            .number => |n| num.toBytes(n, buffer) catch Error.BadOperand,
            else => Error.BadOperand,
        };
    }
};

// The arithmetic operators coerce a string to a number and the bitwise ones do
// not. Lua does the coercion in `cvt2num` for the former and not the latter, and
// the golden file has a line for each so the split cannot drift.
fn toNumber(v: Value, coerce: bool) Error!Number {
    return switch (v) {
        .number => |n| n,
        .string => |s| if (coerce) num.parse(s) orelse Error.NotANumber else Error.BadOperand,
        else => Error.BadOperand,
    };
}

fn evaluate(expr: Ast.Expression) Error!Value {
    return switch (expr) {
        .nil => .nil,
        .boolean => |node| .{ .boolean = node.value },
        .number => |node| .{ .number = node.value },
        .string => |node| .{ .string = node.value },

        .unary => |node| unary(node.operator, node.expression),
        .binary => |node| binary(node.operator, node.left, node.right),
        .parenthesized => |node| evaluate(node.expression),

        // nothing below here is in the golden file, so reaching one means the file
        // and this evaluator have drifted apart rather than that Lua is hard
        else => Error.MalformedCase,
    };
}

fn unary(op: Ast.UnaryOperator, operand: Ast.Expression) Error!Value {
    const v = try evaluate(operand);

    return switch (op) {
        .negation => .{ .number = num.neg(try toNumber(v, true)) },
        .not => .{
            .boolean = switch (v) {
                .nil => true,
                .boolean => |b| !b,
                // everything else is truthy in Lua, zero included
                else => false,
            },
        },
        .bitwise_not => .{ .number = try num.bitNot(try toNumber(v, false)) },
        .length => try length(v),
    };
}

fn length(v: Value) Error!Value {
    return switch (v) {
        .string => |s| .{ .number = Number.fromInt(@intCast(s.len)) },
        .number => |n| .{
            .number = switch (n) {
                .int => |i| Number.fromInt(if (i < 0) -%i else i),
                // truncated towards zero, as Lua's length of a float is
                .float => |f| Number.fromInt(@intFromFloat(@trunc(f))),
            },
        },
        else => Error.BadOperand,
    };
}

fn binary(op: Ast.BinaryOperator, left: Ast.Expression, right: Ast.Expression) Error!Value {
    const a = try evaluate(left);
    const b = try evaluate(right);

    return switch (op) {
        // the arithmetic, where a string operand becomes a number
        .add => .{ .number = num.add(try toNumber(a, true), try toNumber(b, true)) },
        .subtract => .{ .number = num.sub(try toNumber(a, true), try toNumber(b, true)) },
        .multiply => .{ .number = num.mul(try toNumber(a, true), try toNumber(b, true)) },
        .divide => .{ .number = num.div(try toNumber(a, true), try toNumber(b, true)) },
        .floor_divide => .{ .number = try num.floorDiv(try toNumber(a, true), try toNumber(b, true)) },
        .modulo => .{ .number = try num.mod(try toNumber(a, true), try toNumber(b, true)) },
        .power => .{ .number = num.pow(try toNumber(a, true), try toNumber(b, true)) },

        // and the bitwise ones, where it does not
        .bitwise_and => .{ .number = try num.bitAnd(try toNumber(a, false), try toNumber(b, false)) },
        .bitwise_or => .{ .number = try num.bitOr(try toNumber(a, false), try toNumber(b, false)) },
        .bitwise_xor => .{ .number = try num.bitXor(try toNumber(a, false), try toNumber(b, false)) },
        .shift_left => .{ .number = try num.shiftLeft(try toNumber(a, false), try toNumber(b, false)) },
        .shift_right => .{ .number = try num.shiftRight(try toNumber(a, false), try toNumber(b, false)) },

        // comparison crosses over between the two number types
        .less_than => .{ .boolean = compare(a, b, .lt) },
        .greater_than => .{ .boolean = compare(a, b, .gt) },
        .less_equal => .{ .boolean = compare(a, b, .le) },
        .greater_equal => .{ .boolean = compare(a, b, .ge) },
        .equal => .{ .boolean = try equals(a, b) },
        .not_equal => .{ .boolean = !(try equals(a, b)) },

        .@"and" => if (truthy(b)) b else a,
        .@"or" => if (truthy(a)) a else b,

        .concat => .{ .string = try concat(a, b) },
    };
}

const Order = enum { lt, gt, le, ge };

fn compare(a: Value, b: Value, order: Order) bool {
    switch (a) {
        .number => |x| return switch (b) {
            .number => |y| switch (order) {
                .lt => num.less(x, y),
                .gt => num.less(y, x),
                .le => num.lessEq(x, y),
                .ge => num.lessEq(y, x),
            },
            // everything else has an order against a number, so a string here is
            // compared as its own kind and is out of the golden file
            else => return order == .lt or order == .le,
        },
        .string => |x| return switch (b) {
            .string => |y| compareBytes(x, y, order),
            else => return order == .lt or order == .le,
        },
        else => return false,
    }
}

fn compareBytes(x: []const u8, y: []const u8, order: Order) bool {
    const shared = @min(x.len, y.len);
    const at = std.mem.order(u8, x[0..shared], y[0..shared]);

    return switch (order) {
        .lt => at == .lt or (at == .eq and x.len < y.len),
        .gt => at == .gt or (at == .eq and x.len > y.len),
        .le => at != .gt,
        .ge => at != .lt,
    };
}

fn equals(a: Value, b: Value) Error!bool {
    return switch (a) {
        // `1 == 1.0` is true, which is the one place the two types cross over
        .number => |x| switch (b) {
            .number => |y| num.equal(x, y),
            else => false,
        },
        .string => |x| switch (b) {
            .string => |y| std.mem.eql(u8, x, y),
            else => false,
        },
        .boolean => |x| switch (b) {
            .boolean => |y| x == y,
            else => false,
        },
        .nil => b == .nil,
    };
}

// Concatenation joins what `tostring` makes of each side. The result is written
// into scratch that outlives the call, since the golden file keeps it until the
// line has been compared.
const concat_scratch = struct {
    var left: [num.buffer_size]u8 = undefined;
    var right: [num.buffer_size]u8 = undefined;
    var joined: [2 * num.buffer_size]u8 = undefined;
};

fn concat(a: Value, b: Value) Error![]const u8 {
    const left = try a.toText(&concat_scratch.left);
    const right = try b.toText(&concat_scratch.right);

    if (left.len + right.len > concat_scratch.joined.len) return Error.BadOperand;
    @memcpy(concat_scratch.joined[0..left.len], left);
    @memcpy(concat_scratch.joined[left.len..][0..right.len], right);

    return concat_scratch.joined[0 .. left.len + right.len];
}

fn truthy(v: Value) bool {
    return switch (v) {
        .nil => false,
        .boolean => |b| b,
        else => true,
    };
}

// --- reading the golden file ---

/// One line of the golden file: what it asks for, and what Lua said.
const Case = struct {
    /// the expression as written, which is what gets parsed
    source: []const u8,
    /// the type name or the error substring
    expected: []const u8,
    raised: bool,
    /// the line the reference printed for it
    result: []const u8,
};

/// The lines of `Number.golden.lua` from the marker onwards, which is where the
/// two files agree on what a case is. The prelude above the marker is Lua's to
/// run and has no case in it.
fn cases() std.mem.SplitIterator(u8, .scalar) {
    const marker = "==== cases start here ====";

    const at = std.mem.indexOf(u8, golden_source, marker) orelse
        @panic("the golden file has no cases marker, so it cannot be read");

    return std.mem.splitScalar(u8, golden_source[at + marker.len ..], '\n');
}

test "every number rule agrees with a reference Lua 5.4" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var results = std.mem.splitScalar(u8, golden_output, '\n');

    var checked: usize = 0;

    var lines = cases();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '-') continue;

        const case = try parseCase(allocator, line);
        const result = results.next() orelse {
            std.debug.print("the golden file has no result for: {s}\n", .{case.source});
            return error.TooFewResults;
        };

        const got = try runCase(allocator, case);
        const want = std.mem.trim(u8, result, "\r");

        // naming the case, since the diff on its own does not say which of the
        // eighty it was
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("{s}\n  lualite: {s}\n  lua:     {s}\n", .{ case.source, got, want });
            return error.Disagreement;
        }
        checked += 1;
    }

    // the whole of it, rather than the prefix that happened to match
    while (results.next()) |rest| {
        if (std.mem.trim(u8, rest, " \r").len == 0) continue;

        std.debug.print("the golden file has a result lualite has no case for: {s}\n", .{rest});
        return error.TooManyResults;
    }

    try std.testing.expect(checked > 0);
    if (checked < 80) {
        std.debug.print("only {d} cases ran, which is fewer than the file holds\n", .{checked});
        return error.TooFewCases;
    }
}

/// Splits a `show(...)` or `bad(...)` line. Neither argument holds a comma, so
/// the last one separates them.
///
/// A `bad` line carries its expression quoted, since Lua is handed the source
/// rather than the expression: a line that has to raise would otherwise take the
/// whole file down with it. A `show` line carries it bare, and can hold a string
/// literal of its own, so only the `bad` side is unquoted here.
fn parseCase(allocator: std.mem.Allocator, line: []const u8) !Case {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return error.MalformedCase;
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return error.MalformedCase;

    const head = line[0..open];
    const args = line[open + 1 .. close];

    const split = std.mem.lastIndexOfScalar(u8, args, ',') orelse return error.MalformedCase;
    const raised = std.mem.eql(u8, head, "bad");

    const source = std.mem.trim(u8, args[0..split], " \t");

    return .{
        .source = if (raised) try unquote(allocator, source) else source,
        .expected = try unquote(allocator, std.mem.trim(u8, args[split + 1 ..], " \t")),
        .raised = raised,
        .result = "",
    };
}

fn unquote(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len < 2) return error.MalformedCase;

    const quote = text[0];
    if ((quote != '"' and quote != '\'') or text[text.len - 1] != quote) {
        return error.MalformedCase;
    }

    return try allocator.dupe(u8, text[1 .. text.len - 1]);
}

/// Runs one case and returns the line the reference should have printed for it.
fn runCase(allocator: std.mem.Allocator, case: Case) ![]const u8 {
    var t = Parser.Test.init();
    defer t.deinit();

    var buffer: [num.buffer_size]u8 = undefined;
    const expr = try t.parseExpression(case.source);

    const outcome = evaluate(expr);

    if (case.raised) {
        // what the golden file asks for is the substring Lua's own message
        // carried, so an error only has to have been raised, not worded the same
        if (outcome) |_| {
            std.debug.print("expected an error from: {s}\n", .{case.source});
            return error.ExpectedError;
        } else |_| {}

        return std.fmt.allocPrint(allocator, "err\t{s}", .{case.expected});
    }

    const value = outcome catch |err| {
        std.debug.print("{s} raised {t}, which is not what Lua does\n", .{ case.source, err });
        return err;
    };

    if (!std.mem.eql(u8, value.typeName(), case.expected)) {
        std.debug.print("{s} is a {s}, not a {s}\n", .{ case.source, value.typeName(), case.expected });
        return error.WrongType;
    }

    const text = try value.toText(&buffer);
    return std.fmt.allocPrint(allocator, "ok\t{s}\t{s}", .{ value.typeName(), text });
}
