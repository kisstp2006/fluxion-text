// SPDX-License-Identifier: CC0-1.0

//! A growable, owning UTF-8 buffer.
//!
//! `Builder` is the mutable counterpart to `View`. It holds an allocator, so
//! calls read as `b.append("x")` rather than `b.append(gpa, "x")`, and it
//! exposes a `std.Io.Writer` so anything in the standard library that writes to
//! a stream can write into it.
//!
//! Call `deinit` when you are done, or hand the memory off with
//! `toOwnedSlice`, which leaves the builder empty and reusable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const View = @import("View.zig");
const utf8 = @import("utf8.zig");

const Builder = @This();

allocator: Allocator,
list: std.ArrayList(u8),
/// Writer interface. Reach it through `writer()` rather than touching it here.
io_writer: std.Io.Writer,

pub fn init(allocator: Allocator) Builder {
    return .{
        .allocator = allocator,
        .list = .empty,
        .io_writer = .{ .buffer = &.{}, .vtable = &writer_vtable },
    };
}

pub fn initCapacity(allocator: Allocator, initial_capacity: usize) Allocator.Error!Builder {
    var self: Builder = .init(allocator);
    try self.list.ensureTotalCapacity(allocator, initial_capacity);
    return self;
}

/// A builder pre-loaded with a copy of `bytes`.
pub fn initFrom(allocator: Allocator, bytes: []const u8) Allocator.Error!Builder {
    var self: Builder = try .initCapacity(allocator, bytes.len);
    self.list.appendSliceAssumeCapacity(bytes);
    return self;
}

pub fn deinit(self: *Builder) void {
    self.list.deinit(self.allocator);
    self.* = undefined;
}

// -------------------------------------------------------------------------
// Inspecting
// -------------------------------------------------------------------------

pub fn len(self: *const Builder) usize {
    return self.list.items.len;
}

pub fn isEmpty(self: *const Builder) bool {
    return self.list.items.len == 0;
}

pub fn capacity(self: *const Builder) usize {
    return self.list.capacity;
}

/// The bytes written so far. Invalidated by any call that can reallocate.
pub fn items(self: *const Builder) []u8 {
    return self.list.items;
}

/// A borrowed `View` of the contents. Same invalidation rules as `items`.
pub fn view(self: *const Builder) View {
    return .init(self.list.items);
}

pub fn at(self: *const Builder, index: usize) ?u8 {
    if (index >= self.list.items.len) return null;
    return self.list.items[index];
}

// -------------------------------------------------------------------------
// Capacity
// -------------------------------------------------------------------------

pub fn ensureTotalCapacity(self: *Builder, total: usize) Allocator.Error!void {
    return self.list.ensureTotalCapacity(self.allocator, total);
}

pub fn ensureUnusedCapacity(self: *Builder, additional: usize) Allocator.Error!void {
    return self.list.ensureUnusedCapacity(self.allocator, additional);
}

// -------------------------------------------------------------------------
// Appending
// -------------------------------------------------------------------------

pub fn append(self: *Builder, bytes: []const u8) Allocator.Error!void {
    return self.list.appendSlice(self.allocator, bytes);
}

pub fn appendByte(self: *Builder, byte: u8) Allocator.Error!void {
    return self.list.append(self.allocator, byte);
}

pub fn appendNTimes(self: *Builder, byte: u8, n: usize) Allocator.Error!void {
    return self.list.appendNTimes(self.allocator, byte, n);
}

pub fn appendView(self: *Builder, v: View) Allocator.Error!void {
    return self.append(v.bytes);
}

/// Append the UTF-8 encoding of `codepoint`.
pub fn appendCodepoint(self: *Builder, codepoint: u21) (Allocator.Error || utf8.EncodeError)!void {
    const seq = try utf8.encodeSequence(codepoint);
    return self.append(seq.slice());
}

/// Append `bytes` followed by a newline.
pub fn appendLine(self: *Builder, bytes: []const u8) Allocator.Error!void {
    try self.ensureUnusedCapacity(bytes.len + 1);
    self.list.appendSliceAssumeCapacity(bytes);
    self.list.appendAssumeCapacity('\n');
}

/// Append formatted output, same syntax as `std.debug.print`.
pub fn print(self: *Builder, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    return self.list.print(self.allocator, fmt, args);
}

/// Append each of `pieces` with `separator` between them.
pub fn join(self: *Builder, separator: []const u8, pieces: []const []const u8) Allocator.Error!void {
    for (pieces, 0..) |piece, i| {
        if (i != 0) try self.append(separator);
        try self.append(piece);
    }
}

// -------------------------------------------------------------------------
// Editing
// -------------------------------------------------------------------------

