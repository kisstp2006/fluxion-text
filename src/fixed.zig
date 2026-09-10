// SPDX-License-Identifier: CC0-1.0

//! Fixed-capacity strings that live entirely inline.
//!
//! `Fixed(n)` stores up to `n` bytes in the value itself. There is no
//! allocator, no pointer, and nothing to free, so it can sit in a component
//! array, cross a thread boundary, or be copied in a hot loop without ceremony.
//! Overflow is an error rather than a reallocation.
//!
//! The unused tail is always zeroed, which means two `Fixed` values holding the
//! same text are identical byte-for-byte. That makes them safe to use directly
//! as `std.AutoHashMap` keys and to compare with `std.meta.eql`.

const std = @import("std");
const testing = std.testing;

const View = @import("View.zig");
const utf8 = @import("utf8.zig");

/// Returned when text will not fit in the remaining capacity.
pub const Error = error{Overflow};

pub fn Fixed(comptime capacity_bytes: usize) type {
    return struct {
        const Self = @This();

        /// Smallest integer that can hold a length up to `capacity`, so
        /// `Fixed(15)` occupies 16 bytes rather than 15 plus a `usize`.
        pub const Len = std.math.IntFittingRange(0, capacity_bytes);
        pub const capacity: usize = capacity_bytes;

        buf: [capacity_bytes]u8,
        len: Len,

        pub const empty: Self = .{ .buf = @splat(0), .len = 0 };

        /// Fails if `bytes` does not fit.
        pub fn init(bytes: []const u8) Error!Self {
            var self: Self = .empty;
            try self.append(bytes);
            return self;
        }

        /// Keeps as much of `bytes` as fits, cutting on a UTF-8 boundary so the
        /// result is never a half-encoded character.
        pub fn initTruncating(bytes: []const u8) Self {
            var self: Self = .empty;
            const n = if (bytes.len <= capacity_bytes)
                bytes.len
            else
                utf8.floorBoundary(bytes, capacity_bytes);
            @memcpy(self.buf[0..n], bytes[0..n]);
            self.len = @intCast(n);
            return self;
        }

        /// Compile-time construction. Text that does not fit is a compile error
        /// rather than something to handle at runtime.
        pub fn fromLiteral(comptime bytes: []const u8) Self {
            comptime {
                if (bytes.len > capacity_bytes) @compileError(std.fmt.comptimePrint(
                    "string of {d} bytes does not fit in Fixed({d})",
                    .{ bytes.len, capacity_bytes },
                ));
            }
            return init(bytes) catch unreachable;
        }

        fn zeroTail(self: *Self) void {
            @memset(self.buf[self.len..], 0);
        }

        // -----------------------------------------------------------------
        // Reading
        // -----------------------------------------------------------------

        /// Takes a pointer because the bytes live inside the value: taking a
        /// slice of a temporary would dangle.
        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn view(self: *const Self) View {
            return .init(self.slice());
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == capacity_bytes;
        }

        /// Bytes still available.
        pub fn unused(self: *const Self) usize {
            return capacity_bytes - self.len;
        }

        pub fn at(self: *const Self, index: usize) ?u8 {
            if (index >= self.len) return null;
            return self.buf[index];
        }

        // -----------------------------------------------------------------
        // Writing
        // -----------------------------------------------------------------

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.zeroTail();
        }

        /// Replace the contents outright.
        pub fn set(self: *Self, bytes: []const u8) Error!void {
            if (bytes.len > capacity_bytes) return error.Overflow;
            @memcpy(self.buf[0..bytes.len], bytes);
            self.len = @intCast(bytes.len);
            self.zeroTail();
        }

        pub fn append(self: *Self, bytes: []const u8) Error!void {
            if (bytes.len > self.unused()) return error.Overflow;
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += @intCast(bytes.len);
            self.zeroTail();
        }

        pub fn appendByte(self: *Self, byte: u8) Error!void {
            if (self.isFull()) return error.Overflow;
            self.buf[self.len] = byte;
            self.len += 1;
            self.zeroTail();
        }

        pub fn appendCodepoint(self: *Self, codepoint: u21) (Error || utf8.EncodeError)!void {
            const seq = try utf8.encodeSequence(codepoint);
            try self.append(seq.slice());
        }

        /// Append formatted output. Nothing is written if the result would not
        /// fit, so a failed call leaves the string unchanged.
        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) Error!void {
            const written = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch
                return error.Overflow;
            self.len += @intCast(written.len);
            self.zeroTail();
        }

        /// Drop everything past `new_len`. Asserts it is within the length.
        pub fn truncate(self: *Self, new_len: usize) void {
            std.debug.assert(new_len <= self.len);
            self.len = @intCast(new_len);
            self.zeroTail();
        }

        pub fn pop(self: *Self) ?u8 {
            if (self.len == 0) return null;
            self.len -= 1;
            const byte = self.buf[self.len];
            self.zeroTail();
            return byte;
        }

        // -----------------------------------------------------------------
        // Comparison
        // -----------------------------------------------------------------

        pub fn eql(self: *const Self, other: *const Self) bool {
            return std.mem.eql(u8, self.slice(), other.slice());
        }

        pub fn eqlBytes(self: *const Self, other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }

        pub fn order(self: *const Self, other: *const Self) std.math.Order {
            return std.mem.order(u8, self.slice(), other.slice());
        }

        pub fn lessThan(self: *const Self, other: *const Self) bool {
            return std.mem.lessThan(u8, self.slice(), other.slice());
        }

        pub fn hash(self: *const Self) u64 {
            return std.hash.Wyhash.hash(0, self.slice());
        }

        /// Print with `{f}`.
        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll(self.buf[0..self.len]);
        }
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Name = Fixed(16);

