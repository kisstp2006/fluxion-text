// SPDX-License-Identifier: CC0-1.0

//! Word wrapping for on-screen text.
//!
//! The width budget is measured by a function you supply, because an engine
//! knows its own font. Return a glyph advance in pixels and you wrap to a text
//! box; return 1 per character and you wrap to a column count. `monospace`
//! is provided for the terminal-ish case, where East Asian characters occupy
//! two cells and combining marks occupy none.
//!
//! The iterator yields `View`s into the original text, so wrapping a string
//! costs no allocation at all.

const std = @import("std");
const testing = std.testing;

const View = @import("View.zig");
const utf8 = @import("utf8.zig");

/// Width of one codepoint, in whatever unit `Options.width` is expressed in.
pub const Measure = *const fn (codepoint: u21) u16;

/// Every codepoint counts as one, so `width` means "characters per line".
pub fn each(codepoint: u21) u16 {
    _ = codepoint;
    return 1;
}

/// Terminal-style widths: zero for combining marks, two for the East Asian
/// wide and fullwidth ranges, one for everything else.
///
/// This covers the ranges that matter in practice rather than the whole of
/// Unicode's East Asian Width table; if you need exactness, supply your own.
pub fn monospace(codepoint: u21) u16 {
    if (codepoint == 0) return 0;
    // Combining marks and zero-width formatting characters.
    if ((codepoint >= 0x0300 and codepoint <= 0x036F) or
        (codepoint >= 0x200B and codepoint <= 0x200F) or
        (codepoint >= 0xFE00 and codepoint <= 0xFE0F) or
        (codepoint >= 0x20D0 and codepoint <= 0x20FF)) return 0;
    // Wide and fullwidth.
    if ((codepoint >= 0x1100 and codepoint <= 0x115F) or // Hangul Jamo
        (codepoint >= 0x2E80 and codepoint <= 0x303E) or // CJK radicals, punctuation
        (codepoint >= 0x3041 and codepoint <= 0x33FF) or // Kana, CJK compatibility
        (codepoint >= 0x3400 and codepoint <= 0x4DBF) or // CJK extension A
        (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or // CJK unified
        (codepoint >= 0xA000 and codepoint <= 0xA4CF) or // Yi
        (codepoint >= 0xAC00 and codepoint <= 0xD7A3) or // Hangul syllables
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or // CJK compatibility ideographs
        (codepoint >= 0xFE30 and codepoint <= 0xFE6F) or // CJK compatibility forms
        (codepoint >= 0xFF00 and codepoint <= 0xFF60) or // Fullwidth forms
        (codepoint >= 0xFFE0 and codepoint <= 0xFFE6) or
        (codepoint >= 0x1F300 and codepoint <= 0x1F9FF) or // Emoji
        (codepoint >= 0x20000 and codepoint <= 0x3FFFD)) return 2;
    return 1;
}

pub const Options = struct {
    /// Budget per line, in the same unit `measure` returns.
    width: usize,
    measure: Measure = each,
    /// Break a word that cannot fit on a line of its own. With this off, such
    /// a word overflows on a line by itself rather than being cut.
    break_long_words: bool = true,
};

/// Total width of `text`, by the same measure used for wrapping.
pub fn measureText(text: []const u8, measure: Measure) usize {
    var total: usize = 0;
    var it: utf8.Iterator = .init(text);
    while (it.nextLossy()) |d| total += measure(d.codepoint);
    return total;
}

fn isBreakable(codepoint: u21) bool {
    return codepoint == ' ' or codepoint == '\t';
}

/// Yields one line at a time, as a view into the original text.
///
/// Explicit newlines are always honoured, trailing spaces are trimmed off each
/// line, and the space a line was broken at is consumed rather than pushed onto
/// the next line.
pub const Iterator = struct {
    text: []const u8,
    index: usize,
    options: Options,

    pub fn next(self: *Iterator) ?View {
        if (self.index >= self.text.len) return null;

        const start = self.index;
        var used: usize = 0;
        // End of the last complete word, i.e. where the line may be cut.
        var word_end: ?usize = null;
        var previous_was_space = false;
        var i = start;

        while (i < self.text.len) {
            const d = utf8.decodeLossy(self.text[i..]).?;

            if (d.codepoint == '\n') {
                self.index = i + d.len;
                return .init(trimTrailing(self.text[start..i]));
            }

            const is_space = isBreakable(d.codepoint);
            const w = self.options.measure(d.codepoint);

            // Only a visible character can overflow a line. A space that runs
            // past the edge is simply trimmed, so "Fluxion Text" still fits a
            // width of 12 rather than breaking after "Fluxion".
            if (!is_space and used + w > self.options.width and i > start) {
                if (word_end) |cut| {
                    if (cut > start) {
                        self.index = skipSpaces(self.text, cut);
                        return .init(self.text[start..cut]);
                    }
                }
                if (self.options.break_long_words) {
                    self.index = i;
                    return .init(trimTrailing(self.text[start..i]));
                }
                // Let the oversized word run over, and break after it.
                const end = endOfWord(self.text, i);
                self.index = skipSpaces(self.text, end);
                return .init(self.text[start..end]);
            }

            // The first space after a word marks where that word ended.
            if (is_space and !previous_was_space) word_end = i;
            previous_was_space = is_space;

            used += w;
            i += d.len;
        }

        self.index = self.text.len;
        return .init(trimTrailing(self.text[start..]));
    }

    pub fn reset(self: *Iterator) void {
        self.index = 0;
    }
};

fn trimTrailing(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, " \t");
}

