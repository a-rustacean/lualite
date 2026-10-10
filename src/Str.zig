const std = @import("std");

const Object = @import("Object.zig");

/// Lua's strings, and the part of being one that shows up everywhere.
///
/// A string is compared by content, but comparing bytes on every table lookup is
/// not affordable, so strings are interned: two strings with the same bytes are
/// one object and compare by pointer. Lua interns the short ones and compares the
/// long ones by content, since a long string is rarely a repeated key and paying
/// to keep it resident costs more than the comparison saves. The split is
/// `LUAI_MAXSHORTLEN`, 40 bytes.
/// The length at or below which a string is interned, from `llimits.h`.
pub const max_short_len = 40;

/// One string object. Both shapes start with the header the collector needs, so a
/// `Value` pointing at a string is a pointer either way.
pub const Str = struct {
    common: Object.Common,

    /// The bytes, inline for a short string. A long one points at `long_bytes`
    /// instead and this is unused.
    bytes: [max_short_len]u8,
    len: u32,

    /// Where the bytes are when they are not inline, and the allocator that owns
    /// them. A long string is freed one at a time rather than with an arena, since
    /// only the collector knows when it is unreachable, so it holds onto the
    /// allocator it was made with.
    long_bytes: ?[]u8,
    long_allocator: ?std.mem.Allocator,

    fn isLong(s: *const Str) bool {
        return s.long_bytes != null;
    }

    /// The bytes, whether they are inline or behind the pointer.
    pub fn slice(s: *const Str) []const u8 {
        return if (s.isLong()) s.long_bytes.?[0..s.len] else s.bytes[0..s.len];
    }

    /// Frees the bytes of a long string and then the string itself. A short string
    /// holds no bytes of its own and needs none freed, since the arena it sits in
    /// is freed whole, but the object is still tracked and still has to go.
    ///
    /// This is what the sweep will do for every long string it finds. Calling it
    /// directly is what the tests do, and what teardown does until the collector
    /// arrives to take the job over.
    pub fn deinit(s: *Str, tracker: *Object.Tracker) void {
        if (s.long_bytes) |long| s.long_allocator.?.free(long);

        tracker.free(s);
    }
};

/// The interning table and the arena the short strings live in.
///
/// Short strings go in one bump arena so that laying one out never moves another,
/// which is what lets a pointer stay a key. A long string is not interned at all:
/// the table records that one is already around so a lookup can find it, but a
/// second string with the same bytes is a second object, compared by content.
pub const Interner = struct {
    allocator: std.mem.Allocator,
    tracker: *Object.Tracker,

    /// Keyed by the bytes, with the string as the value. The key is a copy of the
    /// bytes that lives inside the string itself rather than wherever the caller
    /// happened to have them, and the arena never moves what is already in it, so
    /// the key stays good for as long as the table does.
    table: std.HashMapUnmanaged([]const u8, *Str, Context, 80),

    short_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, tracker: *Object.Tracker) std.mem.Allocator.Error!Interner {
        return .{
            .allocator = allocator,
            .tracker = tracker,
            .table = .empty,
            .short_arena = .init(allocator),
        };
    }

    pub fn deinit(interner: *Interner) void {
        interner.table.deinit(interner.allocator);
        interner.short_arena.deinit();
        interner.* = undefined;
    }

    /// A string for these bytes. A short one comes back as the same object every
    /// time it is asked for; a long one is a fresh object each time, which is the
    /// same trade Lua makes.
    pub fn intern(interner: *Interner, bytes: []const u8) std.mem.Allocator.Error!*Str {
        // a long string never reaches the table: it is not interned, so asking for
        // one twice gives two objects that compare equal by content
        if (bytes.len > max_short_len) return interner.internLong(bytes);

        const entry = try interner.table.getOrPut(interner.allocator, bytes);
        if (entry.found_existing) return entry.value_ptr.*;

        const made = try interner.internShort(bytes);

        // the key defaults to the caller's bytes, which may be gone by the time
        // anyone looks; the string's own copy is the one that lasts
        entry.key_ptr.* = made.slice();
        entry.value_ptr.* = made;

        return made;
    }

    /// The short string for these bytes if one has been made already. A long string
    /// is never interned, so there is never one to find.
    pub fn find(interner: *const Interner, bytes: []const u8) ?*Str {
        if (bytes.len > max_short_len) return null;

        return interner.table.get(bytes);
    }

    fn internShort(interner: *Interner, bytes: []const u8) std.mem.Allocator.Error!*Str {
        // the short arena, so that laying one out never moves another
        const str = interner.short_arena.allocator().create(Str) catch return error.OutOfMemory;

        str.* = .{
            .common = .{ .kind = .string, .mark = .white, .prev = null, .next = null },
            .bytes = @splat(0),
            .len = @intCast(bytes.len),
            .long_bytes = null,
            .long_allocator = null,
        };
        @memcpy(str.bytes[0..bytes.len], bytes);

        return str;
    }

    fn internLong(interner: *Interner, bytes: []const u8) std.mem.Allocator.Error!*Str {
        const copy = try interner.allocator.dupe(u8, bytes);
        errdefer interner.allocator.free(copy);

        const str = try interner.tracker.alloc(Str, .string);

        str.* = .{
            .common = .{ .kind = .string, .mark = .white, .prev = null, .next = null },
            .bytes = @splat(0),
            .len = @intCast(bytes.len),
            .long_bytes = copy,
            .long_allocator = interner.allocator,
        };

        return str;
    }
};

