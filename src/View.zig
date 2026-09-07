// SPDX-License-Identifier: CC0-1.0

//! An immutable, non-owning window onto UTF-8 text.
//!
//! `View` is a `[]const u8` with a vocabulary attached. It never allocates and
//! never copies: every slicing, trimming and splitting operation hands back
//! another `View` into the *same* backing bytes. That makes it cheap to pass
//! around, and it makes lifetime your responsibility - a `View` is only valid
//! for as long as the memory it points at.
//!
//! Byte offsets, not codepoint offsets, are used throughout. Use `codepoints`
//! or `truncateBytes` when you need to respect UTF-8 boundaries.

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const testing = std.testing;

const utf8 = @import("utf8.zig");

const View = @This();

bytes: []const u8,

/// The default ASCII whitespace set used by `trim` and friends.
pub const whitespace = " \t\r\n\x0B\x0C";

/// A view over nothing.
pub const empty: View = .{ .bytes = "" };

/// The two halves produced by `splitOnce` / `splitLastOnce`.
pub const Pair = struct {
    before: View,
    after: View,
};

pub fn init(bytes: []const u8) View {
    return .{ .bytes = bytes };
}

// -------------------------------------------------------------------------
// Basics
// -------------------------------------------------------------------------

/// Length in bytes. For a count of characters, use `codepointLen`.
pub fn len(self: View) usize {
    return self.bytes.len;
}

pub fn isEmpty(self: View) bool {
    return self.bytes.len == 0;
}

pub fn at(self: View, index: usize) ?u8 {
    if (index >= self.bytes.len) return null;
    return self.bytes[index];
}

pub fn first(self: View) ?u8 {
    return if (self.bytes.len == 0) null else self.bytes[0];
}

pub fn last(self: View) ?u8 {
    return if (self.bytes.len == 0) null else self.bytes[self.bytes.len - 1];
}

/// Byte range `[start, end)`. Asserts the range is within bounds.
pub fn slice(self: View, start: usize, end: usize) View {
    std.debug.assert(start <= end and end <= self.bytes.len);
    return .{ .bytes = self.bytes[start..end] };
}

pub fn sliceFrom(self: View, start: usize) View {
    return self.slice(start, self.bytes.len);
}

pub fn sliceTo(self: View, end: usize) View {
    return self.slice(0, end);
}

// -------------------------------------------------------------------------
// Comparison
// -------------------------------------------------------------------------

pub fn eql(self: View, other: View) bool {
    return mem.eql(u8, self.bytes, other.bytes);
}

/// Byte-for-byte equality against a raw slice, so callers can skip `init`.
pub fn eqlBytes(self: View, other: []const u8) bool {
    return mem.eql(u8, self.bytes, other);
}

/// ASCII-only case folding. Does not handle non-ASCII case pairs.
pub fn eqlIgnoreCase(self: View, other: View) bool {
    return ascii.eqlIgnoreCase(self.bytes, other.bytes);
}

pub fn order(self: View, other: View) std.math.Order {
    return mem.order(u8, self.bytes, other.bytes);
}

pub fn lessThan(self: View, other: View) bool {
    return mem.lessThan(u8, self.bytes, other.bytes);
}

/// A stable 64-bit hash of the contents.
pub fn hash(self: View) u64 {
    return std.hash.Wyhash.hash(0, self.bytes);
}

// -------------------------------------------------------------------------
// Searching
// -------------------------------------------------------------------------

pub fn startsWith(self: View, prefix: []const u8) bool {
    return mem.startsWith(u8, self.bytes, prefix);
}

pub fn endsWith(self: View, suffix: []const u8) bool {
    return mem.endsWith(u8, self.bytes, suffix);
}

pub fn startsWithIgnoreCase(self: View, prefix: []const u8) bool {
    return ascii.startsWithIgnoreCase(self.bytes, prefix);
}

pub fn endsWithIgnoreCase(self: View, suffix: []const u8) bool {
    return ascii.endsWithIgnoreCase(self.bytes, suffix);
}

pub fn contains(self: View, needle: []const u8) bool {
    return mem.indexOf(u8, self.bytes, needle) != null;
}

pub fn containsScalar(self: View, byte: u8) bool {
    return mem.indexOfScalar(u8, self.bytes, byte) != null;
}

