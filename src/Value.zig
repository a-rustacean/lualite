const std = @import("std");

const num = @import("Number.zig");
const Number = num.Number;
const Object = @import("Object.zig");
const Str = @import("Str.zig");

/// What the runtime holds. The header every heap object carries is in Object.zig,
/// and the reason it is there now rather than when the collector is written is
/// written there too.
/// A value the runtime holds. Nil, a boolean and a number need nothing allocated,
/// which is why they are tags over their payload rather than pointers, and is why
/// only the other four are things the collector has to reach.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: Number,
    string: *Str.Str,
    table: *Table,
    function: *Function,
    thread: *Thread,

    /// `type` as the base library spells it.
    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nil => "nil",
            .boolean => "boolean",
            .number => |n| if (n.isInt()) "integer" else "float",
            .string => "string",
            .table => "table",
            .function => "function",
            .thread => "thread",
        };
    }

    /// `math.type` is `type` for everything but a number, where it says which half
    /// of the split it is. A value that is not a number has no `math.type` at all,
    /// which is what returning null is for.
    pub fn mathType(v: Value) ?[]const u8 {
        return switch (v) {
            .number => |n| if (n.isInt()) "integer" else "float",
            .nil, .boolean, .string, .table, .function, .thread => null,
        };
    }

    /// Equality as `==` has it, which crosses over between the two number types,
    /// compares strings by content rather than by identity, and compares the rest
    /// by identity.
    pub fn equal(a: Value, b: Value) bool {
        return switch (a) {
            .nil => b == .nil,
            .boolean => |x| switch (b) {
                .boolean => |y| x == y,
                else => false,
            },
            .number => |x| switch (b) {
                .number => |y| num.equal(x, y),
                else => false,
            },
            .string => |x| switch (b) {
                .string => |y| Str.equal(x, y),
                else => false,
            },
            // A table, a closure and a thread are equal to themselves and to
            // nothing else. `luaV_equalval` compares the pointers rather than
            // anything inside them, so `t == t` holds and two tables holding the
            // same contents do not compare equal. `__eq` is not consulted here;
            // that is metamethod work, which is Phase 7.
            .table => |x| switch (b) {
                .table => |y| x == y,
                else => false,
            },
            .function => |x| switch (b) {
                .function => |y| x == y,
                else => false,
            },
            .thread => |x| switch (b) {
                .thread => |y| x == y,
                else => false,
            },
        };
    }

    /// Everything but nil and false is truthy, zero and the empty string included,
    /// which is what `OP_TEST` does.
    pub fn truthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }
};

/// A table. Only the shape is here so far: the array and hash parts that make
/// `#`, `next` and `ipairs` behave arrive with the collector, which needs them to
/// have somewhere to mark from.
pub const Table = struct {
    common: Object.Common,
};

/// A closure. The upvalues are shared between closures over the same locals,
/// which is what makes a counter count rather than each closure keeping its own
/// copy, and they arrive with the collector for the same reason tables' parts do.
pub const Function = struct {
    common: Object.Common,
};

/// A coroutine. The frame stack and the status go here rather than being a bare
/// pointer, so that a thread is one object for the collector to reach.
pub const Thread = struct {
    common: Object.Common,
};

const testing = std.testing;

test "a number is one value or the other, and says which" {
    try testing.expectEqualStrings("integer", (Value{ .number = Number.fromInt(1) }).typeName());
    try testing.expectEqualStrings("float", (Value{ .number = Number.fromFloat(1) }).typeName());

    try testing.expectEqualStrings("integer", (Value{ .number = Number.fromInt(1) }).mathType().?);
    try testing.expectEqualStrings("float", (Value{ .number = Number.fromFloat(1) }).mathType().?);

    // and nothing else has a math.type at all
    try testing.expect(((Value{ .nil = {} }).mathType() == null));
    try testing.expect((Value{ .boolean = true }).mathType() == null);
}

test "1 and 1.0 are equal without being the same value" {
    const int: Value = .{ .number = Number.fromInt(1) };
    const float: Value = .{ .number = Number.fromFloat(1) };

    try testing.expect(int.equal(float));
    try testing.expect(float.equal(int));
    try testing.expect(!int.equal(.{ .number = Number.fromInt(2) }));
}

