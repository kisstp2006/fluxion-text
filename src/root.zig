// SPDX-License-Identifier: CC0-1.0

//! Fluxion Text - a UTF-8 string toolkit for Zig.
//!
//! Eleven pieces that fit together:
//!
//!   `View`     an immutable, non-owning window onto bytes
//!   `Builder`  a growable, owning buffer that is also a `std.Io.Writer`
//!   `Parser`   a cursor for hand-written parsers and lexers
//!   `utf8`     encode, decode, validate and boundary math
//!   `number`   integer, float and bool scanning that reports what it consumed
//!   `Interner` string interning, text in and a 4-byte `StringId` out
//!   `Fixed`    a string held inline, with no allocator at all
//!   `path`     virtual asset paths: basename, stem, extension, join, normalize
//!   `pattern`  glob matching, both the plain and the path-aware kind
//!   `fuzzy`    command-palette ranking and "did you mean?" suggestions
//!   `wrap`     word wrapping measured by your own font metrics
//!
//! Nothing here allocates unless it takes an `Allocator`, and everything that
//! allocates says who owns the result.

const std = @import("std");
const testing = std.testing;

pub const View = @import("View.zig");
pub const Builder = @import("Builder.zig");
pub const Parser = @import("Parser.zig");
pub const Interner = @import("Interner.zig");
pub const utf8 = @import("utf8.zig");
pub const number = @import("number.zig");
pub const path = @import("path.zig");
pub const pattern = @import("pattern.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const wrap = @import("wrap.zig");

/// A fixed-capacity string held inline, with no allocator. See `fixed`.
pub const Fixed = @import("fixed.zig").Fixed;

/// A handle to an interned string. See `Interner`.
pub const StringId = Interner.Id;

/// Shorthand for `View.init`, so call sites can read `text.view(s)`.
pub fn view(bytes: []const u8) View {
    return .init(bytes);
}

/// Shorthand for `Parser.init`.
pub fn parse(bytes: []const u8) Parser {
    return .init(bytes);
}

/// Shorthand for `Builder.init`.
pub fn build(allocator: std.mem.Allocator) Builder {
    return .init(allocator);
}

/// Concatenate `pieces` with `separator` between them. Caller owns the result.
pub fn join(
    allocator: std.mem.Allocator,
    separator: []const u8,
    pieces: []const []const u8,
) std.mem.Allocator.Error![]u8 {
    var b: Builder = .init(allocator);
    defer b.deinit();
    try b.join(separator, pieces);
    return b.toOwnedSlice();
}

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = View;
    _ = Builder;
    _ = Parser;
    _ = Interner;
    _ = utf8;
    _ = number;
    _ = path;
    _ = pattern;
    _ = fuzzy;
    _ = wrap;
    _ = @import("fixed.zig");
}

test "the pieces compose" {
    // Parse a line of config, intern the key, and render a normalised form.
    var interner: Interner = .init(testing.allocator);
    defer interner.deinit();

    var p = parse("  retries = 0x1F  # inline comment\n");
    _ = p.skipWhitespace();

    const key = try interner.internView(p.takeIdentifier().?);
    _ = p.skipInlineWhitespace();
    try p.expect('=');
    _ = p.skipInlineWhitespace();
    const value = try p.takeInt(u32, .{});

    try testing.expectEqualStrings("retries", interner.resolve(key));
    try testing.expectEqual(@as(u32, 31), value);

    var b = build(testing.allocator);
    defer b.deinit();
    try b.print("{s}={d}", .{ interner.resolve(key), value });
    try testing.expectEqualStrings("retries=31", b.items());

    // The rest of the line is still there, as a view into the original input.
    try testing.expectEqualStrings("# inline comment", p.rest().trim().bytes);
}

test "join" {
    const joined = try join(testing.allocator, " / ", &.{ "usr", "local", "bin" });
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("usr / local / bin", joined);
}

test "shorthands" {
    try testing.expect(view("abc").eqlBytes("abc"));
    var p = parse("abc");
    try testing.expectEqual(@as(?u8, 'a'), p.peek());
}
