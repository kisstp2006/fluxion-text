// SPDX-License-Identifier: CC0-1.0

// A growable, owning UTF-8 buffer.
//
// `Builder` is the mutable counterpart to `View`. It holds an allocator, so
// calls read as `b.append("x")` rather than `b.append(gpa, "x")`, and it is an
// `OutStream`, so anything in the standard library that writes to a stream can
// write into it.
//
// Call `free` when you are done, or hand the memory off with `to_owned`, which
// leaves the builder empty and reusable.
//
// It is a thin layer over the standard library's `DString`, which already owns
// a growable buffer and implements `OutStream`. What this adds is the
// vocabulary the rest of Fluxion Text uses - `View`s in and out, codepoints,
// UTF-8 aware editing - so that a caller never has to change idiom half way
// through a function.
module fluxion::text::builder;
import fluxion::text::view, fluxion::text::utf8;
import std::io;

struct Builder (OutStream, Printable)
{
	Allocator allocator;
	DString buffer;
}

<*
 A builder that will allocate from `allocator` as it grows.
*>
fn void Builder.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.buffer.init(allocator);
}

<*
 The same, with room for `initial_capacity` bytes reserved up front.
*>
fn void Builder.init_with_capacity(&self, Allocator allocator, sz initial_capacity)
{
	self.allocator = allocator;
	self.buffer = dstring::new_with_capacity(allocator, (usz)initial_capacity);
}

<*
 A builder pre-loaded with a copy of `bytes`.
*>
fn void Builder.init_from(&self, Allocator allocator, char[] bytes)
{
	self.init_with_capacity(allocator, bytes.len);
	self.buffer.append_bytes(bytes);
}

fn void Builder.free(&self)
{
	self.buffer.free();
	*self = {};
}

// -------------------------------------------------------------------------
// Inspecting
// -------------------------------------------------------------------------

fn sz Builder.len(&self)
{
	return (sz)self.buffer.len();
}

fn bool Builder.is_empty(&self)
{
	return self.buffer.len() == 0;
}

fn sz Builder.capacity(&self)
{
	return (sz)self.buffer.capacity();
}

<*
 The bytes written so far. Invalidated by any call that can reallocate.
*>
fn char[] Builder.items(&self)
{
	return self.buffer.str_view();
}

<*
 A borrowed `View` of the contents. Same invalidation rules as `items`.
*>
fn View Builder.view(&self)
{
	return view::of(self.items());
}

fn char? Builder.at(&self, sz index)
{
	if (index >= self.len()) return view::OUT_OF_RANGE~;
	return self.items()[index];
}

// -------------------------------------------------------------------------
// Capacity
// -------------------------------------------------------------------------

fn void Builder.reserve(&self, sz additional)
{
	self.buffer.reserve((usz)additional);
}

// -------------------------------------------------------------------------
// Appending
// -------------------------------------------------------------------------

fn void Builder.append(&self, char[] bytes)
{
	self.buffer.append_bytes(bytes);
}

fn void Builder.append_byte(&self, char byte)
{
	self.buffer.append_char(byte);
}

fn void Builder.append_repeat(&self, char byte, sz n)
{
	self.buffer.append_char_repeat(byte, (usz)n);
}

fn void Builder.append_view(&self, View v)
{
	self.append(v.bytes);
}

<*
 Append the UTF-8 encoding of `codepoint`. A surrogate half or an
 out-of-range codepoint is a fault, not a replacement character: this is the
 encoding path, and text that cannot be encoded should not be invented.
*>
fn void? Builder.append_codepoint(&self, Char32 codepoint)
{
	Sequence seq = utf8::encode_sequence(codepoint)!;
	self.append(seq.slice());
}

<*
 Append `bytes` followed by a newline.
*>
fn void Builder.append_line(&self, char[] bytes)
{
	self.append(bytes);
	self.append_byte('\n');
}

<*
 Append formatted output, with the same `%s` / `%d` syntax as `io::printfn`.
*>
fn void Builder.printf(&self, String format, args...)
{
	self.buffer.appendf(format, ...args)!!;
}

<*
 Append each of `pieces` with `separator` between them.
*>
fn void Builder.join(&self, char[] separator, String[] pieces)
{
	foreach (i, piece : pieces)
	{
		if (i != 0) self.append(separator);
		self.append(piece);
	}
}

