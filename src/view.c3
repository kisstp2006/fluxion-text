// SPDX-License-Identifier: CC0-1.0

// An immutable, non-owning window onto UTF-8 text.
//
// `View` is a `char[]` with a vocabulary attached. It never allocates and
// never copies: every slicing, trimming and splitting operation hands back
// another `View` into the *same* backing bytes. That makes it cheap to pass
// around, and it makes lifetime your responsibility - a `View` is only valid
// for as long as the memory it points at.
//
// Byte offsets, not codepoint offsets, are used throughout. Use `codepoints`
// or `truncate_bytes` when you need to respect UTF-8 boundaries.
//
// C3 already has `String`, which is a `char[]` with methods on it, and a
// `View` could have been an inline typedef of one. It is a struct instead so
// that the two never silently swap: a `String` in this library means text
// somebody owns, and a `View` means a window that outlives nothing.
module fluxion::text::view;
import fluxion::text::utf8;
import std::io;

struct View (Printable)
{
	char[] bytes;
}

// The default ASCII whitespace set used by `trim` and friends.
const String WHITESPACE = " \t\r\n\x0B\x0C";

// A view over nothing.
const View EMPTY = {};

<*
 The two halves produced by `split_once` / `split_last_once`.
*>
struct Pair
{
	View before;
	View after;
}

<*
 A view over `bytes`. The bytes are borrowed, not copied.
*>
fn View of(char[] bytes)
{
	return { .bytes = bytes };
}

// -------------------------------------------------------------------------
// Basics
// -------------------------------------------------------------------------

<*
 Length in bytes. For a count of characters, use `codepoint_len`.
*>
fn sz View.len(self)
{
	return self.bytes.len;
}

fn bool View.is_empty(self)
{
	return self.bytes.len == 0;
}

<*
 The text as a `String`, for handing to the standard library.
*>
fn String View.str(self)
{
	return (String)self.bytes;
}

// The index is past the end of the view.
faultdef OUT_OF_RANGE;

fn char? View.at(self, sz index)
{
	if (index >= self.bytes.len) return OUT_OF_RANGE~;
	return self.bytes[index];
}

fn char? View.first(self)
{
	return self.at(0);
}

fn char? View.last(self)
{
	if (self.bytes.len == 0) return OUT_OF_RANGE~;
	return self.bytes[^1];
}

<*
 Byte range `[start, end)`.

 @require start <= end && end <= self.bytes.len : "slice out of range"
*>
fn View View.slice(self, sz start, sz end)
{
	return { .bytes = self.bytes[start:end - start] };
}

<*
 @require start <= self.bytes.len : "slice out of range"
*>
fn View View.slice_from(self, sz start)
{
	return { .bytes = self.bytes[start..] };
}

<*
 @require end <= self.bytes.len : "slice out of range"
*>
fn View View.slice_to(self, sz end)
{
	return { .bytes = self.bytes[:end] };
}

// -------------------------------------------------------------------------
// Comparison
// -------------------------------------------------------------------------

fn bool View.equals(self, View other)
{
	return self.bytes == other.bytes;
}

<*
 Byte-for-byte equality against a raw slice, so callers can skip `of`.
*>
fn bool View.equals_bytes(self, char[] other)
{
	return self.bytes == other;
}

<*
 ASCII-only case folding. Does not handle non-ASCII case pairs.
*>
fn bool View.equals_ignore_case(self, View other)
{
	return self.str().compare_to_ignore_case(other.str()) == 0;
}

<*
 Negative, zero or positive, as `compare_to` is everywhere in C3.
*>
fn int View.compare_to(self, View other)
{
	return self.str().compare_to(other.str());
}

fn bool View.less(self, View other)
{
	return self.compare_to(other) < 0;
}

<*
 A 32-bit hash of the contents, which is the width `HashMap` asks a key for.
*>
fn uint View.hash(self)
{
	return self.bytes.hash();
}

// -------------------------------------------------------------------------
// Searching
// -------------------------------------------------------------------------

fn bool View.starts_with(self, char[] prefix)
{
	return self.str().starts_with((String)prefix);
}

fn bool View.ends_with(self, char[] suffix)
{
	return self.str().ends_with((String)suffix);
}

fn bool View.starts_with_ignore_case(self, char[] prefix)
{
	if (self.bytes.len < prefix.len) return false;
	return self.str()[:prefix.len].compare_to_ignore_case((String)prefix) == 0;
}

