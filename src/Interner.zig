// SPDX-License-Identifier: CC0-1.0

//! String interning: turn text into a small integer `Id` and back again.
//!
//! Interning pays off wherever the same strings recur - identifiers in a
//! compiler, keys in a config, tags on entities. Once interned, comparison is
//! an integer compare, the handle is 4 bytes instead of 16, and equal strings
//! are stored once.
//!
//! Ids are handed out in insertion order and stay valid for the life of the
//! interner. The text lives in an internal arena, so `resolve` hands back a
//! slice that is stable until `deinit` - unlike `Builder` output, you do not
//! free it yourself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const View = @import("View.zig");

const Interner = @This();

/// The allocator backing the lookup table and the id array.
allocator: Allocator,
/// Owns the string bytes. An arena because interned text is never freed
/// individually, which also keeps `resolve` results pointer-stable.
arena: std.heap.ArenaAllocator,
map: std.StringHashMapUnmanaged(Id),
entries: std.ArrayList([]const u8),

/// A handle to an interned string.
///
/// Non-exhaustive, so there is no reserved "none" value: use `?Id` when a
/// string may be absent. Ids from different interners are not interchangeable.
pub const Id = enum(u32) {
    _,

    pub fn toInt(self: Id) u32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(value: u32) Id {
        return @enumFromInt(value);
    }

    /// Print with `{f}`. Shows the numeric handle; use `Interner.resolve` when
    /// you want the text.
    pub fn format(self: Id, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("#{d}", .{@intFromEnum(self)});
    }
};

pub fn init(allocator: Allocator) Interner {
    return .{
        .allocator = allocator,
        .arena = .init(allocator),
        .map = .empty,
        .entries = .empty,
    };
}

pub fn deinit(self: *Interner) void {
    self.map.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.arena.deinit();
    self.* = undefined;
}

/// Number of distinct strings held.
pub fn count(self: *const Interner) usize {
    return self.entries.items.len;
}

/// Intern `str`, returning its id. Interning the same text twice returns the
/// same id and stores no second copy. The interner copies the bytes, so `str`
/// does not need to outlive the call.
pub fn intern(self: *Interner, str: []const u8) Allocator.Error!Id {
    const gop = try self.map.getOrPut(self.allocator, str);
    if (gop.found_existing) return gop.value_ptr.*;
    // From here the slot holds the caller's slice as its key; unwind it if we
    // cannot finish taking ownership.
    errdefer _ = self.map.remove(str);

    const next = std.math.cast(u32, self.entries.items.len) orelse return error.OutOfMemory;
    const owned = try self.arena.allocator().dupe(u8, str);
    gop.key_ptr.* = owned;

    try self.entries.append(self.allocator, owned);
    gop.value_ptr.* = @enumFromInt(next);
    return @enumFromInt(next);
}

pub fn internView(self: *Interner, v: View) Allocator.Error!Id {
    return self.intern(v.bytes);
}

