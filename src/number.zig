// SPDX-License-Identifier: CC0-1.0

//! Number parsing for text that has other things in it.
//!
//! `std.fmt.parseInt` answers "is this whole slice a number?". When you are
//! walking a document you usually need the other question: "how much of what
//! comes next is a number?". Every routine here comes in two flavours:
//!
//!   * `scanX`  - reads a prefix and reports how many bytes it consumed.
//!   * `parseX` - requires the entire slice to be consumed.
//!
//! `Parser` is built on the `scan` family; `parse` is what you want for a
//! standalone string such as a config value.

const std = @import("std");
const testing = std.testing;

pub const ParseError = error{
    /// There was nothing that could start a number.
    NoDigits,
    /// A number was read, but bytes were left over (the `parse` family only).
    TrailingBytes,
    /// The value does not fit in the requested type.
    Overflow,
    /// A separator was in an illegal position, or a sign was not allowed here.
    InvalidCharacter,
};

pub const Base = enum(u8) {
    binary = 2,
    octal = 8,
    decimal = 10,
    hexadecimal = 16,

    pub fn radix(self: Base) u8 {
        return @intFromEnum(self);
    }

    /// The two-character literal prefix for this base, if it has one.
    pub fn prefix(self: Base) ?[]const u8 {
        return switch (self) {
            .binary => "0b",
            .octal => "0o",
            .hexadecimal => "0x",
            .decimal => null,
        };
    }
};

pub const IntOptions = struct {
    /// `null` detects the base from a `0x` / `0o` / `0b` prefix and otherwise
    /// assumes decimal. A concrete base still accepts its own prefix.
    base: ?Base = null,
    /// Whether a leading `+` or `-` may appear.
    allow_sign: bool = true,
    /// Whether `_` may appear between digits, as in `1_000_000`.
    allow_underscores: bool = true,
};

/// A value together with the number of input bytes it came from.
pub fn Scanned(comptime T: type) type {
    return struct {
        value: T,
        len: usize,
    };
}

/// Numeric value of an ASCII digit in any base up to 36, or null.
pub fn digitValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => null,
    };
}

fn digitInBase(c: u8, radix: u8) ?u8 {
    const v = digitValue(c) orelse return null;
    return if (v < radix) v else null;
}

fn startsWithIgnoreCase(bytes: []const u8, needle: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(bytes, needle);
}

// -------------------------------------------------------------------------
// Integers
// -------------------------------------------------------------------------

/// Read an integer from the front of `bytes`.
///
/// A base prefix that is not followed by a valid digit is not an error: `"0x"`
/// scans as the single digit `0`, leaving `"x"` for the caller. This keeps the
/// scanner usable on inputs like `0xZ` where `0` really is the number.
pub fn scanInt(comptime T: type, bytes: []const u8, options: IntOptions) ParseError!Scanned(T) {
    const info = @typeInfo(T).int;

    var i: usize = 0;
    var negative = false;
    if (i < bytes.len and (bytes[i] == '+' or bytes[i] == '-')) {
        if (!options.allow_sign) return error.InvalidCharacter;
        negative = bytes[i] == '-';
        i += 1;
    }
    if (negative and info.signedness == .unsigned) return error.InvalidCharacter;

    var base: Base = options.base orelse .decimal;
    // A leading zero may introduce a base prefix.
    var fallback: ?usize = null;
    if (i + 1 < bytes.len and bytes[i] == '0') {
        const marker = std.ascii.toLower(bytes[i + 1]);
        const detected: ?Base = switch (marker) {
            'b' => .binary,
            'o' => .octal,
            'x' => .hexadecimal,
            else => null,
        };
        if (detected) |d| {
            if (options.base == null or options.base.? == d) {
                base = d;
                // If no digit follows, we rewind to here and report a plain 0.
                fallback = i + 1;
                i += 2;
            }
        }
    }

    const radix = base.radix();
    var acc: T = 0;
    var digits: usize = 0;
    var last_was_digit = false;

    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '_') {
            if (!options.allow_underscores or !last_was_digit) break;
            last_was_digit = false;
            continue;
        }
        const d = digitInBase(c, radix) orelse break;
        const dt = std.math.cast(T, d) orelse return error.Overflow;
        const radix_t = std.math.cast(T, radix) orelse return error.Overflow;
        acc = std.math.mul(T, acc, radix_t) catch return error.Overflow;
        acc = if (negative)
            std.math.sub(T, acc, dt) catch return error.Overflow
        else
            std.math.add(T, acc, dt) catch return error.Overflow;
        digits += 1;
        last_was_digit = true;
    }

    if (digits == 0) {
        if (fallback) |end| return .{ .value = 0, .len = end };
        return error.NoDigits;
    }
    // Do not let a number end on a separator: "1_" consumes only "1".
    if (!last_was_digit) i -= 1;

    return .{ .value = acc, .len = i };
}

