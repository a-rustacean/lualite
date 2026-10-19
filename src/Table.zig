const std = @import("std");

const Object = @import("Object.zig");
const Str = @import("Str.zig");
const Value = @import("Value.zig");

/// A table: the array part, the hash part, and `#` over both.
///
/// The shape is the reference's, not a convenient one, because the parts are
/// observable. `ipairs` walks the array part, `#` is a search over the array
/// part that can fall into the hash part, and `pairs` walks the array part
/// first and then the hash part in node-array order. Reproducing Lua's layout
/// matters for integer and float keys. String-key order cannot be matched
/// across runs because Lua salts its string hash per state.
///
/// It lives in its own file rather than in Value.zig because it is the first
/// object whose mechanics are more than a header: the parts, the `#` search,
/// the node array and the rehash are `ltable.c`, and Value.zig is the value
/// model rather than a home for it. The two files import each other, which
/// Zig allows, and the recursion closes through a slice rather than by value.
///
pub const Table = struct {
    common: Object.Common,
    metatable: ?*Table,

    /// The array part: keys `1..alimit`, held one-based-to-zero-based as Lua
    /// does, so `array[i - 1]` is `t[i]`. A nil entry is an absent one, which
    /// is `isempty` and is what makes a hole a hole.
    array: []Value.Value,

    /// The hint `#` starts from, and what makes `#` history-dependent. Lua
    /// caches a boundary here across calls, and `luaH_getn` is written around
    /// that cache being warm or cold, so it is part of the observable behaviour
    /// rather than an optimisation. `isrealasize` is the flag in `flags` from
    /// `lobject.h`, and it says whether `alimit` is the array's real size or
    /// merely a hint below it.
    alimit: u32,
    isrealasize: bool,

    /// The hash part: a power-of-two array of nodes, chained by `next` offsets
    /// when two keys land on one bucket. Its order is the order `next` walks,
    /// and it depends on both the node count and where each key hashed, so it
    /// is reproduced rather than re-derived.
    nodes: []Node,
    /// log2 of the node count, as `lsizenode` in the reference. Kept rather
    /// than recomputed because the size is what every bucket computation does
    /// `lmod` against.
    lsizenode: u8,
    /// Where the next free node is searched from, walking down. Ported as an
    /// index rather than a pointer; `getfreepos` decrements before testing.
    lastfree: usize,

    allocator: std.mem.Allocator,

    /// One hash-part entry. A nil key means the node is free, which is
    /// `keyisnil`; a nil value with a non-nil key is a dead entry that `next`
    /// skips and the rehash reclaims.
    pub const Node = struct {
        key: Value.Value,
        value: Value.Value,
        /// The offset from this node to the next in its chain, as `gnext`. It
        /// is a relative offset rather than an index because the reference
        /// moves a node to a free position and fixes up the chain around it;
        /// an offset survives that, an index does not.
        next: i32,
    };

    pub const Error = error{ OutOfMemory, TableOverflow };

    pub fn create(allocator: std.mem.Allocator, tracker: *Object.Tracker) Error!*Table {
        const table = try tracker.alloc(Table, .table);
        errdefer tracker.free(table);
        const common = table.common;

        table.* = .{
            .common = common,
            .metatable = null,
            .array = empty_array,
            .alimit = 0,
            .isrealasize = true,
            .nodes = empty_nodes,
            .lsizenode = 0,
            .lastfree = no_nodes,
            .allocator = allocator,
        };

        return table;
    }

    /// Frees the parts and then the table itself. The collector takes this job
    /// over once it exists, the way it does for long strings; until then this is
    /// what teardown and the tests call.
    pub fn deinit(table: *Table, tracker: *Object.Tracker) void {
        freePart(table.allocator, table.array);
        freePart(table.allocator, table.nodes);
        tracker.free(table);
    }

    /// Frees a part that may be empty. A table starts with both parts empty and
    /// an empty slice carries no allocation, so there is nothing to hand back.
    fn freePart(allocator: std.mem.Allocator, part: anytype) void {
        if (part.len != 0) allocator.free(part);
    }

    /// The real size of the array part, which is `alimit` itself unless
    /// `alimit` is a hint below it, in which case it is the smallest power of
    /// two that covers it. `luaH_realasize`, including the bit-smearing that
    /// rounds up: `size |= size >> 1` and so on until the top bit is spread.
    pub fn realasize(table: *const Table) u32 {
        if (limitequalsasize(table)) return table.alimit;

        var size = table.alimit;
        size |= size >> 1;
        size |= size >> 2;
        size |= size >> 4;
        size |= size >> 8;
        size |= size >> 16;
        size += 1;

        return size;
    }

    /// `limitequalsasize`: `alimit` is the size, or happens to be a power of
    /// two, which makes it and the real size the same number.
    fn limitequalsasize(table: *const Table) bool {
        return table.isrealasize or ispow2(table.alimit);
    }

    fn ispow2(x: u32) bool {
        return (x & (x -% 1)) == 0;
    }

    fn ispow2realasize(table: *const Table) bool {
        return !table.isrealasize or ispow2(table.alimit);
    }

    fn setlimittosize(table: *Table) u32 {
        table.alimit = table.realasize();
        table.isrealasize = true;
        return table.alimit;
    }

    /// `isdummy`: no hash part at all. The reference says so by pointing its node
    /// array at one shared `dummynode` and setting `lastfree` to NULL; the
    /// `no_nodes` sentinel stands for that NULL here, since the hash size is
    /// `1 << lsizenode` and so is never zero on its own. Either way a lookup
    /// falls straight through to "absent" and an insert finds no free position
    /// and rehashes, and both of those are spelled out at the call sites.
    fn isdummy(table: *const Table) bool {
        return table.lastfree == no_nodes;
    }

    /// The node count, `sizenode`. The reference keeps `lsizenode` as a byte
    /// and shifts it; that is cheaper than a division and the same answer.
    pub fn sizenode(table: *const Table) u32 {
        return @as(u32, 1) << @intCast(table.lsizenode);
    }

    /// What `lastfree` holds when there is no hash part. The reference uses
    /// NULL for this and `isdummy` tests for it.
    const no_nodes: usize = std.math.maxInt(usize);

    /// The hash part of a table with none, and the array part of one that has
    /// not grown. A zero-length slice over a real address rather than `&.{}`,
    /// whose pointer is undefined and so cannot be handed back to an allocator.
    const empty_nodes: []Node = &.{};
    const empty_array: []Value.Value = &.{};

    /// Whether a key is an index into the array part, and which one.
    /// `arrayindex`: an integer in `[1, MAXASIZE]`. A float that is not
    /// integral never gets here — it is normalised to an integer first, or it
    /// is a hash key — and zero and negatives are excluded by the unsigned
    /// wrap, which is why this is one subtraction rather than two comparisons.
    pub fn arrayIndex(key: i64) u32 {
        const unsigned: u32 = @truncate(@as(u64, @bitCast(key)));
        if (unsigned -% 1 < max_asize) return @intCast(key);
        return 0;
    }

    /// `luaO_ceillog2`: the smallest `n` with `2^n >= x`, and zero for zero and
    /// one. The reference does this with a 256-entry table and shifts, ending on
    /// `log_2[x - 1]`; this counts the bits of the same value, which gives the
    /// same answer. Getting it wrong by one puts every integer key in the wrong
    /// bucket of the rehash count, which moves array boundaries and so changes
    /// both `#` and the `pairs` order.
    pub fn ceillog2(x: u32) u8 {
        if (x <= 1) return 0;
        return @intCast(std.math.log2_int(usize, x - 1) + 1);
    }

    /// The largest array part, from `MAXASIZE` in `ltable.c`. The reference
    /// derives it from the width of an int and a memory limit; the shape of the
    /// bound is all that matters here, and it is the same power of two.
    pub const max_asize: u32 = @as(u32, 1) << 31;

    pub fn get(table: *Table, key: Value.Value) Value.Value {
        return switch (key) {
            .number => |n| if (n.isInt()) getInt(table, n.int) else getGeneric(table, key),
            else => getGeneric(table, key),
        };
    }

    pub fn getInt(table: *Table, key: i64) Value.Value {
        const alimit = table.alimit;
        const unsigned: u32 = @truncate(@as(u64, @bitCast(key)));

        if (unsigned -% 1 < alimit) return table.array[@intCast(key - 1)];

        // The Xmilia trick, verbatim from `luaH_getint`: `alimit` may be a hint
        // below the real size, and `(key-1) & ~(alimit-1)` clears the bit that
        // distinguishes them. If the result is still under `alimit`, the key is
        // inside the array after all. Getting this wrong puts integer keys in
        // the hash part that belong in the array, which shows up as a wrong
        // `pairs` order rather than as a crash.
        if (!table.isrealasize and (unsigned -% 1) & ~(alimit -% 1) < alimit) {
            table.alimit = @intCast(key);
            return table.array[@intCast(key - 1)];
        }

        if (table.isdummy()) return .nil;

        var index = hashInt(table, key);
        while (true) {
            const node = &table.nodes[index];
            if (node.key == .number and node.key.number.isInt() and
                node.key.number.int == key) return node.value;

            const offset = node.next;
            if (offset == 0) break;
            index = @intCast(@as(i64, @intCast(index)) + offset);
        }

        return .nil;
    }

    /// The key a float index normalises to, or null when it stays a float.
    /// `luaV_flttointeger` with `F2Ieq` from `lvm.c`: the value must already be
    /// integral, and must fit in an integer. `t[1] = "int"; t[1.0] = "float"`
    /// leaves `"float"` in `t[1]`, because both are the key `1`.
    pub fn normalizeFloatKey(key: f64) ?i64 {
        const floored = @floor(key);
        if (floored != key) return null;
        if (!(floored >= min_integer_as_float and floored < -min_integer_as_float)) return null;
        return @intFromFloat(floored);
    }

    /// The smallest float above every integer, which is what `lua_numbertointeger`
    /// bounds the conversion with: a float is an integer key only while it is
    /// below `2^63`, since `2^63` itself is not representable as an i64.
    const min_integer_as_float: f64 = -9223372036854775808.0;

    /// `luaH_set`: find where the key would live, and write there if it already
    /// lives somewhere, or make a new entry if it does not. There is no separate
    /// "grow the array to fit this key" path, which is the part that is easy to
    /// get wrong: in the reference an integer key past the end of the array part
    /// goes to the hash part and only a rehash moves it, so `t[4] = v` on
    /// `{1,2,3}` does not become an array part of four.
    pub fn set(table: *Table, key: Value.Value, value: Value.Value) Error!void {
        // `luaH_get` normalises an integral float key to an integer before
        // looking, and `luaH_newkey` normalises it again before inserting. The
        // normalisation is what makes `t[1.0]` the same slot as `t[1]`.
        var normalized = key;
        if (key == .number and !key.number.isInt()) {
            if (normalizeFloatKey(key.number.float)) |as_int| normalized = intKey(as_int);
        }

        if (normalized == .number and normalized.number.isInt()) {
            return table.setInt(normalized.number.int, value);
        }

        if (normalized == .nil) {
            // `luaH_newkey` raises on a nil key rather than storing one. The
            // caller decides how to report it; here it is a no-op.
            return;
        }

        if (value == .nil) {
            // `luaH_newkey` returns without inserting a nil, so `t[k] = nil`
            // removes rather than stores. The dead node is left in place: a hole
            // stays a hole, which is what makes `#` ambiguous and what the
            // rehash later reclaims.
            table.removeFromHash(normalized);
            return;
        }

        try table.setInHash(normalized, value);
    }

    /// `luaH_setint`: write through the array part if the key is already an index
    /// of it, and otherwise go through the hash.
    fn setInt(table: *Table, key: i64, value: Value.Value) Error!void {
        if (table.getInt(key) != .nil or table.intIsInArray(key)) {
            const index = table.arrayIndexOf(key);
            if (value == .nil) {
                table.array[@intCast(index - 1)] = .nil;
            } else {
                table.array[@intCast(index - 1)] = value;
            }
            return;
        }

        if (value == .nil) {
            table.removeFromHash(intKey(key));
            return;
        }

        try table.setInHash(intKey(key), value);
    }

    /// Whether an integer key addresses a slot of the array part, including the
    /// Xmilia trick `luaH_getint` uses for a key past a hint `alimit`. This is
    /// the part of `luaH_getint` that decides whether the key is in the array
    /// at all, and it is why `getInt` returning nil is not on its own enough to
    /// tell "absent from the array" from "absent from the table".
    fn intIsInArray(table: *Table, key: i64) bool {
        const alimit = table.alimit;
        const unsigned: u32 = @truncate(@as(u64, @bitCast(key)));

        if (unsigned -% 1 < alimit) return true;
        if (!table.isrealasize and (unsigned -% 1) & ~(alimit -% 1) < alimit) return true;
        return false;
    }

    /// The array slot for a key `intIsInArray` has already accepted, with the
    /// same two-part test `luaH_getint` does.
    fn arrayIndexOf(table: *Table, key: i64) u32 {
        const alimit = table.alimit;
        const unsigned: u32 = @truncate(@as(u64, @bitCast(key)));

        if (unsigned -% 1 < alimit) return @intCast(key);
        table.alimit = @intCast(key);
        return @intCast(key);
    }

    fn setInHash(table: *Table, key: Value.Value, value: Value.Value) Error!void {
        if (!table.isdummy()) {
            var existing = mainPosition(table, key);
            while (true) {
                const node = &table.nodes[existing];
                if (keyEqual(node.key, key)) {
                    node.value = value;
                    return;
                }
                const offset = node.next;
                if (offset == 0) break;
                existing = @intCast(@as(i64, @intCast(existing)) + offset);
            }
        }
        // With no hash part there is nowhere to put the key and no free position
        // to find, which is exactly when `luaH_newkey` rehashes. It then retries
        // through `luaH_set`, the full entry point, not the hash path: the rehash
        // may have made an array part, and the key may now belong in it.
        if (table.isdummy()) {
            try table.rehash(key);
            return table.set(key, value);
        }

        var index = mainPosition(table, key);

        // `luaH_newkey`: if the main position is taken, either the colliding
        // node is out of its own position and gets moved aside to make room, or
        // it is at home and the new key goes to a free position behind it.
        if (occupied(&table.nodes[index])) {
            const free = table.getfreepos() orelse {
                // no free position is the same condition as no hash part: grow
                // and retry through the full entry point, which is where the
                // rehash may have put this key in an array part instead
                try table.rehash(key);
                return table.set(key, value);
            };

            const othern = mainPositionFromNode(table, index);
            if (othern != index) {
                var other = othern;
                while (@as(i64, @intCast(other)) + table.nodes[other].next != @as(i64, @intCast(index))) {
                    other = @intCast(@as(i64, @intCast(other)) + table.nodes[other].next);
                }
                table.nodes[other].next = @intCast(@as(i64, @intCast(free)) - @as(i64, @intCast(other)));
                table.nodes[free] = table.nodes[index];
                if (table.nodes[index].next != 0) {
                    table.nodes[free].next += @intCast(@as(i64, @intCast(index)) - @as(i64, @intCast(free)));
                    table.nodes[index].next = 0;
                }
                table.nodes[index].value = .nil;
            } else {
                if (table.nodes[index].next != 0) {
                    table.nodes[free].next = @intCast(
                        (@as(i64, @intCast(index)) + table.nodes[index].next) - @as(i64, @intCast(free)),
                    );
                }
                table.nodes[index].next = @intCast(@as(i64, @intCast(free)) - @as(i64, @intCast(index)));
                index = free;
            }
        }

        table.nodes[index].key = key;
        table.nodes[index].value = value;
    }

    fn removeFromHash(table: *Table, key: Value.Value) void {
        // Deletion clears the value and leaves the key, which is what makes the
        // node dead rather than free: `next` skips it and `getfreepos` will not
        // hand it out, so only a rehash returns it. That is `luaH_finishset`'s
        // behaviour, and it is why a table with deletions has holes.
        if (table.isdummy()) return;

        var index = mainPosition(table, key);
        while (true) {
            const node = &table.nodes[index];
            if (keyEqual(node.key, key)) {
                node.value = .nil;
                return;
            }
            const offset = node.next;
            if (offset == 0) return;
            index = @intCast(@as(i64, @intCast(index)) + offset);
        }
    }

    /// `getfreepos`: walk down from `lastfree` for a node whose key is nil.
    /// The reference points one past the end and decrements before testing, so
    /// the last node is the first one tried; that order is what decides where
    /// colliding keys land, and therefore what `pairs` prints.
    fn getfreepos(table: *Table) ?usize {
        while (table.lastfree > 0) {
            table.lastfree -= 1;
            if (table.nodes[table.lastfree].key == .nil) return table.lastfree;
        }
        return null;
    }

    fn getGeneric(table: *Table, key: Value.Value) Value.Value {
        if (table.isdummy()) return .nil;

        var index = mainPosition(table, key);
        while (true) {
            const node = &table.nodes[index];
            if (keyEqual(node.key, key)) return node.value;

            const offset = node.next;
            if (offset == 0) return .nil;
            index = @intCast(@as(i64, @intCast(index)) + offset);
        }
    }

    fn keyEqual(a: Value.Value, b: Value.Value) bool {
        // A nil key marks a free node, so it never matches, not even another
        // nil. `equalkey` treats the dead-key case the same way.
        if (a == .nil) return false;
        return Value.Value.equal(a, b);
    }

    fn occupied(node: *const Node) bool {
        return node.value != .nil;
    }

    /// `#`. `luaH_getn` in full, because the answer is a specific one rather
    /// than any answer in a range, and the corpus compares it.
    ///
    /// A table with a hole has no length the manual can state: Lua picks one by
    /// starting from the cached `alimit` and searching. Verified against 5.4.7:
    /// `{[1],[2],[4]}` is 4, not 2, and `{[1],[3]}` is 1. Do not "correct" these
    /// to the intuitive answers; the intuition is what the reference does not do.
    pub fn len(table: *Table) u32 {
        var limit = table.alimit;

        if (limit > 0 and table.array[@intCast(limit - 1)] == .nil) {
            // (1) the cached boundary is stale, so a real boundary is before it
            if (limit >= 2 and table.array[@intCast(limit - 2)] != .nil) {
                // `limit - 1` is itself a boundary
                if (ispow2realasize(table) and !ispow2(limit - 1)) {
                    table.alimit = limit - 1;
                    table.isrealasize = false;
                }
                return limit - 1;
            }
            const boundary = binsearch(table.array, 0, limit);
            // keep the boundary as a hint for the next call, when it can be one
            if (ispow2realasize(table) and boundary > table.realasize() / 2) {
                table.alimit = boundary;
                table.isrealasize = false;
            }
            return boundary;
        }

        // (2) the boundary is valid but the array runs past it
        if (!limitequalsasize(table)) {
            if (table.array[@intCast(limit)] == .nil) return limit;

            limit = table.realasize();
            if (table.array[@intCast(limit - 1)] == .nil) {
                const boundary = binsearch(table.array, table.alimit, limit);
                table.alimit = boundary;
                return boundary;
            }
        }

        // (3) the last array entry is present, so the answer is past the array
        // part and lives or dies in the hash
        if (table.sizenode() == 0) return limit;
        if (table.getInt(@as(i64, limit) + 1) == .nil) return limit;
        return table.hashSearch(limit);
    }

    /// `binsearch`: the largest `i` in `(lo, hi]` with `t[i]` present, given
    /// `t[hi]` absent. Each step halves the range by testing the middle, and
    /// it is a search rather than a scan because the array can be long.
    fn binsearch(array: []const Value.Value, lo: u32, hi: u32) u32 {
        var i = lo;
        var j = hi;
        while (j - i > 1) {
            const m = (i + j) / 2;
            if (array[@intCast(m - 1)] == .nil) j = m else i = m;
        }
        return i;
    }

    /// `hash_search`: the boundary when it is past the array part. Double from
    /// `j` until an index is absent, then binary search between the last present
    /// one and it.
    fn hashSearch(table: *Table, j: u32) u32 {
        var index = if (j == 0) @as(u32, 1) else j;
        var i: u32 = 0;

        while (true) {
            i = index;
            index = if (index <= std.math.maxInt(i64) / 2)
                index * 2
            else
                std.math.maxInt(i64);
            if (index > max_asize) return i;
            if (table.getInt(@intCast(index)) == .nil) break;
        }

        var lo = i;
        var hi = index;
        while (hi - lo > 1) {
            const m = (lo + hi) / 2;
            if (table.getInt(@intCast(m)) == .nil) hi = m else lo = m;
        }
        return lo;
    }

    /// The entry after `key`, or null at the end. `luaH_next`: the array part
    /// first in index order, then the node array in its own order. The order is
    /// not sorted and not insertion order; it is where each key landed, which
    /// is why the node count and the hash have to be the reference's.
    pub fn next(table: *const Table, key: ?Value.Value) ?struct { key: Value.Value, value: Value.Value } {
        const asize = table.realasize();
        var i = findIndex(table, key, asize);

        while (i < asize) : (i += 1) {
            const value = table.array[@intCast(i)];
            if (value != .nil) return .{ .key = .{ .number = @import("Number.zig").Number.fromInt(@intCast(i + 1)) }, .value = value };
        }

        i -= asize;
        if (table.isdummy()) return null;
        while (i < table.sizenode()) : (i += 1) {
            const node = table.nodes[@intCast(i)];
            if (node.value != .nil) return .{ .key = node.key, .value = node.value };
        }

        return null;
    }

    /// Where the walk resumes from for a given key. `findindex`: nil starts at
    /// zero, an integer in the array part gives its own index, and anything else
    /// is found in the hash part and numbered after the array entries.
    fn findIndex(table: *const Table, key: ?Value.Value, asize: u32) u32 {
        const given = key orelse return 0;

        if (given == .number and given.number.isInt()) {
            const i = arrayIndex(given.number.int);
            if (i -% 1 < asize) return i;
        }

        if (table.isdummy()) return asize;

        var index = mainPosition(table, given);
        while (true) {
            const node = &table.nodes[index];
            if (keyEqual(node.key, given) and node.value != .nil) return @as(u32, @intCast(index)) + 1 + asize;

            const offset = node.next;
            if (offset == 0) return asize;
            index = @intCast(@as(i64, @intCast(index)) + offset);
        }
    }

    /// Where a key's bucket is, `mainpositionTV`. The three shapes: an integer
    /// and a float both take `hashmod`, a string takes `hashpow2` on its own
    /// hash, and everything else is a pointer. The two differ, and using the
    /// wrong one changes the order `pairs` prints.
    fn mainPosition(table: *const Table, key: Value.Value) usize {
        return switch (key) {
            .number => |n| if (n.isInt())
                hashmod(table, @truncate(@as(u64, @bitCast(n.int))))
            else
                hashmod(table, hashFloat(n.toFloat())),
            .string => |s| hashpow2(table, hashString(s)),
            .boolean => |b| hashpow2(table, if (b) 1 else 0),
            .nil => hashpow2(table, 0),
            .table => |t| hashmod(table, @truncate(@intFromPtr(t))),
            .function => |f| hashmod(table, @truncate(@intFromPtr(f))),
            .native_function => |f| hashmod(table, @intFromEnum(f)),
            .thread => |th| hashmod(table, @truncate(@intFromPtr(th))),
        };
    }

    /// `mainpositionfromnode`: the bucket a node already in the table belongs
    /// to, recomputed from its key. A node found at its own bucket needs no
    /// moving; one found elsewhere does.
    fn mainPositionFromNode(table: *const Table, index: usize) usize {
        return mainPosition(table, table.nodes[index].key);
    }

    /// `hashpow2`: a mask, since the node count is a power of two.
    fn hashpow2(table: *const Table, n: u32) usize {
        return @intCast(n & (table.sizenode() - 1));
    }

    /// `hashmod`: a real modulo against `(size-1)|1`, which is not the same
    /// number as the size and so not the same bucket as the mask above.
    fn hashmod(table: *const Table, n: u32) usize {
        const size = table.sizenode();
        return @intCast(@as(u64, n) % @as(u64, (size - 1) | 1));
    }

    fn hashInt(table: *const Table, key: i64) usize {
        return hashmod(table, @truncate(@as(u64, @bitCast(key))));
    }

    /// `l_hashfloat`, so that a float key lands in the bucket the reference
    /// would put it in. The mantissa times `-INT_MIN` puts the exponent and the
    /// fraction into one number whose low bits are then folded together.
    fn hashFloat(n: f64) u32 {
        if (std.math.isNan(n) or std.math.isInf(n)) return 0;

        const parts = std.math.frexp(n);
        const mantissa: f64 = parts.significand * -@as(f64, @floatFromInt(std.math.minInt(i32)));

        const scaled: i64 = @intFromFloat(mantissa);
        const u: u32 = @truncate(@as(u32, @bitCast(parts.exponent)) +% @as(u32, @truncate(@as(u64, @bitCast(scaled)))));

        return if (u <= std.math.maxInt(i32)) u else ~u;
    }

    /// Hashes a string key with `luaS_hash`, the same function `Str` interns by.
    ///
    /// This is deliberately *not* the same bucket the reference picks. The
    /// reference seeds `luaS_hash` per state from `time` and ASLR
    /// (`luai_makeseed` in `lstate.c`), so where a string key lands — and
    /// therefore the order `pairs` walks — changes from run to run. Checked
    /// against 5.4.7: twenty string keys come out in a different order on each
    /// of five consecutive runs. There is no order to match, and an
    /// output-diffing corpus cannot depend on one. Integer and float keys are
    /// unaffected, since they do not go through the seeded hash, and those do
    /// come out in the order the reference gives.
    fn hashString(s: *const Str.Str) u32 {
        return @truncate(Str.hashBytes(s.slice()));
    }

    /// `rehash`: count where the integer keys are, choose an array size and a
    /// node count that fit them, and move everything across.
    ///
    /// The array size is `computesizes`: the largest power of two that more than
    /// half its slots fill, and no larger. That rule is why `{[1],[2],[4]}` ends
    /// up with an array part of four and a `#` of four, and it is the reason
    /// this cannot be simplified to "put contiguous integers in the array".
    fn rehash(table: *Table, extra_key: ?Value.Value) Error!void {
        var nums: [32]u32 = @splat(0);

        _ = setlimittosize(table);

        // `na` is every integer key that could live in the array part, not the
        // number that will: the ones already there plus the eligible ones in the
        // hash part plus the key being added. `computesizes` narrows it to the
        // ones that fit in the size it picks.
        var na = table.numUseArray(&nums);
        var totaluse = na;
        totaluse += table.numUseHash(&nums, &na);

        if (extra_key) |key| {
            if (key == .number and key.number.isInt()) na += table.countInt(key.number.int, &nums);
            totaluse += 1;
        }

        const asize = computesizes(&nums, &na);
        try table.resize(asize, totaluse - na);
    }

    /// `computesizes`: the largest `2^i` holding more than half its slots, and
    /// the number of keys that fit in it.
    fn computesizes(nums: *[32]u32, pna: *u32) u32 {
        var a: u32 = 0;
        var na: u32 = 0;
        var optimal: u32 = 0;

        var i: usize = 0;
        var twotoi: u32 = 1;
        while (twotoi != 0 and pna.* > twotoi / 2) : ({
            // TRACE
            i += 1;
            twotoi *|= 2;
        }) {
            a += nums[i];
            if (a > twotoi / 2) {
                optimal = twotoi;
                na = a;
            }
        }

        pna.* = na;
        return optimal;
    }

    /// `countint`: file an integer key under the slice its magnitude puts it in.
    fn countInt(table: *const Table, key: i64, nums: *[32]u32) u32 {
        _ = table;
        const k = arrayIndex(key);
        if (k != 0) {
            nums[ceillog2(k)] += 1;
            return 1;
        }
        return 0;
    }

    /// `numusearray`: how full the array part is, bucketed by magnitude.
    fn numUseArray(table: *const Table, nums: *[32]u32) u32 {
        var lg: usize = 0;
        var ttlg: u32 = 1;
        var ause: u32 = 0;
        var i: u32 = 1;
        const asize = setlimittosizeConst(table);

        while (lg <= 31) : ({
            lg += 1;
            ttlg *|= 2;
        }) {
            var lc: u32 = 0;
            var lim = ttlg;
            if (lim > asize) {
                lim = asize;
                if (i > lim) break;
            }
            while (i <= lim) : (i += 1) {
                if (table.array[@intCast(i - 1)] != .nil) lc += 1;
            }
            nums[lg] +%= lc;
            ause += lc;
        }

        return ause;
    }

    /// `numusehash`: the same count, over the node array, plus how many of the
    /// integer keys there are candidates for the array part.
    fn numUseHash(table: *const Table, nums: *[32]u32, pna: *u32) u32 {
        var totaluse: u32 = 0;
        var ause: u32 = 0;

        if (table.isdummy()) return 0;

        var i = table.sizenode();
        while (i > 0) {
            i -= 1;
            const node = table.nodes[@intCast(i)];
            if (node.value != .nil) {
                if (node.key == .number and node.key.number.isInt()) {
                    ause += table.countInt(node.key.number.int, nums);
                }
                totaluse += 1;
            }
        }

        pna.* += ause;
        return totaluse;
    }

    /// `luaH_resize`: move to a new array size and a new node count. The
    /// reference builds the new hash part into a second `Table` and swaps it in
    /// at two points, and the order of those swaps is observable: the entries
    /// drained out of a shrinking array land in the new hash part, and the old
    /// hash part is reinserted only after the swap. Doing it in another order
    /// puts the same keys in different nodes, which shows up as a `pairs` order
    /// that differs from the reference for no visible reason.
    fn resize(table: *Table, newasize: u32, nhsize: u32) Error!void {
        const oldasize = setlimittosize(table);
        const oldnodes = table.nodes;

        const newnodes = try table.newNodeVector(nhsize);
        errdefer freePart(table.allocator, newnodes);

        // A rehash can legitimately land on an array size of zero, and asking
        // an allocator for zero elements is not something it has to support.
        // `luaH_resize` never hits this because its array is a NULL pointer
        // rather than a zero-length allocation; the empty slice stands for that.
        const newarray = if (newasize == 0)
            empty_array
        else
            try table.allocator.alloc(Value.Value, newasize);
        errdefer freePart(table.allocator, newarray);
        @memset(newarray, .nil);

        // a shrinking array spills what it loses into the new hash part, while
        // the table still holds the old one — the first of the two swaps
        if (newasize < oldasize) {
            table.alimit = newasize;
            table.installNodes(newnodes);
            defer table.installNodes(oldnodes);

            var i = newasize;
            while (i < oldasize) : (i += 1) {
                const value = table.array[@intCast(i)];
                if (value != .nil) try table.setInt(@intCast(i + 1), value);
            }
        }

        const kept = @min(oldasize, newasize);
        @memcpy(newarray[0..kept], table.array[0..kept]);

        freePart(table.allocator, table.array);
        table.array = newarray;
        table.alimit = newasize;
        table.isrealasize = true;

        // the second swap puts the new hash part in, and the old one's entries
        // go back in through the normal path so they land where the reference
        // would put them
        table.installNodes(newnodes);
        for (oldnodes) |node| {
            if (node.value != .nil) try table.setInHash(node.key, node.value);
        }
        freePart(table.allocator, oldnodes);
    }

    /// Swaps in a node array, resetting `lastfree` the way `setnodevector` does.
    /// The reference uses `exchangehashpart` for this; it is the same move.
    fn installNodes(table: *Table, nodes: []Node) void {
        table.nodes = nodes;
        table.lsizenode = if (nodes.len == 0) 0 else ceillog2(@intCast(nodes.len));
        table.lastfree = if (nodes.len == 0) no_nodes else nodes.len;
    }

    /// `setnodevector`: an empty node array of a power-of-two size, or nothing
    /// at all when the hash part is empty, which is `isdummy` and saves the
    /// allocation.
    fn newNodeVector(table: *Table, size: u32) Error![]Node {
        if (size == 0) return empty_nodes;

        const lsize = ceillog2(size);
        if (lsize > 30) return error.TableOverflow;

        const nodes = try table.allocator.alloc(Node, @as(usize, 1) << @intCast(lsize));
        @memset(nodes, .{ .key = .nil, .value = .nil, .next = 0 });
        return nodes;
    }

    fn setlimittosizeConst(table: *const Table) u32 {
        return if (table.isrealasize or ispow2(table.alimit)) table.alimit else blk: {
            var size = table.alimit;
            size |= size >> 1;
            size |= size >> 2;
            size |= size >> 4;
            size |= size >> 8;
            size |= size >> 16;
            size += 1;
            break :blk size;
        };
    }
};

