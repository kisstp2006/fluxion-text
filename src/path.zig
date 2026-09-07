// SPDX-License-Identifier: CC0-1.0

//! Virtual asset paths.
//!
//! This is deliberately *not* `std.fs.path`. A game's asset paths are a
//! platform-independent namespace: `textures/ui/cursor.png` means the same
//! thing whether it comes out of a directory on Windows, a pak file, or a
//! console filesystem. So separators are always `/` on output, drive letters
//! are none of our business, and nothing here touches the filesystem.
//!
//! Backslashes are accepted on input, because that is what a Windows drag and
//! drop or a `std.fs` call will hand you.

const std = @import("std");
const testing = std.testing;

const View = @import("View.zig");

/// The separator used in output. Input accepts `\` as well.
pub const separator: u8 = '/';

pub fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

fn lastSeparator(p: []const u8) ?usize {
    var i = p.len;
    while (i > 0) {
        i -= 1;
        if (isSeparator(p[i])) return i;
    }
    return null;
}

/// True if the path starts at the root of its namespace.
pub fn isAbsolute(p: []const u8) bool {
    return p.len > 0 and isSeparator(p[0]);
}

/// The final component: `"a/b/c.png"` -> `"c.png"`.
pub fn basename(p: []const u8) View {
    // A trailing separator is ignored, so "a/b/" has basename "b".
    var end = p.len;
    while (end > 0 and isSeparator(p[end - 1])) end -= 1;
    const cut = lastSeparator(p[0..end]);
    const start = if (cut) |i| i + 1 else 0;
    return .init(p[start..end]);
}

/// Everything before the final component: `"a/b/c.png"` -> `"a/b"`.
/// Null when there is no separator at all.
pub fn dirname(p: []const u8) ?View {
    var end = p.len;
    while (end > 0 and isSeparator(p[end - 1])) end -= 1;
    const cut = lastSeparator(p[0..end]) orelse return null;
    if (cut == 0) return .init(p[0..1]); // keep the root "/"
    return .init(p[0..cut]);
}

/// The extension including its dot: `"c.png"` -> `".png"`. Empty when there is
/// none. A leading dot does not count, so `".gitignore"` has no extension.
pub fn extension(p: []const u8) View {
    const base = basename(p).bytes;
    if (base.len == 0) return .init(base[0..0]);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return .init(base[base.len..]);
    if (dot == 0) return .init(base[base.len..]);
    return .init(base[dot..]);
}

/// The final component without its extension: `"a/b/c.png"` -> `"c"`.
pub fn stem(p: []const u8) View {
    const base = basename(p).bytes;
    const ext = extension(p).bytes;
    return .init(base[0 .. base.len - ext.len]);
}

/// The whole path minus the extension: `"a/b/c.png"` -> `"a/b/c"`.
pub fn withoutExtension(p: []const u8) View {
    return .init(p[0 .. p.len - extension(p).len()]);
}

/// Case-insensitive extension test. `ext` may be given with or without its dot.
pub fn hasExtension(p: []const u8, ext: []const u8) bool {
    const actual = extension(p).bytes;
    if (actual.len == 0) return ext.len == 0;
    const wanted = if (ext.len > 0 and ext[0] == '.') ext else null;
    if (wanted) |w| return std.ascii.eqlIgnoreCase(actual, w);
    return std.ascii.eqlIgnoreCase(actual[1..], ext);
}

/// Walk the non-empty components of a path, treating both separators alike.
pub const ComponentIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *ComponentIterator) ?View {
        while (self.index < self.bytes.len and isSeparator(self.bytes[self.index]))
            self.index += 1;
        if (self.index >= self.bytes.len) return null;

        const start = self.index;
        while (self.index < self.bytes.len and !isSeparator(self.bytes[self.index]))
            self.index += 1;
        return .init(self.bytes[start..self.index]);
    }

    pub fn reset(self: *ComponentIterator) void {
        self.index = 0;
    }
};

pub fn components(p: []const u8) ComponentIterator {
    return .{ .bytes = p };
}

pub const Error = error{
    /// The destination buffer is too small.
    NoSpace,
    /// A `..` tried to escape above the root of an absolute path.
    EscapesRoot,
};

