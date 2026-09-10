// SPDX-License-Identifier: CC0-1.0

//! Glob matching, for asset filters and command tables.
//!
//! Supports `*`, `?`, character classes like `[a-z]` and `[!abc]`, and `\` to
//! escape any of them. With `cross_separator` off, `*` stops at a path
//! separator and `**` is the one that crosses it, which is the behaviour people
//! expect from `textures/*.png` versus `**/*.png`.
//!
//! Matching is iterative rather than recursive, so a hostile pattern cannot
//! blow the stack. `?` and `*` work in units of codepoints, so they behave
//! sensibly on non-ASCII names; character classes are byte-oriented and are
//! meant for ASCII ranges.

const std = @import("std");
const testing = std.testing;

const utf8 = @import("utf8.zig");

pub const Options = struct {
    case_sensitive: bool = true,
    /// When false, `*` will not match across `separator` and `**` is required
    /// to descend into subdirectories.
    cross_separator: bool = true,
    separator: u8 = '/',
};

/// Match `text` against `pattern` using the default options.
pub fn match(pattern: []const u8, text: []const u8) bool {
    return matchOptions(pattern, text, .{});
}

/// Match a path, where `*` stays within one component and `**` spans them.
pub fn matchPath(pattern: []const u8, text: []const u8) bool {
    return matchOptions(pattern, text, .{ .cross_separator = false });
}

pub fn matchOptions(pattern: []const u8, text: []const u8, options: Options) bool {
    if (options.cross_separator) return matchSegment(pattern, text, options);
    return matchComponents(pattern, text, options);
}

/// Wildcard matching with no notion of separators, so `*` spans anything.
///
/// This is the classic two-pointer algorithm. Keeping only the most recent
/// star is sound precisely because `*` is unconstrained here: if a later star
/// fails, no amount of extra text given to an earlier one would have helped.
fn matchSegment(pattern: []const u8, text: []const u8, options: Options) bool {
    var p: usize = 0;
    var t: usize = 0;

    // Where to resume from if the most recent star must swallow more text.
    var star_p: ?usize = null;
    var star_t: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            while (p < pattern.len and pattern[p] == '*') p += 1; // collapse a run
            star_p = p;
            star_t = t;
            continue;
        }

        if (p < pattern.len) {
            if (matchOne(pattern, p, text, t, options)) |step| {
                p += step.pattern_len;
                t += step.text_len;
                continue;
            }
        }

        // No match here: let the last star absorb one more codepoint.
        const resume_p = star_p orelse return false;
        if (star_t >= text.len) return false;
        star_t += codepointLen(text, star_t);
        p = resume_p;
        t = star_t;
    }

    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Match component by component, with `**` as the only thing that spans them.
///
/// Splitting first is what makes this correct. A constrained `*` breaks the
/// single-star shortcut above - once `textures/**/*.png` fails on `*.png`, the
/// `**` really does need to swallow another component - but at this level the
/// only wildcard is `**`, which is unconstrained again, so the same two-pointer
/// argument applies. Within one component there are no separators, so `*` is
/// unconstrained there too and `matchSegment` handles it.
///
/// `**` is only special as a whole component; `a**b` is just `a*b`.
fn matchComponents(pattern: []const u8, text: []const u8, options: Options) bool {
    var p_off: usize = 0;
    var t_off: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;

    while (true) {
        var t_next = t_off;
        const t_comp = nextComponent(text, &t_next, options.separator) orelse break;

        var p_next = p_off;
        const p_comp = nextComponent(pattern, &p_next, options.separator);

        if (p_comp) |pc| {
            if (std.mem.eql(u8, pc, "**")) {
                p_off = p_next;
                star_p = p_next;
                star_t = t_off;
                continue;
            }
            if (matchSegment(pc, t_comp, options)) {
                p_off = p_next;
                t_off = t_next;
                continue;
            }
        }

        // Hand one more component to the last `**`.
        const resume_p = star_p orelse return false;
        var skip = star_t;
        _ = nextComponent(text, &skip, options.separator) orelse return false;
        star_t = skip;
        t_off = skip;
        p_off = resume_p;
    }

    // The text ran out; whatever is left of the pattern must match nothing.
    while (nextComponent(pattern, &p_off, options.separator)) |pc| {
        if (!std.mem.eql(u8, pc, "**")) return false;
    }
    return true;
}

/// The next non-empty component at `offset`, advancing it past that component.
fn nextComponent(s: []const u8, offset: *usize, separator: u8) ?[]const u8 {
    var i = offset.*;
    while (i < s.len and s[i] == separator) i += 1;
    if (i >= s.len) {
        offset.* = i;
        return null;
    }
    const start = i;
    while (i < s.len and s[i] != separator) i += 1;
    offset.* = i;
    return s[start..i];
}

