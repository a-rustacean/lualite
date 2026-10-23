const std = @import("std");

// Lua 5.4's number is an integer *or* a float, and the difference is visible
// everywhere: `1 == 1.0` but `math.type` tells them apart, `//` and the bitwise
// operators want integers, `tostring(1.0)` has a `.0` on it, and a table key of
// `1` and one of `1.0` are the same slot. So the type is tagged rather than a
// float with a flag, and every operation below says which of the two it produces.
pub const Number = union(enum) {
    int: i64,
    float: f64,

    pub const max_int: i64 = std.math.maxInt(i64);
    pub const min_int: i64 = std.math.minInt(i64);

    pub fn fromInt(n: i64) Number {
        return .{ .int = n };
    }

    pub fn fromFloat(f: f64) Number {
        return .{ .float = f };
    }

    pub fn isInt(n: Number) bool {
        return n == .int;
    }

    // What an operation needs: the bitwise operators and `//` on a float only
    // work on a value with an exact integer representation, and Lua refuses the
    // rest rather than truncating.
    pub fn toIntExact(n: Number) ?i64 {
        return switch (n) {
            .int => |v| v,
            .float => |f| floatToIntExact(f),
        };
    }

    // The widened form, for a comparison between one of each.
    pub fn toFloat(n: Number) f64 {
        return switch (n) {
            .int => |v| @floatFromInt(v),
            .float => |f| f,
        };
    }
};

/// The errors these can raise, which the VM turns into `error()` calls. Division
/// and modulus by zero are the only ones Lua checks in the arithmetic itself.
pub const Error = error{
    DivideByZero,
    NoIntegerRepresentation,
};

// --- the arithmetic, and which of the two each one produces ---

/// `+ - *` stay integers when both sides are, and wrap rather than becoming
/// floats: `maxinteger + 1` is `mininteger`, as Lua has it.
pub fn add(a: Number, b: Number) Number {
    return switch (pair(a, b)) {
        .both_int => |ints| .{ .int = ints[0] +% ints[1] },
        .mixed => |m| .{ .float = m.a.toFloat() + m.b.toFloat() },
    };
}

pub fn sub(a: Number, b: Number) Number {
    return switch (pair(a, b)) {
        .both_int => |ints| .{ .int = ints[0] -% ints[1] },
        .mixed => |m| .{ .float = m.a.toFloat() - m.b.toFloat() },
    };
}

pub fn mul(a: Number, b: Number) Number {
    return switch (pair(a, b)) {
        .both_int => |ints| .{ .int = ints[0] *% ints[1] },
        .mixed => |m| .{ .float = m.a.toFloat() * m.b.toFloat() },
    };
}

/// `/` is always a float, even over two integers and even where the result is
/// exact: `4 / 2` is `2.0`.
pub fn div(a: Number, b: Number) Number {
    return .{ .float = a.toFloat() / b.toFloat() };
}

/// `^` is always a float too, `2^2` included.
pub fn pow(a: Number, b: Number) Number {
    const base = a.toFloat();
    const exp = b.toFloat();

    // the square is its own multiplication, which is both what Lua does and how
    // a `pow` with an exact answer should be spelled
    const result = if (exp == 2) base * base else std.math.pow(f64, base, exp);
    return .{ .float = result };
}

pub fn neg(a: Number) Number {
    return switch (a) {
        .int => |v| .{ .int = -%v },
        .float => |f| .{ .float = -f },
    };
}

/// `//`, which is `floor(a / b)` rather than truncation, and stays an integer when
/// both sides are.
pub fn floorDiv(a: Number, b: Number) Error!Number {
    return switch (pair(a, b)) {
        .both_int => |ints| .{ .int = try intDiv(ints[0], ints[1]) },
        .mixed => |m| .{ .float = @floor(m.a.toFloat() / m.b.toFloat()) },
    };
}

/// `//` over integers. C truncates towards zero, and floor is one lower whenever
/// the quotient is negative and not exact, so the one case that differs is
/// corrected afterwards.
fn intDiv(m: i64, n: i64) Error!i64 {
    // -1 and 0 are both special, and -1 is handled as `0 - m` rather than as a
    // division so that `mininteger // -1` wraps the way Lua's does instead of
    // being undefined
    if (n == 0) return error.DivideByZero;
    if (n == -1) return 0 -% m;

    const quotient = @divTrunc(m, n);
    if ((m ^ n) < 0 and @rem(m, n) != 0) return quotient -% 1;
    return quotient;
}