/// `luaS_hash`, so a string hashes here as it would there and `pairs` over the
/// table it keys ends up in the order the reference would give.
fn hashBytes(bytes: []const u8) u64 {
    var h: u32 = @truncate(bytes.len);

    var i = bytes.len;
    while (i > 0) {
        i -= 1;
        h ^= (h << 5) +% (h >> 2) +% bytes[i];
    }

    return h;
}

/// Two strings are the same when they are the same object, or when they are both
/// long and their bytes match. A long string is never interned, so for two of
/// them the content is the only thing that can say they are equal.
pub fn equal(a: *const Str, b: *const Str) bool {
    if (a == b) return true;
    if (!a.isLong() or !b.isLong()) return false;

    return std.mem.eql(u8, a.slice(), b.slice());
}

/// Keyed by content rather than by identity, since that is what decides whether a
/// string is already interned. Hashed as Lua would hash it, so that a table keyed
/// by strings comes out in the order the reference would give it.
const Context = struct {
    pub fn hash(_: Context, bytes: []const u8) u64 {
        return hashBytes(bytes);
    }

    pub fn eql(_: Context, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

const testing = std.testing;

/// The tracker and the interner together, because the interner holds a pointer to
/// the tracker and a tracker left to go out of scope while the interner is still
/// standing would be a pointer to nothing.
const Fixture = struct {
    tracker: Object.Tracker,
    interner: Interner,

    fn init() std.mem.Allocator.Error!Fixture {
        return .{
            .tracker = .init(testing.allocator),
            .interner = undefined,
        };
    }

    /// Frees whatever is left over, so that a test which only cares about part of
    /// it still hands back everything. The sweep will do this on its own once there
    /// is a collector to do it.
    fn deinit(self: *Fixture) void {
        var current = self.tracker.first;
        while (current) |common| : (current = common.next) {
            // only long strings are on the tracker's list so far: a short one lives
            // in the arena and goes with it
            const str: *Str = @fieldParentPtr("common", common);
            str.deinit(&self.tracker);
        }

        self.interner.deinit();
        self.tracker.deinit();
        testing.allocator.destroy(self);
    }
};

fn testFixture() !*Fixture {
    const fixture = try testing.allocator.create(Fixture);
    fixture.* = try Fixture.init();
    fixture.interner = try Interner.init(testing.allocator, &fixture.tracker);

    return fixture;
}

test "a short string is interned, so equal bytes are one object" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const a = try fixture.interner.intern("hello");
    const b = try fixture.interner.intern("hello");
    try testing.expectEqual(a, b);

    const c = try fixture.interner.intern("world");
    try testing.expect(a != c);
    try testing.expect(!equal(a, c));
}

test "the bytes come back as written, at either end of the short range" {
    var fixture = try testFixture();
    defer fixture.deinit();

    for ([_][]const u8{ "", "a", "hello", "z" ** 40 }) |text| {
        const str = try fixture.interner.intern(text);
        try testing.expectEqualStrings(text, str.slice());
        try testing.expectEqual(text.len, str.len);
    }
}

test "a string past the short range is kept apart and compares by content" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const long = "y" ** 41;
    const a = try fixture.interner.intern(long);
    const b = try fixture.interner.intern(long);

    // not the same object, since neither was interned, but the same string
    try testing.expect(a != b);
    try testing.expect(equal(a, b));
    try testing.expectEqualStrings(long, a.slice());

    // and it is on the collector's list, which a short string is not
    try testing.expect(a.common.next != null or a.common.prev != null);

    // a long one is never in the table, so there is never one to find
    try testing.expect(fixture.interner.find(long) == null);
    try testing.expect(fixture.interner.find("hello") == null);
}

test "a short string is never equal to a long one" {
    var fixture = try testFixture();
    defer fixture.deinit();

    // forty bytes and forty-one cannot be equal whatever the rest of them is
    const short = try fixture.interner.intern("z" ** 40);
    const long = try fixture.interner.intern("z" ** 41);

    try testing.expect(!equal(short, long));
    try testing.expect(!equal(long, short));
}

test "the same bytes interned twice is one object on one side of the split" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const at_limit = "w" ** 40;
    try testing.expectEqual(try fixture.interner.intern(at_limit), try fixture.interner.intern(at_limit));

    const past = "w" ** 41;
    try testing.expect(try fixture.interner.intern(past) != try fixture.interner.intern(past));
}

test "the hash is the one luaS_hash gives" {
    // taken from the reference, since a different hash would only ever show up as
    // a different order for `pairs`
    try testing.expectEqual(@as(u64, 0), hashBytes(""));
    try testing.expectEqual(@as(u64, 128), hashBytes("a"));
    try testing.expectEqual(@as(u64, 287972584), hashBytes("hello"));
    try testing.expectEqual(@as(u64, 201490), hashBytes("Lua"));
    try testing.expectEqual(@as(u64, 297446982), hashBytes("print"));
}

test "a string with a zero byte in it is one string, not two" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const with_zero = [_]u8{ 'a', 0, 'b' };
    const a = try fixture.interner.intern(&with_zero);
    const b = try fixture.interner.intern(&with_zero);

    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(usize, 3), a.slice().len);
}