fn bool View.ends_with_ignore_case(self, char[] suffix)
{
	if (self.bytes.len < suffix.len) return false;
	return self.str()[^suffix.len..].compare_to_ignore_case((String)suffix) == 0;
}

fn bool View.contains(self, char[] needle)
{
	return self.str().contains((String)needle);
}

fn bool View.contains_char(self, char byte)
{
	return @ok(self.str().index_of_char(byte));
}

<*
 Offset of the first `needle`, or `NOT_FOUND`.
*>
fn sz? View.index_of(self, char[] needle)
{
	return self.str().index_of((String)needle) ?? NOT_FOUND~;
}

// The needle is not in the view.
faultdef NOT_FOUND;

<*
 Offset of the first `needle` at or after `start`.

 @require start <= self.bytes.len : "start out of range"
*>
fn sz? View.index_of_from(self, sz start, char[] needle)
{
	// `??` on a return hands back the fault; assigned to a plain `sz` it would
	// not compile, because the left side is still an optional at that point.
	sz? found = self.str()[start..].index_of((String)needle);
	if (catch found) return NOT_FOUND~;
	return start + found;
}

fn sz? View.last_index_of(self, char[] needle)
{
	return self.str().rindex_of((String)needle) ?? NOT_FOUND~;
}

fn sz? View.index_of_char(self, char byte)
{
	return self.str().index_of_char(byte) ?? NOT_FOUND~;
}

fn sz? View.last_index_of_char(self, char byte)
{
	return self.str().rindex_of_char(byte) ?? NOT_FOUND~;
}

<*
 Offset of the first byte that appears in `set`.
*>
fn sz? View.index_of_any(self, char[] set)
{
	foreach (i, c : self.bytes)
	{
		if (@ok(((String)set).index_of_char(c))) return i;
	}
	return NOT_FOUND~;
}

<*
 Offset of the first byte that does *not* appear in `set`.
*>
fn sz? View.index_of_none(self, char[] set)
{
	foreach (i, c : self.bytes)
	{
		if (!@ok(((String)set).index_of_char(c))) return i;
	}
	return NOT_FOUND~;
}

<*
 Number of non-overlapping occurrences of `needle`.
*>
fn sz View.count(self, char[] needle)
{
	if (needle.len == 0) return 0;
	sz n = 0;
	sz i = 0;
	while (i + needle.len <= self.bytes.len)
	{
		if (self.bytes[i:needle.len] == needle)
		{
			n++;
			i += needle.len;
		}
		else
		{
			i++;
		}
	}
	return n;
}

// -------------------------------------------------------------------------
// Trimming
// -------------------------------------------------------------------------

fn View View.trim(self)
{
	return self.trim_chars(WHITESPACE);
}

fn View View.trim_start(self)
{
	return self.trim_start_chars(WHITESPACE);
}

fn View View.trim_end(self)
{
	return self.trim_end_chars(WHITESPACE);
}

fn View View.trim_chars(self, char[] set)
{
	return self.trim_start_chars(set).trim_end_chars(set);
}

fn View View.trim_start_chars(self, char[] set)
{
	sz start = 0;
	while (start < self.bytes.len && @ok(((String)set).index_of_char(self.bytes[start]))) start++;
	return { .bytes = self.bytes[start..] };
}

fn View View.trim_end_chars(self, char[] set)
{
	sz end = self.bytes.len;
	while (end > 0 && @ok(((String)set).index_of_char(self.bytes[end - 1]))) end--;
	return { .bytes = self.bytes[:end] };
}

<*
 Drop one trailing line terminator, if present. Handles both "\n" and "\r\n".
*>
fn View View.chomp(self)
{
	char[] b = self.bytes;
	if (b.len > 0 && b[^1] == '\n') b = b[:^1];
	if (b.len > 0 && b[^1] == '\r') b = b[:^1];
	return { .bytes = b };
}

// The prefix or suffix asked for is not there.
faultdef NO_SUCH_AFFIX;

<*
 The remainder after `prefix`, or `NO_SUCH_AFFIX` if it is not there.
*>
fn View? View.strip_prefix(self, char[] prefix)
{
	if (!self.starts_with(prefix)) return NO_SUCH_AFFIX~;
	return { .bytes = self.bytes[prefix.len..] };
}

<*
 The remainder before `suffix`, or `NO_SUCH_AFFIX` if it is not there.
*>
fn View? View.strip_suffix(self, char[] suffix)
{
	if (!self.ends_with(suffix)) return NO_SUCH_AFFIX~;
	return { .bytes = self.bytes[:self.bytes.len - suffix.len] };
}

