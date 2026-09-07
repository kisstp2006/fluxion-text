// SPDX-License-Identifier: CC0-1.0

//! UTF-8 primitives: encode, decode, validate, iterate, and boundary math.
//!
//! This is the lowest layer of Fluxion Text. Everything here works on plain
//! `[]const u8` slices and never allocates. The higher-level `View`, `Builder`
//! and `Parser` types are built on top of it.

const std = @import("std");
const unicode = std.unicode;
const testing = std.testing;

/// U+FFFD REPLACEMENT CHARACTER, substituted by the lossy decoding paths.
pub const replacement: u21 = 0xFFFD;

/// The highest codepoint Unicode defines.
pub const max_codepoint: u21 = 0x10FFFF;

/// No UTF-8 sequence is longer than this.
pub const max_sequence_len: usize = 4;

pub const DecodeError = error{
    /// The leading byte can never start a UTF-8 sequence.
    InvalidStartByte,
    /// The sequence runs past the end of the input.
    Truncated,
    /// A byte that should have been a continuation byte (0b10xxxxxx) was not.
    InvalidContinuation,
    /// The codepoint was encoded using more bytes than necessary.
    OverlongEncoding,
    /// The codepoint is a UTF-16 surrogate half (U+D800..U+DFFF).
    SurrogateHalf,
    /// The codepoint is greater than `max_codepoint`.
    CodepointTooLarge,
};

pub const EncodeError = error{
    /// The codepoint is greater than `max_codepoint`.
    CodepointTooLarge,
    /// The codepoint is a UTF-16 surrogate half (U+D800..U+DFFF).
    SurrogateHalf,
    /// The destination buffer cannot hold the encoded sequence.
    BufferTooSmall,
};

/// One decoded codepoint together with the number of bytes it occupied.
pub const Decoded = struct {
    codepoint: u21,
    len: u3,
};

/// True if `byte` is a UTF-8 continuation byte (0b10xxxxxx).
pub fn isContinuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

/// True if `byte` can begin a UTF-8 sequence.
pub fn isStartByte(byte: u8) bool {
    return !isContinuation(byte) and byte != 0xC0 and byte != 0xC1 and byte < 0xF5;
}

/// Length in bytes of the sequence beginning with `first_byte`.
pub fn sequenceLength(first_byte: u8) DecodeError!u3 {
    return unicode.utf8ByteSequenceLength(first_byte) catch error.InvalidStartByte;
}

/// True if `codepoint` is a UTF-16 surrogate half, which UTF-8 may not encode.
pub fn isSurrogate(codepoint: u21) bool {
    return codepoint >= 0xD800 and codepoint <= 0xDFFF;
}

/// Number of bytes `codepoint` needs when encoded.
pub fn encodedLength(codepoint: u21) EncodeError!u3 {
    if (codepoint > max_codepoint) return error.CodepointTooLarge;
    if (isSurrogate(codepoint)) return error.SurrogateHalf;
    return unicode.utf8CodepointSequenceLength(codepoint) catch error.CodepointTooLarge;
}

/// Encode `codepoint` into `out`, returning the number of bytes written.
pub fn encode(codepoint: u21, out: []u8) EncodeError!u3 {
    const len = try encodedLength(codepoint);
    if (out.len < len) return error.BufferTooSmall;
    return unicode.utf8Encode(codepoint, out) catch |err| switch (err) {
        error.CodepointTooLarge => error.CodepointTooLarge,
        error.Utf8CannotEncodeSurrogateHalf => error.SurrogateHalf,
    };
}

/// An encoded codepoint held by value, so you can build one without owning a
/// scratch buffer at the call site.
pub const Sequence = struct {
    bytes: [max_sequence_len]u8,
    len: u3,

    pub fn slice(self: *const Sequence) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn encodeSequence(codepoint: u21) EncodeError!Sequence {
    var seq: Sequence = .{ .bytes = undefined, .len = 0 };
    seq.len = try encode(codepoint, &seq.bytes);
    return seq;
}

fn decodeChecked(bytes: []const u8) !u21 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => unicode.utf8Decode2(bytes[0..2].*),
        3 => unicode.utf8Decode3(bytes[0..3].*),
        4 => unicode.utf8Decode4(bytes[0..4].*),
        else => unreachable,
    };
}