const testing = std.testing;

/// The tracker and the allocator a table needs together. The same reason
/// `Str.Fixture` exists: a table holds an allocator and is freed through the
/// tracker, and one left to go out of scope first is a pointer to nothing.
const Fixture = struct {
    tracker: Object.Tracker,
    interner: Str.Interner,
    tables: std.ArrayList(*Table),

    fn init() std.mem.Allocator.Error!Fixture {
        return .{
            .tracker = .init(testing.allocator),
            .interner = undefined,
            .tables = .empty,
        };
    }

    fn deinit(self: *Fixture) void {
        for (self.tables.items) |table| table.deinit(&self.tracker);

        // the interner's own deinit does not free long strings, so they go
        // first, off the tracker's list; the sweep takes this over once it exists
        var current = self.tracker.first;
        while (current) |common| : (current = common.next) {
            const leftover: *Str.Str = @fieldParentPtr("common", common);
            leftover.deinit(&self.tracker);
        }

        self.interner.deinit();
        self.tables.deinit(testing.allocator);
        self.tracker.deinit();
        testing.allocator.destroy(self);
    }

    fn new(self: *Fixture) Table.Error!*Table {
        const table = try Table.create(testing.allocator, &self.tracker);
        try self.tables.append(testing.allocator, table);
        return table;
    }

    fn str(self: *Fixture, bytes: []const u8) std.mem.Allocator.Error!Value.Value {
        return .{ .string = try self.interner.intern(bytes) };
    }
};