// -------------------------------------------------------------------------
// Splitting
// -------------------------------------------------------------------------

// The splitter has nothing left. As in `utf8`, this is the signal a
// `while (try ...)` loop stops on rather than an error.
faultdef NO_MORE_PIECES;

// How a `Splitter` decides where one piece ends.
enum Delimiter
{
	// The whole `delimiter` sequence, and empty pieces are kept.
	SEQUENCE,
	// Any single byte from `delimiter`, and empty pieces are kept.
	ANY,
	// Any single byte from `delimiter`, and runs of them are one break, so
	// no empty piece is ever produced.
	TOKENS,
}

<*
 Walks the pieces of a view. `next` yields each in turn and ends with
 `NO_MORE_PIECES`:

     Splitter it = line.split(",");
     while (try piece = it.next()) { ... }

 One struct rather than three iterator types, because the difference between
 them is one enum and the loop is the same either way.
*>
struct Splitter
{
	char[] bytes;
	char[] delimiter;
	Delimiter kind;
	sz index;
	// Set once the final piece has been handed out, so that `"a,"` yields
	// "a" and then the empty piece after it, and then stops.
	bool done;
}

fn View? Splitter.next(&self)
{
	if (self.done) return NO_MORE_PIECES~;

	if (self.kind == TOKENS)
	{
		// Skip the run of delimiters in front of the piece; a token splitter
		// never yields an empty one.
		while (self.index < self.bytes.len && self.is_delimiter_at(self.index)) self.index++;
		if (self.index >= self.bytes.len)
		{
			self.done = true;
			return NO_MORE_PIECES~;
		}
	}

	sz start = self.index;
	sz i = start;
	while (i < self.bytes.len)
	{
		if (self.is_delimiter_at(i))
		{
			self.index = i + (self.kind == SEQUENCE ? self.delimiter.len : 1);
			return { .bytes = self.bytes[start:i - start] };
		}
		i++;
	}

	self.done = true;
	self.index = self.bytes.len;
	return { .bytes = self.bytes[start..] };
}

fn bool Splitter.is_delimiter_at(&self, sz i)
{
	if (self.kind == SEQUENCE)
	{
		if (self.delimiter.len == 0) return false;
		if (i + self.delimiter.len > self.bytes.len) return false;
		return self.bytes[i:self.delimiter.len] == self.delimiter;
	}
	return @ok(((String)self.delimiter).index_of_char(self.bytes[i]));
}

<*
 The piece `next` would return, without consuming it.
*>
fn View? Splitter.peek(&self)
{
	Splitter copy = *self;
	return copy.next();
}

<*
 Everything not yet handed out, delimiters and all.
*>
fn View Splitter.rest(&self)
{
	return { .bytes = self.done ? self.bytes[self.bytes.len..] : self.bytes[self.index..] };
}

fn void Splitter.reset(&self)
{
	self.index = 0;
	self.done = false;
}

<*
 Split on every occurrence of the full sequence `delimiter`. Empty pieces are
 preserved: `"a,,b".split(",")` yields "a", "", "b".
*>
fn Splitter View.split(self, char[] delimiter)
{
	return { .bytes = self.bytes, .delimiter = delimiter, .kind = SEQUENCE };
}

<*
 Split on any single byte drawn from `delimiters`.
*>
fn Splitter View.split_any(self, char[] delimiters)
{
	return { .bytes = self.bytes, .delimiter = delimiters, .kind = ANY };
}

<*
 Like `split_any`, but runs of delimiters are one break and no empty piece is
 produced.
*>
fn Splitter View.tokenize(self, char[] delimiters)
{
	return { .bytes = self.bytes, .delimiter = delimiters, .kind = TOKENS };
}

<*
 Split into whitespace-separated words, skipping runs of whitespace.
*>
fn Splitter View.words(self)
{
	return self.tokenize(WHITESPACE);
}

<*
 Split at the first `delimiter`. `NOT_FOUND` when the delimiter is absent,
 which lets you tell "no separator" from "empty right-hand side".
*>
fn Pair? View.split_once(self, char[] delimiter)
{
	sz i = self.index_of(delimiter)!;
	return {
		.before = { .bytes = self.bytes[:i] },
		.after = { .bytes = self.bytes[i + delimiter.len..] },
	};
}

<*
 Split at the last `delimiter`.
*>
fn Pair? View.split_last_once(self, char[] delimiter)
{
	sz i = self.last_index_of(delimiter)!;
	return {
		.before = { .bytes = self.bytes[:i] },
		.after = { .bytes = self.bytes[i + delimiter.len..] },
	};
}