/// Parse `bytes` in full as an integer.
pub fn parseInt(comptime T: type, bytes: []const u8, options: IntOptions) ParseError!T {
    const scanned = try scanInt(T, bytes, options);
    if (scanned.len != bytes.len) return error.TrailingBytes;
    return scanned.value;
}

// -------------------------------------------------------------------------
// Floats
// -------------------------------------------------------------------------

/// End index of a run of digits (and, if permitted, `_` between them), plus
/// how many real digits it contained.
fn digitRun(bytes: []const u8, start: usize, allow_underscores: bool) struct { end: usize, digits: usize } {
    var i = start;
    var digits: usize = 0;
    var last_was_digit = false;
    while (i < bytes.len) : (i += 1) {
        if (std.ascii.isDigit(bytes[i])) {
            digits += 1;
            last_was_digit = true;
        } else if (bytes[i] == '_' and allow_underscores and last_was_digit) {
            last_was_digit = false;
        } else break;
    }
    if (!last_was_digit and digits > 0) i -= 1;
    return .{ .end = i, .digits = digits };
}

pub const FloatOptions = struct {
    allow_sign: bool = true,
    allow_underscores: bool = true,
    /// Whether `inf`, `infinity` and `nan` are recognised (case-insensitive).
    allow_special: bool = true,
};

/// Read a decimal floating point number from the front of `bytes`.
///
/// Accepts `[+-] digits [. digits] [eE [+-] digits]` plus, when enabled, the
/// special forms `inf`, `infinity` and `nan`. Hexadecimal float literals are
/// not scanned.
pub fn scanFloat(comptime T: type, bytes: []const u8, options: FloatOptions) ParseError!Scanned(T) {
    var i: usize = 0;
    if (i < bytes.len and (bytes[i] == '+' or bytes[i] == '-')) {
        if (!options.allow_sign) return error.InvalidCharacter;
        i += 1;
    }

    if (options.allow_special) {
        const rest = bytes[i..];
        const special: ?usize = if (startsWithIgnoreCase(rest, "infinity"))
            "infinity".len
        else if (startsWithIgnoreCase(rest, "inf"))
            "inf".len
        else if (startsWithIgnoreCase(rest, "nan"))
            "nan".len
        else
            null;
        if (special) |n| {
            const end = i + n;
            const value = std.fmt.parseFloat(T, bytes[0..end]) catch return error.InvalidCharacter;
            return .{ .value = value, .len = end };
        }
    }

    const whole = digitRun(bytes, i, options.allow_underscores);
    i = whole.end;
    var digits = whole.digits;

    if (i < bytes.len and bytes[i] == '.') {
        const frac = digitRun(bytes, i + 1, options.allow_underscores);
        if (frac.digits > 0 or digits > 0) {
            i = frac.end;
            digits += frac.digits;
        }
    }
    if (digits == 0) return error.NoDigits;

    // Only consume the exponent if it is well formed; "1e" is the number 1.
    if (i < bytes.len and (bytes[i] == 'e' or bytes[i] == 'E')) {
        var j = i + 1;
        if (j < bytes.len and (bytes[j] == '+' or bytes[j] == '-')) j += 1;
        const exp = digitRun(bytes, j, options.allow_underscores);
        if (exp.digits > 0) i = exp.end;
    }

    const value = std.fmt.parseFloat(T, bytes[0..i]) catch |err| return switch (err) {
        error.InvalidCharacter => error.InvalidCharacter,
    };
    return .{ .value = value, .len = i };
}

