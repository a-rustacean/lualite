const std = @import("std");
const Object = @import("Object.zig");
const Str = @import("Str.zig");
const Table = @import("Table.zig").Table;
const Value = @import("Value.zig").Value;

/// Stop-the-world mark-and-sweep over tracked heap objects. Short interned
/// strings live in the interner arena and are intentionally retained there;
/// long strings and all other heap objects are reclaimed here.
pub const Collector = struct {
    allocator: std.mem.Allocator,

    pub const Error = error{OutOfMemory};
    pub const Result = struct { live: usize, reclaimed: usize };

    fn ignoreReclaim(_: void, _: *Object.Common) void {}

    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator };
    }

    /// `roots` is the complete set of values held by the VM at a safepoint.
    /// Tables trace live keys and values. Closures trace their captured cells.
    pub fn collect(collector: *Collector, tracker: *Object.Tracker, roots: []const Value) Error!Result {
        return collector.collectWith(tracker, roots, {}, ignoreReclaim);
    }

    /// Like `collect`, but lets an owner forget objects immediately before their
    /// storage is released. This keeps owner-side teardown lists from retaining
    /// dangling pointers after a sweep.
    pub fn collectWith(
        collector: *Collector,
        tracker: *Object.Tracker,
        roots: []const Value,
        context: anytype,
        comptime on_reclaim: fn (@TypeOf(context), *Object.Common) void,
    ) Error!Result {
        var stack: std.ArrayList(Value) = .empty;
        defer stack.deinit(collector.allocator);

        var current = tracker.first;
        while (current) |common| : (current = common.next) common.mark = .white;
        for (roots) |root| try collector.pushValue(&stack, root);

        while (stack.pop()) |value| {
            switch (value) {
                .table => |table| {
                    if (table.metatable) |metatable| try collector.pushValue(&stack, .{ .table = metatable });
                    for (table.array) |child| try collector.pushValue(&stack, child);
                    for (table.nodes) |node| {
                        // A deleted hash entry keeps its key as a dead-key
                        // marker until rehash. The slot may still be searched
                        // by `next`, so the key object must remain alive.
                        if (node.key != .nil) try collector.pushValue(&stack, node.key);
                        if (node.value != .nil) {
                            try collector.pushValue(&stack, node.value);
                        }
                    }
                },
                .function => |function| {
                    try collector.pushValue(&stack, function.environment.value);
                    for (function.captures) |cell| try collector.pushValue(&stack, cell.value);
                },
                else => {},
            }
        }

        var reclaimed: usize = 0;
        current = tracker.first;
        while (current) |common| {
            const next = common.next;
            if (common.mark == .white) {
                on_reclaim(context, common);
                switch (common.kind) {
                    .string => (@as(*Str.Str, @fieldParentPtr("common", common))).deinit(tracker),
                    .table => (@as(*Table, @fieldParentPtr("common", common))).deinit(tracker),
                    .function => tracker.free(@as(*@import("Value.zig").Function, @fieldParentPtr("common", common))),
                    .thread => tracker.free(@as(*@import("Value.zig").Thread, @fieldParentPtr("common", common))),
                    .userdata => tracker.free(@as(*Object.Userdata, @fieldParentPtr("common", common))),
                }
                reclaimed += 1;
            } else {
                common.mark = .white;
            }
            current = next;
        }

        return .{ .live = tracker.count, .reclaimed = reclaimed };
    }

    fn pushValue(collector: *Collector, stack: *std.ArrayList(Value), value: Value) Error!void {
        const common: ?*Object.Common = switch (value) {
            // Short interned strings are arena-owned and not swept; long strings
            // are tracked, marked, and have no outgoing references to trace.
            .string => |s| if (s.isLong()) &s.common else null,
            .table => |t| &t.common,
            .function => |f| &f.common,
            .thread => |t| &t.common,
            else => null,
        };
        if (common) |header| {
            if (header.mark == .white) {
                header.mark = .black;
                stack.append(collector.allocator, value) catch return error.OutOfMemory;
            }
        }
    }
};

const testing = std.testing;

fn integerKey(n: i64) Value {
    return .{ .number = @import("Number.zig").Number.fromInt(n) };
}

test "collection traces table cycles and retained dead keys, then sweeps garbage" {
    var tracker: Object.Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var collector = Collector.init(testing.allocator);
    defer _ = collector.collect(&tracker, &.{}) catch {};

    const root = try Table.create(testing.allocator, &tracker);
    const child = try Table.create(testing.allocator, &tracker);
    const kept_key = try interner.intern("a long string key kept alive after removal");
    try root.set(integerKey(1), .{ .table = child });
    try child.set(integerKey(1), .{ .table = root });
    try child.set(.{ .string = kept_key }, .{ .boolean = true });
    try child.set(.{ .string = kept_key }, .nil);

    const garbage_cycle = try Table.create(testing.allocator, &tracker);
    try garbage_cycle.set(integerKey(1), .{ .table = garbage_cycle });
    _ = try interner.intern("an unreachable long string allocated separately");

    const rooted = [_]Value{.{ .table = root }};
    const first = try collector.collect(&tracker, &rooted);
    try testing.expectEqual(@as(usize, 3), first.live);
    try testing.expectEqual(@as(usize, 2), first.reclaimed);
    try testing.expect(root.get(integerKey(1)).table == child);
    try testing.expect(child.get(integerKey(1)).table == root);
    try testing.expectEqualStrings("a long string key kept alive after removal", kept_key.slice());

    const second = try collector.collect(&tracker, &.{});
    try testing.expectEqual(@as(usize, 0), second.live);
    try testing.expectEqual(@as(usize, 3), second.reclaimed);
}
