# Fluxion Text

A UTF-8 string toolkit for Zig 0.16. Eleven pieces that fit together:

| Module | What it is |
| --- | --- |
| `View` | An immutable, non-owning window onto bytes. Slicing, searching, splitting, trimming — all without copying. |
| `Builder` | A growable, owning buffer that is also a `std.Io.Writer`. |
| `Parser` | A cursor for hand-written parsers and lexers, with `peek` / `eat` / `expect` / `take` families and line-column diagnostics. |
| `utf8` | Encode, decode, validate, iterate, and boundary math. |
| `number` | Integer, float and bool scanning that reports how many bytes it consumed. |
| `Interner` | String interning: text in, a 4-byte `StringId` out. |
| `Fixed(n)` | A string held inline with no allocator at all. Safe as a hash-map key. |
| `path` | Virtual asset paths: `basename`, `stem`, `extension`, `join`, `normalize`. |
| `pattern` | Glob matching: `textures/*.png`, `**/*.wav`, `[0-9]`. |
| `fuzzy` | Command-palette ranking and "did you mean?" suggestions. |
| `wrap` | Word wrapping measured by your own font metrics. |

Nothing here allocates unless it takes an `Allocator`, and everything that
allocates documents who owns the result.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-text
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_text = .{ .path = "../fluxion-text" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_text", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_text", fluxion.module("fluxion_text"));
```

```zig
const text = @import("fluxion_text");
```

## Tour

### View — read without copying

```zig
const line: text.View = .init("  host = localhost  ");
const pair = line.trim().splitOnce("=").?;
// pair.before.trim() == "host", pair.after.trim() == "localhost"
```

`View` is a `[]const u8` with a vocabulary attached. Every operation returns
another `View` into the *same* bytes, so lifetime is your responsibility: a
`View` is valid for exactly as long as the memory behind it.

Offsets are byte offsets. When you need to respect character boundaries there
is `truncateBytes`, which backs off to the nearest one:

```zig
const label: text.View = .init("café 漢字");   // 12 bytes, 7 codepoints
label.truncateBytes(5);                        // "café" — never a split character
```

Also: `startsWith`, `endsWith`, `contains`, `indexOf`, `lastIndexOf`,
`indexOfAny`, `count`, `trim`, `trimChars`, `chomp`, `stripPrefix`,
`stripSuffix`, `split`, `splitScalar`, `splitAny`, `words`, `lines`,
`splitOnce`, `splitLastOnce`, `codepoints`, `order`, `hash`, `toOwned`.

### Builder — write and edit

```zig
var b: text.Builder = .init(gpa);
defer b.deinit();

try b.append("hello");
try b.print(", {s}!", .{"world"});
try b.appendCodepoint('🐢');
_ = try b.replaceAll("hello", "goodbye");

const owned = try b.toOwnedSlice();   // caller owns; builder is empty and reusable
defer gpa.free(owned);
```

The builder carries its own allocator, so calls read as `b.append("x")` rather
than `b.append(gpa, "x")`. It also exposes a `std.Io.Writer`, so anything in
the standard library that writes to a stream can write into it:

```zig
const w = b.writer();
try w.print("{d} items", .{count});
```

Editing is in-place: `insert`, `replaceRange`, `remove`, `replaceAll`,
`truncate`, `pop`, `trimEnd`, `clear`.

### Parser — walk the text

```zig
var p: text.Parser = .init("retries = 0x1F  # comment");

_ = p.skipWhitespace();
const key = p.takeIdentifier().?;      // "retries"
_ = p.skipInlineWhitespace();
try p.expect('=');
_ = p.skipInlineWhitespace();
const value = try p.takeInt(u32, .{}); // 31, base detected from the 0x prefix
```

Four families of method:

- `peek*` — look without moving
- `eat*` — move if it matches, report whether it did
- `expect*` — move if it matches, fail if it does not
- `take*` — consume a run of bytes and return the span

Speculative parsing uses `save` / `restore`:

```zig
const mark = p.save();
if (p.takeInt(i64, .{})) |n| {
    if (p.check('.')) p.restore(mark);  // actually a float, back out
} else |_| {}
```

For errors, `location()` gives a 1-based line and column (counted in
codepoints, so it matches what a reader sees) and `currentLine()` gives the
whole line for printing a caret underneath.

### utf8 — the byte level

```zig
var it = utf8.Iterator.init(bytes);
while (try it.next()) |cp| { ... }        // strict: malformed input is an error
while (it.nextLossy()) |cp| { ... }       // substitutes U+FFFD, never fails
```

Decoding rejects overlong encodings, surrogate halves and out-of-range
codepoints, so a successful result is always a valid scalar value. The
boundary helpers — `isBoundary`, `floorBoundary`, `ceilBoundary`,
`byteIndexOfCodepoint` — are what you want before slicing at a computed offset.

### number — parse in the middle of something

`std.fmt.parseInt` answers "is this whole slice a number?". When walking a
document you usually need the other question, so every routine comes in two
flavours:

```zig
const r = try number.scanInt(u32, "123abc", .{});  // r.value == 123, r.len == 3
try number.parseInt(u32, "123abc", .{});           // error.TrailingBytes
```

Handles sign, `_` separators, and `0x` / `0o` / `0b` prefixes. Floats get
`scanFloat` / `parseFloat`, including `inf` and `nan`. Edge cases are decided
so that scanning always makes sensible progress: `"1_"` scans as `1`, `"1e"`
scans as `1`, and a bare `"0x"` scans as `0`.

### Interner — text in, integer out

```zig
var interner: text.Interner = .init(gpa);
defer interner.deinit();

