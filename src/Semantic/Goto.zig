const std = @import("std");

const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");
const Diagnostic = @import("../Diagnostic.zig");

const Semantic = @import("../Semantic.zig");
const Test = Semantic.Test;

// A `goto` names a label written later in the same block quite often, so a goto
// waits for a label to turn up. These are the checks that decide whether one ever
// does, and whether it was allowed to reach the label it found.

test "a goto to a label written later in the same block" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("for i = 1, 10 do\n  if i then goto continue end\n  ::continue::\nend");

    try t.expectClean();
}

test "a goto with no label by that name" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("goto nowhere");

    try t.expectCount(1);
    try t.expectKind(0, .undefined_label);
    try t.expectName(0, "nowhere");
}

// A label is visible in the block it is written in and in every block inside
// that, so a second one of the same name anywhere up the chain is a duplicate.
test "a label is declared twice" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("::a::\n::a::");

    try t.expectCount(1);
    try t.expectKind(0, .duplicate_label);
    try t.expectName(0, "a");
}

test "a label inside a block duplicates one outside it" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("::a::\ndo ::a:: end");

    try t.expectCount(1);
    try t.expectKind(0, .duplicate_label);
}

test "two labels of the same name in blocks beside each other" {
    var t = Test.init();
    defer t.deinit();

    // neither block is inside the other, so neither label is in scope where the
    // other one sits
    _ = try t.parse("do ::a:: end\ndo ::a:: end");

    try t.expectClean();
}

// The one jump Lua will not make, because the frame the local sits in is gone by
// the time the jump lands.
test "a goto that brings a local into scope" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("goto lbl\nlocal x = 1\n::lbl::\nprint(x)");

    try t.expectCount(1);
    try t.expectKind(0, .goto_into_local_scope);
    try t.expectName(0, "lbl");
}

test "a goto that brings a local of a later block into scope" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\local a = 1
        \\do
        \\  goto out
        \\end
        \\local b = 2
        \\::out::
        \\print(b)
    );

    try t.expectCount(1);
    try t.expectKind(0, .goto_into_local_scope);
    // the local it names is the one between the goto and the label
    try std.testing.expectEqualStrings("b", t.errors()[0].opened_name);
}

// A label at the end of a block is treated as though the locals that block
// declared had already gone out of scope, since nothing can jump past the end of
// a block to reach it.
test "a label at the end of a block counts its block's locals as gone" {
    var t = Test.init();
    defer t.deinit();

    // `b` is in scope at the label as written, but the label is the last thing in
    // the chunk, so the jump does not bring it into scope
    _ = try t.parse(
        \\local a = 1
        \\do
        \\  goto out
        \\end
        \\local b = 2
        \\::out::
    );

    try t.expectClean();
}

test "a label followed by a statement counts its block's locals as in scope" {
    var t = Test.init();
    defer t.deinit();

    // the same shape, with one more statement after the label
    _ = try t.parse(
        \\local a = 1
        \\do
        \\  goto out
        \\end
        \\local b = 2
        \\::out::
        \\print(b)
    );

    try t.expectCount(1);
    try t.expectKind(0, .goto_into_local_scope);
}

// `;` and a label are no-ops, so a label followed by either is still the last
// statement in the block for this purpose.
test "a label followed by a no-op statement still counts as last" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\local a = 1
        \\do
        \\  goto out
        \\end
        \\local b = 2
        \\::out::
        \\;
    );

    try t.expectClean();
}

// A `repeat` body is closed by its `until` condition rather than by `end`, so a
// label at the end of one is followed by the condition and its locals still count.
test "a label at the end of a repeat body counts its locals as in scope" {
    var t = Test.init();
    defer t.deinit();

    // the label is the last statement in the body, but the body is closed by its
    // `until` condition rather than by `end`, so `y` is still in scope where the
    // label sits and the jump brings it in
    _ = try t.parse(
        \\repeat
        \\  goto out
        \\  local y = 2
        \\  ::out::
        \\until true
    );

    try t.expectCount(1);
    try t.expectKind(0, .goto_into_local_scope);
    try std.testing.expectEqualStrings("y", t.errors()[0].opened_name);
}

// The same shape in a `do` block, which is closed by `end`, so the label is last
// and its locals do not count.
test "a label at the end of a do block counts its locals as gone" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\do
        \\  goto out
        \\  local y = 2
        \\  ::out::
        \\end
    );

    try t.expectClean();
}

test "a label at the end of a loop body counts its locals as gone" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\while true do
        \\  goto out
        \\  local y = 2
        \\  ::out::
        \\end
        \\::out::
    );

    try t.expectClean();
}

test "a goto that leaves a scope is fine" {
    var t = Test.init();
    defer t.deinit();

    // the local goes out of scope before the label, so nothing is brought in
    _ = try t.parse(
        \\do
        \\  local x = 1
        \\  goto out
        \\end
        \\::out::
    );

    try t.expectClean();
}

test "a goto in an inner block reaches a label in the one around it" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("do\n  do\n    goto out\n  end\nend\n::out::");

    try t.expectClean();
}

// Two labels of one name, an inner and an outer, with a goto written before both.
// The inner one does not claim the goto, since the goto is not inside its block,
// and the outer one does, being the last statement in a block that counts its
// locals as gone. Reusing a label name across nested blocks is ordinary code.
test "a goto reaches the outer of two labels of one name" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\do goto c
        \\local t = 1
        \\do ::c:: end
        \\::c::
        \\end
    );

    try t.expectClean();
}

// The same shape with only the inner label, so the goto has nothing left to reach
// and is reported once its function has been walked whole.
test "a goto with only an inner label of that name" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\do goto c
        \\local t = 1
        \\do ::c:: end
        \\end
    );

    try t.expectCount(1);
    try t.expectKind(0, .undefined_label);
    try t.expectName(0, "c");
}

// With the outer label no longer last, it counts its block's locals as in scope
// and the goto does bring one into scope, which is the one jump Lua will not make.
test "a goto reaching the outer label enters the scope of its local" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\do goto c
        \\local t = 1
        \\do ::c:: end
        \\::c::
        \\print("x")
        \\end
    );

    try t.expectCount(1);
    try t.expectKind(0, .goto_into_local_scope);
    try std.testing.expectEqualStrings("t", t.errors()[0].opened_name);
}

// A label in a block a goto is not written in is not visible to it, which is what
// stops a goto from reaching into a block it is outside of.
test "a goto cannot reach a label in a block it has left" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\do
        \\  local x = 1
        \\  ::skip::
        \\  print(x)
        \\end
        \\goto skip
    );

    try t.expectCount(1);
    try t.expectKind(0, .undefined_label);
    try t.expectName(0, "skip");
}

test "a goto cannot reach a label in another function" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("::out::\nlocal function f() goto out end");

    try t.expectCount(1);
    try t.expectKind(0, .undefined_label);
}

test "a goto out of a loop to a label around it" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\for i = 1, 3 do
        \\  goto done
        \\end
        \\::done::
        \\print("after")
    );

    try t.expectClean();
}

test "two gotos to one label are both claimed" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("do goto l end\ngoto l\n::l::");

    try t.expectClean();
}

test "a label written in a loop is visible in the loop and in what is nested in it" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse(
        \\while true do
        \\  ::top::
        \\  do
        \\    goto top
        \\  end
        \\end
    );

    try t.expectClean();
}
