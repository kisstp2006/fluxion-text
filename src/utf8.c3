// SPDX-License-Identifier: CC0-1.0

// UTF-8 primitives: encode, decode, validate, iterate, and boundary math.
//
// This is the lowest layer of Fluxion Text. Everything here works on plain
// `char[]` slices and never allocates. The higher-level `View`, `Builder` and
// `Parser` types are built on top of it.
//
// C3's `Char32` is the codepoint type - a `uint` wearing a name - and the
// standard library's `conv` module does the actual encoding. What this module
// adds is the checking: `conv::utf8_to_char32` accepts an overlong encoding
// and a surrogate half, and neither is a valid scalar value, so a decoder that
// lets them through hands the rest of the program text it cannot re-encode.
module fluxion::text::utf8;
import std::core::string::conv;

// U+FFFD REPLACEMENT CHARACTER, substituted by the lossy decoding paths.
const Char32 REPLACEMENT = 0xFFFD;

// The highest codepoint Unicode defines.
const Char32 MAX_CODEPOINT = 0x10FFFF;

// No UTF-8 sequence is longer than this.
const sz MAX_SEQUENCE_LEN = 4;

// The leading byte can never start a UTF-8 sequence.
faultdef INVALID_START_BYTE;

// The sequence runs past the end of the input.
faultdef TRUNCATED;

// A byte that should have been a continuation byte (0b10xxxxxx) was not.
faultdef INVALID_CONTINUATION;

// The codepoint was encoded using more bytes than necessary.
faultdef OVERLONG_ENCODING;

// The codepoint is a UTF-16 surrogate half (U+D800..U+DFFF).
faultdef SURROGATE_HALF;

// The codepoint is greater than `MAX_CODEPOINT`.
faultdef CODEPOINT_TOO_LARGE;

// The destination buffer cannot hold the encoded sequence.
faultdef BUFFER_TOO_SMALL;

<*
 One decoded codepoint together with the number of bytes it occupied.
*>
struct Decoded
{
	Char32 codepoint;
	sz len;
}

<*
 True if `byte` is a UTF-8 continuation byte (0b10xxxxxx).
*>
fn bool is_continuation(char byte)
{
	return (byte & 0b1100_0000) == 0b1000_0000;
}

<*
 True if `byte` can begin a UTF-8 sequence.
*>
fn bool is_start_byte(char byte)
{
	return !is_continuation(byte) && byte != 0xC0 && byte != 0xC1 && byte < 0xF5;
}

<*
 Length in bytes of the sequence beginning with `first_byte`.
*>
fn sz? sequence_length(char first_byte)
{
	switch
	{
		case first_byte < 0x80: return 1;
		case first_byte >= 0xC2 && first_byte < 0xE0: return 2;
		case first_byte >= 0xE0 && first_byte < 0xF0: return 3;
		case first_byte >= 0xF0 && first_byte < 0xF5: return 4;
		default: return INVALID_START_BYTE~;
	}
}

<*
 True if `codepoint` is a UTF-16 surrogate half, which UTF-8 may not encode.
*>
fn bool is_surrogate(Char32 codepoint)
{
	return codepoint >= 0xD800 && codepoint <= 0xDFFF;
}

<*
 Number of bytes `codepoint` needs when encoded.
*>
fn sz? encoded_length(Char32 codepoint)
{
	if (codepoint > MAX_CODEPOINT) return CODEPOINT_TOO_LARGE~;
	if (is_surrogate(codepoint)) return SURROGATE_HALF~;
	switch
	{
		case codepoint < 0x80: return 1;
		case codepoint < 0x800: return 2;
		case codepoint < 0x10000: return 3;
		default: return 4;
	}
}

<*
 Encode `codepoint` into `out`, returning the number of bytes written.
*>
fn sz? encode(Char32 codepoint, char[] out)
{
	sz len = encoded_length(codepoint)!;
	if (out.len < len) return BUFFER_TOO_SMALL~;
	// The standard library writes the bytes; the checking above is what makes
	// the call safe, since `char32_to_utf8` would encode a surrogate happily.
	conv::char32_to_utf8(codepoint, out)!!;
	return len;
}

<*
 An encoded codepoint held by value, so you can build one without owning a
 scratch buffer at the call site.
*>
struct Sequence
{
	char[MAX_SEQUENCE_LEN] bytes;
	sz len;
}

<*
 The bytes actually written. Takes the address because they live inside the
 value: a slice of a temporary would dangle.
*>
fn char[] Sequence.slice(&self)
{
	return self.bytes[:self.len];
}

fn Sequence? encode_sequence(Char32 codepoint)
{
	Sequence seq;
	seq.len = encode(codepoint, &seq.bytes)!;
	return seq;
}

<*
 Decode the sequence at the start of `bytes`.

 Rejects overlong encodings, surrogate halves and out-of-range codepoints, so
 a successful result is always a valid Unicode scalar value. The decoding
 itself is written out here rather than handed to the standard library,
 because those three rejections are the whole point of a strict decoder.