fn codepointLen(text: []const u8, index: usize) usize {
    const d = utf8.decodeLossy(text[index..]) orelse return 1;
    return d.len;
}

const Step = struct {
    pattern_len: usize,
    text_len: usize,
};

/// Match the single pattern atom at `pattern[p]` against `text[t]`, returning
/// how far each side advances, or null when it does not match.
fn matchOne(
    pattern: []const u8,
    p: usize,
    text: []const u8,
    t: usize,
    options: Options,
) ?Step {
    switch (pattern[p]) {
        '?' => return .{ .pattern_len = 1, .text_len = codepointLen(text, t) },
        '[' => return matchClass(pattern, p, text[t], options),
        '\\' => {
            if (p + 1 >= pattern.len) return null; // trailing backslash matches nothing
            if (!eqlByte(pattern[p + 1], text[t], options)) return null;
            return .{ .pattern_len = 2, .text_len = 1 };
        },
        else => {
            if (!eqlByte(pattern[p], text[t], options)) return null;
            return .{ .pattern_len = 1, .text_len = 1 };
        },
    }
}

fn eqlByte(a: u8, b: u8, options: Options) bool {
    if (options.case_sensitive) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// Match a `[...]` class. An unterminated `[` is treated as a literal bracket.
fn matchClass(pattern: []const u8, open: usize, c: u8, options: Options) ?Step {
    var i = open + 1;
    var negated = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negated = true;
        i += 1;
    }

    var found = false;
    var first = true;
    while (i < pattern.len) : (first = false) {
        // A `]` in the first position is a literal, per the usual glob rules.
        if (pattern[i] == ']' and !first) {
            const matched = found != negated;
            if (!matched) return null;
            return .{ .pattern_len = i + 1 - open, .text_len = 1 };
        }

        var low = pattern[i];
        if (low == '\\' and i + 1 < pattern.len) {
            i += 1;
            low = pattern[i];
        }
        i += 1;

        // A range, unless the '-' is the last thing before the closing ']'.
        if (i + 1 < pattern.len and pattern[i] == '-' and pattern[i + 1] != ']') {
            i += 1;
            var high = pattern[i];
            if (high == '\\' and i + 1 < pattern.len) {
                i += 1;
                high = pattern[i];
            }
            i += 1;
            if (inRange(c, low, high, options)) found = true;
        } else if (eqlByte(low, c, options)) {
            found = true;
        }
    }

    // Never closed: fall back to treating '[' as an ordinary character.
    if (!eqlByte('[', c, options)) return null;
    return .{ .pattern_len = 1, .text_len = 1 };
}