<*
 Iterate lines, accepting "\n" and "\r\n" and not yielding a phantom empty
 line for input that ends with a terminator.
*>
struct LineIterator
{
	char[] bytes;
	sz index;
}

fn View? LineIterator.next(&self)
{
	if (self.index >= self.bytes.len) return NO_MORE_PIECES~;
	sz start = self.index;
	sz end = self.bytes.len;
	foreach (i, c : self.bytes[start..])
	{
		if (c == '\n')
		{
			end = start + i;
			break;
		}
	}
	self.index = end < self.bytes.len ? end + 1 : self.bytes.len;
	char[] line = self.bytes[start:end - start];
	if (line.len > 0 && line[^1] == '\r') line = line[:^1];
	return { .bytes = line };
}

fn void LineIterator.reset(&self)
{
	self.index = 0;
}

fn LineIterator View.lines(self)
{
	return { .bytes = self.bytes };
}

// -------------------------------------------------------------------------
// UTF-8
// -------------------------------------------------------------------------

fn CodepointIterator View.codepoints(self)
{
	CodepointIterator it;
	it.init(self.bytes);
	return it;
}

fn sz? View.codepoint_len(self)
{
	return utf8::count_codepoints(self.bytes);
}

fn bool View.is_valid_utf8(self)
{
	return utf8::validate(self.bytes);
}

<*
 Shorten to at most `max_bytes`, backing off to the nearest codepoint
 boundary so the result is never a half-encoded character.
*>
fn View View.truncate_bytes(self, sz max_bytes)
{
	if (self.bytes.len <= max_bytes) return self;
	return { .bytes = self.bytes[:utf8::floor_boundary(self.bytes, max_bytes)] };
}

<*
 Codepoint range `[start, end)`.

 @require start <= end : "backwards codepoint range"
*>
fn View? View.slice_codepoints(self, sz start, sz end)
{
	sz from = utf8::byte_index_of_codepoint(self.bytes, start)!;
	sz to = utf8::byte_index_of_codepoint(self.bytes, end)!;
	return { .bytes = self.bytes[from:to - from] };
}

// -------------------------------------------------------------------------
// Escaping the view
// -------------------------------------------------------------------------

<*
 Copy the contents into freshly allocated memory owned by the caller.
*>
fn String View.copy(self, Allocator allocator)
{
	return self.str().copy(allocator);
}

<*
 Like `copy`, but NUL-terminated for C interop.
*>
fn ZString View.zstr_copy(self, Allocator allocator)
{
	return self.str().zstr_copy(allocator);
}

<*
 What `%s` prints: the text itself.