pub fn indexOf(self: View, needle: []const u8) ?usize {
    return mem.indexOf(u8, self.bytes, needle);
}

pub fn indexOfPos(self: View, start: usize, needle: []const u8) ?usize {
    return mem.indexOfPos(u8, self.bytes, start, needle);
}

pub fn lastIndexOf(self: View, needle: []const u8) ?usize {
    return mem.lastIndexOf(u8, self.bytes, needle);
}

pub fn indexOfScalar(self: View, byte: u8) ?usize {
    return mem.indexOfScalar(u8, self.bytes, byte);
}

pub fn lastIndexOfScalar(self: View, byte: u8) ?usize {
    return mem.lastIndexOfScalar(u8, self.bytes, byte);
}

/// Offset of the first byte that appears in `set`.
pub fn indexOfAny(self: View, set: []const u8) ?usize {
    return mem.indexOfAny(u8, self.bytes, set);
}

/// Offset of the first byte that does *not* appear in `set`.
pub fn indexOfNone(self: View, set: []const u8) ?usize {
    return mem.indexOfNone(u8, self.bytes, set);
}

/// Number of non-overlapping occurrences of `needle`.
pub fn count(self: View, needle: []const u8) usize {
    return mem.count(u8, self.bytes, needle);
}

// -------------------------------------------------------------------------
// Trimming
// -------------------------------------------------------------------------

pub fn trim(self: View) View {
    return .{ .bytes = mem.trim(u8, self.bytes, whitespace) };
}

pub fn trimStart(self: View) View {
    return .{ .bytes = mem.trimStart(u8, self.bytes, whitespace) };
}

pub fn trimEnd(self: View) View {
    return .{ .bytes = mem.trimEnd(u8, self.bytes, whitespace) };
}

pub fn trimChars(self: View, set: []const u8) View {
    return .{ .bytes = mem.trim(u8, self.bytes, set) };
}

pub fn trimStartChars(self: View, set: []const u8) View {
    return .{ .bytes = mem.trimStart(u8, self.bytes, set) };
}

pub fn trimEndChars(self: View, set: []const u8) View {
    return .{ .bytes = mem.trimEnd(u8, self.bytes, set) };
}

/// Drop one trailing line terminator, if present. Handles both "\n" and "\r\n".
pub fn chomp(self: View) View {
    var b = self.bytes;
    if (mem.endsWith(u8, b, "\n")) b = b[0 .. b.len - 1];
    if (mem.endsWith(u8, b, "\r")) b = b[0 .. b.len - 1];
    return .{ .bytes = b };
}

/// The remainder after `prefix`, or null if it is not there.
pub fn stripPrefix(self: View, prefix: []const u8) ?View {
    if (!self.startsWith(prefix)) return null;
    return .{ .bytes = self.bytes[prefix.len..] };
}

/// The remainder before `suffix`, or null if it is not there.
pub fn stripSuffix(self: View, suffix: []const u8) ?View {
    if (!self.endsWith(suffix)) return null;
    return .{ .bytes = self.bytes[0 .. self.bytes.len - suffix.len] };
}

// -------------------------------------------------------------------------
// Splitting
// -------------------------------------------------------------------------

/// Wraps a `std.mem` iterator so the yielded pieces are `View`s.
pub fn SplitIterator(comptime delimiter_type: mem.DelimiterType) type {
    return struct {
        inner: mem.SplitIterator(u8, delimiter_type),

        const Self = @This();

        pub fn next(self: *Self) ?View {
            return if (self.inner.next()) |piece| .{ .bytes = piece } else null;
        }

        pub fn peek(self: *Self) ?View {
            return if (self.inner.peek()) |piece| .{ .bytes = piece } else null;
        }

        pub fn rest(self: Self) View {
            return .{ .bytes = self.inner.rest() };
        }

        pub fn reset(self: *Self) void {
            self.inner.reset();
        }
    };
}

