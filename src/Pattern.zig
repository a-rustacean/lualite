const std = @import("std");

pub const Capture = struct { start: usize, end: usize, position: bool = false };
pub const Result = struct {
    start: usize,
    end: usize,
    captures: [32]Capture,
    capture_count: usize,
};

const Matcher = struct {
    source: []const u8,
    pattern: []const u8,
    captures: [32]Capture = undefined,
    capture_count: usize = 0,
    open: [32]usize = undefined,
    open_count: usize = 0,
    budget: usize = 100_000,
    invalid: bool = false,

    fn match(m: *Matcher, source_pos: usize, pattern_pos: usize) ?usize {
        if (m.budget == 0) return null;
        m.budget -= 1;
        if (pattern_pos == m.pattern.len) return source_pos;
        if (m.pattern[pattern_pos] == '$' and pattern_pos + 1 == m.pattern.len) return if (source_pos == m.source.len) source_pos else null;
        if (m.pattern[pattern_pos] == '(') {
            if (m.capture_count == m.captures.len or m.open_count == m.open.len) {
                m.invalid = true;
                return null;
            }
            const old_capture_count = m.capture_count;
            const old_open_count = m.open_count;
            const id = m.capture_count;
            m.capture_count += 1;
            m.captures[id] = .{ .start = source_pos, .end = source_pos, .position = pattern_pos + 1 < m.pattern.len and m.pattern[pattern_pos + 1] == ')' };
            if (pattern_pos + 1 < m.pattern.len and m.pattern[pattern_pos + 1] == ')') {
                if (m.match(source_pos, pattern_pos + 2)) |end| return end;
            } else {
                m.open[m.open_count] = id;
                m.open_count += 1;
                if (m.match(source_pos, pattern_pos + 1)) |end| return end;
            }
            m.capture_count = old_capture_count;
            m.open_count = old_open_count;
            return null;
        }
        if (m.pattern[pattern_pos] == ')') {
            if (m.open_count == 0) {
                m.invalid = true;
                return null;
            }
            const id = m.open[m.open_count - 1];
            const old_end = m.captures[id].end;
            m.open_count -= 1;
            m.captures[id].end = source_pos;
            if (m.match(source_pos, pattern_pos + 1)) |end| return end;
            m.open_count += 1;
            m.captures[id].end = old_end;
            return null;
        }

        if (pattern_pos + 1 < m.pattern.len and m.pattern[pattern_pos] == '%') {
            const escaped = m.pattern[pattern_pos + 1];
            if (escaped == 'b') {
                if (pattern_pos + 3 >= m.pattern.len) {
                    m.invalid = true;
                    return null;
                }
                const opening = m.pattern[pattern_pos + 2];
                const closing = m.pattern[pattern_pos + 3];
                if (source_pos >= m.source.len or m.source[source_pos] != opening) return null;
                var depth: usize = 1;
                var scan = source_pos + 1;
                while (scan < m.source.len) : (scan += 1) {
                    if (m.source[scan] == closing) {
                        depth -= 1;
                        if (depth == 0) return m.match(scan + 1, pattern_pos + 4);
                    } else if (m.source[scan] == opening) {
                        depth += 1;
                    }
                }
                return null;
            }
            if (escaped == 'f') {
                const set_start = pattern_pos + 2;
                const set_end = m.setEnd(set_start) orelse {
                    m.invalid = true;
                    return null;
                };
                const previous = if (source_pos == 0) 0 else m.source[source_pos - 1];
                const current = if (source_pos == m.source.len) 0 else m.source[source_pos];
                if (m.setMatches(set_start, set_end, previous) or !m.setMatches(set_start, set_end, current)) return null;
                return m.match(source_pos, set_end);
            }
            if (escaped >= '1' and escaped <= '9') {
                const id: usize = escaped - '1';
                if (id >= m.capture_count or m.captures[id].position) {
                    m.invalid = true;
                    return null;
                }
                const capture = m.captures[id];
                const length = capture.end - capture.start;
                if (source_pos + length > m.source.len or !std.mem.eql(u8, m.source[capture.start..capture.end], m.source[source_pos .. source_pos + length])) return null;
                return m.match(source_pos + length, pattern_pos + 2);
            }
        }

        const atom = m.atomEnd(pattern_pos) orelse return null;
        const quantifier = if (atom < m.pattern.len and std.mem.indexOfScalar(u8, "*+?-", m.pattern[atom]) != null) m.pattern[atom] else 0;
        const next_pattern = atom + @intFromBool(quantifier != 0);
        if (quantifier == 0) {
            if (source_pos >= m.source.len or !m.atomMatches(pattern_pos, atom, selfByte(m, source_pos))) return null;
            return m.match(source_pos + 1, next_pattern);
        }

        var repetitions: usize = 0;
        while (source_pos + repetitions < m.source.len and m.atomMatches(pattern_pos, atom, m.source[source_pos + repetitions])) : (repetitions += 1) {
            if (repetitions >= m.budget) break;
        }
        const minimum: usize = if (quantifier == '+') 1 else 0;
        if (repetitions < minimum) return null;
        if (quantifier == '-') {
            var count = minimum;
            while (count <= repetitions) : (count += 1) {
                if (m.match(source_pos + count, next_pattern)) |end| return end;
            }
            return null;
        }
        var count = repetitions;
        while (true) {
            if (count >= minimum) if (m.match(source_pos + count, next_pattern)) |end| return end;
            if (count == minimum) break;
            count -= 1;
        }
        return null;
    }

    fn selfByte(m: *Matcher, pos: usize) u8 {
        return m.source[pos];
    }

    fn atomEnd(m: *Matcher, pos: usize) ?usize {
        if (pos >= m.pattern.len) return null;
        return switch (m.pattern[pos]) {
            '%' => if (pos + 1 < m.pattern.len) blk: {
                const escaped = m.pattern[pos + 1];
                if (escaped == 'b') break :blk if (pos + 3 < m.pattern.len) pos + 4 else null;
                if (escaped == 'f') break :blk m.setEnd(pos + 2) orelse invalid_set: {
                    m.invalid = true;
                    break :invalid_set null;
                };
                if (escaped >= '1' and escaped <= '9') break :blk null;
                break :blk pos + 2;
            } else null,
            '[' => m.setEnd(pos),
            else => pos + 1,
        };
    }

    fn setEnd(m: *Matcher, pos: usize) ?usize {
        if (pos >= m.pattern.len or m.pattern[pos] != '[') return null;
        var i = pos + 1;
        if (i < m.pattern.len and m.pattern[i] == '^') i += 1;
        if (i < m.pattern.len and m.pattern[i] == ']') i += 1;
        while (i < m.pattern.len and m.pattern[i] != ']') : (i += 1) {
            if (m.pattern[i] == '%' and i + 1 < m.pattern.len) i += 1;
        }
        if (i >= m.pattern.len) return null;
        return i + 1;
    }

    fn setMatches(m: *Matcher, start: usize, end: usize, byte: u8) bool {
        var i = start + 1;
        const negate = i < end and m.pattern[i] == '^';
        if (negate) i += 1;
        var found = false;
        while (i + 1 < end) {
            if (m.pattern[i] == '%' and i + 2 < end) {
                found = found or classMatches(m.pattern[i + 1], byte);
                i += 2;
            } else if (i + 2 < end and m.pattern[i + 1] == '-') {
                found = found or (byte >= m.pattern[i] and byte <= m.pattern[i + 2]);
                i += 3;
            } else {
                found = found or m.pattern[i] == byte;
                i += 1;
            }
        }
        return if (negate) !found else found;
    }

    fn atomMatches(m: *Matcher, start: usize, end: usize, byte: u8) bool {
        if (m.pattern[start] == '.') return true;
        if (m.pattern[start] == '%') return classMatches(m.pattern[start + 1], byte);
        if (m.pattern[start] != '[') return m.pattern[start] == byte;
        return m.setMatches(start, end, byte);
    }
};

