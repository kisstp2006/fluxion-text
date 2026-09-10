// SPDX-License-Identifier: CC0-1.0

// String interning: turn text into a small integer `StringId` and back again.
//
// Interning pays off wherever the same strings recur - identifiers in a
// compiler, keys in a config, tags on entities. Once interned, comparison is
// an integer compare, the handle is 4 bytes instead of 16, and equal strings
// are stored once.
//
// Ids are handed out in insertion order and stay valid for the life of the
// interner. The text lives in blocks the interner owns and never moves, so
// `resolve` hands back a slice that is stable until `free` - unlike `Builder`
// output, you do not free it yourself.
module fluxion::text::interner;
import fluxion::text::view;
import std::collections::map, std::collections::list;
import std::io;

<*
 A handle to an interned string.

 A `typedef` rather than a bare `uint`, so that a `StringId` and an entity id
 do not silently swap. There is no reserved "none" value: an id that may be
 absent is a `StringId?`, and the fault says so.
*>
typedef StringId (Printable) = uint;

fn uint StringId.to_int(self)
{
	return (uint)self;
}

fn StringId from_int(uint value)
{
	return (StringId)value;
}

fn bool StringId.equals(self, StringId other)
{
	return (uint)self == (uint)other;
}

fn uint StringId.hash(self)
{
	return (uint)self;
}

<*
 What `%s` prints: the numeric handle. Use `Interner.resolve` for the text.
*>
fn sz? StringId.to_format(&self, Formatter* f) @dynamic
{
	return f.printf("#%d", (uint)*self);
}

// No string has been interned under that id.
faultdef NO_SUCH_ID;

// The text is not interned, and this call does not intern it.
faultdef NOT_INTERNED;

// One block of interned text. The blocks are a linked list rather than one
// growing array, because a `resolve` result has to stay put: growing an array
// would move every string already handed out.
struct Block @local
{
	char[] bytes;
	sz used;
	Block* next;
}

// How much text one block holds. Anything longer gets a block of its own,
// which keeps a single huge string from wasting most of a fresh block.
const sz BLOCK_BYTES = 4096;

struct Interner
{
	Allocator allocator;
	// Text to id. The key is a slice into a `Block`, so it lives exactly as
	// long as the interner does.
	HashMap{String, StringId} map;
	// Id to text, in the order the ids were issued.
	List{String} entries;
	Block* blocks;
}

fn void Interner.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.map.init(allocator);
	self.entries.init(allocator);
	self.blocks = null;
}

fn void Interner.free(&self)
{
	self.map.free();
	self.entries.free();
	Block* block = self.blocks;
	while (block != null)
	{
		Block* next = block.next;
		alloc::free(self.allocator, block.bytes.ptr);
		alloc::free(self.allocator, block);
		block = next;
	}
	*self = {};
}

<*
 Number of distinct strings held.
*>
fn sz Interner.count(&self)
{
	return self.entries.len();
}

// A copy of `str` in memory the interner owns and never moves.
fn String Interner.store(&self, String str)
{
	if (self.blocks == null || self.blocks.bytes.len - self.blocks.used < str.len)
	{
		sz size = max(BLOCK_BYTES, str.len);
		Block* block = alloc::new(self.allocator, Block);
		block.bytes = alloc::alloc_array(self.allocator, char, size);
		block.used = 0;
		block.next = self.blocks;
		self.blocks = block;
	}
	Block* block = self.blocks;
	char[] slot = block.bytes[block.used:str.len];
	mem::copy(slot.ptr, str.ptr, (usz)str.len);
	block.used += str.len;
	return (String)slot;
}

<*
 Intern `str`, returning its id. Interning the same text twice returns the
 same id and stores no second copy. The interner copies the bytes, so `str`
 does not need to outlive the call.
*>
fn StringId Interner.intern(&self, char[] str)
{
	String text = (String)str;
	if (try found = self.map.get(text)) return found;

	String owned = self.store(text);
	StringId id = (StringId)(uint)self.entries.len();
	self.entries.push(owned);
	self.map.set(owned, id);
	return id;
}

fn StringId Interner.intern_view(&self, View v)
{
	return self.intern(v.bytes);
}

<*
 Intern the result of a format string, without you having to build the text
 in a separate buffer first.
*>
fn StringId Interner.internf(&self, String format, args...)
{
	@pool()
	{
		return self.intern(string::tformat(format, ...args));
	};
}

<*
 The id `str` already has. Unlike `intern` this never allocates and never
 adds anything.
*>
fn StringId? Interner.find(&self, char[] str)
{
	return self.map.get((String)str) ?? NOT_INTERNED~;
}

