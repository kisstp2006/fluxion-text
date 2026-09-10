// SPDX-License-Identifier: CC0-1.0

//! A cursor over UTF-8 text, for hand-written parsers and lexers.
//!
//! `Parser` never allocates and never copies: everything it hands back is a
//! `View` into the original input. The three families of method are
//!
//!   * `peek*`   - look without moving,
//!   * `eat*`    - move if it matches, report whether it did,
//!   * `expect*` - move if it matches, fail if it does not,
//!
//! plus the `take*` family, which consumes a run of bytes and returns the span.
//! Use `save`/`restore` to speculatively try a production and back out.

const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;

const View = @import("View.zig");
const utf8 = @import("utf8.zig");
const number = @import("number.zig");

const Parser = @This();

input: []const u8,
/// Byte offset of the cursor. Always on a byte boundary, not necessarily on a
/// codepoint boundary if you advance by raw byte counts.
index: usize,

pub const Error = error{
    /// The input ran out before the expected item.
    UnexpectedEnd,
    /// The next byte was not the expected one.
    UnexpectedByte,
};

/// An opaque cursor position, produced by `save` and consumed by `restore`.
pub const Mark = usize;

pub fn init(input: []const u8) Parser {
    return .{ .input = input, .index = 0 };
}

pub fn initView(v: View) Parser {
    return .{ .input = v.bytes, .index = 0 };
}

// -------------------------------------------------------------------------
// Position
// -------------------------------------------------------------------------

pub fn isAtEnd(self: *const Parser) bool {
    return self.index >= self.input.len;
}

/// Everything not yet consumed.
pub fn rest(self: *const Parser) View {
    return .init(self.input[self.index..]);
}

/// Everything consumed so far.
pub fn consumed(self: *const Parser) View {
    return .init(self.input[0..self.index]);
}

pub fn save(self: *const Parser) Mark {
    return self.index;
}

pub fn restore(self: *Parser, mark: Mark) void {
    std.debug.assert(mark <= self.input.len);
    self.index = mark;
}

pub fn reset(self: *Parser) void {
    self.index = 0;
}

/// Move forward by up to `n` bytes, stopping at the end of the input.
pub fn advance(self: *Parser, n: usize) void {
    self.index = @min(self.index + n, self.input.len);
}

// -------------------------------------------------------------------------
// Peeking
// -------------------------------------------------------------------------

pub fn peek(self: *const Parser) ?u8 {
    if (self.isAtEnd()) return null;
    return self.input[self.index];
}

pub fn peekAt(self: *const Parser, offset: usize) ?u8 {
    const i = self.index + offset;
    if (i >= self.input.len) return null;
    return self.input[i];
}

/// The next `n` bytes, or null if fewer than `n` remain.
pub fn peekSlice(self: *const Parser, n: usize) ?View {
    if (self.index + n > self.input.len) return null;
    return .init(self.input[self.index..][0..n]);
}

pub fn peekCodepoint(self: *const Parser) utf8.DecodeError!?utf8.Decoded {
    if (self.isAtEnd()) return null;
    return try utf8.decode(self.input[self.index..]);
}

/// True if the next byte is `byte`, without consuming it.
pub fn check(self: *const Parser, byte: u8) bool {
    return self.peek() == byte;
}

/// True if the input continues with `bytes`, without consuming them.
pub fn checkSlice(self: *const Parser, bytes: []const u8) bool {
    return std.mem.startsWith(u8, self.input[self.index..], bytes);
}

// -------------------------------------------------------------------------
// Consuming one item
// -------------------------------------------------------------------------

pub fn next(self: *Parser) ?u8 {
    if (self.isAtEnd()) return null;
    defer self.index += 1;
    return self.input[self.index];
}

pub fn nextCodepoint(self: *Parser) utf8.DecodeError!?utf8.Decoded {
    if (self.isAtEnd()) return null;
    const d = try utf8.decode(self.input[self.index..]);
    self.index += d.len;
    return d;
}

// -------------------------------------------------------------------------
// Matching
// -------------------------------------------------------------------------

/// Consume `byte` if it is next. Returns whether it was.
pub fn eat(self: *Parser, byte: u8) bool {
    if (!self.check(byte)) return false;
    self.index += 1;
    return true;
}

/// Consume the next byte if it appears in `set`, returning which one it was.
pub fn eatAny(self: *Parser, set: []const u8) ?u8 {
    const c = self.peek() orelse return null;
    if (std.mem.indexOfScalar(u8, set, c) == null) return null;
    self.index += 1;
    return c;
}

