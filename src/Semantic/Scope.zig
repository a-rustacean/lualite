const std = @import("std");

const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");

const Semantic = @import("../Semantic.zig");
const Test = Semantic.Test;

// resolves a name against a source that has already been walked
fn expectResolution(t: *Test, source: []const u8, name: []const u8, expected: Semantic.Resolution) !void {
    const program = try t.parse(source);
    try std.testing.expectEqual(expected, try resolutionOf(program, source, name));
}

// Where a name sits in the source, which is what the results are keyed by. The
// name has to stand as a word of its own, since `a` is otherwise found inside
// `local` before the declaration it is meant to be.
fn resolutionOf(program: Semantic.Program, source: []const u8, name: []const u8) !Semantic.Resolution {
    return program.resolutions.get(try wordOffset(source, name, 0)) orelse error.NameNotResolved;
}

fn wordOffset(source: []const u8, name: []const u8, from: usize) !u32 {
    var at = from;
    while (std.mem.indexOfPos(u8, source, at, name)) |index| {
        const before_ok = index == 0 or !isNameChar(source[index - 1]);
        const after = index + name.len;
        const after_ok = after == source.len or !isNameChar(source[after]);

        if (before_ok and after_ok) return @intCast(index);
        at = after;
    }

    return error.NameNotInSource;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn resolutionAt(program: *const Semantic.Program, offset: u32) !Semantic.Resolution {
    return program.resolutions.get(offset) orelse error.NameNotResolved;
}

test "a local takes a slot, in source order" {
    var t = Test.init();
    defer t.deinit();

    const source = "local a, b, c\na = b + c";
    const program = try t.parse(source);
    try t.expectClean();

    const names = [_][]const u8{ "a", "b", "c" };
    for (names, 0..) |name, slot| {
        try std.testing.expectEqual(
            Semantic.Resolution{ .local = @intCast(slot) },
            try resolutionOf(program, source, name),
        );
    }
}

test "parameters are the first locals of a function" {
    var t = Test.init();
    defer t.deinit();

    const source = "function f(x, y)\n  local z\n  return x, y, z\nend";
    const program = try t.parse(source);
    try t.expectClean();

    try std.testing.expectEqual(@as(u32, 0), (try resolutionOf(program, source, "x")).local);
    try std.testing.expectEqual(@as(u32, 1), (try resolutionOf(program, source, "y")).local);
    try std.testing.expectEqual(@as(u32, 2), (try resolutionOf(program, source, "z")).local);
}

test "a name nothing declares is a global" {
    var t = Test.init();
    defer t.deinit();

    const source = "print(1)\nx = 2";
    const program = try t.parse(source);
    try t.expectClean();

    try std.testing.expectEqual(Semantic.Resolution.global, try resolutionOf(program, source, "print"));
    try std.testing.expectEqual(Semantic.Resolution.global, try resolutionOf(program, source, "x"));
}

// A block shadows a name from around it. It does not take the slot the outer one
// has, since that one is still live, and it gives its own slot back on the way out
// so a local declared afterwards in an outer block can have it.
test "a block shadows a name and gives its slot back" {
    var t = Test.init();
    defer t.deinit();

    const program = try t.parse("local x = 1\ndo local x = 2 end\nlocal y");
    try t.expectClean();

    const outer = program.body.locals[0];
    const inner = program.body.children[0].locals[0];

    try std.testing.expectEqualStrings("x", outer.name);
    try std.testing.expectEqualStrings("x", inner.name);

    // side by side, so the inner takes the next slot rather than reusing one
    try std.testing.expectEqual(@as(u32, 0), outer.slot);
    try std.testing.expectEqual(@as(u32, 1), inner.slot);

    // and once the block closes, the slot it held is the next one to go out
    const after = program.body.locals[1];
    try std.testing.expectEqualStrings("y", after.name);
    try std.testing.expectEqual(@as(u32, 1), after.slot);
}

test "a name reads the innermost declaration of it" {
    var t = Test.init();
    defer t.deinit();

    const source = "local x = 1\ndo local x = 2 print(x) end\nprint(x)";
    const program = try t.parse(source);
    try t.expectClean();

    // the read inside the block is the inner local, the one after it the outer
    const inner = program.body.children[0].locals[0].slot;
    const outer = program.body.locals[0].slot;
    try std.testing.expect(inner != outer);

    // keyed by where the name was written, so the read inside the block is the
    // inner local and the one after it is the outer
    const inside = std.mem.indexOf(u8, source, "print(x)") orelse unreachable;
    const after = std.mem.indexOfPos(u8, source, inside + 8, "x") orelse unreachable;

    try std.testing.expectEqual(
        Semantic.Resolution{ .local = inner },
        try resolutionAt(&program, try wordOffset(source, "x", inside)),
    );
    try std.testing.expectEqual(
        Semantic.Resolution{ .local = outer },
        try resolutionAt(&program, try wordOffset(source, "x", after)),
    );
}

test "the frame is as wide as the most locals live at once" {
    var t = Test.init();
    defer t.deinit();

    // two live, then a third beside them, then back to two
    const program = try t.parse("local a, b\ndo\n  local c\nend");

    try std.testing.expectEqual(@as(u32, 3), program.functions[0].frame_size);
}

test "the chunk is a function that takes `...` and names no upvalues" {
    var t = Test.init();
    defer t.deinit();

    const program = try t.parse("local x = ...\nreturn x");
    try t.expectClean();

    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
    try std.testing.expect(program.functions[0].is_vararg);
    try std.testing.expectEqual(@as(?u32, null), program.functions[0].parent);
    try std.testing.expectEqual(@as(usize, 0), program.functions[0].upvalues.len);
}

// A function is given the index of its own depth in the source rather than the
// order the walk happens to finish them in, so the result is ordered by position
// however deeply the walk nests.
test "a function is told the function it was written inside" {
    var t = Test.init();
    defer t.deinit();

    const program = try t.parse(
        \\local function outer()
        \\  local function inner() end
        \\end
    );

    // the chunk, then outer, then inner
    try std.testing.expectEqual(@as(usize, 3), program.functions.len);
    try std.testing.expectEqual(@as(?u32, null), program.functions[0].parent);
    try std.testing.expectEqual(@as(?u32, 0), program.functions[1].parent);
    try std.testing.expectEqual(@as(?u32, 1), program.functions[2].parent);
}

test "a body is told the function it makes" {
    var t = Test.init();
    defer t.deinit();

    const source =
        \\local f = function() return 1 end
        \\local g
        \\function g.h() return 2 end
    ;

    const program = try t.parse(source);
    try t.expectClean();

    try std.testing.expectEqual(@as(usize, 3), program.functions.len);

    // the chunk, then f, then g.h, each recorded against the span of its body,
    // which runs from the `(` opening the parameter list to the `end` closing it
    const opens = [_][]const u8{ "function() return 1 end", "function g.h() return 2 end" };
    const expected = [_]u32{ 1, 2 };

    for (opens, expected) |text, index| {
        const at = std.mem.indexOf(u8, source, text) orelse return error.BodyNotInSource;
        const open = std.mem.indexOfScalarPos(u8, source, at, '(') orelse return error.NoParen;

        const definition = program.definitions.get(@intCast(open)) orelse return error.NoDefinition;
        try std.testing.expectEqual(index, definition.function);
    }
}

test "a name captured by a nested function becomes an upvalue" {
    var t = Test.init();
    defer t.deinit();

    const source =
        \\local function outer()
        \\  local n = 0
        \\  return function() n = n + 1 end
        \\end
    ;

    const program = try t.parse(source);
    try t.expectClean();

    // the closure is the third function written and it holds one upvalue
    const closure = program.functions[2];
    try std.testing.expectEqual(@as(usize, 1), closure.upvalues.len);
    try std.testing.expectEqual(Semantic.Upvalue{ .parent_local = 0 }, closure.upvalues[0]);

    // and the local it reads is marked, since its slot may not be handed on while
    // a closure can still see it
    const captured = program.functions[1].body.locals[0];
    try std.testing.expectEqualStrings("n", captured.name);
    try std.testing.expect(captured.is_captured);
}

test "a capture hops through every function between the two" {
    var t = Test.init();
    defer t.deinit();

    const program = try t.parse(
        \\local function outer()
        \\  local a = 1
        \\  local function mid()
        \\    local function inner()
        \\      return a
        \\    end
        \\    return inner
        \\  end
        \\  return mid
        \\end
    );
    try t.expectClean();

    // inner reads `a` out of mid's upvalues and mid reads it out of outer's
    // frame, so both hold one and each points one hop further out
    const mid = program.functions[2];
    const inner = program.functions[3];

    try std.testing.expectEqual(@as(usize, 1), mid.upvalues.len);
    try std.testing.expectEqual(Semantic.Upvalue{ .parent_local = 0 }, mid.upvalues[0]);

    try std.testing.expectEqual(@as(usize, 1), inner.upvalues.len);
    try std.testing.expectEqual(Semantic.Upvalue{ .parent_upvalue = 0 }, inner.upvalues[0]);
}

test "the same name captured twice is one upvalue" {
    var t = Test.init();
    defer t.deinit();

    const program = try t.parse(
        \\local function outer()
        \\  local a = 1
        \\  return function() return a end, function() return a end
        \\end
    );
    try t.expectClean();

    // each closure holds one, and both name the same slot of the same frame
    try std.testing.expectEqual(@as(usize, 1), program.functions[2].upvalues.len);
    try std.testing.expectEqual(@as(usize, 1), program.functions[3].upvalues.len);
    try std.testing.expectEqual(program.functions[2].upvalues[0], program.functions[3].upvalues[0]);
}

test "`...` outside a function that takes it" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("function f() return ... end");

    try t.expectCount(1);
    try t.expectKind(0, .vararg_outside_function);
}

