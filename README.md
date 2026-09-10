# Fluxion Text

A UTF-8 string toolkit for C3 0.8. Eleven pieces that fit together:

| Module | What it is |
| --- | --- |
| `view` | An immutable, non-owning window onto bytes. Slicing, searching, splitting, trimming - all without copying. |
| `builder` | A growable, owning buffer that is also an `OutStream`. |
| `parser` | A cursor for hand-written parsers and lexers, with `peek` / `eat` / `expect` / `take` families and line-column diagnostics. |
| `utf8` | Encode, decode, validate, iterate, and boundary math. |
| `number` | Integer, float and bool scanning that reports how many bytes it consumed. |
| `interner` | String interning: text in, a 4-byte `StringId` out. |
| `fixed` | `Fixed{N}`, a string held inline with no allocator at all. Safe as a hash-map key. |
| `path` | Virtual asset paths: `basename`, `stem`, `extension`, `join`, `normalize`. |
| `pattern` | Glob matching: `textures/*.png`, `**/*.wav`, `[0-9]`. |
| `fuzzy` | Command-palette ranking and "did you mean?" suggestions. |
| `wrap` | Word wrapping measured by your own font metrics. |

Nothing here allocates unless it takes an `Allocator`, and everything that
allocates documents who owns the result.

## Install

The library is the `fluxion_text.c3l` directory in this repository. For a
checkout next to your project, add to `project.json`:

```json
"dependency-search-paths": ["../fluxion-text"],
"dependencies": ["fluxion_text"]
```

Then, in the code:

```c3
import fluxion::text;
```

One import is the whole library: C3 imports a module's sub-modules with it, so
`View`, `Parser`, `Builder`, `Interner` and the rest are all in scope from that
line.

## Tour

Every routine that takes options takes a struct, and every option is named so
that zero is the default: `{}` is "the defaults", `{ .ignore_case = true }`
changes one thing. The options parameter can be left off altogether.

### view - read without copying

```c3
View line = text::of("  host = localhost  ");
Pair pair = line.trim().split_once("=")!;
// pair.before.trim() is "host", pair.after.trim() is "localhost"
```

`View` is a `char[]` with a vocabulary attached. Every operation returns
another `View` into the *same* bytes, so lifetime is your responsibility: a
`View` is valid for exactly as long as the memory behind it.

Offsets are byte offsets. When you need to respect character boundaries there
is `truncate_bytes`, which backs off to the nearest one:

```c3
View label = text::of("café 漢字");   // 12 bytes, 7 codepoints
label.truncate_bytes(5);              // "café" - never a split character
```

Splitting is one `Splitter` with three modes rather than three iterator types,
and it ends on a fault so that `while (try ...)` is the loop:

```c3
Splitter it = line.split(",");
while (try piece = it.next()) { ... }
```

Also: `starts_with`, `ends_with`, `contains`, `index_of`, `last_index_of`,
`index_of_any`, `count`, `trim`, `trim_chars`, `chomp`, `strip_prefix`,
`strip_suffix`, `split_any`, `tokenize`, `words`, `lines`, `split_once`,
`split_last_once`, `codepoints`, `compare_to`, `hash`, `copy`.

### builder - write and edit

```c3
Builder b = text::build(mem);
defer b.free();

b.append("hello");
b.printf(", %s!", "world");
b.append_codepoint(0x1F422)!;
b.replace_all("hello", "goodbye");

String owned = b.to_owned(mem);   // a copy the caller owns
defer free(owned);
```

The builder carries its own allocator, so calls read as `b.append("x")` rather
than `b.append(gpa, "x")`. It is also an `OutStream`, so anything in the
standard library that writes to a stream can write into it:

```c3
io::fprintf(&b, "%d items", count)!;
```

Editing is in place: `insert`, `replace_range`, `remove`, `replace_all`,
`truncate`, `pop`, `trim_end`, `clear`.

One difference from the Zig original: `to_owned` copies rather than handing
the buffer over, because the `DString` underneath owns one allocation and
giving it away would leave the builder holding a pointer it no longer owns.

### parser - walk the text

```c3
Parser p = text::parse("retries = 0x1F  # comment");

p.skip_whitespace();
View key = p.take_identifier()!;      // "retries"
p.skip_inline_whitespace();
p.expect('=')!;
p.skip_inline_whitespace();
uint value = p.take_int(uint)!;       // 31, base detected from the 0x prefix
```

Four families of method:

- `peek_*` - look without moving
- `eat_*` - move if it matches, report whether it did
- `expect_*` - move if it matches, fail if it does not
- `take_*` - consume a run of bytes and return the span

Speculative parsing uses `save` / `restore`:

```c3
Mark mark = p.save();
if (try n = p.take_int(long))
{
    if (p.check('.')) p.restore(mark);  // actually a float, back out
}
```

For errors, `location()` gives a 1-based line and column (counted in
codepoints, so it matches what a reader sees) and `current_line()` gives the
whole line for printing a caret underneath.

### utf8 - the byte level

```c3
CodepointIterator it;
it.init(bytes);
while (try d = it.next()) { ... }        // strict: malformed input is a fault
while (try d = it.next_lossy()) { ... }  // substitutes U+FFFD, only stops at the end
```

Decoding rejects overlong encodings, surrogate halves and out-of-range
codepoints, so a successful result is always a valid scalar value. That
checking is why this module decodes by hand rather than calling the standard
library: `conv::utf8_to_char32` accepts an overlong encoding, and a decoder
that lets one through hands the rest of the program text it cannot re-encode.