/// Parse `bytes` in full as a float.
pub fn parseFloat(comptime T: type, bytes: []const u8, options: FloatOptions) ParseError!T {
    const scanned = try scanFloat(T, bytes, options);
    if (scanned.len != bytes.len) return error.TrailingBytes;
    return scanned.value;
}

// -------------------------------------------------------------------------
// Booleans
// -------------------------------------------------------------------------

/// Read `true` or `false` (case-insensitive) from the front of `bytes`.
pub fn scanBool(bytes: []const u8) ?Scanned(bool) {
    if (startsWithIgnoreCase(bytes, "true")) return .{ .value = true, .len = 4 };
    if (startsWithIgnoreCase(bytes, "false")) return .{ .value = false, .len = 5 };
    return null;
}

pub fn parseBool(bytes: []const u8) ?bool {
    const scanned = scanBool(bytes) orelse return null;
    if (scanned.len != bytes.len) return null;
    return scanned.value;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "scanInt reports how far it got" {
    const r = try scanInt(u32, "123abc", .{});
    try testing.expectEqual(@as(u32, 123), r.value);
    try testing.expectEqual(@as(usize, 3), r.len);

    const none = scanInt(u32, "abc", .{});
    try testing.expectError(error.NoDigits, none);
}

test "parseInt requires the whole slice" {
    try testing.expectEqual(@as(u32, 123), try parseInt(u32, "123", .{}));
    try testing.expectError(error.TrailingBytes, parseInt(u32, "123abc", .{}));
}

test "signs" {
    try testing.expectEqual(@as(i32, -42), try parseInt(i32, "-42", .{}));
    try testing.expectEqual(@as(i32, 42), try parseInt(i32, "+42", .{}));
    try testing.expectError(error.InvalidCharacter, parseInt(u32, "-42", .{}));
    try testing.expectError(error.InvalidCharacter, parseInt(i32, "-42", .{ .allow_sign = false }));
}

test "signed minimum does not overflow" {
    try testing.expectEqual(@as(i8, -128), try parseInt(i8, "-128", .{}));
    try testing.expectError(error.Overflow, parseInt(i8, "128", .{}));
    try testing.expectError(error.Overflow, parseInt(i8, "-129", .{}));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try parseInt(i64, "-9223372036854775808", .{}));
}

test "base detection" {
    try testing.expectEqual(@as(u32, 0xFF), try parseInt(u32, "0xFF", .{}));
    try testing.expectEqual(@as(u32, 0o17), try parseInt(u32, "0o17", .{}));
    try testing.expectEqual(@as(u32, 0b1011), try parseInt(u32, "0b1011", .{}));
    try testing.expectEqual(@as(i32, -0xFF), try parseInt(i32, "-0xFF", .{}));
    try testing.expectEqual(@as(u32, 10), try parseInt(u32, "10", .{}));
}

test "explicit base wins" {
    try testing.expectEqual(@as(u32, 255), try parseInt(u32, "FF", .{ .base = .hexadecimal }));
    try testing.expectEqual(@as(u32, 255), try parseInt(u32, "0xFF", .{ .base = .hexadecimal }));
    // 'x' is not a decimal digit, so only the leading 0 is a number here.
    try testing.expectError(error.TrailingBytes, parseInt(u32, "0x10", .{ .base = .decimal }));
}

test "a bare prefix scans as zero" {
    const r = try scanInt(u32, "0x", .{});
    try testing.expectEqual(@as(u32, 0), r.value);
    try testing.expectEqual(@as(usize, 1), r.len);

    const z = try scanInt(u32, "0xZZ", .{});
    try testing.expectEqual(@as(u32, 0), z.value);
    try testing.expectEqual(@as(usize, 1), z.len);
}