/// `%`, which is `a - floor(a / b) * b`, and stays an integer when both sides
/// are. So the sign follows the divisor, not the dividend: `-7 % 2` is `1`.
pub fn mod(a: Number, b: Number) Error!Number {
    return switch (pair(a, b)) {
        .both_int => |ints| .{ .int = try intMod(ints[0], ints[1]) },
        .mixed => |m| .{ .float = floatMod(m.a.toFloat(), m.b.toFloat()) },
    };
}

fn intMod(m: i64, n: i64) Error!i64 {
    // the same two special cases, and `m % -1` is always 0 without needing one
    if (n == 0) return error.DivideByZero;
    if (n == -1) return 0;

    const remainder = @rem(m, n);
    if (remainder != 0 and (remainder ^ n) < 0) return remainder +% n;
    return remainder;
}

/// `fmod` truncates, so the result needs correcting when `trunc(a/b)` and
/// `floor(a/b)` differ, which is exactly when it is negative and not exact.
fn floatMod(a: f64, b: f64) f64 {
    const remainder = @rem(a, b);
    if (remainder > 0) {
        if (b < 0) return remainder + b;
    } else if (remainder < 0 and b > 0) return remainder + b;
    return remainder;
}

// --- comparison ---

/// `l_intfitsf`: an integer within ±2^53 becomes a float without rounding, so
/// a mixed comparison can be done in floats. Outside that the reference
/// converts the float towards the integer side instead, which keeps
/// `maxinteger < 2^63` true and `maxinteger == 2^63` false.
fn intFitsFloat(i: i64) bool {
    return i >= -9007199254740992 and i <= 9007199254740992;
}

const min_integer_as_float: f64 = -9223372036854775808.0;

/// `luaV_flttointeger` with `F2Ifloor`, or with `F2Iceil` when `ceil` is set:
/// the rounded value, or null when it is NaN or beyond the integer range. The
/// upper bound is exclusive because 2^63 is not an `i64`.
fn floatToIntRounded(f: f64, comptime ceil: bool) ?i64 {
    var rounded = @floor(f);
    if (ceil and rounded != f) rounded += 1;
    if (!(rounded >= min_integer_as_float and rounded < -min_integer_as_float)) return null;
    return @intFromFloat(rounded);
}

/// `F2Ieq`: the float must already be integral.
fn floatToIntExact(f: f64) ?i64 {
    if (f != @trunc(f)) return null;
    return floatToIntRounded(f, false);
}

fn lessIntFloat(i: i64, f: f64) bool {
    if (intFitsFloat(i)) return @as(f64, @floatFromInt(i)) < f;
    // `i < f` is `i < ceil(f)`, and a float beyond the range is above every
    // integer exactly when it is positive
    if (floatToIntRounded(f, true)) |ceiling| return i < ceiling;
    return f > 0;
}

fn lessFloatInt(f: f64, i: i64) bool {
    if (intFitsFloat(i)) return f < @as(f64, @floatFromInt(i));
    if (floatToIntRounded(f, false)) |floored| return floored < i;
    return f < 0;
}

fn lessEqIntFloat(i: i64, f: f64) bool {
    if (intFitsFloat(i)) return @as(f64, @floatFromInt(i)) <= f;
    if (floatToIntRounded(f, false)) |floored| return i <= floored;
    return f > 0;
}

fn lessEqFloatInt(f: f64, i: i64) bool {
    if (intFitsFloat(i)) return f <= @as(f64, @floatFromInt(i));
    if (floatToIntRounded(f, true)) |ceiling| return ceiling <= i;
    return f < 0;
}

/// `<` with the reference's mixed rules. NaN makes every comparison false,
/// which falls out of IEEE rather than needing a check of its own.
pub fn less(a: Number, b: Number) bool {
    return switch (a) {
        .int => |i| switch (b) {
            .int => |j| i < j,
            .float => |f| lessIntFloat(i, f),
        },
        .float => |f| switch (b) {
            .int => |i| lessFloatInt(f, i),
            .float => |g| f < g,
        },
    };
}

pub fn lessEq(a: Number, b: Number) bool {
    return switch (a) {
        .int => |i| switch (b) {
            .int => |j| i <= j,
            .float => |f| lessEqIntFloat(i, f),
        },
        .float => |f| switch (b) {
            .int => |i| lessEqFloatInt(f, i),
            .float => |g| f <= g,
        },
    };
}