// -------------------------------------------------------------------------
// Editing
// -------------------------------------------------------------------------

<*
 Insert `bytes` at `index`.

 @require index <= self.len() : "insert past the end"
*>
fn void Builder.insert(&self, sz index, char[] bytes)
{
	self.buffer.insert_chars_at((usz)index, (String)bytes);
}

<*
 @require index <= self.len() : "insert past the end"
*>
fn void Builder.insert_byte(&self, sz index, char byte)
{
	self.buffer.insert_char_at((usz)index, byte);
}

<*
 Swap the byte range `[start, end)` for `bytes`.

 @require start <= end && end <= self.len() : "replace range out of range"
*>
fn void Builder.replace_range(&self, sz start, sz end, char[] bytes)
{
	self.remove(start, end);
	self.insert(start, bytes);
}

<*
 Delete the byte range `[start, end)`.

 @require start <= end && end <= self.len() : "remove range out of range"
*>
fn void Builder.remove(&self, sz start, sz end)
{
	if (start == end) return;
	self.buffer.delete((usz)start, (usz)(end - start));
}

<*
 Replace every occurrence of `needle`, returning how many were replaced. An
 empty `needle` matches nothing.
*>
fn sz Builder.replace_all(&self, char[] needle, char[] replacement)
{
	if (needle.len == 0) return 0;
	sz n = self.view().count(needle);
	if (n == 0) return 0;
	self.buffer.replace((String)needle, (String)replacement);
	return n;
}

<*
 Drop everything past `new_len`.

 @require new_len <= self.len() : "truncate past the end"
*>
fn void Builder.truncate(&self, sz new_len)
{
	self.buffer.chop((usz)new_len);
}

fn char? Builder.pop(&self)
{
	sz n = self.len();
	if (n == 0) return view::OUT_OF_RANGE~;
	char byte = self.items()[n - 1];
	self.truncate(n - 1);
	return byte;
}

<*
 Strip trailing bytes that appear in `set`.
*>
fn void Builder.trim_end(&self, char[] set)
{
	self.truncate(self.view().trim_end_chars(set).len());
}

<*
 Reset the length to zero but keep the allocation for reuse.
*>
fn void Builder.clear(&self)
{
	self.buffer.clear();
}

// -------------------------------------------------------------------------
// Handing the bytes over
// -------------------------------------------------------------------------

<*
 A copy of the contents in memory the caller owns. The builder is left
 untouched, unlike Zig's `toOwnedSlice`, because `DString` owns one
 allocation and handing it away would leave the builder holding a pointer it
 no longer owns.
*>
fn String Builder.to_owned(&self, Allocator allocator)
{
	return self.buffer.copy_str(allocator);
}

<*
 Like `to_owned`, but NUL-terminated for C interop.
*>
fn ZString Builder.to_owned_zstr(&self, Allocator allocator)
{
	return self.buffer.copy_zstr(allocator);
}

<*
 An independent copy, which the caller must `free`.
*>
fn Builder Builder.clone(&self, Allocator allocator)
{
	Builder copy;
	copy.init_from(allocator, self.items());
	return copy;
}

// -------------------------------------------------------------------------
// Stream interface
// -------------------------------------------------------------------------
//
// These two are what `OutStream` demands, and having them is what lets
// `io::fprintf(&builder, ...)` work, and what lets a `Builder` stand in
// anywhere the standard library wants somewhere to write.

fn sz? Builder.write(&self, char[] bytes) @dynamic
{
	self.append(bytes);
	return bytes.len;
}

fn void? Builder.write_byte(&self, char c) @dynamic
{
	self.append_byte(c);
}

<*
 What `%s` prints: the contents.