test "underscore separators" {
    try testing.expectEqual(@as(u32, 1000000), try parseInt(u32, "1_000_000", .{}));
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try parseInt(u32, "0xDEAD_BEEF", .{}));

    // A trailing or doubled separator ends the number rather than joining it.
    const trailing = try scanInt(u32, "1_", .{});
    try testing.expectEqual(@as(u32, 1), trailing.value);
    try testing.expectEqual(@as(usize, 1), trailing.len);

    const doubled = try scanInt(u32, "1__0", .{});
    try testing.expectEqual(@as(u32, 1), doubled.value);
    try testing.expectEqual(@as(usize, 1), doubled.len);

    try testing.expectError(error.TrailingBytes, parseInt(u32, "1_0", .{ .allow_underscores = false }));
}

test "overflow is detected" {
    try testing.expectError(error.Overflow, parseInt(u8, "256", .{}));
    try testing.expectError(error.Overflow, parseInt(u32, "99999999999999999999", .{}));
}

test "scanFloat" {
    const a = try scanFloat(f64, "3.5rest", .{});
    try testing.expectEqual(@as(f64, 3.5), a.value);
    try testing.expectEqual(@as(usize, 3), a.len);

    try testing.expectEqual(@as(f64, -0.25), try parseFloat(f64, "-0.25", .{}));
    try testing.expectEqual(@as(f64, 1.5e3), try parseFloat(f64, "1.5e3", .{}));
    try testing.expectEqual(@as(f64, 1.5e-3), try parseFloat(f64, "1.5E-3", .{}));
    try testing.expectEqual(@as(f64, 42), try parseFloat(f64, "42", .{}));
    try testing.expectEqual(@as(f64, 0.5), try parseFloat(f64, ".5", .{}));
    try testing.expectEqual(@as(f64, 5), try parseFloat(f64, "5.", .{}));
    try testing.expectEqual(@as(f64, 1000.5), try parseFloat(f64, "1_000.5", .{}));
}

test "a dangling exponent is not consumed" {
    const r = try scanFloat(f64, "1e", .{});
    try testing.expectEqual(@as(f64, 1), r.value);
    try testing.expectEqual(@as(usize, 1), r.len);

    const s = try scanFloat(f64, "1e+", .{});
    try testing.expectEqual(@as(usize, 1), s.len);
}

test "float special values" {
    try testing.expect(std.math.isPositiveInf(try parseFloat(f64, "inf", .{})));
    try testing.expect(std.math.isNegativeInf(try parseFloat(f64, "-Infinity", .{})));
    try testing.expect(std.math.isNan(try parseFloat(f64, "NaN", .{})));
    try testing.expectError(error.NoDigits, parseFloat(f64, "inf", .{ .allow_special = false }));
}

test "float errors" {
    try testing.expectError(error.NoDigits, scanFloat(f64, "abc", .{}));
    try testing.expectError(error.NoDigits, scanFloat(f64, ".", .{}));
    try testing.expectError(error.TrailingBytes, parseFloat(f64, "3.5rest", .{}));
}

test "booleans" {
    try testing.expectEqual(@as(?bool, true), parseBool("true"));
    try testing.expectEqual(@as(?bool, false), parseBool("FALSE"));
    try testing.expectEqual(@as(?bool, null), parseBool("truthy"));
    try testing.expectEqual(@as(usize, 4), scanBool("true story").?.len);
}

test "digitValue" {
    try testing.expectEqual(@as(?u8, 0), digitValue('0'));
    try testing.expectEqual(@as(?u8, 9), digitValue('9'));
    try testing.expectEqual(@as(?u8, 10), digitValue('a'));
    try testing.expectEqual(@as(?u8, 35), digitValue('Z'));
    try testing.expectEqual(@as(?u8, null), digitValue('!'));
}