/// Join `parts` with `/` into `buf`, skipping empty parts and collapsing
/// separators. Returns the slice of `buf` that was written.
pub fn joinBuf(buf: []u8, parts: []const []const u8) Error![]u8 {
    var written: usize = 0;
    for (parts) |part| {
        const trimmed = std.mem.trim(u8, part, "/\\");
        if (trimmed.len == 0) continue;
        if (written != 0) {
            if (written + 1 > buf.len) return error.NoSpace;
            buf[written] = separator;
            written += 1;
        }
        if (written + trimmed.len > buf.len) return error.NoSpace;
        @memcpy(buf[written..][0..trimmed.len], trimmed);
        written += trimmed.len;
    }
    return buf[0..written];
}

/// Like `joinBuf`, but allocating. Caller owns the result.
pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts) |part| total += part.len + 1;
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    const written = try joinBuf(buf, parts);
    return allocator.realloc(buf, written.len);
}

/// Resolve `.` and `..`, collapse repeated separators, and emit `/` throughout.
/// Returns the slice of `buf` that was written.
///
/// A relative path may keep leading `..` components, because there is nothing
/// above it to resolve them against. An absolute path may not: `/..` is an
/// error rather than a silent no-op, since it usually means a bad asset id.
pub fn normalizeBuf(buf: []u8, p: []const u8) Error![]u8 {
    const absolute = isAbsolute(p);
    // Bytes at the front that `..` may never eat into: the leading "/", if any.
    const root_len: usize = if (absolute) 1 else 0;
    var written: usize = 0;

    if (absolute) {
        if (buf.len < 1) return error.NoSpace;
        buf[0] = separator;
        written = 1;
    }

    var it = components(p);
    while (it.next()) |component| {
        const c = component.bytes;
        if (std.mem.eql(u8, c, ".")) continue;

        if (std.mem.eql(u8, c, "..")) {
            if (lastComponentStart(buf, written, root_len)) |start| {
                if (!std.mem.eql(u8, buf[start..written], "..")) {
                    // Drop the previous component along with its separator.
                    written = if (start <= root_len) root_len else start - 1;
                    continue;
                }
                // The previous component is itself a "..", so it cannot be
                // popped through; fall through and stack another one.
            } else if (absolute) {
                return error.EscapesRoot;
            }
        }

        if (written > root_len) {
            if (written + 1 > buf.len) return error.NoSpace;
            buf[written] = separator;
            written += 1;
        }
        if (written + c.len > buf.len) return error.NoSpace;
        @memcpy(buf[written..][0..c.len], c);
        written += c.len;
    }

    if (written == 0) {
        if (buf.len < 1) return error.NoSpace;
        buf[0] = '.';
        return buf[0..1];
    }
    return buf[0..written];
}

/// Offset where the final component of `buf[0..written]` begins, or null when
/// there is no component to speak of.
fn lastComponentStart(buf: []const u8, written: usize, root_len: usize) ?usize {
    if (written <= root_len) return null;
    var i = written;
    while (i > root_len) {
        i -= 1;
        if (buf[i] == separator) return i + 1;
    }
    return root_len;
}

/// Like `normalizeBuf`, but allocating. Caller owns the result.
pub fn normalize(allocator: std.mem.Allocator, p: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, @max(p.len + 1, 2));
    errdefer allocator.free(buf);
    const written = try normalizeBuf(buf, p);
    return allocator.realloc(buf, written.len);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "basename" {
    try testing.expectEqualStrings("cursor.png", basename("textures/ui/cursor.png").bytes);
    try testing.expectEqualStrings("cursor.png", basename("cursor.png").bytes);
    try testing.expectEqualStrings("ui", basename("textures/ui/").bytes);
    try testing.expectEqualStrings("cursor.png", basename("textures\\ui\\cursor.png").bytes);
    try testing.expectEqualStrings("", basename("").bytes);
    try testing.expectEqualStrings("", basename("/").bytes);
}

test "dirname" {
    try testing.expectEqualStrings("textures/ui", dirname("textures/ui/cursor.png").?.bytes);
    try testing.expectEqualStrings("textures", dirname("textures/ui/").?.bytes);
    try testing.expectEqualStrings("/", dirname("/cursor.png").?.bytes);
    try testing.expectEqual(@as(?View, null), dirname("cursor.png"));
}

test "extension and stem" {
    try testing.expectEqualStrings(".png", extension("textures/cursor.png").bytes);
    try testing.expectEqualStrings("cursor", stem("textures/cursor.png").bytes);
    try testing.expectEqualStrings("textures/cursor", withoutExtension("textures/cursor.png").bytes);

    // Only the last extension counts.
    try testing.expectEqualStrings(".gz", extension("archive.tar.gz").bytes);
    try testing.expectEqualStrings("archive.tar", stem("archive.tar.gz").bytes);

    // No extension at all.
    try testing.expectEqualStrings("", extension("README").bytes);
    try testing.expectEqualStrings("README", stem("README").bytes);

    // A leading dot is a hidden file, not an extension.
    try testing.expectEqualStrings("", extension(".gitignore").bytes);
    try testing.expectEqualStrings(".gitignore", stem(".gitignore").bytes);

    // A dot in a directory name does not leak into the basename's extension.
    try testing.expectEqualStrings("", extension("v1.2/README").bytes);
}