*>
fn Decoded? decode(char[] bytes)
{
	if (bytes.len == 0) return TRUNCATED~;
	sz len = sequence_length(bytes[0])!;
	if (bytes.len < len) return TRUNCATED~;

	Char32 codepoint;
	switch (len)
	{
		case 1:
			codepoint = bytes[0];
		case 2:
			codepoint = (Char32)(bytes[0] & 0x1F) << 6;
		case 3:
			codepoint = (Char32)(bytes[0] & 0x0F) << 12;
		default:
			codepoint = (Char32)(bytes[0] & 0x07) << 18;
	}
	for (sz i = 1; i < len; i++)
	{
		if (!is_continuation(bytes[i])) return INVALID_CONTINUATION~;
		codepoint |= (Char32)(bytes[i] & 0x3F) << (uint)(6 * (len - 1 - i));
	}

	// Every codepoint has exactly one encoding, and a decoder that accepts a
	// longer one lets the same text be spelled two ways - which is how a
	// filter that rejects "../" gets past by a program that then opens it.
	if (encoded_length(codepoint) ?? 0 != len)
	{
		return is_surrogate(codepoint) ? SURROGATE_HALF~ : OVERLONG_ENCODING~;
	}
	return { .codepoint = codepoint, .len = len };
}

<*
 Decode the sequence at the start of `bytes`, substituting `REPLACEMENT` for
 anything malformed. Never fails, and always advances by at least one byte.
*>
fn Decoded? decode_lossy(char[] bytes)
{
	if (bytes.len == 0) return NO_MORE_CODEPOINTS~;
	Decoded? d = decode(bytes);
	if (catch d) return { .codepoint = REPLACEMENT, .len = 1 };
	return d;
}

// The iterator has nothing left. Not an error - it is how a `while (try ...)`
// loop learns to stop.
faultdef NO_MORE_CODEPOINTS;

<*
 True if every byte of `bytes` is part of a well-formed UTF-8 sequence.
*>
fn bool validate(char[] bytes)
{
	sz i = 0;
	while (i < bytes.len)
	{
		Decoded? d = decode(bytes[i..]);
		if (catch d) return false;
		i += d.len;
	}
	return true;
}

<*
 Number of codepoints in `bytes`.
*>
fn sz? count_codepoints(char[] bytes)
{
	sz n = 0;
	sz i = 0;
	while (i < bytes.len)
	{
		Decoded d = decode(bytes[i..])!;
		i += d.len;
		n++;
	}
	return n;
}

<*
 True if `index` sits on a codepoint boundary. `bytes.len` counts as one.
*>
fn bool is_boundary(char[] bytes, sz index)
{
	if (index == 0 || index == bytes.len) return true;
	if (index > bytes.len) return false;
	return !is_continuation(bytes[index]);
}

<*
 The largest boundary at or before `index`. Clamp a byte offset with this
 before slicing and you can never split a codepoint in half.
*>
fn sz floor_boundary(char[] bytes, sz index)
{
	sz i = min(index, bytes.len);
	while (i > 0 && i < bytes.len && is_continuation(bytes[i])) i--;
	return i;
}

<*
 The smallest boundary at or after `index`.
*>
fn sz ceil_boundary(char[] bytes, sz index)
{
	sz i = min(index, bytes.len);
	while (i < bytes.len && is_continuation(bytes[i])) i++;
	return i;
}

// The string holds fewer codepoints than the index asked for.
faultdef NO_SUCH_CODEPOINT;

// The byte index is not on a codepoint boundary.
faultdef NOT_A_BOUNDARY;

<*
 Byte offset of codepoint number `codepoint_index`.
*>
fn sz? byte_index_of_codepoint(char[] bytes, sz codepoint_index)
{
	sz n = 0;
	sz i = 0;
	while (true)
	{
		if (n == codepoint_index) return i;
		if (i >= bytes.len) return NO_SUCH_CODEPOINT~;
		Decoded d = decode(bytes[i..])!;
		i += d.len;
		n++;
	}
}

<*
 How many codepoints precede `byte_index`.
*>
fn sz? codepoint_index_of_byte(char[] bytes, sz byte_index)
{
	if (!is_boundary(bytes, byte_index)) return NOT_A_BOUNDARY~;
	return count_codepoints(bytes[:byte_index]);
}

<*
 Forward iterator over the codepoints of a UTF-8 slice.

     CodepointIterator it;
     it.init(bytes);
     while (try d = it.next()) { ... }

 `next` is strict and reports malformed input as a fault; `next_lossy`
 substitutes `REPLACEMENT` and only ever stops at the end. Both end with
 `NO_MORE_CODEPOINTS`, which is what makes `while (try ...)` the loop.
*>
struct CodepointIterator
{
	char[] bytes;
	// Byte offset of the next codepoint to be decoded.
	sz index;
}

fn void CodepointIterator.init(&self, char[] bytes)
{
	*self = { .bytes = bytes };
}

fn Decoded? CodepointIterator.next(&self)
{
	if (self.index >= self.bytes.len) return NO_MORE_CODEPOINTS~;
	Decoded d = decode(self.bytes[self.index..])!;
	self.index += d.len;
	return d;
}