/// `==` is true across the two, since `1 == 1.0`. The reference converts both
/// sides to integers, so a float outside the integer range — or one with a
/// fraction — never equals an integer.
pub fn equal(a: Number, b: Number) bool {
    return switch (a) {
        .int => |i| switch (b) {
            .int => |j| i == j,
            .float => |f| blk: {
                const fi = floatToIntExact(f) orelse break :blk false;
                break :blk fi == i;
            },
        },
        .float => |f| switch (b) {
            .int => |i| blk: {
                const fi = floatToIntExact(f) orelse break :blk false;
                break :blk fi == i;
            },
            .float => |g| f == g,
        },
    };
}

// --- the bitwise operators, which want integers ---

/// And so does a float, provided it holds an exact integer: `3.0 & 1` is the
/// integer `1`. `3.5 & 1` is what Lua calls *number has no integer
/// representation*.
fn bitwiseOperands(a: Number, b: Number) Error![2]i64 {
    const x = a.toIntExact() orelse return error.NoIntegerRepresentation;
    const y = b.toIntExact() orelse return error.NoIntegerRepresentation;
    return .{ x, y };
}

pub fn bitAnd(a: Number, b: Number) Error!Number {
    const o = try bitwiseOperands(a, b);
    return .{ .int = o[0] & o[1] };
}

pub fn bitOr(a: Number, b: Number) Error!Number {
    const o = try bitwiseOperands(a, b);
    return .{ .int = o[0] | o[1] };
}

pub fn bitXor(a: Number, b: Number) Error!Number {
    const o = try bitwiseOperands(a, b);
    return .{ .int = o[0] ^ o[1] };
}

/// `~` is bitwise not, so its operand is an integer rather than being widened.
pub fn bitNot(a: Number) Error!Number {
    const v = a.toIntExact() orelse return error.NoIntegerRepresentation;
    return .{ .int = ~v };
}

/// A shift by 64 or more has nothing left to shift, which is `0` rather than an
/// error. A negative shift is the other direction, so `~x >> y` is `x << y`.
pub fn shiftLeft(a: Number, b: Number) Error!Number {
    const o = try bitwiseOperands(a, b);
    return .{ .int = shift(o[0], o[1]) };
}

pub fn shiftRight(a: Number, b: Number) Error!Number {
    const o = try bitwiseOperands(a, b);
    // negated with wrapping, since negating the smallest integer overflows and
    // lands back on itself, which the shift below then reads as a shift of zero
    return .{ .int = shift(o[0], -%o[1]) };
}

// `luaV_shiftl`: a positive amount moves bits out to the left and a negative one
// out to the right, and either of 64 or more moves every bit out, which is 0
// rather than an error.
//
// The right shift is on the unsigned representation, which is what `intop` does
// in lvm.c, so `-1 >> 1` is 9223372036854775807 rather than -1. It reads as a
// wart but it is what Lua 5.4 does, and the golden file has a line for it.
fn shift(x: i64, by: i64) i64 {
    const bits: i64 = @bitSizeOf(i64);

    if (by < 0) {
        // negated with wrapping, since negating the smallest integer overflows and
        // lands back on itself, which is a shift of zero either way
        const right = -%by;
        if (right >= bits) return 0;
        return @bitCast(@as(u64, @bitCast(x)) >> @intCast(right));
    }

    if (by >= bits) return 0;
    return x << @intCast(by);
}

// --- the internal case split every operation above shares ---

const Pair = union(enum) {
    both_int: [2]i64,
    mixed: struct { a: Number, b: Number },
};

fn pair(a: Number, b: Number) Pair {
    if (a == .int and b == .int) return .{ .both_int = .{ a.int, b.int } };
    return .{ .mixed = .{ .a = a, .b = b } };
}

// --- parsing ---

/// The largest integer literal whose decimal digits fit, and the last digit that
/// fits in it. `9223372036854775808` is one past the first, which is how a decimal
/// that overruns is told from a hex that wraps.
const max_by_10: u64 = @as(u64, Number.max_int) / 10;
const max_last_digit: u32 = @intCast(@as(u64, Number.max_int) % 10);

/// Reads a numeral, or returns null where Lua would read nothing.
///
/// This is `luaO_str2num`: an integer if that reads whole, else a float, else
/// nothing. Spaces around are allowed and the whole string has to be consumed, so
/// this is what `tonumber("  0x1F  ")` and `tonumber("12abc")` go through as well
/// as what a literal in the source goes through.
pub fn parse(text: []const u8) ?Number {
    if (parseInt(text)) |i| return .{ .int = i };
    return parseFloatText(text);
}

