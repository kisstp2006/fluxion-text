// SPDX-License-Identifier: CC0-1.0

// Fixed-capacity strings that live entirely inline.
//
// `Fixed{N}` stores up to `N` bytes in the value itself. There is no
// allocator, no pointer, and nothing to free, so it can sit in a component
// array, cross a thread boundary, or be copied in a hot loop without ceremony.
// Overflow is a fault rather than a reallocation.
//
// The unused tail is always zeroed, which means two `Fixed` values holding the
// same text are identical byte-for-byte. That is what makes them safe to use
// directly as `HashMap` keys.
//
// The capacity is a generic constant, so `Fixed{16}` is its own type and the
// compiler stamps out one copy of the methods per size actually used.
module fluxion::text::fixed <CAPACITY>;
import fluxion::text::view, fluxion::text::utf8;
import std::io;

// The text will not fit in the remaining capacity.
faultdef OVERFLOW;

struct Fixed (Printable)
{
	char[CAPACITY] buf;
	// A `sz` rather than the smallest integer that would hold the length:
	// C3 has no `IntFittingRange`, and the alignment of the array would
	// usually eat the saving anyway.
	sz len;
}

<*
 The capacity, for code that needs to ask.
*>
fn sz Fixed.capacity(&self)
{
	return CAPACITY;
}

<*
 Replace the contents outright. `OVERFLOW` if `bytes` does not fit, in which
 case the value is unchanged.
*>
fn void? Fixed.set(&self, char[] bytes)
{
	if (bytes.len > CAPACITY) return OVERFLOW~;
	mem::copy(&self.buf, bytes.ptr, (usz)bytes.len);
	self.len = bytes.len;
	self.zero_tail();
}

<*
 Keep as much of `bytes` as fits, cutting on a UTF-8 boundary so the result
 is never a half-encoded character.
*>
fn void Fixed.set_truncating(&self, char[] bytes)
{
	sz n = bytes.len <= CAPACITY ? bytes.len : utf8::floor_boundary(bytes, CAPACITY);
	mem::copy(&self.buf, bytes.ptr, (usz)n);
	self.len = n;
	self.zero_tail();
}

// Zeroing what is past the end is what makes two equal strings equal bytes,
// and that is what makes the type safe as a hash-map key.
fn void Fixed.zero_tail(&self)
{
	if (self.len < CAPACITY) self.buf[self.len..] = 0;
}

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

<*
 Takes the address because the bytes live inside the value: a slice of a
 temporary would dangle.
*>
fn char[] Fixed.slice(&self)
{
	return self.buf[:self.len];
}

fn String Fixed.str(&self)
{
	return (String)self.slice();
}

fn View Fixed.view(&self)
{
	return view::of(self.slice());
}

fn bool Fixed.is_empty(&self)
{
	return self.len == 0;
}

fn bool Fixed.is_full(&self)
{
	return self.len == CAPACITY;
}

<*
 Bytes still available.
*>
fn sz Fixed.unused(&self)
{
	return CAPACITY - self.len;
}