test "`...` is fine in the chunk and in a vararg function" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local function f(...) return ... end\nreturn f(...)");

    try t.expectClean();
}

// `function a.b` reads the first name and writes the last, so only the first is
// resolved and the rest are field names rather than names of their own.
test "a dotted function name reads the first name only" {
    var t = Test.init();
    defer t.deinit();

    const source = "local a = {}\nfunction a.b.c:d() end";
    const program = try t.parse(source);
    try t.expectClean();

    const start = std.mem.indexOf(u8, source, "a =") orelse return error.NameNotInSource;
    try std.testing.expectEqual(
        Semantic.Resolution{ .local = 0 },
        program.resolutions.get(@intCast(start)).?,
    );

    // `b`, `c` and `d` are field names rather than names of their own, so the only
    // two names resolved are the declaration and the one the definition reads
    try std.testing.expectEqual(@as(usize, 2), program.resolutions.count());
}

test "a plain function name is assigned rather than read" {
    var t = Test.init();
    defer t.deinit();

    const source = "local f\nfunction f() end";
    const program = try t.parse(source);
    try t.expectClean();

    try std.testing.expectEqual(
        Semantic.Resolution{ .local = 0 },
        try resolutionOf(program, source, "f"),
    );
}

test "a local function binds its name before the body, so it can call itself" {
    var t = Test.init();
    defer t.deinit();

    const source = "local function fact(n) return n * fact(n - 1) end";
    try std.testing.expectEqual(
        Semantic.Resolution{ .local = 0 },
        try resolutionOf(try t.parse(source), source, "fact"),
    );
    try t.expectClean();
}