*>
fn sz? View.to_format(&self, Formatter* f) @dynamic
{
	return f.print(self.str());
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_basics() @test
{
	View v = of("hello");
	test::eq(v.len(), 5);
	test::@check(!v.is_empty());
	test::@check(EMPTY.is_empty());
	test::eq(v.first()!!, 'h');
	test::eq(v.last()!!, 'o');
	test::eq(v.at(1)!!, 'e');
	test::@error(v.at(5), OUT_OF_RANGE);
	test::eq(v.slice(1, 4).str(), "ell");
	test::eq(v.slice_from(2).str(), "llo");
	test::eq(v.slice_to(2).str(), "he");
}

fn void test_comparison() @test
{
	View a = of("Apple");
	test::@check(a.equals_bytes("Apple"));
	test::@check(!a.equals_bytes("apple"));
	test::@check(a.equals_ignore_case(of("aPPLe")));
	test::@check(a.compare_to(of("Banana")) < 0);
	test::@check(a.less(of("Banana")));
	test::eq(a.hash(), of("Apple").hash());
}

fn void test_searching() @test
{
	View v = of("the quick brown fox");
	test::@check(v.starts_with("the"));
	test::@check(v.ends_with("fox"));
	test::@check(v.starts_with_ignore_case("THE"));
	test::@check(v.ends_with_ignore_case("FOX"));
	test::@check(v.contains("quick"));
	test::@check(!v.contains("slow"));
	test::@check(v.contains_char('q'));

	test::eq(v.index_of("quick")!!, 4);
	test::@error(v.index_of("slow"), NOT_FOUND);
	test::eq(v.last_index_of("o")!!, 17);
	test::eq(v.index_of_from(5, "o")!!, 12);
	test::eq(v.index_of_char(' ')!!, 3);
	test::eq(v.last_index_of_char(' ')!!, 15);
	test::eq(v.index_of_any("xe")!!, 2);
	test::eq(v.index_of_none("the")!!, 3);
	test::eq(v.count(" "), 3);
}

fn void test_trimming() @test
{
	test::eq(of("  hi \n").trim().str(), "hi");
	test::eq(of("  hi \n").trim_start().str(), "hi \n");
	test::eq(of("  hi \n").trim_end().str(), "  hi");
	test::eq(of("xxhixx").trim_chars("x").str(), "hi");
	test::eq(of("xxhixx").trim_start_chars("x").str(), "hixx");
	test::eq(of("xxhixx").trim_end_chars("x").str(), "xxhi");

	test::eq(of("a\r\n").chomp().str(), "a");
	test::eq(of("a\n").chomp().str(), "a");
	test::eq(of("a").chomp().str(), "a");
}

fn void test_strip_prefix_and_suffix() @test
{
	View v = of("prefix-body-suffix");
	test::eq(v.strip_prefix("prefix-")!!.str(), "body-suffix");
	test::eq(v.strip_suffix("-suffix")!!.str(), "prefix-body");
	test::@error(v.strip_prefix("nope"), NO_SUCH_AFFIX);
	test::@error(v.strip_suffix("nope"), NO_SUCH_AFFIX);
}

fn void test_split_preserves_empty_pieces() @test
{
	Splitter it = of("a,,b").split(",");
	test::eq(it.next()!!.str(), "a");
	test::eq(it.next()!!.str(), "");
	test::eq(it.next()!!.str(), "b");
	test::@error(it.next(), NO_MORE_PIECES);
}

fn void test_split_on_a_sequence() @test
{
	Splitter it = of("a::b::c").split("::");
	test::eq(it.next()!!.str(), "a");
	test::eq(it.peek()!!.str(), "b");
	test::eq(it.next()!!.str(), "b");
	test::eq(it.rest().str(), "c");
}

fn void test_tokenize_skips_empty_pieces() @test
{
	Splitter it = of("  a  b  ").words();
	test::eq(it.next()!!.str(), "a");
	test::eq(it.next()!!.str(), "b");
	test::@error(it.next(), NO_MORE_PIECES);
}

fn void test_split_once_distinguishes_missing_from_empty() @test
{
	Pair p = of("key=value=extra").split_once("=")!!;
	test::eq(p.before.str(), "key");
	test::eq(p.after.str(), "value=extra");

	Pair q = of("key=value=extra").split_last_once("=")!!;
	test::eq(q.before.str(), "key=value");
	test::eq(q.after.str(), "extra");

	Pair r = of("key=").split_once("=")!!;
	test::eq(r.after.str(), "");
	test::@error(of("key").split_once("="), NOT_FOUND);
}

fn void test_lines_handles_crlf_and_no_trailing_newline() @test
{
	LineIterator it = of("one\r\ntwo\nthree").lines();
	test::eq(it.next()!!.str(), "one");
	test::eq(it.next()!!.str(), "two");
	test::eq(it.next()!!.str(), "three");
	test::@error(it.next(), NO_MORE_PIECES);

	LineIterator trailing = of("one\n").lines();
	test::eq(trailing.next()!!.str(), "one");
	test::@error(trailing.next(), NO_MORE_PIECES);

	LineIterator blank = of("a\n\nb").lines();
	test::eq(blank.next()!!.str(), "a");
	test::eq(blank.next()!!.str(), "");
	test::eq(blank.next()!!.str(), "b");
}

fn void test_utf8_aware_operations() @test
{
	View v = of("aé漢");
	test::eq(v.len(), 6);
	test::eq(v.codepoint_len()!!, 3);
	test::@check(v.is_valid_utf8());

	// A naive slice_to(2) would cut the 2-byte 'e-acute' in half.
	test::eq(v.truncate_bytes(2).str(), "a");
	test::eq(v.truncate_bytes(3).str(), "aé");
	test::eq(v.truncate_bytes(99).str(), "aé漢");

	test::eq(v.slice_codepoints(1, 2)!!.str(), "é");
	test::@error(v.slice_codepoints(1, 9), utf8::NO_SUCH_CODEPOINT);

	CodepointIterator it = v.codepoints();
	test::eq(it.next()!!.codepoint, (Char32)'a');
}

fn void test_copy_and_format() @test
{
	View v = of("copy me");
	String owned = v.copy(mem);
	defer free(owned);
	test::eq(owned, "copy me");

	@pool()
	{
		test::eq(string::tformat("[%s]", v), "[copy me]");
	};
}