fn inRange(c: u8, low: u8, high: u8, options: Options) bool {
    if (options.case_sensitive) return c >= low and c <= high;
    const lc = std.ascii.toLower(c);
    const uc = std.ascii.toUpper(c);
    return (lc >= std.ascii.toLower(low) and lc <= std.ascii.toLower(high)) or
        (uc >= std.ascii.toUpper(low) and uc <= std.ascii.toUpper(high));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "literals" {
    try testing.expect(match("cursor.png", "cursor.png"));
    try testing.expect(!match("cursor.png", "cursor.jpg"));
    try testing.expect(!match("cursor", "cursor.png"));
    try testing.expect(match("", ""));
    try testing.expect(!match("", "x"));
}

test "star" {
    try testing.expect(match("*.png", "cursor.png"));
    try testing.expect(match("*", "anything"));
    try testing.expect(match("*", ""));
    try testing.expect(match("cursor.*", "cursor.png"));
    try testing.expect(match("*cursor*", "ui_cursor_2x"));
    try testing.expect(!match("*.png", "cursor.jpg"));

    // A star may match nothing at all.
    try testing.expect(match("a*b", "ab"));
    try testing.expect(match("a*", "a"));
}

test "several stars backtrack correctly" {
    try testing.expect(match("*a*b*c*", "xxaxxbxxcxx"));
    try testing.expect(!match("*a*b*c*", "xxaxxcxxbxx"));
    try testing.expect(match("**", "anything"));
    try testing.expect(match("a**b", "aXXXb"));
}

test "question mark matches one codepoint" {
    try testing.expect(match("?", "a"));
    try testing.expect(match("?", "\u{00E9}")); // one character, two bytes
    try testing.expect(match("???", "abc"));
    try testing.expect(!match("?", ""));
    try testing.expect(!match("?", "ab"));
    try testing.expect(match("caf?", "caf\u{00E9}"));
}

test "character classes" {
    try testing.expect(match("[abc]", "b"));
    try testing.expect(!match("[abc]", "d"));
    try testing.expect(match("[a-z]", "q"));
    try testing.expect(!match("[a-z]", "Q"));
    try testing.expect(match("[0-9a-f]", "e"));
    try testing.expect(match("tile_[0-9][0-9].png", "tile_07.png"));
    try testing.expect(!match("tile_[0-9][0-9].png", "tile_7x.png"));
}

test "negated classes" {
    try testing.expect(match("[!abc]", "d"));
    try testing.expect(!match("[!abc]", "a"));
    try testing.expect(match("[^0-9]", "x"));
    try testing.expect(!match("[^0-9]", "5"));
}

test "class edge cases" {
    // A ']' straight after '[' is a literal.
    try testing.expect(match("[]]", "]"));
    // A '-' at the end of a class is a literal.
    try testing.expect(match("[a-]", "-"));
    try testing.expect(match("[a-]", "a"));
    // An unterminated '[' is a literal bracket.
    try testing.expect(match("[abc", "[abc"));
}

test "escaping" {
    try testing.expect(match("\\*", "*"));
    try testing.expect(!match("\\*", "star"));
    try testing.expect(match("\\?", "?"));
    try testing.expect(match("\\[a\\]", "[a]"));
    try testing.expect(match("[\\]]", "]"));
}

test "case insensitivity" {
    try testing.expect(matchOptions("*.PNG", "cursor.png", .{ .case_sensitive = false }));
    try testing.expect(matchOptions("[A-Z]*", "cursor", .{ .case_sensitive = false }));
    try testing.expect(!matchOptions("*.PNG", "cursor.png", .{}));
}

test "path mode keeps star inside one component" {
    try testing.expect(matchPath("textures/*.png", "textures/cursor.png"));
    try testing.expect(!matchPath("textures/*.png", "textures/ui/cursor.png"));
    try testing.expect(!matchPath("*.png", "ui/cursor.png"));

    // '?' will not eat a separator either.
    try testing.expect(!matchPath("a?b", "a/b"));
}

test "double star descends" {
    try testing.expect(matchPath("**/*.wav", "sounds/sfx/hit.wav"));
    try testing.expect(matchPath("**/*.wav", "sounds/hit.wav"));
    try testing.expect(matchPath("sounds/**", "sounds/sfx/hit.wav"));
    try testing.expect(matchPath("**", "a/b/c"));
    try testing.expect(!matchPath("**/*.wav", "sounds/sfx/hit.ogg"));
}

test "a nested star must be able to give ground to an outer one" {
    // The regression this covers: matching "ui" against "*.png" fails, and the
    // only way forward is for the preceding "**" to swallow another component.
    // Single-star backtracking cannot do that, which is why path mode splits
    // into components first.
    try testing.expect(matchPath("textures/**/*.png", "textures/ui/icons/close.png"));
    try testing.expect(matchPath("**/*.png", "a/b/c/d/e.png"));
    try testing.expect(!matchPath("textures/**/*.png", "textures/ui/icons/close.jpg"));
}

test "several double stars" {
    try testing.expect(matchPath("a/**/b/**/c", "a/x/y/b/z/c"));
    try testing.expect(matchPath("**/**/*.png", "a/b/c.png"));
    try testing.expect(!matchPath("a/**/b/**/c", "a/x/y/b/z/d"));
}

test "double star matches zero components" {
    try testing.expect(matchPath("a/**/c", "a/c"));
    try testing.expect(matchPath("**/a", "a"));
    try testing.expect(!matchPath("a/**/c", "a/b/d"));
}

test "path mode handles empty and separator-only input" {
    try testing.expect(matchPath("", ""));
    try testing.expect(!matchPath("", "a"));
    try testing.expect(!matchPath("a", ""));
    // Repeated and trailing separators are absorbed.
    try testing.expect(matchPath("a/b", "a//b/"));
    try testing.expect(matchPath("**", ""));
}

test "default mode lets star cross separators" {
    try testing.expect(match("textures/*.png", "textures/ui/cursor.png"));
    try testing.expect(match("*.png", "a/b/c.png"));
}

test "a pathological pattern still terminates" {
    // The classic exponential-backtracking case for a recursive matcher.
    const pattern = "*a*a*a*a*a*a*a*a*b";
    const text = "a" ** 64;
    try testing.expect(!match(pattern, text));
}

test "realistic asset filters" {
    try testing.expect(matchPath("textures/**/*.png", "textures/ui/icons/close.png"));
    try testing.expect(matchPath("*.[oa]", "libfoo.a"));
    try testing.expect(matchOptions(
        "Enemy_*",
        "enemy_goblin",
        .{ .case_sensitive = false },
    ));
    try testing.expect(!matchPath("textures/**/*.png", "sounds/ui/click.wav"));
}