const a = try interner.intern("player.health");
const b = try interner.intern("player.health");
// a == b, comparison is now an integer compare

interner.resolve(a);  // "player.health"
```

Ids are handed out in insertion order and stay valid for the interner's
lifetime. The text lives in an internal arena, so `resolve` results are
pointer-stable — you do not free them yourself. `find` and `contains` look up
without interning.

### Fixed — a string with no allocator

```zig
const Name = text.Fixed(32);

var label: Name = .empty;
try label.print("enemy_{d}", .{id});

// Or fail loudly at compile time if it could never fit:
const tag = Name.fromLiteral("player.health");
```

`Fixed(n)` stores its bytes in the value itself. Nothing to free, nothing to
outlive, and it copies like an integer — so it can sit in a component array or
cross a thread boundary without ceremony. Overflow is an `error.Overflow`
rather than a reallocation, and `initTruncating` cuts on a UTF-8 boundary when
you would rather clamp than fail.

The unused tail is always zeroed, which means two `Fixed` values holding the
same text are byte-for-byte identical. That is what makes this safe:

```zig
var names: std.AutoHashMapUnmanaged(Name, Entity) = .empty;
```

### path — asset paths

```zig
path.stem("textures/ui/cursor.png");         // "cursor"
path.extension("textures/ui/cursor.png");    // ".png"
path.hasExtension("CURSOR.PNG", "png");      // true

var buf: [256]u8 = undefined;
try path.normalizeBuf(&buf, "assets\\textures\\..\\ui\\cursor.png");
// "assets/ui/cursor.png"
```

Deliberately *not* `std.fs.path`. A game's asset paths are a platform-
independent namespace, so output is always `/`, `\` is accepted on input
because that is what Windows hands you, and nothing here touches the disk.
`normalize` resolves `.` and `..`, and refuses to let an absolute path escape
its own root — usually a sign of a malformed asset id.

### pattern — globs

```zig
pattern.match("*.png", "cursor.png");                    // true
pattern.matchPath("textures/*.png", "textures/ui/x.png"); // false, * stops at /
pattern.matchPath("**/*.wav", "sounds/sfx/hit.wav");      // true
pattern.match("tile_[0-9][0-9].png", "tile_07.png");      // true
```

Supports `*`, `?`, `[a-z]`, `[!abc]` and `\` escapes. `matchPath` is the
gitignore-style mode where `*` stays inside one component and `**` spans them.
Matching is iterative, never recursive, so a hostile pattern cannot blow the
stack or go exponential.

### fuzzy — consoles

```zig
var buf: [8]fuzzy.Ranked = undefined;
const hits = fuzzy.rank("spwn", &commands, &buf, .{});
// commands[hits[0].index] == "spawn_enemy"

const suggestion = try fuzzy.closest("screenshto", &commands, 2);
// "did you mean screenshot?"
```

`score` ranks candidates as the user types, favouring consecutive runs, word
starts (including camelCase) and prefixes. `editDistance` bails out as soon as
it passes the budget you give it, because a suggestion prompt only cares about
near misses. Neither allocates; `rank` writes into a buffer you own.

### wrap — UI text

```zig
var it = wrap.iterator(message, .{ .width = 40 });
while (it.next()) |line| drawText(line.bytes);
```

The width budget is measured by a function you supply, because an engine knows
its own font. Return a glyph advance in pixels and you wrap to a text box:

```zig
fn advance(cp: u21) u16 { return font.glyph(cp).advance; }
wrap.iterator(message, .{ .width = box_width_px, .measure = advance });
```

`wrap.monospace` is built in for the terminal case, where CJK characters take
two cells and combining marks take none. Lines are views into the original
text, so wrapping costs no allocation.

## Everything together

```zig
var interner: text.Interner = .init(gpa);
defer interner.deinit();

var p = text.parse("  retries = 0x1F  # inline comment\n");
_ = p.skipWhitespace();

const key = try interner.internView(p.takeIdentifier().?);
_ = p.skipInlineWhitespace();
try p.expect('=');
_ = p.skipInlineWhitespace();
const value = try p.takeInt(u32, .{});

// interner.resolve(key) == "retries", value == 31
// p.rest().trim() == "# inline comment", still a view into the original input
```

## Build

```bash
zig build test        # run the test suite
zig build example     # build and run the demo tour
zig build docs        # generate API docs into zig-out/docs
```

## Requirements

Zig 0.16.0.

## License

`SPDX-License-Identifier: CC0-1.0`

[CC0 1.0 Universal](LICENSE) — public domain dedication. Do whatever you like
with this, no attribution required.