The boundary helpers - `is_boundary`, `floor_boundary`, `ceil_boundary`,
`byte_index_of_codepoint` - are what you want before slicing at a computed
offset.

### number - parse in the middle of something

`String.to_int` answers "is this whole slice a number?". When walking a
document you usually need the other question, so every routine comes in two
flavours:

```c3
Scanned{uint} r = number::scan_int(uint, "123abc")!;  // r.value 123, r.len 3
number::parse_int(uint, "123abc");                    // TRAILING_BYTES
```

Handles sign, `_` separators, and `0x` / `0o` / `0b` prefixes. Floats get
`scan_float` / `parse_float`, including `inf` and `nan`. Edge cases are decided
so that scanning always makes sensible progress: `"1_"` scans as `1`, `"1e"`
scans as `1`, and a bare `"0x"` scans as `0`.

Overflow is checked on every digit rather than at the end, because C3 integer
arithmetic wraps silently and a scan that wrapped would report a value it never
read.

### interner - text in, integer out

```c3
Interner symbols;
symbols.init(mem);
defer symbols.free();

StringId a = symbols.intern("player.health");
StringId b = symbols.intern("player.health");
// a.equals(b), and comparison is now an integer compare

symbols.resolve(a);  // "player.health"
```

Ids are handed out in insertion order and stay valid for the interner's
lifetime. The text lives in blocks the interner owns and never moves, so
`resolve` results are pointer-stable - you do not free them yourself. `find`
and `contains` look up without interning.

### fixed - a string with no allocator

```c3
alias Name = Fixed{32};

Name label;
label.appendf("enemy_%d", id)!;
```

`Fixed{N}` stores its bytes in the value itself. Nothing to free, nothing to
outlive, and it copies like an integer - so it can sit in a component array or
cross a thread boundary without ceremony. Overflow is a fault rather than a
reallocation, and `set_truncating` cuts on a UTF-8 boundary when you would
rather clamp than fail.

The unused tail is always zeroed, which means two `Fixed` values holding the
same text are byte-for-byte identical. That is what makes this safe:

```c3
HashMap{Name, Entity} names;
```

### path - asset paths

```c3
path::stem("textures/ui/cursor.png");         // "cursor"
path::extension("textures/ui/cursor.png");    // ".png"
path::has_extension("CURSOR.PNG", "png");     // true

char[256] buf;
path::normalize_buf(&buf, "assets\\textures\\..\\ui\\cursor.png")!;
// "assets/ui/cursor.png"
```

Deliberately *not* the standard library's path module. A game's asset paths are
a platform-independent namespace, so output is always `/`, `\` is accepted on
input because that is what Windows hands you, and nothing here touches the
disk. `normalize` resolves `.` and `..`, and refuses to let an absolute path
escape its own root - usually a sign of a malformed asset id.

### pattern - globs

```c3
pattern::match("*.png", "cursor.png");                     // true
pattern::match_path("textures/*.png", "textures/ui/x.png"); // false, * stops at /
pattern::match_path("**/*.wav", "sounds/sfx/hit.wav");      // true
pattern::match("tile_[0-9][0-9].png", "tile_07.png");       // true
```

Supports `*`, `?`, `[a-z]`, `[!abc]` and `\` escapes. `match_path` is the
gitignore-style mode where `*` stays inside one component and `**` spans them.
Matching is iterative, never recursive, so a hostile pattern cannot blow the
stack or go exponential.

### fuzzy - consoles

```c3
Ranked[8] buf;
Ranked[] hits = fuzzy::rank("spwn", commands, &buf);
// commands[hits[0].index] is "spawn_enemy"

Match suggestion = fuzzy::closest("screenshto", commands, 2)!;
// "did you mean screenshot?"
```

`score` ranks candidates as the user types, favouring consecutive runs, word
starts (including camelCase) and prefixes. `edit_distance` bails out as soon as
it passes the budget you give it, because a suggestion prompt only cares about
near misses. Neither allocates; `rank` writes into a buffer you own.

### wrap - UI text

```c3
LineWrapper it = wrap::wrapper(message, { .width = 40 });
while (try line = it.next()) draw_text(line.bytes);
```

The width budget is measured by a function you supply, because an engine knows
its own font. Return a glyph advance in pixels and you wrap to a text box:

```c3
fn ushort advance(Char32 cp) { return font.glyph(cp).advance; }
wrap::wrapper(message, { .width = box_width_px, .measure = &advance });
```

`wrap::monospace` is built in for the terminal case, where CJK characters take
two cells and combining marks take none. Lines are views into the original
text, so wrapping costs no allocation.

## Everything together

```c3
Interner symbols;
symbols.init(mem);
defer symbols.free();

Parser p = text::parse("  retries = 0x1F  # inline comment\n");
p.skip_whitespace();

StringId key = symbols.intern_view(p.take_identifier()!);
p.skip_inline_whitespace();
p.expect('=')!;
p.skip_inline_whitespace();
uint value = p.take_int(uint)!;

// symbols.resolve(key) is "retries", value is 31
// p.rest().trim() is "# inline comment", still a view into the original input
```

## Build

```bash
c3c test          # run the test suite
c3c run demo      # build and run the demo tour
```

## Layout

```
fluxion_text.c3l/manifest.json   what a consumer's build reads
src/                             the library, one module per file
examples/demo.c3                 the tour
project.json5                    this repository's own build: tests and the demo
```

## Requirements

C3 0.8.3.

## License

`SPDX-License-Identifier: CC0-1.0`

[CC0 1.0 Universal](LICENSE) - public domain dedication. Do whatever you like
with this, no attribution required.