pub fn TokenIterator(comptime delimiter_type: mem.DelimiterType) type {
    return struct {
        inner: mem.TokenIterator(u8, delimiter_type),

        const Self = @This();

        pub fn next(self: *Self) ?View {
            return if (self.inner.next()) |piece| .{ .bytes = piece } else null;
        }

        pub fn peek(self: *Self) ?View {
            return if (self.inner.peek()) |piece| .{ .bytes = piece } else null;
        }

        pub fn rest(self: Self) View {
            return .{ .bytes = self.inner.rest() };
        }

        pub fn reset(self: *Self) void {
            self.inner.reset();
        }
    };
}

/// Split on every occurrence of the full sequence `delimiter`.
/// Empty pieces are preserved: `"a,,b".split(",")` yields "a", "", "b".
pub fn split(self: View, delimiter: []const u8) SplitIterator(.sequence) {
    return .{ .inner = mem.splitSequence(u8, self.bytes, delimiter) };
}

pub fn splitScalar(self: View, delimiter: u8) SplitIterator(.scalar) {
    return .{ .inner = mem.splitScalar(u8, self.bytes, delimiter) };
}

/// Split on any single byte drawn from `delimiters`.
pub fn splitAny(self: View, delimiters: []const u8) SplitIterator(.any) {
    return .{ .inner = mem.splitAny(u8, self.bytes, delimiters) };
}

/// Like `splitAny`, but empty pieces are skipped.
pub fn tokenizeAny(self: View, delimiters: []const u8) TokenIterator(.any) {
    return .{ .inner = mem.tokenizeAny(u8, self.bytes, delimiters) };
}

pub fn tokenizeScalar(self: View, delimiter: u8) TokenIterator(.scalar) {
    return .{ .inner = mem.tokenizeScalar(u8, self.bytes, delimiter) };
}

/// Split into whitespace-separated words, skipping runs of whitespace.
pub fn words(self: View) TokenIterator(.any) {
    return self.tokenizeAny(whitespace);
}

/// Split at the first `delimiter`. Null when the delimiter is absent, which
/// lets you distinguish "no separator" from "empty right-hand side".
pub fn splitOnce(self: View, delimiter: []const u8) ?Pair {
    const i = self.indexOf(delimiter) orelse return null;
    return .{
        .before = .{ .bytes = self.bytes[0..i] },
        .after = .{ .bytes = self.bytes[i + delimiter.len ..] },
    };
}

/// Split at the last `delimiter`.
pub fn splitLastOnce(self: View, delimiter: []const u8) ?Pair {
    const i = self.lastIndexOf(delimiter) orelse return null;
    return .{
        .before = .{ .bytes = self.bytes[0..i] },
        .after = .{ .bytes = self.bytes[i + delimiter.len ..] },
    };
}

/// Iterate lines, accepting "\n" and "\r\n" and not yielding a phantom empty
/// line for input that ends with a terminator.
pub const LineIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *LineIterator) ?View {
        if (self.index >= self.bytes.len) return null;
        const start = self.index;
        const nl = mem.indexOfScalarPos(u8, self.bytes, start, '\n');
        const end = nl orelse self.bytes.len;
        self.index = if (nl) |i| i + 1 else self.bytes.len;
        var line = self.bytes[start..end];
        if (mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
        return .{ .bytes = line };
    }

    pub fn reset(self: *LineIterator) void {
        self.index = 0;
    }
};

pub fn lines(self: View) LineIterator {
    return .{ .bytes = self.bytes };
}

// -------------------------------------------------------------------------
// UTF-8
// -------------------------------------------------------------------------

pub fn codepoints(self: View) utf8.Iterator {
    return .init(self.bytes);
}

pub fn codepointLen(self: View) utf8.DecodeError!usize {
    return utf8.countCodepoints(self.bytes);
}

pub fn isValidUtf8(self: View) bool {
    return utf8.validate(self.bytes);
}

/// Shorten to at most `max_bytes`, backing off to the nearest codepoint
/// boundary so the result is never a half-encoded character.
pub fn truncateBytes(self: View, max_bytes: usize) View {
    if (self.bytes.len <= max_bytes) return self;
    return .{ .bytes = self.bytes[0..utf8.floorBoundary(self.bytes, max_bytes)] };
}

/// Codepoint range `[start, end)`. Null when the range runs past the end.
pub fn sliceCodepoints(self: View, start: usize, end: usize) utf8.DecodeError!?View {
    std.debug.assert(start <= end);
    const from = try utf8.byteIndexOfCodepoint(self.bytes, start) orelse return null;
    const to = try utf8.byteIndexOfCodepoint(self.bytes, end) orelse return null;
    return .{ .bytes = self.bytes[from..to] };
}