fn Decoded? CodepointIterator.next_lossy(&self)
{
	if (self.index >= self.bytes.len) return NO_MORE_CODEPOINTS~;
	Decoded d = decode_lossy(self.bytes[self.index..])!!;
	self.index += d.len;
	return d;
}

<*
 Look at the next codepoint without consuming it.
*>
fn Decoded? CodepointIterator.peek(&self)
{
	if (self.index >= self.bytes.len) return NO_MORE_CODEPOINTS~;
	return decode(self.bytes[self.index..]);
}

<*
 The bytes not yet consumed.
*>
fn char[] CodepointIterator.rest(&self)
{
	return self.bytes[self.index..];
}

fn void CodepointIterator.reset(&self)
{
	self.index = 0;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_encode_and_decode_round_trip() @test
{
	Char32[] samples = { 'a', 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, MAX_CODEPOINT };
	foreach (cp : samples)
	{
		Sequence seq = encode_sequence(cp)!!;
		Decoded d = decode(seq.slice())!!;
		test::eq(d.codepoint, cp);
		test::eq(d.len, seq.len);
	}
}

fn void test_encode_rejects_surrogates_and_out_of_range_codepoints() @test
{
	char[4] buf;
	test::@error(encode(0xD800, &buf), SURROGATE_HALF);
	test::@error(encode(0xDFFF, &buf), SURROGATE_HALF);
	test::@error(encode(0x110000, &buf), CODEPOINT_TOO_LARGE);

	char[1] small;
	test::@error(encode(0x800, &small), BUFFER_TOO_SMALL);
}

fn void test_decode_rejects_malformed_sequences() @test
{
	test::@error(decode(""), TRUNCATED);
	test::@error(decode("\x80"), INVALID_START_BYTE);
	test::@error(decode("\xE2\x82"), TRUNCATED);
	test::@error(decode("\xE2\x28\xA1"), INVALID_CONTINUATION);
	test::@error(decode("\xC0\xAF"), INVALID_START_BYTE);
	test::@error(decode("\xE0\x80\xAF"), OVERLONG_ENCODING);
	test::@error(decode("\xED\xA0\x80"), SURROGATE_HALF);
}

fn void test_lossy_decoding_always_makes_progress() @test
{
	CodepointIterator it;
	it.init("a\xFFb");
	test::eq(it.next_lossy()!!.codepoint, (Char32)'a');
	test::eq(it.next_lossy()!!.codepoint, REPLACEMENT);
	test::eq(it.next_lossy()!!.codepoint, (Char32)'b');
	test::@error(it.next_lossy(), NO_MORE_CODEPOINTS);
}

fn void test_iterate_a_mixed_width_string() @test
{
	String s = "aé漢\U0001F422";
	test::eq(s.len, 10);
	test::eq(count_codepoints(s)!!, 4);

	CodepointIterator it;
	it.init(s);
	test::eq(it.next()!!.len, 1);
	test::eq(it.next()!!.len, 2);
	test::eq(it.next()!!.len, 3);

	Decoded turtle = it.next()!!;
	test::eq(turtle.len, 4);
	test::eq(turtle.codepoint, (Char32)0x1F422);
	test::@error(it.next(), NO_MORE_CODEPOINTS);
}

fn void test_peek_does_not_advance() @test
{
	CodepointIterator it;
	it.init("hi");
	test::eq(it.peek()!!.codepoint, (Char32)'h');
	test::eq(it.peek()!!.codepoint, (Char32)'h');
	test::eq(it.next()!!.codepoint, (Char32)'h');
	test::eq((String)it.rest(), "i");
}

fn void test_boundary_arithmetic() @test
{
	String s = "aé漢"; // 1 + 2 + 3 bytes
	test::@check(is_boundary(s, 0));
	test::@check(is_boundary(s, 1));
	test::@check(!is_boundary(s, 2));
	test::@check(is_boundary(s, 3));
	test::@check(is_boundary(s, s.len));

	test::eq(floor_boundary(s, 2), 1);
	test::eq(ceil_boundary(s, 2), 3);
	test::eq(floor_boundary(s, 3), 3);
	test::eq(ceil_boundary(s, 99), s.len);
	test::eq(floor_boundary(s, 99), s.len);
}

fn void test_codepoint_and_byte_index_conversion() @test
{
	String s = "aé漢";
	test::eq(byte_index_of_codepoint(s, 0)!!, 0);
	test::eq(byte_index_of_codepoint(s, 1)!!, 1);
	test::eq(byte_index_of_codepoint(s, 2)!!, 3);
	test::eq(byte_index_of_codepoint(s, 3)!!, 6);
	test::@error(byte_index_of_codepoint(s, 4), NO_SUCH_CODEPOINT);

	test::eq(codepoint_index_of_byte(s, 3)!!, 2);
	test::@error(codepoint_index_of_byte(s, 2), NOT_A_BOUNDARY);
}

fn void test_validate() @test
{
	test::@check(validate("hello 漢字"));
	test::@check(!validate("\xFF"));
	test::@check(!validate("\xED\xA0\x80"));
}