/// Intern the result of a format string, without you having to build the
/// text in a separate buffer first.
pub fn internPrint(
    self: *Interner,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!Id {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(self.allocator);
    try tmp.print(self.allocator, fmt, args);
    return self.intern(tmp.items);
}

/// The id `str` already has, or null. Unlike `intern` this never allocates and
/// never adds anything.
pub fn find(self: *const Interner, str: []const u8) ?Id {
    return self.map.get(str);
}

pub fn contains(self: *const Interner, str: []const u8) bool {
    return self.map.contains(str);
}

/// The text behind `id`. Asserts the id came from this interner.
pub fn resolve(self: *const Interner, id: Id) []const u8 {
    const i = @intFromEnum(id);
    std.debug.assert(i < self.entries.items.len);
    return self.entries.items[i];
}

/// Like `resolve`, but null for an id this interner never issued.
pub fn tryResolve(self: *const Interner, id: Id) ?[]const u8 {
    const i = @intFromEnum(id);
    if (i >= self.entries.items.len) return null;
    return self.entries.items[i];
}

pub fn resolveView(self: *const Interner, id: Id) View {
    return .init(self.resolve(id));
}

/// Walk every interned string in the order the ids were issued.
pub const Iterator = struct {
    entries: []const []const u8,
    index: u32 = 0,

    pub const Item = struct {
        id: Id,
        text: []const u8,
    };

    pub fn next(self: *Iterator) ?Item {
        if (self.index >= self.entries.len) return null;
        defer self.index += 1;
        return .{ .id = @enumFromInt(self.index), .text = self.entries[self.index] };
    }
};

pub fn iterator(self: *const Interner) Iterator {
    return .{ .entries = self.entries.items };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the same text gets the same id" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    const a = try it.intern("hello");
    const b = try it.intern("hello");
    const c = try it.intern("world");

    try testing.expectEqual(a, b);
    try testing.expect(a != c);
    try testing.expectEqual(@as(usize, 2), it.count());
}

test "ids are issued in order from zero" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    try testing.expectEqual(@as(u32, 0), (try it.intern("a")).toInt());
    try testing.expectEqual(@as(u32, 1), (try it.intern("b")).toInt());
    try testing.expectEqual(@as(u32, 2), (try it.intern("c")).toInt());
    try testing.expectEqual(@as(u32, 0), (try it.intern("a")).toInt());
}

test "resolve returns the text" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    const id = try it.intern("round trip");
    try testing.expectEqualStrings("round trip", it.resolve(id));
    try testing.expect(it.resolveView(id).eqlBytes("round trip"));
    try testing.expectEqual(@as(?[]const u8, null), it.tryResolve(.fromInt(99)));
}

test "the interner owns its copy of the text" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    var scratch: [5]u8 = "abcde".*;
    const id = try it.intern(&scratch);
    @memset(&scratch, 'z'); // the caller's buffer is free to change

    try testing.expectEqualStrings("abcde", it.resolve(id));
}

test "resolved slices survive later interning" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    const first = it.resolve(try it.intern("stable"));
    for (0..500) |i| _ = try it.internPrint("filler{d}", .{i});
    try testing.expectEqualStrings("stable", first); // not invalidated by growth
}

test "find and contains do not intern" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    _ = try it.intern("present");
    try testing.expect(it.contains("present"));
    try testing.expect(!it.contains("absent"));
    try testing.expectEqual(@as(?Id, null), it.find("absent"));
    try testing.expectEqual(@as(usize, 1), it.count());
}

test "internView and internPrint" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    const a = try it.internView(.init("shared"));
    const b = try it.internPrint("sha{s}", .{"red"});
    try testing.expectEqual(a, b);
}

test "empty string is a normal entry" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    const id = try it.intern("");
    try testing.expectEqualStrings("", it.resolve(id));
    try testing.expectEqual(id, try it.intern(""));
}

test "iterator" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    _ = try it.intern("one");
    _ = try it.intern("two");

    var iter = it.iterator();
    const first = iter.next().?;
    try testing.expectEqual(@as(u32, 0), first.id.toInt());
    try testing.expectEqualStrings("one", first.text);

    const second = iter.next().?;
    try testing.expectEqual(@as(u32, 1), second.id.toInt());
    try testing.expectEqualStrings("two", second.text);
    try testing.expectEqual(@as(?Iterator.Item, null), iter.next());
}

test "id formatting" {
    var it: Interner = .init(testing.allocator);
    defer it.deinit();

    _ = try it.intern("zero");
    const id = try it.intern("one");
    try testing.expectFmt("#1", "{f}", .{id});
}

test "interning survives allocation failure" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 3 });
    var it: Interner = .init(failing.allocator());
    defer it.deinit();

    var interned: usize = 0;
    for (0..64) |i| {
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "sym{d}", .{i}) catch unreachable;
        _ = it.intern(text) catch break;
        interned += 1;
    }
    // Whatever made it in must still be intact and consistent.
    try testing.expectEqual(interned, it.count());
    var iter = it.iterator();
    while (iter.next()) |item| {
        try testing.expectEqual(@as(?Id, item.id), it.find(item.text));
    }
}