fn skipSpaces(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

fn endOfWord(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') i += 1;
    return i;
}

pub fn iterator(text: []const u8, options: Options) Iterator {
    return .{ .text = text, .index = 0, .options = options };
}

/// Wrap into a newly allocated string with `\n` between lines.
pub fn alloc(allocator: std.mem.Allocator, text: []const u8, options: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var it = iterator(text, options);
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line.bytes);
        first = false;
    }
    return out.toOwnedSlice(allocator);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn expectLines(expected: []const []const u8, text: []const u8, options: Options) !void {
    var it = iterator(text, options);
    for (expected) |want| {
        const line = it.next() orelse {
            std.debug.print("ran out of lines, wanted \"{s}\"\n", .{want});
            return error.TooFewLines;
        };
        try testing.expectEqualStrings(want, line.bytes);
    }
    if (it.next()) |extra| {
        std.debug.print("unexpected extra line \"{s}\"\n", .{extra.bytes});
        return error.TooManyLines;
    }
}

test "wraps at spaces" {
    try expectLines(
        &.{ "the quick", "brown fox" },
        "the quick brown fox",
        .{ .width = 10 },
    );
}

test "text that fits stays on one line" {
    try expectLines(&.{"short"}, "short", .{ .width = 40 });
}

test "empty input yields no lines" {
    try expectLines(&.{}, "", .{ .width = 10 });
}

test "explicit newlines are honoured" {
    try expectLines(
        &.{ "one", "two", "three" },
        "one\ntwo\nthree",
        .{ .width = 40 },
    );
}

test "blank lines survive" {
    try expectLines(
        &.{ "a", "", "b" },
        "a\n\nb",
        .{ .width = 40 },
    );
}

test "trailing spaces are trimmed from each line" {
    try expectLines(
        &.{ "aaa", "bbb" },
        "aaa   bbb",
        .{ .width = 4 },
    );
}

test "runs of spaces collapse at a break" {
    try expectLines(
        &.{ "aaa", "bbb" },
        "aaa     bbb",
        .{ .width = 5 },
    );
}

test "long words are broken when asked" {
    try expectLines(
        &.{ "abcde", "fghij", "klm" },
        "abcdefghijklm",
        .{ .width = 5, .break_long_words = true },
    );
}

test "long words overflow when breaking is off" {
    try expectLines(
        &.{ "abcdefghijklm", "next" },
        "abcdefghijklm next",
        .{ .width = 5, .break_long_words = false },
    );
}

test "a long word after a short one starts its own line" {
    try expectLines(
        &.{ "hi", "abcde", "fgh" },
        "hi abcdefgh",
        .{ .width = 5 },
    );
}

test "breaking a long word respects codepoint boundaries" {
    // Six 2-byte characters; a byte-based break would split one in half.
    const text = "\u{00E9}" ** 6;
    var it = iterator(text, .{ .width = 2, .break_long_words = true });
    while (it.next()) |line| {
        try testing.expect(line.isValidUtf8());
        try testing.expectEqual(@as(usize, 2), try line.codepointLen());
    }
}

test "measure controls the unit" {
    // With `each`, width is a character count.
    try testing.expectEqual(@as(usize, 3), measureText("abc", each));
    // With `monospace`, CJK characters take two cells.
    try testing.expectEqual(@as(usize, 4), measureText("\u{6F22}\u{5B57}", monospace));
    // Combining marks take none.
    try testing.expectEqual(@as(usize, 1), measureText("e\u{0301}", monospace));
}

test "wraps by display width, not character count" {
    // Four CJK characters at two cells each will not fit a width of 6.
    const text = "\u{6F22}\u{5B57} \u{6F22}\u{5B57}";
    try expectLines(
        &.{ "\u{6F22}\u{5B57}", "\u{6F22}\u{5B57}" },
        text,
        .{ .width = 5, .measure = monospace },
    );
}

test "a proportional measure wraps by pixel budget" {
    // A stand-in for font metrics: 'i' is narrow, 'W' is wide.
    const S = struct {
        fn advance(codepoint: u21) u16 {
            return switch (codepoint) {
                'i', 'l', ' ' => 4,
                'W', 'M' => 20,
                else => 10,
            };
        }
    };
    // "Wi" is 24px, "ill" 12px; a 30px box fits "Wi" but not "Wi ill".
    try expectLines(
        &.{ "Wi", "ill" },
        "Wi ill",
        .{ .width = 30, .measure = S.advance },
    );
}

test "alloc joins with newlines" {
    const wrapped = try alloc(
        testing.allocator,
        "the quick brown fox jumps",
        .{ .width = 10 },
    );
    defer testing.allocator.free(wrapped);
    try testing.expectEqualStrings("the quick\nbrown fox\njumps", wrapped);
}

test "lines are views into the original text" {
    const text = "alpha beta";
    var it = iterator(text, .{ .width = 5 });
    const first = it.next().?;
    // Same backing memory, not a copy.
    try testing.expectEqual(text.ptr, first.bytes.ptr);
}

test "a paragraph round-trips through wrapping" {
    const text = "Fluxion Text is a UTF-8 string toolkit for Zig.";
    const wrapped = try alloc(testing.allocator, text, .{ .width = 12 });
    defer testing.allocator.free(wrapped);

    var it = View.init(wrapped).lines();
    while (it.next()) |line| {
        try testing.expect(measureText(line.bytes, each) <= 12);
    }
    // No words were lost or invented.
    var original_words = View.init(text).words();
    var wrapped_words = View.init(wrapped).words();
    while (original_words.next()) |want| {
        try testing.expectEqualStrings(want.bytes, wrapped_words.next().?.bytes);
    }
    try testing.expectEqual(@as(?View, null), wrapped_words.next());
}
