const std = @import("std");

// The header every heap object starts with, and the list the collector will walk.
//
// The header is here from the first increment rather than added when the collector
// arrives, because it fixes the layout everything else has to fit into. A `Value`
// pointing at a string, a table or a function is a pointer to one of these, and
// the collector reaches it by reading the kind out of the header rather than by
// knowing which field of which union holds it.
//
// The collector is a stop-the-world mark and sweep. Nothing mutates while it runs,
// since the mutator is one thread and nothing calls out during collection, so no
// write barrier is needed and a value can be overwritten with no bookkeeping at
// all. Only the shape lands here; the sweep itself comes with tables, which are
// the first thing that can make a cycle.

/// The part every heap object starts with. Anything the collector allocates has to
/// begin with one of these named `common`, since that is how the list finds its
/// way in and out of the object.
pub const Common = struct {
    kind: Kind,
    mark: Mark,

    /// Every object the collector knows about is on one list. An object joins it
    /// when it is made and leaves when it is freed, which is what lets a sweep free
    /// the ones that were never reached without the collector knowing how anything
    /// is shaped inside.
    prev: ?*Common,
    next: ?*Common,
};

pub const Kind = enum(u8) {
    string,
    table,
    function,
    userdata,
    thread,
};

/// Placeholder payload for the userdata kind until the standard library adds
/// userdata semantics. It still has a concrete allocation type for the sweep.
pub const Userdata = struct { common: Common };

/// White is "not reached", which is what a sweep frees. Black is "reached by the
/// marker", which is still here.
pub const Mark = enum(u8) {
    white,
    black,
};

pub const Error = error{OutOfMemory};

/// Makes objects and remembers them, so that a sweep has one list to walk.
pub const Tracker = struct {
    allocator: std.mem.Allocator,
    first: ?*Common = null,
    last: ?*Common = null,
    /// how many objects are live, which is what a sweep compares against how many
    /// the marker reached
    count: usize = 0,
    /// Bytes in individually tracked objects, used by collectgarbage("count").
    /// Auxiliary table storage and VM frames are not included in this estimate.
    memory_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Tracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(tracker: *Tracker) void {
        tracker.* = undefined;
    }

    /// Memory for one object of `T`, linked onto the list with its kind.
    ///
    /// Every heap object goes through here rather than straight to the allocator,
    /// so that the list stays the one thing the sweep reads.
    pub fn alloc(tracker: *Tracker, comptime T: type, kind: Kind) Error!*T {
        const memory = try tracker.allocator.create(T);
        errdefer tracker.allocator.destroy(memory);

        const common: *Common = &memory.common;
        common.* = .{ .kind = kind, .mark = .white, .prev = tracker.last, .next = null };

        if (tracker.last) |previous| previous.next = common;
        tracker.last = common;
        if (tracker.first == null) tracker.first = common;
        tracker.count += 1;
        tracker.memory_bytes = std.math.add(usize, tracker.memory_bytes, @sizeOf(T)) catch std.math.maxInt(usize);

        return memory;
    }

    /// Frees one object and takes it off the list. The memory has to be what `alloc`
    /// handed out, since that is where the list pointer came from.
    pub fn free(tracker: *Tracker, memory: anytype) void {
        tracker.memory_bytes -|= @sizeOf(@TypeOf(memory.*));
        tracker.unlink(&memory.common);
        tracker.allocator.destroy(memory);
    }

    /// Takes one object off the list without freeing it, for one that is being
    /// moved rather than dropped. The caller puts it back, which is `link`.
    pub fn unlink(tracker: *Tracker, common: *Common) void {
        if (common.prev) |previous| previous.next = common.next else tracker.first = common.next;
        if (common.next) |next| next.prev = common.prev else tracker.last = common.prev;
        tracker.count -= 1;
    }

    /// Walks every object against a context that has a `count` method, which is
    /// what a mark and a sweep both are. The order is allocation order and it is
    /// the same every time.
    pub fn walk(tracker: *const Tracker, context: anytype) void {
        var current = tracker.first;
        while (current) |common| : (current = common.next) context.count(common);
    }
};

const testing = std.testing;

const Thing = struct { common: Common, tag: u8 };

test "an object joins the list and leaves it" {
    var tracker: Tracker = .init(testing.allocator);
    defer tracker.deinit();

    const a = try tracker.alloc(Thing, .table);
    const b = try tracker.alloc(Thing, .function);

    a.tag = 1;
    b.tag = 2;
    try testing.expectEqual(@as(usize, 2), tracker.count);

    tracker.free(a);
    try testing.expectEqual(@as(usize, 1), tracker.count);

    // the list closed up over it, so what is left is still reachable
    try testing.expectEqual(@as(*Common, &b.common), tracker.first);

    tracker.free(b);
    try testing.expectEqual(@as(usize, 0), tracker.count);
    try testing.expect(tracker.first == null);
    try testing.expect(tracker.last == null);
}

test "the kind is written where a Value pointing at it can read it" {
    var tracker: Tracker = .init(testing.allocator);
    defer tracker.deinit();

    const thing = try tracker.alloc(Thing, .thread);

    try testing.expectEqual(Kind.thread, thing.common.kind);
    try testing.expectEqual(Mark.white, thing.common.mark);

    tracker.free(thing);
}

/// Walks the list and checks it comes back in the order it went on, which is what
/// a mark and a sweep both rely on.
const Walked = struct {
    wanted: []const Kind,
    seen: usize = 0,
    /// recorded rather than asserted, so a difference names itself here rather
    /// than three frames up
    wrong: ?Kind = null,

    fn count(self: *Walked, common: *Common) void {
        if (self.seen >= self.wanted.len) {
            self.wrong = common.kind;
            return;
        }
        if (self.wanted[self.seen] != common.kind) self.wrong = common.kind;
        self.seen += 1;
    }
};

test "the list is walked in allocation order" {
    var tracker: Tracker = .init(testing.allocator);
    defer tracker.deinit();

    const wanted = [_]Kind{ .string, .table, .thread, .function };

    var made: [wanted.len]*Thing = undefined;
    for (&made, wanted) |*slot, kind| slot.* = try tracker.alloc(Thing, kind);

    var walked: Walked = .{ .wanted = &wanted };
    tracker.walk(&walked);

    try testing.expect(walked.wrong == null);
    try testing.expectEqual(wanted.len, walked.seen);

    for (made) |thing| tracker.free(thing);
}

test "every object the tracker made is freed" {
    const Counting = std.testing.allocator;

    var tracker: Tracker = .init(Counting);
    defer tracker.deinit();

    // the testing allocator fails the test on anything still live at the end, so
    // the pointers are held onto rather than re-derived from the header afterwards:
    // walking gives back the header, and a header alone does not name the type it
    // fronts, so `free` would have nothing concrete to hand back to the allocator
    var made: [8]*Thing = undefined;
    for (&made, 0..) |*slot, i| {
        const thing = try tracker.alloc(Thing, .table);
        thing.tag = @intCast(i);
        slot.* = thing;
    }

    const all_tables = @as([8]Kind, @splat(.table));
    var walked: Walked = .{ .wanted = &all_tables };
    tracker.walk(&walked);
    try testing.expectEqual(@as(usize, 8), walked.seen);

    for (made) |thing| tracker.free(thing);

    try testing.expectEqual(@as(usize, 0), tracker.count);
}