test "hasExtension" {
    try testing.expect(hasExtension("cursor.PNG", ".png"));
    try testing.expect(hasExtension("cursor.PNG", "png"));
    try testing.expect(!hasExtension("cursor.png", ".jpg"));
    try testing.expect(hasExtension("README", ""));
    try testing.expect(!hasExtension("README", "md"));
}

test "isAbsolute" {
    try testing.expect(isAbsolute("/assets/x"));
    try testing.expect(isAbsolute("\\assets\\x"));
    try testing.expect(!isAbsolute("assets/x"));
    try testing.expect(!isAbsolute(""));
}

test "components" {
    var it = components("//textures\\ui//cursor.png");
    try testing.expectEqualStrings("textures", it.next().?.bytes);
    try testing.expectEqualStrings("ui", it.next().?.bytes);
    try testing.expectEqualStrings("cursor.png", it.next().?.bytes);
    try testing.expectEqual(@as(?View, null), it.next());
}

test "joinBuf" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "textures/ui/cursor.png",
        try joinBuf(&buf, &.{ "textures", "ui", "cursor.png" }),
    );
    // Stray separators and empty parts are absorbed.
    try testing.expectEqualStrings(
        "textures/ui",
        try joinBuf(&buf, &.{ "textures/", "", "/ui/" }),
    );
    try testing.expectEqualStrings("", try joinBuf(&buf, &.{}));

    var tiny: [4]u8 = undefined;
    try testing.expectError(error.NoSpace, joinBuf(&tiny, &.{ "textures", "ui" }));
}

test "join allocates" {
    const joined = try join(testing.allocator, &.{ "sounds", "sfx", "hit.wav" });
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("sounds/sfx/hit.wav", joined);
}

test "normalize resolves dot and dot-dot" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a/b", try normalizeBuf(&buf, "a/./b"));
    try testing.expectEqualStrings("a/c", try normalizeBuf(&buf, "a/b/../c"));
    try testing.expectEqualStrings("c", try normalizeBuf(&buf, "a/b/../../c"));
    try testing.expectEqualStrings("a", try normalizeBuf(&buf, "a/b/.."));
    try testing.expectEqualStrings("a/b", try normalizeBuf(&buf, "a//b//"));
    try testing.expectEqualStrings("a/b", try normalizeBuf(&buf, "a\\b"));
}

test "normalize keeps absolute roots and rejects escapes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/a/c", try normalizeBuf(&buf, "/a/b/../c"));
    try testing.expectEqualStrings("/a", try normalizeBuf(&buf, "/a/b/.."));
    try testing.expectEqualStrings("/a", try normalizeBuf(&buf, "//a//"));
    try testing.expectError(error.EscapesRoot, normalizeBuf(&buf, "/.."));
    try testing.expectError(error.EscapesRoot, normalizeBuf(&buf, "/a/../.."));
}

test "normalize keeps leading dot-dot on relative paths" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("..", try normalizeBuf(&buf, ".."));
    try testing.expectEqualStrings("../a", try normalizeBuf(&buf, "../a"));
    try testing.expectEqualStrings("../..", try normalizeBuf(&buf, "../.."));
    try testing.expectEqualStrings("..", try normalizeBuf(&buf, "a/../.."));
}

test "normalize collapses to a dot when nothing is left" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(".", try normalizeBuf(&buf, ""));
    try testing.expectEqualStrings(".", try normalizeBuf(&buf, "."));
    try testing.expectEqualStrings(".", try normalizeBuf(&buf, "a/.."));
}

test "normalize allocates" {
    const n = try normalize(testing.allocator, "textures/../sounds/./hit.wav");
    defer testing.allocator.free(n);
    try testing.expectEqualStrings("sounds/hit.wav", n);
}

test "normalized output feeds the other helpers" {
    var buf: [64]u8 = undefined;
    const p = try normalizeBuf(&buf, "assets\\textures\\..\\ui\\cursor.PNG");
    try testing.expectEqualStrings("assets/ui/cursor.PNG", p);
    try testing.expectEqualStrings("cursor", stem(p).bytes);
    try testing.expect(hasExtension(p, "png"));
}