fn char? Fixed.at(&self, sz index)
{
	if (index >= self.len) return view::OUT_OF_RANGE~;
	return self.buf[index];
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

fn void Fixed.clear(&self)
{
	self.len = 0;
	self.zero_tail();
}

fn void? Fixed.append(&self, char[] bytes)
{
	if (bytes.len > self.unused()) return OVERFLOW~;
	mem::copy(&self.buf[self.len], bytes.ptr, (usz)bytes.len);
	self.len += bytes.len;
	self.zero_tail();
}

fn void? Fixed.append_byte(&self, char byte)
{
	if (self.is_full()) return OVERFLOW~;
	self.buf[self.len] = byte;
	self.len++;
	self.zero_tail();
}

fn void? Fixed.append_codepoint(&self, Char32 codepoint)
{
	Sequence seq = utf8::encode_sequence(codepoint)!;
	return self.append(seq.slice());
}

<*
 Append formatted output. Nothing is written if the result would not fit, so
 a failed call leaves the string unchanged.

 The text is formatted into a scratch buffer first, because the standard
 library's formatter has no way to ask "would this fit?" before it starts.
*>
fn void? Fixed.appendf(&self, String format, args...)
{
	char[CAPACITY + 1] scratch;
	String written = string::bformat(&scratch, format, ...args);
	return self.append(written);
}

<*
 Drop everything past `new_len`.

 @require new_len <= self.len : "truncate past the end"
*>
fn void Fixed.truncate(&self, sz new_len)
{
	self.len = new_len;
	self.zero_tail();
}

fn char? Fixed.pop(&self)
{
	if (self.len == 0) return view::OUT_OF_RANGE~;
	self.len--;
	char byte = self.buf[self.len];
	self.zero_tail();
	return byte;
}

// -------------------------------------------------------------------------
// Comparison
// -------------------------------------------------------------------------

fn bool Fixed.equals(&self, Fixed other)
{
	return self.slice() == other.slice();
}

fn bool Fixed.equals_bytes(&self, char[] other)
{
	return self.slice() == other;
}

fn int Fixed.compare_to(&self, Fixed other)
{
	return self.str().compare_to(other.str());
}

fn bool Fixed.less(&self, Fixed other)
{
	return self.compare_to(other) < 0;
}

fn uint Fixed.hash(&self)
{
	return self.slice().hash();
}

<*
 What `%s` prints: the text.
*>
fn sz? Fixed.to_format(&self, Formatter* f) @dynamic
{
	return f.print(self.str());
}

// -------------------------------------------------------------------------
// Tests
//
// A generic module cannot hold tests - there is no `CAPACITY` to run them for
// - so they live in a plain module beside it, over one concrete size.
// -------------------------------------------------------------------------

module fluxion::text::fixed_test;
import fluxion::text::fixed, fluxion::text::utf8, fluxion::text::view;
import std::collections::map;

alias Name = Fixed{16};

fn Name named(char[] bytes)
{
	Name n;
	n.set(bytes)!!;
	return n;
}

fn void test_construction() @test
{
	Name n = named("player");
	test::eq(n.str(), "player");
	test::eq(n.len, 6);
	test::@check(!n.is_empty());
	test::@check(!n.is_full());
	test::eq(n.unused(), 10);

	Name empty;
	test::@check(empty.is_empty());

	Name too_big;
	test::@error(too_big.set("a string well past sixteen bytes"), fixed::OVERFLOW);
}

fn void test_set_truncating_cuts_on_a_codepoint_boundary() @test
{
	// 15 ASCII bytes then a 2-byte 'e-acute', so a plain cut at the 16-byte
	// capacity would land between its two bytes.
	Name n;
	n.set_truncating("abcdefghijklmnoéxyz");
	test::eq(n.str(), "abcdefghijklmno");
	test::@check(n.view().is_valid_utf8());

	// Text that already fits is kept whole.
	Name short_one;
	short_one.set_truncating("short");
	test::eq(short_one.str(), "short");
}

fn void test_appending() @test
{
	Name n;
	n.append("ent")!!;
	n.append_byte('_')!!;
	n.appendf("%d", 42)!!;
	n.append_codepoint(0x00E9)!!;
	test::eq(n.str(), "ent_42é");
}

fn void test_overflow_leaves_the_value_unchanged() @test
{
	Name n = named("0123456789");
	test::@error(n.append("too much text here"), fixed::OVERFLOW);
	test::eq(n.str(), "0123456789");

	test::@error(n.appendf("%d", 1234567890), fixed::OVERFLOW);
	test::eq(n.str(), "0123456789");

	// Exactly filling the capacity is fine.
	n.append("123456")!!;
	test::@check(n.is_full());
	test::@error(n.append_byte('x'), fixed::OVERFLOW);
}

fn void test_set_truncate_pop_and_clear() @test
{
	Name n = named("original");
	n.set("replaced")!!;
	test::eq(n.str(), "replaced");

	n.truncate(2);
	test::eq(n.str(), "re");
	test::eq(n.pop()!!, 'e');
	test::eq(n.str(), "r");

	n.clear();
	test::@check(n.is_empty());
	test::@error(n.pop(), view::OUT_OF_RANGE);
}

fn void test_comparison_and_views() @test
{
	Name a = named("alpha");
	Name b = named("beta");
	Name a2 = named("alpha");

	test::@check(a.equals(a2));
	test::@check(!a.equals(b));
	test::@check(a.equals_bytes("alpha"));
	test::@check(a.less(b));
	test::@check(a.compare_to(b) < 0);
	test::eq(a.hash(), a2.hash());
	test::@check(a.view().starts_with("al"));
}

fn void test_the_unused_tail_is_always_zeroed() @test
{
	// This is what makes the type safe as a hash-map key: two values with the
	// same text must have identical bytes, including the unused tail.
	Name a = named("scratched");
	a.clear();
	a.append("hi")!!;

	Name b = named("hi");
	test::eq(a.buf, b.buf);
}

fn void test_works_as_a_hash_map_key() @test
{
	HashMap{Name, uint} map;
	map.init(mem);
	defer map.free();

	map.set(named("health"), 100);
	map.set(named("mana"), 50);
	// Same text arrived at a different way must hit the same slot.
	Name rebuilt;
	rebuilt.append("heal")!!;
	rebuilt.append("th")!!;
	map.set(rebuilt, 75);

	test::eq(map.len(), 2);
	test::eq(map.get(named("health"))!!, 75U);
	test::eq(map.get(named("mana"))!!, 50U);
}

fn void test_copies_are_independent() @test
{
	Name a = named("first");
	Name b = a; // plain value copy, no allocator involved
	b.set("second")!!;
	test::eq(a.str(), "first");
	test::eq(b.str(), "second");
}

fn void test_format() @test
{
	Name n = named("shown");
	@pool()
	{
		test::eq(string::tformat("[%s]", &n), "[shown]");
	};
}