test "construction" {
    var n = try Name.init("player");
    try testing.expectEqualStrings("player", n.slice());
    try testing.expectEqual(@as(usize, 6), n.len);
    try testing.expect(!n.isEmpty());
    try testing.expect(!n.isFull());
    try testing.expectEqual(@as(usize, 10), n.unused());

    try testing.expect(Name.empty.isEmpty());
    try testing.expectError(error.Overflow, Name.init("a string well past sixteen bytes"));
}

test "fromLiteral is checked at compile time" {
    const n = Name.fromLiteral("compile-time");
    try testing.expectEqualStrings("compile-time", n.slice());
}

test "initTruncating cuts on a codepoint boundary" {
    // 15 ASCII bytes then a 2-byte 'e-acute', so a plain cut at the 16-byte
    // capacity would land between its two bytes.
    const long = "abcdefghijklmno\u{00E9}xyz";
    const n = Name.initTruncating(long);
    try testing.expectEqualStrings("abcdefghijklmno", n.slice());
    try testing.expect(n.view().isValidUtf8());

    // Text that already fits is kept whole.
    const short = Name.initTruncating("short");
    try testing.expectEqualStrings("short", short.slice());
}

test "appending" {
    var n: Name = .empty;
    try n.append("ent");
    try n.appendByte('_');
    try n.print("{d}", .{42});
    try n.appendCodepoint(0x00E9);
    try testing.expectEqualStrings("ent_42\u{00E9}", n.slice());
}

test "overflow leaves the value unchanged" {
    var n = try Name.init("0123456789");
    try testing.expectError(error.Overflow, n.append("too much text here"));
    try testing.expectEqualStrings("0123456789", n.slice());

    try testing.expectError(error.Overflow, n.print("{d}", .{1234567890}));
    try testing.expectEqualStrings("0123456789", n.slice());

    // Exactly filling the capacity is fine.
    try n.append("123456");
    try testing.expect(n.isFull());
    try testing.expectError(error.Overflow, n.appendByte('x'));
}

test "set, truncate, pop and clear" {
    var n = try Name.init("original");
    try n.set("replaced");
    try testing.expectEqualStrings("replaced", n.slice());

    n.truncate(2);
    try testing.expectEqualStrings("re", n.slice());
    try testing.expectEqual(@as(?u8, 'e'), n.pop());
    try testing.expectEqualStrings("r", n.slice());

    n.clear();
    try testing.expect(n.isEmpty());
    try testing.expectEqual(@as(?u8, null), n.pop());
}

test "comparison and views" {
    const a = try Name.init("alpha");
    const b = try Name.init("beta");
    const a2 = try Name.init("alpha");

    try testing.expect(a.eql(&a2));
    try testing.expect(!a.eql(&b));
    try testing.expect(a.eqlBytes("alpha"));
    try testing.expect(a.lessThan(&b));
    try testing.expectEqual(std.math.Order.lt, a.order(&b));
    try testing.expectEqual(a.hash(), a2.hash());
    try testing.expect(a.view().startsWith("al"));
}

test "the unused tail is always zeroed" {
    // This is what makes the type safe as an AutoHashMap key: two values with
    // the same text must have identical bytes, including the unused tail.
    var a = try Name.init("scratched");
    a.clear();
    try a.append("hi");

    const b = try Name.init("hi");
    try testing.expectEqualSlices(u8, &b.buf, &a.buf);
    try testing.expect(std.meta.eql(a, b));
}

test "works as an AutoHashMap key" {
    var map: std.AutoHashMapUnmanaged(Name, u32) = .empty;
    defer map.deinit(testing.allocator);

    try map.put(testing.allocator, try .init("health"), 100);
    try map.put(testing.allocator, try .init("mana"), 50);
    // Same text arrived at a different way must hit the same slot.
    var rebuilt: Name = .empty;
    try rebuilt.append("heal");
    try rebuilt.append("th");
    try map.put(testing.allocator, rebuilt, 75);

    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expectEqual(@as(?u32, 75), map.get(try .init("health")));
    try testing.expectEqual(@as(?u32, 50), map.get(try .init("mana")));
}

test "capacity is packed into the length field" {
    try testing.expectEqual(u4, Fixed(15).Len);
    try testing.expectEqual(u8, Fixed(255).Len);
    try testing.expectEqual(@as(usize, 16), @sizeOf(Fixed(15)));
}

test "copies are independent" {
    var a = try Name.init("first");
    var b = a; // plain value copy, no allocator involved
    try b.set("second");
    try testing.expectEqualStrings("first", a.slice());
    try testing.expectEqualStrings("second", b.slice());
}

test "format" {
    const n = try Name.init("shown");
    try testing.expectFmt("[shown]", "[{f}]", .{n});
}