/// Decode the sequence at the start of `bytes`.
///
/// Rejects overlong encodings, surrogate halves and out-of-range codepoints, so
/// a successful result is always a valid Unicode scalar value.
pub fn decode(bytes: []const u8) DecodeError!Decoded {
    if (bytes.len == 0) return error.Truncated;
    const len = try sequenceLength(bytes[0]);
    if (bytes.len < len) return error.Truncated;
    const codepoint = decodeChecked(bytes[0..len]) catch |err| return switch (err) {
        error.Utf8ExpectedContinuation => error.InvalidContinuation,
        error.Utf8OverlongEncoding => error.OverlongEncoding,
        error.Utf8EncodesSurrogateHalf => error.SurrogateHalf,
        error.Utf8CodepointTooLarge => error.CodepointTooLarge,
    };
    return .{ .codepoint = codepoint, .len = len };
}

/// Decode the sequence at the start of `bytes`, substituting `replacement` for
/// anything malformed. Never fails, and always advances by at least one byte.
pub fn decodeLossy(bytes: []const u8) ?Decoded {
    if (bytes.len == 0) return null;
    return decode(bytes) catch .{ .codepoint = replacement, .len = 1 };
}

/// True if every byte of `bytes` is part of a well-formed UTF-8 sequence.
pub fn validate(bytes: []const u8) bool {
    return unicode.utf8ValidateSlice(bytes);
}

/// Number of codepoints in `bytes`.
pub fn countCodepoints(bytes: []const u8) DecodeError!usize {
    var it: Iterator = .init(bytes);
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

/// True if `index` sits on a codepoint boundary. `bytes.len` counts as one.
pub fn isBoundary(bytes: []const u8, index: usize) bool {
    if (index == 0 or index == bytes.len) return true;
    if (index > bytes.len) return false;
    return !isContinuation(bytes[index]);
}

/// The largest boundary at or before `index`. Clamp a byte offset with this
/// before slicing and you can never split a codepoint in half.
pub fn floorBoundary(bytes: []const u8, index: usize) usize {
    var i = @min(index, bytes.len);
    while (i > 0 and i < bytes.len and isContinuation(bytes[i])) i -= 1;
    return i;
}

/// The smallest boundary at or after `index`.
pub fn ceilBoundary(bytes: []const u8, index: usize) usize {
    var i = @min(index, bytes.len);
    while (i < bytes.len and isContinuation(bytes[i])) i += 1;
    return i;
}

/// Byte offset of codepoint number `codepoint_index`, or null when the string
/// holds fewer codepoints than that.
pub fn byteIndexOfCodepoint(bytes: []const u8, codepoint_index: usize) DecodeError!?usize {
    var it: Iterator = .init(bytes);
    var n: usize = 0;
    while (true) {
        if (n == codepoint_index) return it.index;
        if (try it.next() == null) return null;
        n += 1;
    }
}

/// How many codepoints precede `byte_index`, or null if it is not a boundary.
pub fn codepointIndexOfByte(bytes: []const u8, byte_index: usize) DecodeError!?usize {
    if (!isBoundary(bytes, byte_index)) return null;
    return try countCodepoints(bytes[0..byte_index]);
}

/// Forward iterator over the codepoints of a UTF-8 slice.
///
/// `next` is strict and reports malformed input as an error; `nextLossy`
/// substitutes `replacement` and never fails. Pick one and stay with it.
pub const Iterator = struct {
    bytes: []const u8,
    /// Byte offset of the next codepoint to be decoded.
    index: usize,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes, .index = 0 };
    }

    pub fn next(self: *Iterator) DecodeError!?Decoded {
        if (self.index >= self.bytes.len) return null;
        const d = try decode(self.bytes[self.index..]);
        self.index += d.len;
        return d;
    }

    pub fn nextLossy(self: *Iterator) ?Decoded {
        if (self.index >= self.bytes.len) return null;
        const d = decodeLossy(self.bytes[self.index..]).?;
        self.index += d.len;
        return d;
    }

    /// Look at the next codepoint without consuming it.
    pub fn peek(self: *const Iterator) DecodeError!?Decoded {
        if (self.index >= self.bytes.len) return null;
        return try decode(self.bytes[self.index..]);
    }

    /// The bytes not yet consumed.
    pub fn rest(self: *const Iterator) []const u8 {
        return self.bytes[self.index..];
    }

    pub fn reset(self: *Iterator) void {
        self.index = 0;
    }
};

test "encode and decode round-trip" {
    const samples = [_]u21{ 'a', 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, max_codepoint };
    for (samples) |cp| {
        const seq = try encodeSequence(cp);
        const d = try decode(seq.slice());
        try testing.expectEqual(cp, d.codepoint);
        try testing.expectEqual(seq.len, d.len);
    }
}