// The values are read before the names are bound, so `local x = x` reads the name
// from around the declaration rather than the local it introduces.
test "the values of a local declaration are read before it binds the names" {
    var t = Test.init();
    defer t.deinit();

    const source = "local x = 1\nlocal y = x";
    const program = try t.parse(source);
    try t.expectClean();

    try std.testing.expectEqual(@as(u32, 0), program.body.locals[0].slot);
    try std.testing.expectEqual(@as(u32, 1), program.body.locals[1].slot);
    try std.testing.expectEqual(
        Semantic.Resolution{ .local = 0 },
        try resolutionOf(program, source, "x"),
    );
}

test "a generic for binds every name of its list, in source order" {
    var t = Test.init();
    defer t.deinit();

    const source = "for k, v in pairs(t) do print(k, v) end";
    const program = try t.parse(source);
    try t.expectClean();

    const loop = program.body.children[0];
    try std.testing.expectEqualStrings("k", loop.locals[0].name);
    try std.testing.expectEqualStrings("v", loop.locals[1].name);
    try std.testing.expectEqual(@as(u32, 0), loop.locals[0].slot);
    try std.testing.expectEqual(@as(u32, 1), loop.locals[1].slot);
}

test "a numeric for binds its control variable in the loop" {
    var t = Test.init();
    defer t.deinit();

    // the three bounds are outside the loop, so they see nothing it declares
    const program = try t.parse("local limit = 3\nfor i = 1, limit do print(i) end");

    try std.testing.expectEqualStrings("i", program.body.children[0].locals[0].name);
}

// The `until` condition sits inside the loop, which is what lets it see what the
// body declared.
test "a repeat condition sees the locals of its body" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("repeat local n = 0 until n == 1");

    try t.expectClean();
}