pub fn eatSlice(self: *Parser, bytes: []const u8) bool {
    if (!self.checkSlice(bytes)) return false;
    self.index += bytes.len;
    return true;
}

pub fn eatSliceIgnoreCase(self: *Parser, bytes: []const u8) bool {
    if (!ascii.startsWithIgnoreCase(self.input[self.index..], bytes)) return false;
    self.index += bytes.len;
    return true;
}

pub fn expect(self: *Parser, byte: u8) Error!void {
    if (self.isAtEnd()) return error.UnexpectedEnd;
    if (!self.eat(byte)) return error.UnexpectedByte;
}

pub fn expectSlice(self: *Parser, bytes: []const u8) Error!void {
    if (self.input.len - self.index < bytes.len) return error.UnexpectedEnd;
    if (!self.eatSlice(bytes)) return error.UnexpectedByte;
}

pub fn expectAny(self: *Parser, set: []const u8) Error!u8 {
    if (self.isAtEnd()) return error.UnexpectedEnd;
    return self.eatAny(set) orelse error.UnexpectedByte;
}

// -------------------------------------------------------------------------
// Consuming spans
// -------------------------------------------------------------------------

/// The next `n` bytes, or null if fewer than `n` remain (cursor unmoved).
pub fn take(self: *Parser, n: usize) ?View {
    const v = self.peekSlice(n) orelse return null;
    self.index += n;
    return v;
}

/// Everything that is left.
pub fn takeRest(self: *Parser) View {
    defer self.index = self.input.len;
    return .init(self.input[self.index..]);
}

/// The longest run of bytes satisfying `pred`. May be empty.
pub fn takeWhile(self: *Parser, comptime pred: fn (u8) bool) View {
    const start = self.index;
    while (self.index < self.input.len and pred(self.input[self.index])) self.index += 1;
    return .init(self.input[start..self.index]);
}

/// The longest run of bytes drawn from `set`. May be empty.
pub fn takeWhileAny(self: *Parser, set: []const u8) View {
    const start = self.index;
    while (self.index < self.input.len and
        std.mem.indexOfScalar(u8, set, self.input[self.index]) != null) self.index += 1;
    return .init(self.input[start..self.index]);
}

/// Everything up to the first byte of `set`, leaving the cursor on it. If no
/// such byte exists, consumes the rest of the input.
pub fn takeUntilAny(self: *Parser, set: []const u8) View {
    const start = self.index;
    while (self.index < self.input.len and
        std.mem.indexOfScalar(u8, set, self.input[self.index]) == null) self.index += 1;
    return .init(self.input[start..self.index]);
}

/// Everything up to the next `byte`, leaving the cursor on it. If the byte
/// does not occur, consumes the rest of the input.
pub fn takeUntilScalar(self: *Parser, byte: u8) View {
    const start = self.index;
    const found = std.mem.indexOfScalarPos(u8, self.input, self.index, byte);
    self.index = found orelse self.input.len;
    return .init(self.input[start..self.index]);
}

/// Everything up to the next occurrence of `needle`, leaving the cursor at the
/// start of it. Null when `needle` does not occur, in which case the cursor
/// does not move.
pub fn takeUntilSlice(self: *Parser, needle: []const u8) ?View {
    const found = std.mem.indexOfPos(u8, self.input, self.index, needle) orelse return null;
    const start = self.index;
    self.index = found;
    return .init(self.input[start..found]);
}

// -------------------------------------------------------------------------
// Skipping
// -------------------------------------------------------------------------

/// Skip ASCII whitespace, including newlines. Returns the bytes skipped.
pub fn skipWhitespace(self: *Parser) usize {
    return self.takeWhileAny(View.whitespace).len();
}

/// Skip spaces and tabs but stop at a line break.
pub fn skipInlineWhitespace(self: *Parser) usize {
    return self.takeWhileAny(" \t").len();
}

/// Skip every byte that appears in `set`. Returns the count skipped.
pub fn skipAny(self: *Parser, set: []const u8) usize {
    return self.takeWhileAny(set).len();
}

// -------------------------------------------------------------------------
// Common tokens
// -------------------------------------------------------------------------

fn isIdentStart(c: u8) bool {
    return ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return ascii.isAlphanumeric(c) or c == '_';
}

