// SPDX-License-Identifier: CC0-1.0

// Fluxion Text - a UTF-8 string toolkit for C3.
//
// Eleven pieces that fit together, each its own module under `fluxion::text`:
//
//   `view`      an immutable, non-owning window onto bytes
//   `builder`   a growable, owning buffer that is also an `OutStream`
//   `parser`    a cursor for hand-written parsers and lexers
//   `utf8`      encode, decode, validate and boundary math
//   `number`    integer, float and bool scanning that reports what it consumed
//   `interner`  string interning, text in and a 4-byte `StringId` out
//   `fixed`     a string held inline, with no allocator at all
//   `path`      virtual asset paths: basename, stem, extension, join, normalize
//   `pattern`   glob matching, both the plain and the path-aware kind
//   `fuzzy`     command-palette ranking and "did you mean?" suggestions
//   `wrap`      word wrapping measured by your own font metrics
//
// Nothing here allocates unless it takes an `Allocator`, and everything that
// allocates says who owns the result.
//
// This module holds the shorthands. Importing `fluxion::text` imports the
// eleven sub-modules with it, so `View`, `Parser`, `Builder` and the rest are
// all in scope from one line.
module fluxion::text;
import fluxion::text::view, fluxion::text::builder, fluxion::text::parser;
import fluxion::text::utf8, fluxion::text::number, fluxion::text::interner;
import fluxion::text::fixed, fluxion::text::path, fluxion::text::pattern;
import fluxion::text::fuzzy, fluxion::text::wrap;

<*
 A view over `bytes`, so call sites read `text::of(s)`. Shorthand for
 `view::of`.
*>
fn View of(char[] bytes)
{
	return view::of(bytes);
}

<*
 A parser over `bytes`. Shorthand for `Parser.init`.
*>
fn Parser parse(char[] bytes)
{
	Parser p;
	p.init(bytes);
	return p;
}

<*
 A builder that allocates from `allocator`. Shorthand for `Builder.init`.
*>
fn Builder build(Allocator allocator)
{
	Builder b;
	b.init(allocator);
	return b;
}

<*
 Concatenate `pieces` with `separator` between them. Caller owns the result.
*>
fn String join(Allocator allocator, char[] separator, String[] pieces)
{
	Builder b;
	b.init(allocator);
	defer b.free();
	b.join(separator, pieces);
	return b.to_owned(allocator);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_the_pieces_compose() @test
{
	// Parse a line of config, intern the key, and render a normalised form.
	Interner symbols;
	symbols.init(mem);
	defer symbols.free();

	Parser p = parse("  retries = 0x1F  # inline comment\n");
	p.skip_whitespace();

	StringId key = symbols.intern_view(p.take_identifier()!!);
	p.skip_inline_whitespace();
	p.expect('=')!!;
	p.skip_inline_whitespace();
	uint value = p.take_int(uint)!!;

	test::eq(symbols.resolve(key), "retries");
	test::eq(value, 31U);

	Builder b = build(mem);
	defer b.free();
	b.printf("%s=%d", symbols.resolve(key), value);
	test::eq((String)b.items(), "retries=31");

	// The rest of the line is still there, as a view into the original input.
	test::eq(p.rest().trim().str(), "# inline comment");
}

fn void test_join() @test
{
	String joined = join(mem, " / ", { "usr", "local", "bin" });
	defer free(joined);
	test::eq(joined, "usr / local / bin");
}

fn void test_shorthands() @test
{
	test::@check(of("abc").equals_bytes("abc"));
	Parser p = parse("abc");
	test::eq(p.peek()!!, 'a');
}

fn void test_an_asset_pipeline_in_miniature() @test
{
	// The four path-shaped modules, used the way a loader would: normalise
	// what came in, filter it, name it, and rank it for a console.
	char[64] buf;
	char[] normalised = path::normalize_buf(&buf, "assets\\textures\\..\\ui\\cursor.PNG")!!;
	test::eq((String)normalised, "assets/ui/cursor.PNG");
	test::@check(path::has_extension(normalised, "png"));
	test::@check(pattern::match_path("assets/**/*.PNG", normalised));
	test::eq(path::stem(normalised).str(), "cursor");

	String[] loaded = { "assets/ui/cursor.PNG", "assets/ui/close.png" };
	Ranked[4] ranked;
	Ranked[] hits = fuzzy::rank("curs", loaded, &ranked);
	test::eq(hits.len, 1);
	test::eq(loaded[hits[0].index], "assets/ui/cursor.PNG");
}