fn bool Interner.contains(&self, char[] str)
{
	return self.map.has_key((String)str);
}

<*
 The text behind `id`.

 @require (uint)id < (uint)self.entries.len() : "an id from another interner"
*>
fn String Interner.resolve(&self, StringId id)
{
	return self.entries[(sz)(uint)id];
}

<*
 Like `resolve`, but a fault for an id this interner never issued.
*>
fn String? Interner.try_resolve(&self, StringId id)
{
	if ((uint)id >= (uint)self.entries.len()) return NO_SUCH_ID~;
	return self.entries[(sz)(uint)id];
}

fn View Interner.resolve_view(&self, StringId id)
{
	return view::of(self.resolve(id));
}

<*
 One interned string and the id it was issued under.
*>
struct Entry
{
	StringId id;
	String text;
}

// The walk is finished.
faultdef NO_MORE_ENTRIES;

<*
 Walk every interned string in the order the ids were issued.
*>
struct EntryIterator
{
	String[] entries;
	uint index;
}

fn Entry? EntryIterator.next(&self)
{
	if ((sz)self.index >= self.entries.len) return NO_MORE_ENTRIES~;
	Entry entry = { .id = (StringId)self.index, .text = self.entries[(sz)self.index] };
	self.index++;
	return entry;
}

fn EntryIterator Interner.iterator(&self)
{
	return { .entries = self.entries.array_view() };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_the_same_text_gets_the_same_id() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	StringId a = it.intern("hello");
	StringId b = it.intern("hello");
	StringId c = it.intern("world");

	test::@check(a.equals(b));
	test::@check(!a.equals(c));
	test::eq(it.count(), 2);
}

fn void test_ids_are_issued_in_order_from_zero() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	test::eq(it.intern("a").to_int(), 0U);
	test::eq(it.intern("b").to_int(), 1U);
	test::eq(it.intern("c").to_int(), 2U);
	test::eq(it.intern("a").to_int(), 0U);
}

fn void test_resolve_returns_the_text() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	StringId id = it.intern("round trip");
	test::eq(it.resolve(id), "round trip");
	test::@check(it.resolve_view(id).equals_bytes("round trip"));
	test::@error(it.try_resolve(from_int(99)), NO_SUCH_ID);
}

fn void test_the_interner_owns_its_copy_of_the_text() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	char[5] scratch = "abcde";
	StringId id = it.intern(&scratch);
	scratch[..] = 'z'; // the caller's buffer is free to change

	test::eq(it.resolve(id), "abcde");
}

fn void test_resolved_slices_survive_later_interning() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	String first = it.resolve(it.intern("stable"));
	for (int i = 0; i < 500; i++) it.internf("filler%d", i);
	test::eq(first, "stable"); // not invalidated by growth
}

fn void test_find_and_contains_do_not_intern() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	it.intern("present");
	test::@check(it.contains("present"));
	test::@check(!it.contains("absent"));
	test::@error(it.find("absent"), NOT_INTERNED);
	test::eq(it.count(), 1);
}

fn void test_intern_view_and_internf() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	StringId a = it.intern_view(view::of("shared"));
	StringId b = it.internf("sha%s", "red");
	test::@check(a.equals(b));
}

fn void test_empty_string_is_a_normal_entry() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	StringId id = it.intern("");
	test::eq(it.resolve(id), "");
	test::@check(id.equals(it.intern("")));
}

fn void test_a_string_larger_than_a_block() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	// Longer than BLOCK_BYTES, so it gets a block of its own rather than
	// overflowing the shared one.
	char[BLOCK_BYTES * 2] big;
	big[..] = 'x';
	StringId id = it.intern(&big);
	test::eq(it.resolve(id).len, BLOCK_BYTES * 2);
	// And the interner still works afterwards.
	test::eq(it.resolve(it.intern("after")), "after");
}

fn void test_iterator() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	it.intern("one");
	it.intern("two");

	EntryIterator iter = it.iterator();
	Entry first = iter.next()!!;
	test::eq(first.id.to_int(), 0U);
	test::eq(first.text, "one");

	Entry second = iter.next()!!;
	test::eq(second.id.to_int(), 1U);
	test::eq(second.text, "two");
	test::@error(iter.next(), NO_MORE_ENTRIES);
}

fn void test_id_formatting() @test
{
	Interner it;
	it.init(mem);
	defer it.free();

	it.intern("zero");
	StringId id = it.intern("one");
	@pool()
	{
		test::eq(string::tformat("%s", id), "#1");
	};
}