/// The integer half on its own, which is `l_str2int`. Returns null both for a
/// numeral that is not one and for a decimal that overruns, since an overrunning
/// decimal is a float rather than a refusal.
fn parseInt(text: []const u8) ?i64 {
    var s = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (s.len == 0) return null;

    // a sign is only read here; the lexer puts it in front of the numeral as its
    // own token and never passes it to a literal
    var negate = false;
    if (s[0] == '+' or s[0] == '-') {
        negate = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) return null;

    var value: u64 = 0;

    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        // hex accumulates without checking, so an overlarge one wraps rather than
        // falling through to a float. `0xffffffffffffffff` is -1. A bare "0x"
        // reads no digits and is refused outright, like the reference's first
        // `lisxdixel` check in `l_str2int`.
        if (s.len == 2) return null;
        for (s[2..]) |c| {
            if (!std.ascii.isHex(c)) return null;
            value = value *% 16 + hexValue(c);
        }
    } else {
        for (s) |c| {
            if (!std.ascii.isDigit(c)) return null;

            const digit = c - '0';
            // the check is on the value about to be built, not the one built, so
            // that a decimal which overruns is recognised as doing so
            if (value >= max_by_10 and
                (value > max_by_10 or digit > max_last_digit +% @as(u32, @intFromBool(negate))))
            {
                return null;
            }
            value = value *% 10 + digit;
        }
    }

    const signed: i64 = @bitCast(value);
    return if (negate) -%signed else signed;
}

/// The float half, which is what the standard library's `strtod` does and what
/// Lua hands the rest of a numeral to. `l_str2d` first looks for the first of
/// `.xXnN` and refuses the numeral when it is `n` or `N`, which is how `inf`
/// and `nan` — words C's `strtod` would accept — stay non-numerals in Lua.
fn parseFloatText(text: []const u8) ?Number {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    for (trimmed) |c| {
        switch (c) {
            '.', 'x', 'X' => break,
            'n', 'N' => return null,
            else => {},
        }
    }
    const f = std.fmt.parseFloat(f64, trimmed) catch return null;
    return .{ .float = f };
}

fn hexValue(c: u8) u64 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => c - 'A' + 10,
    };
}

// --- printing ---

// Enough for anything below: a sign, 14 significant digits with a point between
// them, and an exponent.
pub const buffer_size = 64;

/// The significant digits `tostring` keeps. Lua's `LUA_NUMBER_FMT` is `%.14g`,
/// which is 14 *significant* digits and not 14 decimal places, so it is built here
/// out of the scientific form rather than handed to a formatter: Zig's `{d:.14}`
/// means fourteen places after the point.
const significant_digits = 14;

const FormatError = error{NoSpaceLeft};

/// What `tostring` writes: a plain decimal for an integer, and for a float
/// `%.14g` with a `.0` put on the end when what came out reads as an integer, so
/// `1.0` is `"1.0"` and `1e15` is `"1e+15"`.
///
/// `%g` uses exponent form when the exponent is below -4 or at least as large as
/// the precision, and fixed otherwise, and drops trailing zeros in both.
pub fn toBytes(n: Number, buffer: []u8) FormatError![]const u8 {
    return switch (n) {
        .int => |v| std.fmt.bufPrint(buffer, "{d}", .{v}),
        .float => |f| formatFloat(f, buffer, true),
    };
}

/// What `io.write` and `file:write` write for a number: the same digits
/// `tostring` gives, but without the `.0`, because `g_write` formats floats
/// with plain `LUA_NUMBER_FMT` (`%.14g`) there — `1.0` goes out as `"1"`.
pub fn toWriteBytes(n: Number, buffer: []u8) FormatError![]const u8 {
    return switch (n) {
        .int => |v| std.fmt.bufPrint(buffer, "{d}", .{v}),
        .float => |f| formatFloat(f, buffer, false),
    };
}