/// Insert `bytes` at `index`. Asserts `index <= len()`.
pub fn insert(self: *Builder, index: usize, bytes: []const u8) Allocator.Error!void {
    return self.list.insertSlice(self.allocator, index, bytes);
}

pub fn insertByte(self: *Builder, index: usize, byte: u8) Allocator.Error!void {
    return self.list.insert(self.allocator, index, byte);
}

/// Swap the byte range `[start, end)` for `bytes`.
pub fn replaceRange(self: *Builder, start: usize, end: usize, bytes: []const u8) Allocator.Error!void {
    std.debug.assert(start <= end and end <= self.list.items.len);
    return self.list.replaceRange(self.allocator, start, end - start, bytes);
}

/// Delete the byte range `[start, end)`.
pub fn remove(self: *Builder, start: usize, end: usize) void {
    std.debug.assert(start <= end and end <= self.list.items.len);
    self.list.replaceRangeAssumeCapacity(start, end - start, &.{});
}

/// Replace every occurrence of `needle`, returning how many were replaced.
/// An empty `needle` matches nothing.
pub fn replaceAll(self: *Builder, needle: []const u8, replacement: []const u8) Allocator.Error!usize {
    if (needle.len == 0) return 0;
    const n = std.mem.count(u8, self.list.items, needle);
    if (n == 0) return 0;

    const size = std.mem.replacementSize(u8, self.list.items, needle, replacement);
    const out = try self.allocator.alloc(u8, size);
    _ = std.mem.replace(u8, self.list.items, needle, replacement, out);
    self.list.deinit(self.allocator);
    self.list = .fromOwnedSlice(out);
    return n;
}

/// Drop everything past `new_len`. Asserts `new_len <= len()`.
pub fn truncate(self: *Builder, new_len: usize) void {
    self.list.shrinkRetainingCapacity(new_len);
}

pub fn pop(self: *Builder) ?u8 {
    return self.list.pop();
}

/// Strip trailing bytes that appear in `set`.
pub fn trimEnd(self: *Builder, set: []const u8) void {
    const trimmed = std.mem.trimEnd(u8, self.list.items, set);
    self.list.shrinkRetainingCapacity(trimmed.len);
}

/// Reset the length to zero but keep the allocation for reuse.
pub fn clear(self: *Builder) void {
    self.list.clearRetainingCapacity();
}

/// Reset the length to zero and release the allocation.
pub fn clearAndFree(self: *Builder) void {
    self.list.clearAndFree(self.allocator);
}

// -------------------------------------------------------------------------
// Handing the bytes over
// -------------------------------------------------------------------------

/// Transfer ownership of the buffer to the caller, leaving the builder empty.
pub fn toOwnedSlice(self: *Builder) Allocator.Error![]u8 {
    return self.list.toOwnedSlice(self.allocator);
}

/// Like `toOwnedSlice`, but NUL-terminated for C interop.
pub fn toOwnedSliceZ(self: *Builder) Allocator.Error![:0]u8 {
    return self.list.toOwnedSliceSentinel(self.allocator, 0);
}

/// An independent copy, which the caller must `deinit`.
pub fn clone(self: *const Builder) Allocator.Error!Builder {
    return initFrom(self.allocator, self.list.items);
}

/// Print with `{f}`.
pub fn format(self: Builder, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(self.list.items);
}

// -------------------------------------------------------------------------
// Writer interface
// -------------------------------------------------------------------------

/// A `std.Io.Writer` that appends to this builder.
///
/// The returned pointer borrows the builder, so do not move or copy the
/// builder while it is outstanding.
pub fn writer(self: *Builder) *std.Io.Writer {
    return &self.io_writer;
}

const writer_vtable: std.Io.Writer.VTable = .{ .drain = drain };

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *Builder = @alignCast(@fieldParentPtr("io_writer", w));

    // The interface may have staged bytes in its own buffer; those come first
    // and do not count towards the returned total.
    const buffered = w.buffer[0..w.end];
    if (buffered.len != 0) {
        self.append(buffered) catch return error.WriteFailed;
        w.end = 0;
    }
    if (data.len == 0) return 0;

    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        self.append(bytes) catch return error.WriteFailed;
        consumed += bytes.len;
    }
    // The final slice is repeated `splat` times.
    const pattern = data[data.len - 1];
    if (pattern.len != 0) {
        self.ensureUnusedCapacity(pattern.len * splat) catch return error.WriteFailed;
        for (0..splat) |_| self.list.appendSliceAssumeCapacity(pattern);
        consumed += pattern.len * splat;
    }
    return consumed;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "append and read back" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    try testing.expect(b.isEmpty());
    try b.append("hello");
    try b.appendByte(' ');
    try b.appendView(.init("world"));
    try testing.expectEqualStrings("hello world", b.items());
    try testing.expectEqual(@as(usize, 11), b.len());
    try testing.expect(!b.isEmpty());
    try testing.expectEqual(@as(?u8, 'h'), b.at(0));
    try testing.expectEqual(@as(?u8, null), b.at(11));
    try testing.expect(b.view().eqlBytes("hello world"));
}

