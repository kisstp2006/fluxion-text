// SPDX-License-Identifier: CC0-1.0

//! Fuzzy matching, for developer consoles and asset browsers.
//!
//! Two different jobs live here:
//!
//!   * `score` ranks candidates against what the user has typed so far, the
//!     way a command palette does. `spwn` should find `spawn_enemy`.
//!   * `editDistance` and `closest` answer "did you mean?" after a command has
//!     already failed.
//!
//! Neither allocates.

const std = @import("std");
const testing = std.testing;

pub const Options = struct {
    case_sensitive: bool = false,
};

/// Longest input `editDistance` will consider. Command and asset names are
/// far below this; anything longer is rejected rather than silently truncated.
pub const max_distance_len: usize = 255;

// -------------------------------------------------------------------------
// Subsequence scoring
// -------------------------------------------------------------------------

// Tuned so that, given several candidates containing the typed letters, the
// ones a human would pick first come out on top.
const score_match: i32 = 16;
const bonus_consecutive: i32 = 15;
const bonus_word_start: i32 = 30;
const bonus_first_char: i32 = 20;
const penalty_gap: i32 = -4;
const penalty_unmatched_tail: i32 = -1;

fn eqlByte(a: u8, b: u8, options: Options) bool {
    if (options.case_sensitive) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn isWordStart(haystack: []const u8, i: usize) bool {
    if (i == 0) return true;
    const prev = haystack[i - 1];
    const cur = haystack[i];
    if (prev == '_' or prev == '-' or prev == '.' or prev == '/' or prev == ' ') return true;
    // camelCase transition.
    return std.ascii.isLower(prev) and std.ascii.isUpper(cur);
}

/// Score how well `needle` matches `haystack`, or null when `needle` is not a
/// subsequence of it. Higher is better; scores are only comparable between
/// candidates scored against the same needle.
///
/// An empty needle scores 0, so "nothing typed yet" ranks everything equally.
pub fn score(needle: []const u8, haystack: []const u8, options: Options) ?i32 {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var total: i32 = 0;
    var h: usize = 0;
    var previous_match: ?usize = null;

    for (needle) |want| {
        // Walk forward to the next occurrence.
        while (h < haystack.len and !eqlByte(want, haystack[h], options)) h += 1;
        if (h >= haystack.len) return null;

        total += score_match;
        if (h == 0) total += bonus_first_char;
        if (isWordStart(haystack, h)) total += bonus_word_start;
        if (previous_match) |prev| {
            if (h == prev + 1) {
                total += bonus_consecutive;
            } else {
                const gap: i32 = @intCast(@min(h - prev - 1, 32));
                total += penalty_gap * gap;
            }
        }

        previous_match = h;
        h += 1;
    }

    // Prefer the tighter candidate when two otherwise score alike.
    const tail: i32 = @intCast(@min(haystack.len - needle.len, 64));
    total += penalty_unmatched_tail * tail;
    return total;
}

/// Whether `needle` appears in `haystack` as a subsequence.
pub fn matches(needle: []const u8, haystack: []const u8, options: Options) bool {
    return score(needle, haystack, options) != null;
}

pub const Ranked = struct {
    index: usize,
    score: i32,
};

/// Score every candidate, keeping the ones that match, best first.
///
/// Results are written into `out` and the filled prefix is returned, so this
/// never allocates. Candidates beyond `out.len` are still considered: the
/// weakest result is dropped to make room.
pub fn rank(
    needle: []const u8,
    candidates: []const []const u8,
    out: []Ranked,
    options: Options,
) []Ranked {
    if (out.len == 0) return out[0..0];
    var n: usize = 0;

    for (candidates, 0..) |candidate, i| {
        const s = score(needle, candidate, options) orelse continue;
        if (n < out.len) {
            out[n] = .{ .index = i, .score = s };
            n += 1;
        } else if (s > out[n - 1].score) {
            out[n - 1] = .{ .index = i, .score = s };
        } else continue;

        // Bubble the new entry into place; `out` stays sorted at all times.
        var j = n - 1;
        while (j > 0 and out[j].score > out[j - 1].score) : (j -= 1) {
            std.mem.swap(Ranked, &out[j], &out[j - 1]);
        }
    }
    return out[0..n];
}

// -------------------------------------------------------------------------
// Edit distance
// -------------------------------------------------------------------------

pub const DistanceError = error{InputTooLong};

/// Levenshtein distance between `a` and `b`, or null when it exceeds `max`.
///
/// Bailing out at `max` is not just an optimisation: a "did you mean?" prompt
/// only cares about near misses, and stopping early keeps the cost down.
pub fn editDistance(a: []const u8, b: []const u8, max: usize) DistanceError!?usize {
    // Keep the shorter string on the row axis so the buffer stays small.
    const short = if (a.len <= b.len) a else b;
    const long = if (a.len <= b.len) b else a;
    if (long.len > max_distance_len) return error.InputTooLong;

    if (long.len - short.len > max) return null;
    if (short.len == 0) return if (long.len <= max) long.len else null;

    var row: [max_distance_len + 1]usize = undefined;
    for (0..short.len + 1) |i| row[i] = i;

    for (long, 1..) |lc, i| {
        var previous_diagonal = row[0];
        row[0] = i;
        var best = row[0];

        for (short, 1..) |sc, j| {
            const cost: usize = if (lc == sc) 0 else 1;
            const substitute = previous_diagonal + cost;
            const insert = row[j] + 1;
            const delete = row[j - 1] + 1;
            previous_diagonal = row[j];
            row[j] = @min(substitute, @min(insert, delete));
            best = @min(best, row[j]);
        }

        // Every remaining row can only grow this minimum, so we can stop.
        if (best > max) return null;
    }

    const result = row[short.len];
    return if (result <= max) result else null;
}

pub const Match = struct {
    index: usize,
    distance: usize,
};

/// The candidate nearest to `needle` within `max_edits`, for suggesting a
/// correction. Ties go to the earlier candidate.
pub fn closest(
    needle: []const u8,
    candidates: []const []const u8,
    max_edits: usize,
) DistanceError!?Match {
    var best: ?Match = null;
    for (candidates, 0..) |candidate, i| {
        const limit = if (best) |b| @min(max_edits, b.distance -| 1) else max_edits;
        const d = try editDistance(needle, candidate, limit) orelse continue;
        if (best == null or d < best.?.distance) best = .{ .index = i, .distance = d };
    }
    return best;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "score finds subsequences" {
    try testing.expect(matches("spwn", "spawn_enemy", .{}));
    try testing.expect(matches("se", "spawn_enemy", .{}));
    try testing.expect(!matches("xyz", "spawn_enemy", .{}));
    // Order matters: the letters must appear in sequence.
    try testing.expect(!matches("nwps", "spawn_enemy", .{}));
}

test "an empty needle matches everything" {
    try testing.expectEqual(@as(?i32, 0), score("", "anything", .{}));
    try testing.expectEqual(@as(?i32, 0), score("", "", .{}));
}

test "a needle longer than the haystack cannot match" {
    try testing.expectEqual(@as(?i32, null), score("spawn_enemy", "spwn", .{}));
}

test "case sensitivity" {
    try testing.expect(matches("SPWN", "spawn_enemy", .{}));
    try testing.expect(!matches("SPWN", "spawn_enemy", .{ .case_sensitive = true }));
}

test "consecutive matches beat scattered ones" {
    const tight = score("spa", "spawn", .{}).?;
    const loose = score("spa", "set_player_alpha", .{}).?;
    try testing.expect(tight > loose);
}

test "word starts are rewarded" {
    // 'se' as two word initials should beat 'se' buried inside one word.
    const initials = score("se", "spawn_enemy", .{}).?;
    const buried = score("se", "unset", .{}).?;
    try testing.expect(initials > buried);
}

test "camelCase counts as a word start" {
    const camel = score("se", "spawnEnemy", .{}).?;
    const flat = score("se", "spawnenemy", .{}).?;
    try testing.expect(camel > flat);
}

test "a prefix match beats a later one" {
    const prefix = score("spa", "spawn", .{}).?;
    const later = score("spa", "respawn", .{}).?;
    try testing.expect(prefix > later);
}

test "shorter candidates win ties" {
    const short = score("ab", "ab", .{}).?;
    const long = score("ab", "ab_with_a_long_tail", .{}).?;
    try testing.expect(short > long);
}

test "rank orders candidates best first" {
    const commands = [_][]const u8{
        "quit",
        "spawn_enemy",
        "set_gravity",
        "screenshot",
        "reload_shaders",
    };
    var buf: [8]Ranked = undefined;
    const results = rank("se", &commands, &buf, .{});

    try testing.expect(results.len >= 2);
    // Sorted descending.
    for (1..results.len) |i| try testing.expect(results[i - 1].score >= results[i].score);
    // "set_gravity" and "spawn_enemy" both hit word starts; "screenshot" does
    // not, so it must not come first.
    try testing.expect(results[0].index == 1 or results[0].index == 2);
    // "quit" has no 's', so it is filtered out entirely.
    for (results) |r| try testing.expect(r.index != 0);
}

test "rank respects a small output buffer" {
    const commands = [_][]const u8{ "aaa", "aab", "aac", "aad" };
    var buf: [2]Ranked = undefined;
    const results = rank("aa", &commands, &buf, .{});
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expect(results[0].score >= results[1].score);

    var none: [0]Ranked = undefined;
    try testing.expectEqual(@as(usize, 0), rank("aa", &commands, &none, .{}).len);
}

test "editDistance" {
    try testing.expectEqual(@as(?usize, 0), try editDistance("spawn", "spawn", 4));
    try testing.expectEqual(@as(?usize, 1), try editDistance("spawn", "spwn", 4));
    try testing.expectEqual(@as(?usize, 1), try editDistance("spwn", "spawn", 4));
    try testing.expectEqual(@as(?usize, 3), try editDistance("kitten", "sitting", 4));
    try testing.expectEqual(@as(?usize, 5), try editDistance("", "spawn", 8));
    try testing.expectEqual(@as(?usize, 0), try editDistance("", "", 0));
}

test "editDistance bails out past the limit" {
    try testing.expectEqual(@as(?usize, null), try editDistance("kitten", "sitting", 2));
    try testing.expectEqual(@as(?usize, null), try editDistance("abc", "xyz", 2));
    // A length difference alone can exceed the budget.
    try testing.expectEqual(@as(?usize, null), try editDistance("a", "abcdefgh", 3));
}

test "editDistance is symmetric" {
    const a = try editDistance("reload_shaders", "reload_shader", 4);
    const b = try editDistance("reload_shader", "reload_shaders", 4);
    try testing.expectEqual(a, b);
}

test "editDistance rejects overlong input" {
    const long = "a" ** (max_distance_len + 1);
    try testing.expectError(error.InputTooLong, editDistance(long, "a", 4));
    try testing.expectError(error.InputTooLong, editDistance("a", long, 4));
}

test "closest suggests a correction" {
    const commands = [_][]const u8{ "quit", "spawn_enemy", "set_gravity", "screenshot" };

    const hit = (try closest("spawn_enemey", &commands, 3)).?;
    try testing.expectEqual(@as(usize, 1), hit.index);
    try testing.expectEqual(@as(usize, 1), hit.distance);

    // Nothing is close enough to be worth suggesting.
    try testing.expectEqual(@as(?Match, null), try closest("zzzzzzzz", &commands, 2));
    try testing.expectEqual(@as(?Match, null), try closest("anything", &.{}, 4));
}

test "closest picks the nearest of several" {
    const candidates = [_][]const u8{ "spawn", "spawns", "spwn" };
    const hit = (try closest("spawn", &candidates, 3)).?;
    try testing.expectEqual(@as(usize, 0), hit.index);
    try testing.expectEqual(@as(usize, 0), hit.distance);
}

test "a console flow: rank while typing, suggest on failure" {
    const commands = [_][]const u8{ "spawn_enemy", "set_gravity", "screenshot", "quit" };

    // The user has typed "spw" - offer completions.
    var buf: [4]Ranked = undefined;
    const suggestions = rank("spw", &commands, &buf, .{});
    try testing.expectEqual(@as(usize, 1), suggestions.len);
    try testing.expectEqualStrings("spawn_enemy", commands[suggestions[0].index]);

    // They committed a typo instead - offer the nearest real command.
    try testing.expect(!matches("screenshto", "screenshot", .{}));
    const did_you_mean = (try closest("screenshto", &commands, 2)).?;
    try testing.expectEqualStrings("screenshot", commands[did_you_mean.index]);
}