*>
fn sz? Builder.to_format(&self, Formatter* f) @dynamic
{
	return f.print(self.buffer.str_view());
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_append_and_read_back() @test
{
	Builder b;
	b.init(mem);
	defer b.free();

	test::@check(b.is_empty());
	b.append("hello");
	b.append_byte(' ');
	b.append_view(view::of("world"));
	test::eq((String)b.items(), "hello world");
	test::eq(b.len(), 11);
	test::@check(!b.is_empty());
	test::eq(b.at(0)!!, 'h');
	test::@error(b.at(11), view::OUT_OF_RANGE);
	test::@check(b.view().equals_bytes("hello world"));
}

fn void test_init_from_and_clone() @test
{
	Builder b;
	b.init_from(mem, "seed");
	defer b.free();
	test::eq((String)b.items(), "seed");

	Builder c = b.clone(mem);
	defer c.free();
	c.append("ling");
	test::eq((String)b.items(), "seed");
	test::eq((String)c.items(), "seedling");
}

fn void test_append_repeat_and_append_line() @test
{
	Builder b;
	b.init(mem);
	defer b.free();

	b.append_repeat('-', 5);
	b.append_byte('\n');
	b.append_line("row");
	test::eq((String)b.items(), "-----\nrow\n");
}

fn void test_append_codepoint() @test
{
	Builder b;
	b.init(mem);
	defer b.free();

	b.append_codepoint('a')!!;
	b.append_codepoint(0x00E9)!!;
	b.append_codepoint(0x1F422)!!;
	test::eq((String)b.items(), "aé\U0001F422");
	test::@error(b.append_codepoint(0xD800), utf8::SURROGATE_HALF);
}

fn void test_printf() @test
{
	Builder b;
	b.init(mem);
	defer b.free();

	b.printf("%s is %d", "answer", 42);
	test::eq((String)b.items(), "answer is 42");
}

fn void test_join() @test
{
	Builder b;
	b.init(mem);
	defer b.free();

	b.join(", ", { "a", "b", "c" });
	test::eq((String)b.items(), "a, b, c");

	b.clear();
	b.join(", ", {});
	test::eq((String)b.items(), "");
}

fn void test_insert_and_remove() @test
{
	Builder b;
	b.init_from(mem, "hello world");
	defer b.free();

	b.insert(5, ",");
	test::eq((String)b.items(), "hello, world");

	b.insert_byte(0, '>');
	test::eq((String)b.items(), ">hello, world");

	b.remove(0, 1);
	test::eq((String)b.items(), "hello, world");

	b.replace_range(0, 5, "goodbye");
	test::eq((String)b.items(), "goodbye, world");
}

fn void test_replace_all() @test
{
	Builder b;
	b.init_from(mem, "a-b-c-d");
	defer b.free();

	test::eq(b.replace_all("-", " to "), 3);
	test::eq((String)b.items(), "a to b to c to d");

	// Shrinking replacement, and a needle that is not present.
	test::eq(b.replace_all(" to ", "-"), 3);
	test::eq((String)b.items(), "a-b-c-d");
	test::eq(b.replace_all("zzz", "!"), 0);
	test::eq(b.replace_all("", "!"), 0);
	test::eq((String)b.items(), "a-b-c-d");
}

fn void test_truncate_pop_and_trim_end() @test
{
	Builder b;
	b.init_from(mem, "abcdef");
	defer b.free();

	test::eq(b.pop()!!, 'f');
	b.truncate(3);
	test::eq((String)b.items(), "abc");

	b.append("   \n");
	b.trim_end(" \n");
	test::eq((String)b.items(), "abc");
}

fn void test_clear_keeps_capacity() @test
{
	Builder b;
	b.init(mem);
	defer b.free();

	b.append("some reasonably long content");
	sz cap = b.capacity();
	b.clear();
	test::eq(b.len(), 0);
	test::eq(b.capacity(), cap);
}

fn void test_to_owned() @test
{
	Builder b;
	b.init(mem);
	defer b.free();

	b.append("first");
	String owned = b.to_owned(mem);
	defer free(owned);
	test::eq(owned, "first");
	// Unlike Zig's toOwnedSlice, the builder still holds its text.
	test::eq(b.len(), 5);

	ZString owned_z = b.to_owned_zstr(mem);
	defer free(owned_z);
	test::eq(owned_z.str_view(), "first");
}

fn void test_stream_interface() @test
{
	Builder b;
	b.init(mem);
	defer b.free();

	io::fprintf(&b, "via stream")!!;
	io::fprintf(&b, " plus %d", 7)!!;
	b.write_byte('!')!!;
	test::eq((String)b.items(), "via stream plus 7!");
}

fn void test_format() @test
{
	Builder b;
	b.init_from(mem, "shown");
	defer b.free();
	@pool()
	{
		test::eq(string::tformat("[%s]", &b), "[shown]");
	};
}
