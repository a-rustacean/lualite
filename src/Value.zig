const std = @import("std");

const num = @import("Number.zig");
const Number = num.Number;
const Object = @import("Object.zig");
const Str = @import("Str.zig");
const Ast = @import("Ast.zig");

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
    native_function: NativeFunction,
    thread: *Thread,

    /// `type` as the base library spells it, which says `number` for both halves
    /// of the split. `math.type` is the one that tells them apart.
    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nil => "nil",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .table => "table",
            .function, .native_function => "function",
            .thread => "thread",
        };
    }

    /// `math.type` is `type` for everything but a number, where it says which half
    /// of the split it is. A value that is not a number has no `math.type` at all,
    /// which is what returning null is for.
    pub fn mathType(v: Value) ?[]const u8 {
        return switch (v) {
            .number => |n| if (n.isInt()) "integer" else "float",
            .nil, .boolean, .string, .table, .function, .native_function, .thread => null,
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
            .native_function => |x| switch (b) {
                .native_function => |y| x == y,
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

pub const NativeFunction = enum {
    base_print,
    base_type,
    base_tostring,
    base_tonumber,
    base_assert,
    base_error,
    base_pcall,
    base_xpcall,
    base_select,
    base_rawequal,
    base_rawget,
    base_rawset,
    base_rawlen,
    base_setmetatable,
    base_getmetatable,
    base_load,
    base_loadfile,
    base_dofile,
    base_warn,
    base_collectgarbage,
    next,
    ipairs_iterator,
    pairs,
    ipairs,
    table_insert,
    table_remove,
    table_concat,
    table_unpack,
    table_pack,
    table_move,
    table_sort,
    string_len,
    string_sub,
    string_rep,
    string_reverse,
    string_upper,
    string_lower,
    string_byte,
    string_char,
    string_find,
    string_match,
    string_gmatch,
    string_gmatch_iterator,
    string_gsub,
    string_format,
    string_pack,
    string_packsize,
    string_unpack,
    string_dump,
    utf8_char,
    utf8_len,
    utf8_codepoint,
    utf8_offset,
    utf8_codes,
    utf8_codes_iterator,
    utf8_codes_iterator_lax,
    math_abs,
    math_floor,
    math_ceil,
    math_sqrt,
    math_fmod,
    math_max,
    math_min,
    math_tointeger,
    math_type,
    math_sin,
    math_cos,
    math_tan,
    math_asin,
    math_acos,
    math_atan,
    math_exp,
    math_log,
    math_deg,
    math_rad,
    math_modf,
    math_ult,
    math_random,
    math_randomseed,
    os_clock,
    os_time,
    os_difftime,
    os_getenv,
    os_date,
    os_execute,
    os_remove,
    os_rename,
    os_setlocale,
    os_exit,
    os_tmpname,
    io_open,
    io_write,
    io_flush,
    io_type,
    io_close,
    io_lines,
    io_input,
    io_output,
    io_read,
    io_tmpfile,
    io_index,
    file_read,
    file_write,
    file_flush,
    file_close,
    file_seek,
    file_lines,
    file_setvbuf,
    file_lines_iterator,
    file_tostring,
    coroutine_create,
    coroutine_resume,
    coroutine_yield,
    coroutine_status,
    coroutine_running,
    coroutine_isyieldable,
    coroutine_close,
    coroutine_wrap,
    /// The callable `coroutine.wrap` hands back: a function whose `bound` is
    /// the thread and whose `native` is this entry.
    coroutine_wrap_call,
};

/// A table. Its mechanics live in Table.zig, which is where the array and hash
/// parts that make `#`, `next` and `ipairs` behave are written. This file keeps
/// the tag that points at one.
pub const Table = @import("Table.zig").Table;

/// A closure over an AST function body. Captured cells are shared between
/// closures over the same locals, so assignments remain visible after return.
pub const Function = struct {
    common: Object.Common,
    semantics: *const @import("Semantic.zig").Program,
    body: *const Ast.FunctionBody,
    function_index: u32,
    captures: []*Cell,
    environment: *Cell,
    /// A Lua closure has no native behind it. `coroutine.wrap` builds a
    /// function value that does: calling it runs `native` with `bound` in
    /// front of every argument, which is how the thread stays attached.
    native: ?NativeFunction = null,
    bound: Value = .nil,
};

pub const Cell = struct { value: Value };

/// A coroutine. The frame stack and the status go here rather than being a bare
/// pointer, so that a thread is one object for the collector to reach.
pub const Thread = struct {
    common: Object.Common,
    /// The runtime's `Coroutine` behind this thread. Typed as an opaque
    /// pointer so the value layer does not have to import the VM.
    coroutine: ?*anyopaque = null,
};

const testing = std.testing;

test "a number is one value or the other, and says which" {
    // `type` says number for both halves, which is the point of `math.type`
    try testing.expectEqualStrings("number", (Value{ .number = Number.fromInt(1) }).typeName());
    try testing.expectEqualStrings("number", (Value{ .number = Number.fromFloat(1) }).typeName());

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