fn classMatches(class: u8, byte: u8) bool {
    const positive = switch (std.ascii.toLower(class)) {
        'a' => std.ascii.isAlphabetic(byte),
        'c' => std.ascii.isControl(byte),
        'd' => std.ascii.isDigit(byte),
        'g' => std.ascii.isGraphical(byte),
        'l' => std.ascii.isLower(byte),
        'p' => std.ascii.isPunctuation(byte),
        's' => std.ascii.isWhitespace(byte),
        'u' => std.ascii.isUpper(byte),
        'w' => std.ascii.isAlphanumeric(byte),
        'x' => std.ascii.isHex(byte),
        'z' => byte == 0,
        else => return class == byte,
    };
    return if (std.ascii.isUpper(class)) !positive else positive;
}

pub fn find(source: []const u8, pattern: []const u8, start: usize) error{InvalidPattern}!?Result {
    const anchored = pattern.len > 0 and pattern[0] == '^';
    const pattern_start: usize = if (anchored) 1 else 0;
    var candidate = @min(start, source.len);
    while (true) {
        var matcher: Matcher = .{ .source = source, .pattern = pattern };
        if (matcher.match(candidate, pattern_start)) |end| {
            if (matcher.invalid or matcher.open_count != 0) return error.InvalidPattern;
            return .{ .start = candidate, .end = end, .captures = matcher.captures, .capture_count = matcher.capture_count };
        }
        if (matcher.invalid) return error.InvalidPattern;
        if (anchored or candidate == source.len) break;
        candidate += 1;
    }
    return null;
}

test "Lua byte patterns match classes, repetition, anchors and captures" {
    const testing = std.testing;
    const found = try find("-- item: 42", "(%a+):%s*(%d+)", 0);
    try testing.expect(found != null);
    try testing.expectEqual(@as(usize, 2), found.?.capture_count);
    try testing.expectEqual(@as(usize, 3), found.?.captures[0].start);
    try testing.expectEqual(@as(usize, 7), found.?.captures[0].end);
    try testing.expectEqual(@as(usize, 9), found.?.captures[1].start);
    try testing.expectEqual(@as(usize, 11), found.?.captures[1].end);
    try testing.expect((try find("abc", "^b", 0)) == null);
    try testing.expect((try find("abc", "^a.c$", 0)) != null);
}

test "Lua byte patterns support balanced items, frontiers and capture references" {
    const testing = std.testing;
    const balanced = try find("x(a(b)c)y", "%b()", 0);
    try testing.expect(balanced != null);
    try testing.expectEqual(@as(usize, 1), balanced.?.start);
    try testing.expectEqual(@as(usize, 8), balanced.?.end);

    const frontier = try find("12 hello!", "%f[%a]%a+%f[%A]", 0);
    try testing.expect(frontier != null);
    try testing.expectEqualStrings("hello", "12 hello!"[frontier.?.start..frontier.?.end]);

    const backref = try find("book book", "(%a%a%a%a)%s+%1", 0);
    try testing.expect(backref != null);
    try testing.expectEqualStrings("book book", "book book"[backref.?.start..backref.?.end]);
}