/// A C-style identifier: `[A-Za-z_][A-Za-z0-9_]*`. Null if the next byte
/// cannot start one, in which case the cursor does not move.
pub fn takeIdentifier(self: *Parser) ?View {
    const c = self.peek() orelse return null;
    if (!isIdentStart(c)) return null;
    const start = self.index;
    self.index += 1;
    _ = self.takeWhile(isIdentContinue);
    return .init(self.input[start..self.index]);
}

/// One line without its terminator, consuming the terminator. Accepts "\n"
/// and "\r\n". Null once the input is exhausted.
pub fn takeLine(self: *Parser) ?View {
    if (self.isAtEnd()) return null;
    const line = self.takeUntilScalar('\n');
    _ = self.eat('\n');
    return line.chomp();
}

/// The contents of a `quote`-delimited string, with the quotes consumed and
/// the inner span returned *unescaped* - a `\` still protects the next byte
/// from ending the string, but no escape decoding is performed. Decoding is
/// left to the caller because the escape dialect is yours to define.
///
/// Null when the next byte is not `quote` (cursor unmoved); `UnexpectedEnd`
/// when the closing quote is missing.
pub fn takeQuoted(self: *Parser, quote: u8) Error!?View {
    if (!self.check(quote)) return null;
    const mark = self.save();
    self.index += 1;
    const start = self.index;
    while (self.index < self.input.len) {
        const c = self.input[self.index];
        if (c == '\\') {
            // Skip the escape and whatever it protects.
            self.index += if (self.index + 1 < self.input.len) 2 else 1;
            continue;
        }
        if (c == quote) {
            const body = self.input[start..self.index];
            self.index += 1;
            return .init(body);
        }
        self.index += 1;
    }
    self.restore(mark);
    return error.UnexpectedEnd;
}

// -------------------------------------------------------------------------
// Numbers
// -------------------------------------------------------------------------

/// Read an integer at the cursor. On failure the cursor does not move.
pub fn takeInt(self: *Parser, comptime T: type, options: number.IntOptions) number.ParseError!T {
    const scanned = try number.scanInt(T, self.input[self.index..], options);
    self.index += scanned.len;
    return scanned.value;
}

/// Read a float at the cursor. On failure the cursor does not move.
pub fn takeFloat(self: *Parser, comptime T: type, options: number.FloatOptions) number.ParseError!T {
    const scanned = try number.scanFloat(T, self.input[self.index..], options);
    self.index += scanned.len;
    return scanned.value;
}

/// Read `true` or `false` at the cursor, case-insensitively.
pub fn takeBool(self: *Parser) ?bool {
    const scanned = number.scanBool(self.input[self.index..]) orelse return null;
    self.index += scanned.len;
    return scanned.value;
}

// -------------------------------------------------------------------------
// Diagnostics
// -------------------------------------------------------------------------

pub const Location = struct {
    /// Byte offset from the start of the input.
    offset: usize,
    /// 1-based line number.
    line: usize,
    /// 1-based column, counted in codepoints so it matches what a reader sees.
    column: usize,

    /// Print with `{f}`, as `line:column`.
    pub fn format(self: Location, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ self.line, self.column });
    }
};

