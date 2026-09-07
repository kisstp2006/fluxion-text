// SPDX-License-Identifier: CC0-1.0

//! A tour of Fluxion Text. Run it with `zig build example`.

const std = @import("std");
const Io = std.Io;
const text = @import("fluxion_text");

// Written with explicit escapes rather than a `\\` block, because multiline
// string literals in Zig do not process escape sequences.
const source =
    "# server settings\n" ++
    "host    = localhost\n" ++
    "port    = 8080\n" ++
    "retries = 0x1F\n" ++
    "timeout = 2.5\n" ++
    "debug   = false\n" ++
    "name    = \"caf\u{00E9} \u{6F22}\u{5B57}\"\n";

const Value = union(enum) {
    string: text.View,
    boolean: bool,
    int: i64,
    float: f64,
    raw: text.View,
};

/// Try each value shape in turn, rewinding the cursor between attempts.
fn parseValue(p: *text.Parser) !Value {
    if (try p.takeQuoted('"')) |s| return .{ .string = s };
    if (p.takeBool()) |b| return .{ .boolean = b };

    const mark = p.save();
    if (p.takeInt(i64, .{})) |n| {
        // A '.' or exponent right after the digits means it was really a float.
        const next = p.peek() orelse return .{ .int = n };
        if (next != '.' and next != 'e' and next != 'E') return .{ .int = n };
        p.restore(mark);
    } else |_| {}

    if (p.takeFloat(f64, .{})) |f| {
        return .{ .float = f };
    } else |_| {
        p.restore(mark);
    }

    return .{ .raw = p.takeUntilScalar('\n') };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    var interner: text.Interner = .init(gpa);
    defer interner.deinit();

    // A Builder is a std.Io.Writer, so anything that can print can print here.
    var report: text.Builder = .init(gpa);
    defer report.deinit();

    var p: text.Parser = .init(source);
    while (!p.isAtEnd()) {
        _ = p.skipWhitespace();
        if (p.isAtEnd()) break;

        if (p.eat('#')) {
            try report.print("comment  {f}\n", .{p.takeLine().?.trim()});
            continue;
        }

        const key = p.takeIdentifier() orelse {
            try report.print("junk at {f}\n", .{p.location()});
            _ = p.takeLine();
            continue;
        };
        const id = try interner.internView(key);

        _ = p.skipInlineWhitespace();
        try p.expect('=');
        _ = p.skipInlineWhitespace();

        try report.print("{f} {s} = ", .{ id, interner.resolve(id) });
        switch (try parseValue(&p)) {
            .string => |s| try report.print("string {f} ({d} codepoints)\n", .{ s, try s.codepointLen() }),
            .boolean => |b| try report.print("bool {}\n", .{b}),
            .int => |n| try report.print("int {d}\n", .{n}),
            .float => |f| try report.print("float {d}\n", .{f}),
            .raw => |v| try report.print("raw {f}\n", .{v.trim()}),
        }
    }

    try out.print("--- parser + interner + builder ---\n{f}", .{report});

    // Views slice without copying.
    const line: text.View = .init("  host    = localhost  ");
    const pair = line.trim().splitOnce("=").?;
    try out.print(
        "\n--- view ---\nkey={f} value={f}\n",
        .{ pair.before.trim(), pair.after.trim() },
    );

    // UTF-8 aware truncation never splits a character in half.
    const label: text.View = .init("caf\u{00E9} \u{6F22}\u{5B57}");
    try out.print(
        "\n--- utf8 ---\n{d} bytes, {d} codepoints, cut to 5 bytes: {f}\n",
        .{ label.len(), try label.codepointLen(), label.truncateBytes(5) },
    );

    // Interned ids compare as integers and resolve back to text.
    try out.print("\n--- interned keys ({d}) ---\n", .{interner.count()});
    var it = interner.iterator();
    while (it.next()) |entry| try out.print("  {f} -> {s}\n", .{ entry.id, entry.text });

    try out.flush();
}