fn testFixture() std.mem.Allocator.Error!*Fixture {
    const fixture = try testing.allocator.create(Fixture);
    fixture.* = try Fixture.init();
    fixture.interner = try Str.Interner.init(testing.allocator, &fixture.tracker);
    return fixture;
}

/// Integer keys read better written this way than spelled out each time.
fn intKey(n: i64) Value.Value {
    return .{ .number = @import("Number.zig").Number.fromInt(n) };
}

fn floatKey(n: f64) Value.Value {
    return .{ .number = @import("Number.zig").Number.fromFloat(n) };
}

test "an empty table has nothing in it" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();

    try testing.expect(table.get(intKey(1)) == .nil);
    try testing.expectEqual(@as(u32, 0), table.len());
    try testing.expect(table.next(null) == null);
}

test "an integer key with an exact float value is the same key" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();

    try table.set(intKey(1), try fixture.str("int"));
    try table.set(floatKey(1.0), try fixture.str("float"));

    // 1.0 overwrote 1, which is what reference Lua does and the reason the
    // normalisation has to happen before the key is hashed
    const got = table.get(intKey(1));
    try testing.expectEqualStrings("float", got.string.slice());
    try testing.expectEqual(@as(u32, 1), table.len());
}

test "a non-integral float key stays a float key" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();

    try table.set(floatKey(1.5), try fixture.str("half"));

    try testing.expectEqualStrings("half", (table.get(floatKey(1.5))).string.slice());
    // and it is not the same key as 1
    try testing.expect(table.get(intKey(1)) == .nil);
    // a hash-part key is not a length
    try testing.expectEqual(@as(u32, 0), table.len());
}

