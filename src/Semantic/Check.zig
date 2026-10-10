const std = @import("std");

const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");
const Diagnostic = @import("../Diagnostic.zig");

const Semantic = @import("../Semantic.zig");
const Test = Semantic.Test;

// The checks a chunk is refused for that need no resolution to decide: a name is
// in the wrong place, an attribute is not one Lua has, or a function has more of
// something than Lua allows.

test "a break outside a loop" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("break");

    try t.expectCount(1);
    try t.expectKind(0, .break_outside_loop);
}

// A `break` jumps to the end of the innermost loop around it, so one further out
// will not do.
test "a break reaches the innermost loop around it" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\while true do
        \\  for i = 1, 3 do
        \\    if i then break end
        \\  end
        \\end
    );
    _ = try t.parse("repeat do break end until true");
    _ = try t.parse("for k in pairs(t) do break end");

    try t.expectClean();
}

// A function body is a scope of its own, so a `break` in one cannot reach a loop
// in the function around it.
test "a break cannot reach a loop in the function around it" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\while true do
        \\  return (function() break end)()
        \\end
    );

    try t.expectCount(1);
    try t.expectKind(0, .break_outside_loop);
}

test "a break in a loop nested inside a function is fine" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local function f() for i = 1, 3 do break end end");

    try t.expectClean();
}

test "assigning to a const local" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local c <const> = 1\nc = 2");

    try t.expectCount(1);
    try t.expectKind(0, .assign_to_const);
    try t.expectName(0, "c");
}

test "a const local may be read and may be declared" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local c <const> = 1\nprint(c)\nlocal d <const> = c");

    try t.expectClean();
}

// Assigning through a field or an index writes into whatever the name reads, not
// into the name itself, so `<const>` does not stand in the way.
test "a const local may be read through a field or an index" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local t <const> = {}\nt.field = 1\nt[1] = 2");

    try t.expectClean();
}

test "an unknown attribute" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local x <bogus> = 1");

    try t.expectCount(1);
    try t.expectKind(0, .unknown_attribute);
    try t.expectName(0, "bogus");
}

test "const and close are the two attributes" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local a <const> = 1\nlocal b <close> = f()");

    try t.expectClean();
}

// Closing the first variable of a list would close the others with it, so Lua
// allows only one.
test "two to-be-closed variables in one list" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local a <close>, b <close> = f(), g()");

    try t.expectCount(1);
    try t.expectKind(0, .multiple_close_variables);
}

test "one to-be-closed variable per list is fine" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("do local a <close> = f() end\ndo local b <close> = g() end");

    try t.expectClean();
}

test "too many local variables in one function" {
    var t = Test.init();
    defer t.deinit();

    // Lua's own limit is 200, so the 201st is the one reported
    const arena = t.arena.allocator();
    const source = try std.fmt.allocPrint(arena, "local {s}", .{
        try names(arena, 'n', Semantic.max_locals + 2),
    });

    _ = try t.parse(source);

    try t.expectCount(2);
    try t.expectKind(0, .too_many_locals);
}

test "too many parameters in one function" {
    var t = Test.init();
    defer t.deinit();

    // parameters are locals too, so they count towards the same limit
    const arena = t.arena.allocator();
    const source = try std.fmt.allocPrint(arena, "function f({s}) end", .{
        try names(arena, 'n', Semantic.max_locals + 2),
    });

    _ = try t.parse(source);

    try t.expectCount(2);
    try t.expectKind(0, .too_many_locals);
}

test "each function has its own limit" {
    var t = Test.init();
    defer t.deinit();

    // 150 in each of two functions, which is under the limit in both
    const arena = t.arena.allocator();
    const list = try names(arena, 'n', 150);
    const source = try std.fmt.allocPrint(arena, "do local {s} end\ndo local {s} end", .{ list, list });

    const program = try t.parse(source);
    try t.expectClean();

    // and each frame is sized for its own
    try std.testing.expectEqual(@as(u32, 150), program.functions[0].frame_size);
}