/// Where `offset` falls in the input. Costs a scan from the start, so call it
/// when reporting an error rather than in the parsing loop.
pub fn locationAt(self: *const Parser, offset: usize) Location {
    const upto = self.input[0..@min(offset, self.input.len)];
    var line: usize = 1;
    var line_start: usize = 0;
    for (upto, 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    var column: usize = 1;
    var it: utf8.Iterator = .init(upto[line_start..]);
    while (it.nextLossy()) |_| column += 1;
    return .{ .offset = offset, .line = line, .column = column };
}

/// Where the cursor currently is.
pub fn location(self: *const Parser) Location {
    return self.locationAt(self.index);
}

/// The whole line the cursor sits on, without its terminator. Useful for
/// printing a caret under the offending column.
pub fn currentLine(self: *const Parser) View {
    const i = @min(self.index, self.input.len);
    const start = if (std.mem.lastIndexOfScalar(u8, self.input[0..i], '\n')) |nl| nl + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, self.input, i, '\n') orelse self.input.len;
    return View.init(self.input[start..end]).chomp();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "position and movement" {
    var p: Parser = .init("abcdef");
    try testing.expect(!p.isAtEnd());
    try testing.expectEqualStrings("abcdef", p.rest().bytes);

    p.advance(2);
    try testing.expectEqualStrings("ab", p.consumed().bytes);
    try testing.expectEqualStrings("cdef", p.rest().bytes);

    p.advance(999); // clamped, not out of bounds
    try testing.expect(p.isAtEnd());
    p.reset();
    try testing.expectEqual(@as(usize, 0), p.index);
}

test "save and restore" {
    var p: Parser = .init("let x = 1");
    const mark = p.save();
    try testing.expect(p.eatSlice("let "));
    try testing.expectEqualStrings("x", p.takeIdentifier().?.bytes);
    p.restore(mark);
    try testing.expectEqualStrings("let x = 1", p.rest().bytes);
}

test "peeking never moves the cursor" {
    var p: Parser = .init("hello");
    try testing.expectEqual(@as(?u8, 'h'), p.peek());
    try testing.expectEqual(@as(?u8, 'l'), p.peekAt(2));
    try testing.expectEqual(@as(?u8, null), p.peekAt(99));
    try testing.expectEqualStrings("hel", p.peekSlice(3).?.bytes);
    try testing.expectEqual(@as(?View, null), p.peekSlice(99));
    try testing.expect(p.check('h'));
    try testing.expect(p.checkSlice("hell"));
    try testing.expectEqual(@as(usize, 0), p.index);
}

test "eat and expect" {
    var p: Parser = .init("key=value");
    try testing.expect(p.eatSlice("key"));
    try testing.expect(!p.eatSlice("key"));
    try p.expect('=');
    try testing.expectEqual(@as(?u8, 'v'), p.eatAny("xyzv"));
    try testing.expectEqual(@as(?u8, null), p.eatAny("xyz"));

    var q: Parser = .init("a");
    try testing.expectError(error.UnexpectedByte, q.expect('b'));
    try testing.expect(q.eat('a'));
    try testing.expectError(error.UnexpectedEnd, q.expect('a'));
    try testing.expectError(error.UnexpectedEnd, q.expectSlice("ab"));
}

test "next and nextCodepoint" {
    var p: Parser = .init("a\u{00E9}");
    try testing.expectEqual(@as(?u8, 'a'), p.next());
    const d = (try p.nextCodepoint()).?;
    try testing.expectEqual(@as(u21, 0x00E9), d.codepoint);
    try testing.expect(p.isAtEnd());
    try testing.expectEqual(@as(?u8, null), p.next());

    var bad: Parser = .init("\xFF");
    try testing.expectError(error.InvalidStartByte, bad.nextCodepoint());
}

test "take spans" {
    var p: Parser = .init("abc123def");
    try testing.expectEqualStrings("abc", p.takeWhile(ascii.isAlphabetic).bytes);
    try testing.expectEqualStrings("123", p.takeWhile(ascii.isDigit).bytes);
    try testing.expectEqualStrings("", p.takeWhile(ascii.isDigit).bytes);
    try testing.expectEqualStrings("def", p.takeRest().bytes);

    var q: Parser = .init("aab!!");
    try testing.expectEqualStrings("aab", q.takeWhileAny("ab").bytes);
    try testing.expectEqualStrings("!!", q.takeRest().bytes);

    var r: Parser = .init("abc");
    try testing.expectEqualStrings("ab", r.take(2).?.bytes);
    try testing.expectEqual(@as(?View, null), r.take(2));
}

test "take until" {
    var p: Parser = .init("name: value");
    try testing.expectEqualStrings("name", p.takeUntilScalar(':').bytes);
    try testing.expectEqual(@as(?u8, ':'), p.peek());

    var q: Parser = .init("no delimiter here");
    try testing.expectEqualStrings("no delimiter here", q.takeUntilScalar(';').bytes);
    try testing.expect(q.isAtEnd());

    var r: Parser = .init("head<!--tail");
    try testing.expectEqualStrings("head", r.takeUntilSlice("<!--").?.bytes);
    try testing.expect(r.checkSlice("<!--"));
    try testing.expectEqual(@as(?View, null), r.takeUntilSlice("zzz"));

    var s: Parser = .init("abc,def");
    try testing.expectEqualStrings("abc", s.takeUntilAny(",;").bytes);
}

test "skipping" {
    var p: Parser = .init("  \n\t x");
    try testing.expectEqual(@as(usize, 5), p.skipWhitespace());
    try testing.expectEqual(@as(?u8, 'x'), p.peek());

    var q: Parser = .init("  \n x");
    try testing.expectEqual(@as(usize, 2), q.skipInlineWhitespace());
    try testing.expectEqual(@as(?u8, '\n'), q.peek());
}

test "identifiers" {
    var p: Parser = .init("_foo9 bar");
    try testing.expectEqualStrings("_foo9", p.takeIdentifier().?.bytes);
    try testing.expectEqual(@as(?View, null), p.takeIdentifier()); // on a space
    _ = p.skipWhitespace();
    try testing.expectEqualStrings("bar", p.takeIdentifier().?.bytes);

    var q: Parser = .init("9lives");
    try testing.expectEqual(@as(?View, null), q.takeIdentifier());
    try testing.expectEqual(@as(usize, 0), q.index);
}

test "lines" {
    var p: Parser = .init("one\r\ntwo\nthree");
    try testing.expectEqualStrings("one", p.takeLine().?.bytes);
    try testing.expectEqualStrings("two", p.takeLine().?.bytes);
    try testing.expectEqualStrings("three", p.takeLine().?.bytes);
    try testing.expectEqual(@as(?View, null), p.takeLine());
}

test "quoted strings" {
    var p: Parser = .init("\"hello\" rest");
    try testing.expectEqualStrings("hello", (try p.takeQuoted('"')).?.bytes);
    try testing.expectEqualStrings(" rest", p.rest().bytes);

    // A backslash protects the quote that follows it.
    var esc: Parser = .init("\"a\\\"b\"");
    try testing.expectEqualStrings("a\\\"b", (try esc.takeQuoted('"')).?.bytes);
    try testing.expect(esc.isAtEnd());

    var unterminated: Parser = .init("\"oops");
    try testing.expectError(error.UnexpectedEnd, unterminated.takeQuoted('"'));
    try testing.expectEqual(@as(usize, 0), unterminated.index); // cursor restored

    var not_quoted: Parser = .init("bare");
    try testing.expectEqual(@as(?View, null), try not_quoted.takeQuoted('"'));
}

test "numbers" {
    var p: Parser = .init("42 -1.5 0xFF true");
    try testing.expectEqual(@as(u32, 42), try p.takeInt(u32, .{}));
    _ = p.skipWhitespace();
    try testing.expectEqual(@as(f64, -1.5), try p.takeFloat(f64, .{}));
    _ = p.skipWhitespace();
    try testing.expectEqual(@as(u32, 255), try p.takeInt(u32, .{}));
    _ = p.skipWhitespace();
    try testing.expectEqual(@as(?bool, true), p.takeBool());
    try testing.expect(p.isAtEnd());
}

test "a failed number leaves the cursor alone" {
    var p: Parser = .init("abc");
    try testing.expectError(error.NoDigits, p.takeInt(u32, .{}));
    try testing.expectEqual(@as(usize, 0), p.index);
}

test "locations" {
    var p: Parser = .init("one\ntwo\nthr\u{00E9}e");
    _ = p.takeLine();
    const l2 = p.location();
    try testing.expectEqual(@as(usize, 2), l2.line);
    try testing.expectEqual(@as(usize, 1), l2.column);
    try testing.expectFmt("2:1", "{f}", .{l2});

    _ = p.takeLine();
    p.advance(5); // past the 2-byte e-acute on line 3
    const l3 = p.location();
    try testing.expectEqual(@as(usize, 3), l3.line);
    try testing.expectEqual(@as(usize, 5), l3.column); // codepoints, not bytes
    try testing.expectEqualStrings("thr\u{00E9}e", p.currentLine().bytes);
}

test "a small key=value parser" {
    const Entry = struct { key: []const u8, value: []const u8 };
    var entries: [3]Entry = undefined;
    var n: usize = 0;

    var p: Parser = .init("host = localhost\nport= 8080\n# comment\nquiet =true\n");
    while (!p.isAtEnd()) {
        _ = p.skipWhitespace();
        if (p.isAtEnd()) break;
        if (p.eat('#')) {
            _ = p.takeLine();
            continue;
        }
        const key = p.takeIdentifier().?;
        _ = p.skipInlineWhitespace();
        try p.expect('=');
        _ = p.skipInlineWhitespace();
        const value = p.takeUntilScalar('\n');
        entries[n] = .{ .key = key.bytes, .value = value.trim().bytes };
        n += 1;
    }

    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("host", entries[0].key);
    try testing.expectEqualStrings("localhost", entries[0].value);
    try testing.expectEqualStrings("port", entries[1].key);
    try testing.expectEqualStrings("8080", entries[1].value);
    try testing.expectEqualStrings("quiet", entries[2].key);
    try testing.expectEqualStrings("true", entries[2].value);
}