fn formatFloat(f: f64, buffer: []u8, comptime with_zero: bool) FormatError![]const u8 {
    var scratch: [std.fmt.float.min_buffer_size]u8 = undefined;

    // the scientific form rounded to the precision, which is where both the digits
    // and the exponent come from. A non-finite float has no 'e' in it.
    const scientific = std.fmt.float.render(&scratch, f, .{
        .mode = .scientific,
        .precision = significant_digits - 1,
    }) catch return error.NoSpaceLeft;

    const e_pos = std.mem.lastIndexOfScalar(u8, scientific, 'e') orelse
        return std.fmt.bufPrint(buffer, "{s}", .{scientific});

    const exp = std.fmt.parseInt(i32, scientific[e_pos + 1 ..], 10) catch
        return error.NoSpaceLeft;

    // the mantissa is a sign, a digit, maybe a point, and the digits. Taking the
    // point out is what leaves the significant digits as one run.
    const negative = scientific[0] == '-';
    const body = scientific[(if (negative) @as(usize, 1) else 0)..e_pos];
    const point = std.mem.indexOfScalar(u8, body, '.');

    var digits_buf: [significant_digits]u8 = undefined;
    const digits = blk: {
        if (point) |at| {
            // the point goes, and the run closes up
            const kept = @min(at, digits_buf.len);
            @memcpy(digits_buf[0..kept], body[0..kept]);
            const after = @min(body.len - at - 1, digits_buf.len - kept);
            @memcpy(digits_buf[kept .. kept + after], body[at + 1 ..][0..after]);
            break :blk digits_buf[0 .. kept + after];
        }
        break :blk body[0..@min(body.len, digits_buf.len)];
    };

    // dropping the trailing zeros is what turns `1.5000000000000` into `15`, which
    // the layout below puts the point back into
    var kept = digits.len;
    while (kept > 1 and digits[kept - 1] == '0') kept -= 1;
    const sigils = digits[0..kept];

    var out: Out = .{ .buffer = buffer };
    if (negative) try out.put('-');

    if (exp >= -4 and exp < significant_digits) {
        try fixed(&out, sigils, exp);
    } else {
        try exponent(&out, sigils, exp);
    }

    // `tostring` puts a `.0` on a float whose printed form reads as an integer, so
    // `1.0` is `"1.0"` and `100.0` is `"100.0"`. What is being tested is whether
    // every character is a digit or a sign, which `inf`, `nan` and anything with
    // an exponent in it fail. `g_write` leaves it off.
    if (with_zero and readsAsInteger(out.written())) {
        try out.put('.');
        try out.put('0');
    }

    return out.written();
}

fn readsAsInteger(text: []const u8) bool {
    for (text) |c| {
        if (c != '-' and !std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// The fixed form, which is `digits` with a point after `exp + 1` of them, padded
/// with zeros where the exponent reaches past what there is.
fn fixed(out: *Out, digits: []const u8, exp: i32) FormatError!void {
    if (exp >= 0) {
        const whole: u32 = @intCast(exp + 1);

        const have = @min(whole, digits.len);
        for (digits[0..have]) |c| try out.put(c);

        // the exponent reaching past the digits there are is a run of zeros, as
        // `100` has two of them under a single digit and an exponent of two
        var written: u32 = @intCast(have);
        while (written < whole) : (written += 1) try out.put('0');

        if (digits.len > whole) {
            try out.put('.');
            for (digits[whole..]) |c| try out.put(c);
        }
        return;
    }

    // below one, so a zero, a point, and enough zeros to reach the first digit
    try out.put('0');
    try out.put('.');
    var pad: i32 = -1;
    while (pad > exp) : (pad -= 1) try out.put('0');

    for (digits) |c| try out.put(c);
}

/// The exponent form, which keeps a point only when there is more than one digit to
/// put on either side of it, and gives the exponent at least two digits.
fn exponent(out: *Out, digits: []const u8, exp: i32) FormatError!void {
    try out.put(digits[0]);

    if (digits.len > 1) {
        try out.put('.');
        for (digits[1..]) |c| try out.put(c);
    }

    try out.put('e');
    // C always writes the sign, so `1e+15` rather than `1e15`
    try out.put(if (exp < 0) '-' else '+');

    // and always at least two digits, so `1e+05` rather than `1e+5`
    const magnitude: u32 = @intCast(if (exp < 0) -exp else exp);
    var started = false;

    var place: u32 = 100;
    while (true) {
        const digit = magnitude / place;
        if (digit != 0 or started or place == 10) {
            try out.put(decimalDigit(digit));
            started = true;
        }
        if (place == 1) break;
        place /= 10;
    }
}

fn decimalDigit(n: u32) u8 {
    return @intCast('0' + n % 10);
}

/// Writes into a fixed buffer and refuses to run past it, rather than dropping
/// what does not fit and returning a shorter number than the one asked for.
const Out = struct {
    buffer: []u8,
    at: usize = 0,

    fn put(out: *Out, c: u8) FormatError!void {
        if (out.at >= out.buffer.len) return error.NoSpaceLeft;
        out.buffer[out.at] = c;
        out.at += 1;
    }

    fn written(out: *const Out) []const u8 {
        return out.buffer[0..out.at];
    }
};