// Slots are counted in u32 rather than u16, since the count keeps going past
// `max_locals` rather than stopping there. At u16 this overflowed on the way and
// took the process down on a chunk well under any size limit.
test "more locals than a u16 could hold is refused rather than fatal" {
    var t = Test.init();
    defer t.deinit();

    const arena = t.arena.allocator();
    const count = std.math.maxInt(u16) + 2;
    const source = try std.fmt.allocPrint(arena, "local {s}", .{try names(arena, 'n', count)});

    // the cap is lifted for this one, since what is being checked is the counting
    // rather than the reporting
    t.reporter.max = count;

    const program = try t.parse(source);

    // every one past the limit is reported, and the chunk still walks to the end
    try t.expectCount(count - @as(u32, Semantic.max_locals));
    try t.expectKind(0, .too_many_locals);

    // and the slots are counted rather than wrapped
    try std.testing.expectEqual(@as(u32, count), program.functions[0].frame_size);
    try std.testing.expectEqual(@as(u32, count - 1), program.body.locals[count - 1].slot);
}

test "a file with more problems than the cap keeps the first and counts the rest" {
    var t = Test.init();
    defer t.deinit();

    t.reporter.max = 10;

    const arena = t.arena.allocator();
    const count = 250;
    const source = try std.fmt.allocPrint(arena, "local {s}", .{try names(arena, 'n', count)});

    _ = try t.parse(source);

    // only the ones past the limit are a problem at all, so that is what the cap
    // applies to rather than the whole list
    const problems = count - Semantic.max_locals;
    try t.expectCount(10);
    try t.expectKind(0, .too_many_locals);

    // the rest are counted rather than silently lost, so a caller can say the list
    // is short instead of letting it read as the whole truth
    try std.testing.expect(t.reporter.truncated());
    try std.testing.expectEqual(@as(usize, problems - 10), t.reporter.dropped);
}

test "a file with no more problems than the cap is not truncated" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("break\ngoto nowhere\n");

    try t.expectCount(2);
    try std.testing.expect(!t.reporter.truncated());
}

// The 255 upvalues of a function can be reached across more than one function,
// since each of those is under 200 locals of its own, so the names come from two
// scopes rather than one.
test "too many upvalues in one function" {
    var t = Test.init();
    defer t.deinit();

    const arena = t.arena.allocator();
    const per_scope: u16 = 150;

    const outer = try names(arena, 'a', per_scope);
    const inner = try names(arena, 'b', per_scope);

    const source = try std.fmt.allocPrint(
        arena,
        \\local {s}
        \\local function f()
        \\  local {s}
        \\  local function g()
        \\    return {s}, {s}
        \\  end
        \\end
    ,
        .{ outer, inner, outer, inner },
    );

    const program = try t.parse(source);

    // 300 captures wanted and Lua allows 255, so the ones past that are reported
    const wanted = per_scope * 2;
    try t.expectCount(wanted - Semantic.max_upvalues);
    try t.expectKind(0, .too_many_upvalues);

    // each function is under the local limit, which is what makes this reachable
    try std.testing.expectEqual(@as(usize, 3), program.functions.len);
    try std.testing.expectEqual(
        @as(usize, Semantic.max_upvalues),
        program.functions[2].upvalues.len,
    );
}

// `a0, a1, ...`, count of them
fn names(arena: std.mem.Allocator, prefix: u8, count: u32) ![]const u8 {
    const list = try arena.alloc([]const u8, count);
    for (list, 0..) |*name, i| {
        name.* = try std.fmt.allocPrint(arena, "{c}{d}", .{ prefix, i });
    }
    return std.mem.join(arena, ", ", list);
}

// Every check reports and carries on, since one out of scope name says nothing
// about the rest of the file, and a caller wants every error rather than the first.
test "every check reports and the walk carries on" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\break
        \\goto nowhere
        \\local c <const> = 1
        \\c = 2
        \\local x <bogus> = 1
    );

    // the goto is only known to be nameless once its block closes, so it is the
    // last of the four rather than the second
    try t.expectCount(4);
    try t.expectKind(0, .break_outside_loop);
    try t.expectKind(1, .assign_to_const);
    try t.expectKind(2, .unknown_attribute);
    try t.expectKind(3, .undefined_label);
}