test "a number is never equal to a string, though the two read alike" {
    var tracker: Object.Tracker = .init(testing.allocator);
    defer tracker.deinit();

    var interner: Str.Interner = try .init(testing.allocator, &tracker);
    defer interner.deinit();

    const one: Value = .{ .number = Number.fromInt(1) };
    const text: Value = .{ .string = try interner.intern("1") };

    try testing.expect(!one.equal(text));
    try testing.expect(!text.equal(one));
}

test "two strings with the same bytes are equal whichever way round" {
    var tracker: Object.Tracker = .init(testing.allocator);
    defer tracker.deinit();

    var interner: Str.Interner = try .init(testing.allocator, &tracker);
    defer interner.deinit();

    const a: Value = .{ .string = try interner.intern("same") };
    const b: Value = .{ .string = try interner.intern("same") };
    const c: Value = .{ .string = try interner.intern("other") };

    try testing.expect(a.equal(b));
    try testing.expect(b.equal(a));
    try testing.expect(!a.equal(c));
}

test "a table, a closure and a thread are equal only to themselves" {
    var tracker: Object.Tracker = .init(testing.allocator);
    defer tracker.deinit();

    const table = try tracker.alloc(Table, .table);
    const same = try tracker.alloc(Table, .table);
    const function = try tracker.alloc(Function, .function);
    const other_function = try tracker.alloc(Function, .function);
    const thread = try tracker.alloc(Thread, .thread);
    const other_thread = try tracker.alloc(Thread, .thread);

    // `t == t` is true, which it was not before: identity is a pointer compare
    try testing.expect((Value{ .table = table }).equal(.{ .table = table }));
    try testing.expect((Value{ .function = function }).equal(.{ .function = function }));
    try testing.expect((Value{ .thread = thread }).equal(.{ .thread = thread }));

    // two of a kind that are not the same one are not equal, since nothing inside
    // them is consulted
    try testing.expect(!(Value{ .table = table }).equal(.{ .table = same }));
    try testing.expect(!(Value{ .function = function }).equal(.{ .function = other_function }));
    try testing.expect(!(Value{ .thread = thread }).equal(.{ .thread = other_thread }));

    // and they are never equal to a value of another type
    try testing.expect(!(Value{ .table = table }).equal(.nil));
    try testing.expect(!(Value{ .function = function }).equal(.{ .table = table }));

    tracker.free(table);
    tracker.free(same);
    tracker.free(function);
    tracker.free(other_function);
    tracker.free(thread);
    tracker.free(other_thread);
}

test "everything but nil and false is truthy" {
    var tracker: Object.Tracker = .init(testing.allocator);
    defer tracker.deinit();

    var interner: Str.Interner = try .init(testing.allocator, &tracker);
    defer interner.deinit();

    const zero: Value = .{ .number = Number.fromInt(0) };
    const empty: Value = .{ .string = try interner.intern("") };

    try testing.expect(!(Value{ .nil = {} }).truthy());
    try testing.expect(!(Value{ .boolean = false }).truthy());
    try testing.expect((Value{ .boolean = true }).truthy());
    try testing.expect(zero.truthy());
    try testing.expect(empty.truthy());
}

test "every heap value points at something with the header on it" {
    var tracker: Object.Tracker = .init(testing.allocator);
    defer tracker.deinit();

    const table = try tracker.alloc(Table, .table);
    const function = try tracker.alloc(Function, .function);
    const thread = try tracker.alloc(Thread, .thread);

    // the kind is readable off the pointer a `Value` holds, which is what lets the
    // collector find its way without knowing what it is holding
    try testing.expectEqual(Object.Kind.table, table.common.kind);
    try testing.expectEqual(Object.Kind.function, function.common.kind);
    try testing.expectEqual(Object.Kind.thread, thread.common.kind);

    const as_value: Value = .{ .table = table };
    try testing.expectEqualStrings("table", as_value.typeName());

    tracker.free(table);
    tracker.free(function);
    tracker.free(thread);
}
