pub const Decoded = struct {
    codepoint: u32,
    next: usize,
};

pub fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

/// Decode one Lua UTF-8 sequence. Lax mode still rejects malformed and
/// overlong encodings, but permits surrogates and values above Unicode.
pub fn decode(bytes: []const u8, start: usize, lax: bool) ?Decoded {
    if (start >= bytes.len) return null;
    const lead = bytes[start];
    if (lead < 0x80) return .{ .codepoint = lead, .next = start + 1 };

    const width: usize = if (lead >= 0xc2 and lead <= 0xdf)
        2
    else if (lead >= 0xe0 and lead <= 0xef)
        3
    else if (lead >= 0xf0 and lead <= 0xf7)
        4
    else if (lead >= 0xf8 and lead <= 0xfb)
        5
    else if (lead >= 0xfc and lead <= 0xfd)
        6
    else
        return null;
    if (bytes.len - start < width) return null;

    const first_bits: u8 = switch (width) {
        2 => lead & 0x1f,
        3 => lead & 0x0f,
        4 => lead & 0x07,
        5 => lead & 0x03,
        6 => lead & 0x01,
        else => unreachable,
    };
    var codepoint: u32 = first_bits;
    for (1..width) |offset| {
        const byte = bytes[start + offset];
        if (!isContinuation(byte)) return null;
        codepoint = (codepoint << 6) | (byte & 0x3f);
    }
    const minimum: u32 = switch (width) {
        2 => 0x80,
        3 => 0x800,
        4 => 0x10000,
        5 => 0x200000,
        6 => 0x4000000,
        else => unreachable,
    };
    if (codepoint < minimum or codepoint > 0x7fffffff) return null;
    if (!lax and (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff))) return null;
    return .{ .codepoint = codepoint, .next = start + width };
}

pub fn encode(codepoint: u64) ?struct { bytes: [6]u8, len: usize } {
    if (codepoint > 0x7fffffff) return null;
    var output: [6]u8 = undefined;
    if (codepoint < 0x80) {
        output[0] = @intCast(codepoint);
        return .{ .bytes = output, .len = 1 };
    }
    const width: usize = if (codepoint < 0x800)
        2
    else if (codepoint < 0x10000)
        3
    else if (codepoint < 0x200000)
        4
    else if (codepoint < 0x4000000)
        5
    else
        6;
    var value = codepoint;
    var index = width;
    while (index > 1) {
        index -= 1;
        output[index] = 0x80 | @as(u8, @truncate(value & 0x3f));
        value >>= 6;
    }
    const prefixes = [_]u8{ 0, 0, 0xc0, 0xe0, 0xf0, 0xf8, 0xfc };
    output[0] = prefixes[width] | @as(u8, @truncate(value));
    return .{ .bytes = output, .len = width };
}

test "UTF-8 codec validates strict and lax Lua sequences" {
    const std = @import("std");
    const testing = std.testing;
    const encoded = encode(0x1f642).?;
    const decoded = decode(encoded.bytes[0..encoded.len], 0, false).?;
    try testing.expectEqual(@as(u32, 0x1f642), decoded.codepoint);
    try testing.expectEqual(encoded.len, decoded.next);
    try testing.expect(decode("\xed\xa0\x80", 0, false) == null);
    try testing.expectEqual(@as(u32, 0xd800), decode("\xed\xa0\x80", 0, true).?.codepoint);
    try testing.expect(decode("\xc0\x80", 0, true) == null);
}