test "initFrom and clone" {
    var b: Builder = try .initFrom(testing.allocator, "seed");
    defer b.deinit();
    try testing.expectEqualStrings("seed", b.items());

    var c = try b.clone();
    defer c.deinit();
    try c.append("ling");
    try testing.expectEqualStrings("seed", b.items());
    try testing.expectEqualStrings("seedling", c.items());
}

test "appendNTimes and appendLine" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    try b.appendNTimes('-', 5);
    try b.appendByte('\n');
    try b.appendLine("row");
    try testing.expectEqualStrings("-----\nrow\n", b.items());
}

test "appendCodepoint" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    try b.appendCodepoint('a');
    try b.appendCodepoint(0x00E9);
    try b.appendCodepoint(0x1F422);
    try testing.expectEqualStrings("a\u{00E9}\u{1F422}", b.items());
    try testing.expectError(error.SurrogateHalf, b.appendCodepoint(0xD800));
}

test "print" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    try b.print("{s} is {d}", .{ "answer", 42 });
    try testing.expectEqualStrings("answer is 42", b.items());
}

test "join" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    try b.join(", ", &.{ "a", "b", "c" });
    try testing.expectEqualStrings("a, b, c", b.items());

    b.clear();
    try b.join(", ", &.{});
    try testing.expectEqualStrings("", b.items());
}

test "insert and remove" {
    var b: Builder = try .initFrom(testing.allocator, "hello world");
    defer b.deinit();

    try b.insert(5, ",");
    try testing.expectEqualStrings("hello, world", b.items());

    try b.insertByte(0, '>');
    try testing.expectEqualStrings(">hello, world", b.items());

    b.remove(0, 1);
    try testing.expectEqualStrings("hello, world", b.items());

    try b.replaceRange(0, 5, "goodbye");
    try testing.expectEqualStrings("goodbye, world", b.items());
}

test "replaceAll" {
    var b: Builder = try .initFrom(testing.allocator, "a-b-c-d");
    defer b.deinit();

    try testing.expectEqual(@as(usize, 3), try b.replaceAll("-", " to "));
    try testing.expectEqualStrings("a to b to c to d", b.items());

    // Shrinking replacement, and a needle that is not present.
    try testing.expectEqual(@as(usize, 3), try b.replaceAll(" to ", "-"));
    try testing.expectEqualStrings("a-b-c-d", b.items());
    try testing.expectEqual(@as(usize, 0), try b.replaceAll("zzz", "!"));
    try testing.expectEqual(@as(usize, 0), try b.replaceAll("", "!"));
    try testing.expectEqualStrings("a-b-c-d", b.items());
}

test "truncate, pop and trimEnd" {
    var b: Builder = try .initFrom(testing.allocator, "abcdef");
    defer b.deinit();

    try testing.expectEqual(@as(?u8, 'f'), b.pop());
    b.truncate(3);
    try testing.expectEqualStrings("abc", b.items());

    try b.append("   \n");
    b.trimEnd(" \n");
    try testing.expectEqualStrings("abc", b.items());
}

test "clear keeps capacity, clearAndFree does not" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    try b.append("some reasonably long content");
    const cap = b.capacity();
    b.clear();
    try testing.expectEqual(@as(usize, 0), b.len());
    try testing.expectEqual(cap, b.capacity());

    try b.append("x");
    b.clearAndFree();
    try testing.expectEqual(@as(usize, 0), b.capacity());
}

test "toOwnedSlice leaves the builder reusable" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    try b.append("first");
    const owned = try b.toOwnedSlice();
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("first", owned);
    try testing.expectEqual(@as(usize, 0), b.len());

    try b.append("second");
    const ownedZ = try b.toOwnedSliceZ();
    defer testing.allocator.free(ownedZ);
    try testing.expectEqualStrings("second", ownedZ);
    try testing.expectEqual(@as(u8, 0), ownedZ[ownedZ.len]);
}

test "writer interface" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    const w = b.writer();
    try w.writeAll("via writer");
    try w.print(" plus {d}", .{7});
    try w.writeByte('!');
    // splatByteAll exercises the repeated-pattern path in drain.
    try w.splatByteAll('.', 3);
    try testing.expectEqualStrings("via writer plus 7!...", b.items());
}

test "format" {
    var b: Builder = try .initFrom(testing.allocator, "shown");
    defer b.deinit();
    try testing.expectFmt("[shown]", "[{f}]", .{b});
}