test "encode rejects surrogates and out-of-range codepoints" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.SurrogateHalf, encode(0xD800, &buf));
    try testing.expectError(error.SurrogateHalf, encode(0xDFFF, &buf));
    try testing.expectError(error.CodepointTooLarge, encode(0x110000, &buf));

    var small: [1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, encode(0x800, &small));
}

test "decode rejects malformed sequences" {
    try testing.expectError(error.Truncated, decode(""));
    try testing.expectError(error.InvalidStartByte, decode("\x80"));
    try testing.expectError(error.Truncated, decode("\xE2\x82"));
    try testing.expectError(error.InvalidContinuation, decode("\xE2\x28\xA1"));
    try testing.expectError(error.OverlongEncoding, decode("\xC0\xAF"));
    try testing.expectError(error.SurrogateHalf, decode("\xED\xA0\x80"));
}

test "lossy decoding always makes progress" {
    var it: Iterator = .init("a\xFFb");
    try testing.expectEqual(@as(u21, 'a'), it.nextLossy().?.codepoint);
    try testing.expectEqual(replacement, it.nextLossy().?.codepoint);
    try testing.expectEqual(@as(u21, 'b'), it.nextLossy().?.codepoint);
    try testing.expectEqual(@as(?Decoded, null), it.nextLossy());
}

test "iterate a mixed-width string" {
    const s = "a\u{00E9}\u{6F22}\u{1F422}";
    try testing.expectEqual(@as(usize, 10), s.len);
    try testing.expectEqual(@as(usize, 4), try countCodepoints(s));

    var it: Iterator = .init(s);
    try testing.expectEqual(@as(u3, 1), (try it.next()).?.len);
    try testing.expectEqual(@as(u3, 2), (try it.next()).?.len);
    try testing.expectEqual(@as(u3, 3), (try it.next()).?.len);

    const turtle = (try it.next()).?;
    try testing.expectEqual(@as(u3, 4), turtle.len);
    try testing.expectEqual(@as(u21, 0x1F422), turtle.codepoint);
    try testing.expectEqual(@as(?Decoded, null), try it.next());
}

test "peek does not advance" {
    var it: Iterator = .init("hi");
    try testing.expectEqual(@as(u21, 'h'), (try it.peek()).?.codepoint);
    try testing.expectEqual(@as(u21, 'h'), (try it.peek()).?.codepoint);
    try testing.expectEqual(@as(u21, 'h'), (try it.next()).?.codepoint);
    try testing.expectEqualStrings("i", it.rest());
}

test "boundary arithmetic" {
    const s = "a\u{00E9}\u{6F22}"; // 1 + 2 + 3 bytes
    try testing.expect(isBoundary(s, 0));
    try testing.expect(isBoundary(s, 1));
    try testing.expect(!isBoundary(s, 2));
    try testing.expect(isBoundary(s, 3));
    try testing.expect(isBoundary(s, s.len));

    try testing.expectEqual(@as(usize, 1), floorBoundary(s, 2));
    try testing.expectEqual(@as(usize, 3), ceilBoundary(s, 2));
    try testing.expectEqual(@as(usize, 3), floorBoundary(s, 3));
    try testing.expectEqual(@as(usize, s.len), ceilBoundary(s, 99));
    try testing.expectEqual(@as(usize, s.len), floorBoundary(s, 99));
}

test "codepoint and byte index conversion" {
    const s = "a\u{00E9}\u{6F22}";
    try testing.expectEqual(@as(?usize, 0), try byteIndexOfCodepoint(s, 0));
    try testing.expectEqual(@as(?usize, 1), try byteIndexOfCodepoint(s, 1));
    try testing.expectEqual(@as(?usize, 3), try byteIndexOfCodepoint(s, 2));
    try testing.expectEqual(@as(?usize, 6), try byteIndexOfCodepoint(s, 3));
    try testing.expectEqual(@as(?usize, null), try byteIndexOfCodepoint(s, 4));

    try testing.expectEqual(@as(?usize, 2), try codepointIndexOfByte(s, 3));
    try testing.expectEqual(@as(?usize, null), try codepointIndexOfByte(s, 2));
}

test "validate" {
    try testing.expect(validate("hello \u{6F22}\u{5B57}"));
    try testing.expect(!validate("\xFF"));
    try testing.expect(!validate("\xED\xA0\x80"));
}