test "the normalisation boundary is where lua_numbertointeger puts it" {
    // 2^63 is not representable as an i64, so it does not normalise, while
    // 2^53 does. Both were checked against reference Lua.
    try testing.expect(Table.normalizeFloatKey(2.0) != null);
    try testing.expect(Table.normalizeFloatKey(3.5) == null);
    try testing.expect(Table.normalizeFloatKey(9007199254740992.0) != null);
    try testing.expect(Table.normalizeFloatKey(9223372036854775808.0) == null);
}

test "# is the reference's answer for a table with holes, not the intuitive one" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();
    for ([_]i64{ 1, 2, 4 }) |key| {
        try table.set(intKey(key), .{ .boolean = true });
    }

    // 4, not 2. This is `luaH_getn` starting from the cached alimit and
    // searching; do not "fix" it to 2, which is what a person would expect and
    // what the reference does not return. Verified against Lua 5.4.7.
    try testing.expectEqual(@as(u32, 4), table.len());
}

test "# after deleting from the middle keeps the reference's answer" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();
    for (1..7) |key| {
        try table.set(intKey(@intCast(key)), .{ .boolean = true });
    }
    try table.set(intKey(3), .nil);

    // 6, not 2: the boundary Lua finds is past the hole, because the array part
    // is still sized for six and its last entry is present. Verified against
    // 5.4.7 with `local t={} for i=1,6 do t[i]=i end t[3]=nil print(#t)`.
    try testing.expectEqual(@as(u32, 6), table.len());
}