// -------------------------------------------------------------------------
// Escaping the view
// -------------------------------------------------------------------------

/// Copy the contents into freshly allocated memory owned by the caller.
pub fn toOwned(self: View, allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, self.bytes);
}

/// Like `toOwned`, but NUL-terminated for C interop.
pub fn toOwnedZ(self: View, allocator: std.mem.Allocator) ![:0]u8 {
    return allocator.dupeZ(u8, self.bytes);
}

/// Print with `{f}`.
pub fn format(self: View, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(self.bytes);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "basics" {
    const v: View = .init("hello");
    try testing.expectEqual(@as(usize, 5), v.len());
    try testing.expect(!v.isEmpty());
    try testing.expect(View.empty.isEmpty());
    try testing.expectEqual(@as(?u8, 'h'), v.first());
    try testing.expectEqual(@as(?u8, 'o'), v.last());
    try testing.expectEqual(@as(?u8, 'e'), v.at(1));
    try testing.expectEqual(@as(?u8, null), v.at(5));
    try testing.expectEqualStrings("ell", v.slice(1, 4).bytes);
    try testing.expectEqualStrings("llo", v.sliceFrom(2).bytes);
    try testing.expectEqualStrings("he", v.sliceTo(2).bytes);
}

test "comparison" {
    const a: View = .init("Apple");
    try testing.expect(a.eqlBytes("Apple"));
    try testing.expect(!a.eqlBytes("apple"));
    try testing.expect(a.eqlIgnoreCase(.init("aPPLe")));
    try testing.expectEqual(std.math.Order.lt, a.order(.init("Banana")));
    try testing.expect(a.lessThan(.init("Banana")));
    try testing.expectEqual(a.hash(), View.init("Apple").hash());
}

test "searching" {
    const v: View = .init("the quick brown fox");
    try testing.expect(v.startsWith("the"));
    try testing.expect(v.endsWith("fox"));
    try testing.expect(v.startsWithIgnoreCase("THE"));
    try testing.expect(v.endsWithIgnoreCase("FOX"));
    try testing.expect(v.contains("quick"));
    try testing.expect(!v.contains("slow"));
    try testing.expect(v.containsScalar('q'));

    try testing.expectEqual(@as(?usize, 4), v.indexOf("quick"));
    try testing.expectEqual(@as(?usize, null), v.indexOf("slow"));
    try testing.expectEqual(@as(?usize, 17), v.lastIndexOf("o"));
    try testing.expectEqual(@as(?usize, 12), v.indexOfPos(5, "o"));
    try testing.expectEqual(@as(?usize, 3), v.indexOfScalar(' '));
    try testing.expectEqual(@as(?usize, 15), v.lastIndexOfScalar(' '));
    try testing.expectEqual(@as(?usize, 2), v.indexOfAny("xe"));
    try testing.expectEqual(@as(?usize, 3), v.indexOfNone("the"));
    try testing.expectEqual(@as(usize, 3), v.count(" "));
}

test "trimming" {
    try testing.expectEqualStrings("hi", View.init("  hi \n").trim().bytes);
    try testing.expectEqualStrings("hi \n", View.init("  hi \n").trimStart().bytes);
    try testing.expectEqualStrings("  hi", View.init("  hi \n").trimEnd().bytes);
    try testing.expectEqualStrings("hi", View.init("xxhixx").trimChars("x").bytes);
    try testing.expectEqualStrings("hixx", View.init("xxhixx").trimStartChars("x").bytes);
    try testing.expectEqualStrings("xxhi", View.init("xxhixx").trimEndChars("x").bytes);

    try testing.expectEqualStrings("a", View.init("a\r\n").chomp().bytes);
    try testing.expectEqualStrings("a", View.init("a\n").chomp().bytes);
    try testing.expectEqualStrings("a", View.init("a").chomp().bytes);
}

test "strip prefix and suffix" {
    const v: View = .init("prefix-body-suffix");
    try testing.expectEqualStrings("body-suffix", v.stripPrefix("prefix-").?.bytes);
    try testing.expectEqualStrings("prefix-body", v.stripSuffix("-suffix").?.bytes);
    try testing.expectEqual(@as(?View, null), v.stripPrefix("nope"));
    try testing.expectEqual(@as(?View, null), v.stripSuffix("nope"));
}

test "split preserves empty pieces" {
    var it = View.init("a,,b").splitScalar(',');
    try testing.expectEqualStrings("a", it.next().?.bytes);
    try testing.expectEqualStrings("", it.next().?.bytes);
    try testing.expectEqualStrings("b", it.next().?.bytes);
    try testing.expectEqual(@as(?View, null), it.next());
}

test "split on a sequence" {
    var it = View.init("a::b::c").split("::");
    try testing.expectEqualStrings("a", it.next().?.bytes);
    try testing.expectEqualStrings("b", it.peek().?.bytes);
    try testing.expectEqualStrings("b", it.next().?.bytes);
    try testing.expectEqualStrings("c", it.rest().bytes);
}

test "tokenize skips empty pieces" {
    var it = View.init("  a  b  ").words();
    try testing.expectEqualStrings("a", it.next().?.bytes);
    try testing.expectEqualStrings("b", it.next().?.bytes);
    try testing.expectEqual(@as(?View, null), it.next());
}

test "splitOnce distinguishes missing from empty" {
    const p = View.init("key=value=extra").splitOnce("=").?;
    try testing.expectEqualStrings("key", p.before.bytes);
    try testing.expectEqualStrings("value=extra", p.after.bytes);

    const q = View.init("key=value=extra").splitLastOnce("=").?;
    try testing.expectEqualStrings("key=value", q.before.bytes);
    try testing.expectEqualStrings("extra", q.after.bytes);

    const r = View.init("key=").splitOnce("=").?;
    try testing.expectEqualStrings("", r.after.bytes);
    try testing.expectEqual(@as(?Pair, null), View.init("key").splitOnce("="));
}

test "lines handles CRLF and no trailing newline" {
    var it = View.init("one\r\ntwo\nthree").lines();
    try testing.expectEqualStrings("one", it.next().?.bytes);
    try testing.expectEqualStrings("two", it.next().?.bytes);
    try testing.expectEqualStrings("three", it.next().?.bytes);
    try testing.expectEqual(@as(?View, null), it.next());

    var trailing = View.init("one\n").lines();
    try testing.expectEqualStrings("one", trailing.next().?.bytes);
    try testing.expectEqual(@as(?View, null), trailing.next());

    var blank = View.init("a\n\nb").lines();
    try testing.expectEqualStrings("a", blank.next().?.bytes);
    try testing.expectEqualStrings("", blank.next().?.bytes);
    try testing.expectEqualStrings("b", blank.next().?.bytes);
}

test "utf8 aware operations" {
    const v: View = .init("a\u{00E9}\u{6F22}");
    try testing.expectEqual(@as(usize, 6), v.len());
    try testing.expectEqual(@as(usize, 3), try v.codepointLen());
    try testing.expect(v.isValidUtf8());

    // A naive v.sliceTo(2) would cut the 2-byte 'e-acute' in half.
    try testing.expectEqualStrings("a", v.truncateBytes(2).bytes);
    try testing.expectEqualStrings("a\u{00E9}", v.truncateBytes(3).bytes);
    try testing.expectEqualStrings("a\u{00E9}\u{6F22}", v.truncateBytes(99).bytes);

    try testing.expectEqualStrings("\u{00E9}", (try v.sliceCodepoints(1, 2)).?.bytes);
    try testing.expectEqual(@as(?View, null), try v.sliceCodepoints(1, 9));

    var it = v.codepoints();
    try testing.expectEqual(@as(u21, 'a'), (try it.next()).?.codepoint);
}

test "toOwned and format" {
    const v: View = .init("copy me");
    const owned = try v.toOwned(testing.allocator);
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("copy me", owned);

    const ownedZ = try v.toOwnedZ(testing.allocator);
    defer testing.allocator.free(ownedZ);
    try testing.expectEqual(@as(u8, 0), ownedZ[ownedZ.len]);

    try testing.expectFmt("[copy me]", "[{f}]", .{v});
}