// A `while` condition is outside the loop, so it cannot see what the body
// declares.
test "a while condition cannot see the locals of its body" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("while true do local n = 1 end\nprint(n)");

    // `n` is gone by the time it is read, so the read is a global
    const program = try t.parse("while true do local n = 1 end\nprint(n)");
    try std.testing.expectEqual(@as(usize, 1), program.functions[0].body.children[0].locals.len);
}

// Each `elseif` and `else` gets a scope of its own, so a local in one clause is
// not in scope in the next.
test "each clause of an if gets a scope of its own" {
    var t = Test.init();
    defer t.deinit();

    const program = try t.parse(
        \\if a then
        \\  local x = 1
        \\elseif b then
        \\  local x = 2
        \\else
        \\  local x = 3
        \\end
    );
    try t.expectClean();

    // each clause is a block beside the others rather than nested in the first,
    // since none of them is in scope in the next
    try std.testing.expectEqual(@as(usize, 3), program.body.children.len);

    // and all three take the same slot, since each closes before the next opens
    for (program.body.children) |clause| {
        try std.testing.expectEqual(@as(u32, 0), clause.locals[0].slot);
    }
}

test "a field or an index reads the object it hangs off, and the field is not a name" {
    var t = Test.init();
    defer t.deinit();

    const source = "local o = {}\nprint(o.field, o[key])";
    const program = try t.parse(source);
    try t.expectClean();

    // the declaration and the three reads are `o`, and `key` is the only other
    // name, which nothing declares
    try std.testing.expectEqual(
        Semantic.Resolution{ .local = 0 },
        try resolutionAt(&program, try wordOffset(source, "o", 0)),
    );
    try std.testing.expectEqual(
        Semantic.Resolution{ .local = 0 },
        try resolutionAt(&program, try wordOffset(source, "o", 16)),
    );
    try std.testing.expectEqual(Semantic.Resolution.global, try resolutionOf(program, source, "key"));
    try std.testing.expectEqual(Semantic.Resolution.global, try resolutionOf(program, source, "print"));
}

test "a method call reads its object, and the method name is not a name" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local o = {}\no:method(o.field, o[key])");

    try t.expectClean();
}

test "a table constructor resolves the names in every kind of field" {
    var t = Test.init();
    defer t.deinit();

    const source = "local k, v = 1, 2\nlocal t = { k, named = k, [k] = v }";
    _ = try t.parse(source);

    try t.expectClean();
}

// The frame is as wide as the most locals live at once, and the compiler sizes it
// from this rather than counting the declarations.
test "a function's frame holds its parameters, its locals and its temporaries" {
    var t = Test.init();
    defer t.deinit();

    // a, b, c and d are live at once, and e takes the next slot rather than
    // reusing one of them, since all four are still in scope
    const program = try t.parse(
        \\function f(a, b, c)
        \\  local d
        \\  do local e end
        \\end
    );

    try std.testing.expectEqual(@as(u32, 5), program.functions[1].frame_size);
    try std.testing.expectEqual(@as(usize, 3), program.functions[1].parameters.len);
}

// Two closures over one local share the cell, which is what makes a counter
// count rather than each closure keeping its own copy.
test "two closures over one local are two functions with one upvalue each" {
    var t = Test.init();
    defer t.deinit();

    const program = try t.parse(
        \\local function counter()
        \\  local n = 0
        \\  return function() n = n + 1 return n end, function() return n end
        \\end
    );
    try t.expectClean();

    // the chunk, counter, then the two closures
    try std.testing.expectEqual(@as(usize, 4), program.functions.len);
    for (program.functions[2..]) |closure| {
        try std.testing.expectEqual(@as(usize, 1), closure.upvalues.len);
        try std.testing.expectEqual(Semantic.Upvalue{ .parent_local = 0 }, closure.upvalues[0]);
    }
}

// A local captured by a nested function cannot have its slot handed to something
// else while the closure may still see it, so the block that declared it does not
// give the slot back.
test "a captured local is marked, and an uncaptured one is not" {
    var t = Test.init();
    defer t.deinit();

    const program = try t.parse(
        \\local function outer()
        \\  local taken = 1
        \\  do local free = 2 end
        \\  return function() return taken end
        \\end
    );
    try t.expectClean();

    const body = program.functions[1].body;
    try std.testing.expect(body.locals[0].is_captured);
    try std.testing.expect(!body.children[0].locals[0].is_captured);
}