test "setting a key to nil removes it and leaves a hole" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();
    for (1..5) |key| {
        try table.set(intKey(@intCast(key)), intKey(@intCast(key)));
    }
    try table.set(intKey(2), .nil);

    try testing.expect(table.get(intKey(2)) == .nil);
    // the others are untouched
    try testing.expect(table.get(intKey(1)) != .nil);
    try testing.expect(table.get(intKey(4)) != .nil);
}

test "a string key round-trips and does not collide with a number key" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();
    const one = try fixture.str("1");

    try table.set(one, .{ .boolean = true });
    try table.set(intKey(1), .{ .boolean = false });

    // "1" and 1 are different keys even though they read alike
    try testing.expect((table.get(one)).boolean);
    try testing.expect(!(table.get(intKey(1))).boolean);
}

test "next walks the array part then the hash part and stops" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();
    try table.set(intKey(1), intKey(10));
    try table.set(try fixture.str("k"), intKey(20));
    try table.set(intKey(2), intKey(30));

    var seen: usize = 0;
    var current = table.next(null);
    while (current) |entry| : (current = table.next(entry.key)) seen += 1;

    try testing.expectEqual(@as(usize, 3), seen);
}

test "next returns every entry exactly once, array part before hash part" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();
    try table.set(intKey(1), intKey(10));
    try table.set(try fixture.str("k"), intKey(20));
    try table.set(intKey(2), intKey(30));
    try table.set(floatKey(2.5), intKey(40));

    var seen: usize = 0;
    var saw_float = false;
    var current = table.next(null);
    while (current) |entry| : (current = table.next(entry.key)) {
        if (entry.key == .number and !entry.key.number.isInt()) saw_float = true;
        seen += 1;
    }

    try testing.expectEqual(@as(usize, 4), seen);
    // 2.5 is in the hash part rather than the array, and is still visited
    try testing.expect(saw_float);
}

test "the array part is walked before the hash part, whatever the string order" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();
    try table.set(intKey(1), intKey(10));
    try table.set(try fixture.str("k"), intKey(20));
    try table.set(try fixture.str("j"), intKey(30));
    try table.set(intKey(2), intKey(40));

    // only the two array entries, in index order, are reproducible: the
    // reference seeds its string hash per run, so where "j" and "k" land is not
    const first = table.next(null).?;
    try testing.expect(Value.Value.equal(first.key, intKey(1)));
    const second = table.next(first.key).?;
    try testing.expect(Value.Value.equal(second.key, intKey(2)));

    // the other two come after, in whichever order they hashed
    const third = table.next(second.key).?;
    const fourth = table.next(third.key).?;
    try testing.expect(third.key == .string or fourth.key == .string);
    try testing.expect(table.next(fourth.key) == null);
}

test "a hole is skipped by next" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();
    for (1..6) |key| {
        try table.set(intKey(@intCast(key)), .{ .boolean = true });
    }
    try table.set(intKey(2), .nil);
    try table.set(intKey(4), .nil);

    var seen: usize = 0;
    var current = table.next(null);
    while (current) |entry| : (current = table.next(entry.key)) seen += 1;

    // three of the five are present
    try testing.expectEqual(@as(usize, 3), seen);
}

test "many keys survive a rehash" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();

    for (1..201) |i| {
        try table.set(intKey(@intCast(i)), intKey(@intCast(i)));
    }

    for (1..201) |i| {
        try testing.expect(table.get(intKey(@intCast(i))) != .nil);
    }

    var seen: usize = 0;
    var current = table.next(null);
    while (current) |entry| : (current = table.next(entry.key)) seen += 1;
    try testing.expectEqual(@as(usize, 200), seen);
    try testing.expectEqual(@as(u32, 200), table.len());
}

test "string keys survive a rehash and keep their values" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();

    for (0..100) |i| {
        var buffer: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "key{d}", .{i});
        try table.set(try fixture.str(text), intKey(@intCast(i)));
    }

    for (0..100) |i| {
        var buffer: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "key{d}", .{i});
        try testing.expectEqual(@as(i64, @intCast(i)), (table.get(try fixture.str(text))).number.int);
    }
}

test "a table is equal only to itself" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const a = try fixture.new();
    const b = try fixture.new();

    try testing.expect(Value.Value.equal(.{ .table = a }, .{ .table = a }));
    try testing.expect(!Value.Value.equal(.{ .table = a }, .{ .table = b }));
}

test "the table's own type name is table" {
    var fixture = try testFixture();
    defer fixture.deinit();

    const table = try fixture.new();
    try testing.expectEqualStrings("table", (Value.Value{ .table = table }).typeName());
}
