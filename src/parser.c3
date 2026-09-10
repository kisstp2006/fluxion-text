// SPDX-License-Identifier: CC0-1.0

// A cursor over UTF-8 text, for hand-written parsers and lexers.
//
// `Parser` never allocates and never copies: everything it hands back is a
// `View` into the original input. The three families of method are
//
//   * `peek_*`    - look without moving,
//   * `eat_*`     - move if it matches, report whether it did,
//   * `expect_*`  - move if it matches, fail if it does not,
//
// plus the `take_*` family, which consumes a run of bytes and returns the
// span. Use `save`/`restore` to speculatively try a production and back out.
module fluxion::text::parser;
import fluxion::text::view, fluxion::text::utf8, fluxion::text::number;
import std::io;

struct Parser
{
	char[] input;
	// Byte offset of the cursor. Always on a byte boundary, not necessarily
	// on a codepoint boundary if you advance by raw byte counts.
	sz index;
}

// The input ran out before the expected item.
faultdef UNEXPECTED_END;

// The next byte was not the expected one.
faultdef UNEXPECTED_BYTE;

// The cursor is not on something that could start this token. Distinct from
// `UNEXPECTED_BYTE` because it means "not this production", which a caller
// usually answers by trying another one rather than by failing.
faultdef NO_MATCH;

// An opaque cursor position, produced by `save` and consumed by `restore`.
alias Mark = sz;

fn void Parser.init(&self, char[] input)
{
	*self = { .input = input };
}

fn void Parser.init_view(&self, View v)
{
	self.init(v.bytes);
}

// -------------------------------------------------------------------------
// Position
// -------------------------------------------------------------------------

fn bool Parser.is_at_end(&self)
{
	return self.index >= self.input.len;
}

<*
 Everything not yet consumed.
*>
fn View Parser.rest(&self)
{
	return view::of(self.input[self.index..]);
}

<*
 Everything consumed so far.
*>
fn View Parser.consumed(&self)
{
	return view::of(self.input[:self.index]);
}

fn Mark Parser.save(&self)
{
	return self.index;
}

<*
 @require mark <= self.input.len : "a mark from another parser"
*>
fn void Parser.restore(&self, Mark mark)
{
	self.index = mark;
}

fn void Parser.reset(&self)
{
	self.index = 0;
}

<*
 Move forward by up to `n` bytes, stopping at the end of the input.
*>
fn void Parser.advance(&self, sz n)
{
	self.index = min(self.index + n, self.input.len);
}

// -------------------------------------------------------------------------
// Peeking
// -------------------------------------------------------------------------

fn char? Parser.peek(&self)
{
	if (self.is_at_end()) return UNEXPECTED_END~;
	return self.input[self.index];
}

fn char? Parser.peek_at(&self, sz offset)
{
	sz i = self.index + offset;
	if (i >= self.input.len) return UNEXPECTED_END~;
	return self.input[i];
}

<*
 The next `n` bytes, or `UNEXPECTED_END` if fewer than `n` remain.
*>
fn View? Parser.peek_slice(&self, sz n)
{
	if (self.index + n > self.input.len) return UNEXPECTED_END~;
	return view::of(self.input[self.index:n]);
}

fn Decoded? Parser.peek_codepoint(&self)
{
	if (self.is_at_end()) return UNEXPECTED_END~;
	return utf8::decode(self.input[self.index..]);
}

<*
 True if the next byte is `byte`, without consuming it.
*>
fn bool Parser.check(&self, char byte)
{
	if (self.is_at_end()) return false;
	return self.input[self.index] == byte;
}

<*
 True if the input continues with `bytes`, without consuming them.
*>
fn bool Parser.check_slice(&self, char[] bytes)
{
	return self.rest().starts_with(bytes);
}

// -------------------------------------------------------------------------
// Consuming one item
// -------------------------------------------------------------------------

fn char? Parser.next(&self)
{
	if (self.is_at_end()) return UNEXPECTED_END~;
	char c = self.input[self.index];
	self.index++;
	return c;
}

fn Decoded? Parser.next_codepoint(&self)
{
	if (self.is_at_end()) return UNEXPECTED_END~;
	Decoded d = utf8::decode(self.input[self.index..])!;
	self.index += d.len;
	return d;
}

// -------------------------------------------------------------------------
// Matching
// -------------------------------------------------------------------------

<*
 Consume `byte` if it is next. Returns whether it was.
*>
fn bool Parser.eat(&self, char byte)
{
	if (!self.check(byte)) return false;
	self.index++;
	return true;
}

<*
 Consume the next byte if it appears in `set`, returning which one it was.
*>
fn char? Parser.eat_any(&self, char[] set)
{
	char c = self.peek()!;
	if (!@ok(((String)set).index_of_char(c))) return NO_MATCH~;
	self.index++;
	return c;
}

fn bool Parser.eat_slice(&self, char[] bytes)
{
	if (!self.check_slice(bytes)) return false;
	self.index += bytes.len;
	return true;
}

fn bool Parser.eat_slice_ignore_case(&self, char[] bytes)
{
	if (!self.rest().starts_with_ignore_case(bytes)) return false;
	self.index += bytes.len;
	return true;
}

fn void? Parser.expect(&self, char byte)
{
	if (self.is_at_end()) return UNEXPECTED_END~;
	if (!self.eat(byte)) return UNEXPECTED_BYTE~;
}

fn void? Parser.expect_slice(&self, char[] bytes)
{
	if (self.input.len - self.index < bytes.len) return UNEXPECTED_END~;
	if (!self.eat_slice(bytes)) return UNEXPECTED_BYTE~;
}

fn char? Parser.expect_any(&self, char[] set)
{
	if (self.is_at_end()) return UNEXPECTED_END~;
	char? c = self.eat_any(set);
	if (catch c) return UNEXPECTED_BYTE~;
	return c;
}

// -------------------------------------------------------------------------
// Consuming spans
// -------------------------------------------------------------------------

<*
 The next `n` bytes, or `UNEXPECTED_END` if fewer than `n` remain (cursor
 unmoved).
*>
fn View? Parser.take(&self, sz n)
{
	View v = self.peek_slice(n)!;
	self.index += n;
	return v;
}

<*
 Everything that is left.
*>
fn View Parser.take_rest(&self)
{
	View v = self.rest();
	self.index = self.input.len;
	return v;
}

<*
 What `take_while` tests each byte with.

 A function pointer rather than an untyped macro parameter, because the
 standard library's `char.is_digit` and friends are macros, and a macro has
 no address to pass. The wrappers just below give those a callable form; any
 `fn bool(char)` of your own works too.
*>
alias Predicate = fn bool(char c);

fn bool is_digit(char c) => c.is_digit();
fn bool is_alpha(char c) => c.is_alpha();
fn bool is_alnum(char c) => c.is_alnum();
fn bool is_space(char c) => c.is_space();
fn bool is_xdigit(char c) => c.is_xdigit();

<*
 The longest run of bytes satisfying `pred`. May be empty.
*>
fn View Parser.take_while(&self, Predicate pred)
{
	sz start = self.index;
	while (self.index < self.input.len && pred(self.input[self.index])) self.index++;
	return view::of(self.input[start:self.index - start]);
}

<*
 The longest run of bytes drawn from `set`. May be empty.
*>
fn View Parser.take_while_any(&self, char[] set)
{
	sz start = self.index;
	while (self.index < self.input.len && @ok(((String)set).index_of_char(self.input[self.index])))
	{
		self.index++;
	}
	return view::of(self.input[start:self.index - start]);
}

<*
 Everything up to the first byte of `set`, leaving the cursor on it. If no
 such byte exists, consumes the rest of the input.
*>
fn View Parser.take_until_any(&self, char[] set)
{
	sz start = self.index;
	while (self.index < self.input.len && !@ok(((String)set).index_of_char(self.input[self.index])))
	{
		self.index++;
	}
	return view::of(self.input[start:self.index - start]);
}

<*
 Everything up to the next `byte`, leaving the cursor on it. If the byte does
 not occur, consumes the rest of the input.
*>
fn View Parser.take_until_char(&self, char byte)
{
	sz start = self.index;
	sz? found = self.rest().index_of_char(byte);
	self.index = @ok(found) ? start + found!! : self.input.len;
	return view::of(self.input[start:self.index - start]);
}

<*
 Everything up to the next occurrence of `needle`, leaving the cursor at the
 start of it. `NO_MATCH` when `needle` does not occur, in which case the
 cursor does not move.
*>
fn View? Parser.take_until_slice(&self, char[] needle)
{
	sz? found = self.rest().index_of(needle);
	if (catch found) return NO_MATCH~;
	sz start = self.index;
	self.index = start + found;
	return view::of(self.input[start:found]);
}

// -------------------------------------------------------------------------
// Skipping
// -------------------------------------------------------------------------

<*
 Skip ASCII whitespace, including newlines. Returns the bytes skipped.
*>
fn sz Parser.skip_whitespace(&self)
{
	return self.take_while_any(view::WHITESPACE).len();
}

<*
 Skip spaces and tabs but stop at a line break.
*>
fn sz Parser.skip_inline_whitespace(&self)
{
	return self.take_while_any(" \t").len();
}

<*
 Skip every byte that appears in `set`. Returns the count skipped.
*>
fn sz Parser.skip_any(&self, char[] set)
{
	return self.take_while_any(set).len();
}

// -------------------------------------------------------------------------
// Common tokens
// -------------------------------------------------------------------------

fn bool is_ident_start(char c)
{
	return c.is_alpha() || c == '_';
}

fn bool is_ident_continue(char c)
{
	return c.is_alnum() || c == '_';
}

<*
 A C-style identifier: `[A-Za-z_][A-Za-z0-9_]*`. `NO_MATCH` if the next byte
 cannot start one, in which case the cursor does not move.
*>
fn View? Parser.take_identifier(&self)
{
	char? c = self.peek();
	if (catch c) return NO_MATCH~;
	if (!is_ident_start(c)) return NO_MATCH~;
	sz start = self.index;
	self.index++;
	self.take_while(&is_ident_continue);
	return view::of(self.input[start:self.index - start]);
}

<*
 One line without its terminator, consuming the terminator. Accepts "\n" and
 "\r\n". `UNEXPECTED_END` once the input is exhausted.
*>
fn View? Parser.take_line(&self)
{
	if (self.is_at_end()) return UNEXPECTED_END~;
	View line = self.take_until_char('\n');
	self.eat('\n');
	return line.chomp();
}

<*
 The contents of a `quote`-delimited string, with the quotes consumed and the
 inner span returned *unescaped* - a `\` still protects the next byte from
 ending the string, but no escape decoding is performed. Decoding is left to
 the caller because the escape dialect is yours to define.

 `NO_MATCH` when the next byte is not `quote` (cursor unmoved);
 `UNEXPECTED_END` when the closing quote is missing.
*>
fn View? Parser.take_quoted(&self, char quote)
{
	if (!self.check(quote)) return NO_MATCH~;
	Mark mark = self.save();
	self.index++;
	sz start = self.index;
	while (self.index < self.input.len)
	{
		char c = self.input[self.index];
		if (c == '\\')
		{
			// Skip the escape and whatever it protects.
			self.index += self.index + 1 < self.input.len ? 2 : 1;
			continue;
		}
		if (c == quote)
		{
			char[] body = self.input[start:self.index - start];
			self.index++;
			return view::of(body);
		}
		self.index++;
	}
	self.restore(mark);
	return UNEXPECTED_END~;
}

// -------------------------------------------------------------------------
// Numbers
// -------------------------------------------------------------------------

<*
 Read an integer at the cursor. On failure the cursor does not move.
*>
macro Parser.take_int(&self, $Type, IntOptions options = {})
{
	Scanned{$Type} scanned = number::scan_int($Type, self.input[self.index..], options)!;
	self.index += scanned.len;
	return scanned.value;
}

<*
 Read a float at the cursor. On failure the cursor does not move.
*>
fn double? Parser.take_float(&self, FloatOptions options = {})
{
	Scanned{double} scanned = number::scan_float(self.input[self.index..], options)!;
	self.index += scanned.len;
	return scanned.value;
}

<*
 Read `true` or `false` at the cursor, case-insensitively.
*>
fn bool? Parser.take_bool(&self)
{
	Scanned{bool} scanned = number::scan_bool(self.input[self.index..])!;
	self.index += scanned.len;
	return scanned.value;
}

// -------------------------------------------------------------------------
// Diagnostics
// -------------------------------------------------------------------------

struct Location (Printable)
{
	// Byte offset from the start of the input.
	sz offset;
	// 1-based line number.
	sz line;
	// 1-based column, counted in codepoints so it matches what a reader sees.
	sz column;
}

<*
 What `%s` prints: `line:column`.
*>
fn sz? Location.to_format(&self, Formatter* f) @dynamic
{
	return f.printf("%d:%d", self.line, self.column);
}

<*
 Where `offset` falls in the input. Costs a scan from the start, so call it
 when reporting an error rather than in the parsing loop.
*>
fn Location Parser.location_at(&self, sz offset)
{
	char[] upto = self.input[:min(offset, self.input.len)];
	sz line = 1;
	sz line_start = 0;
	foreach (i, c : upto)
	{
		if (c == '\n')
		{
			line++;
			line_start = i + 1;
		}
	}
	sz column = 1;
	CodepointIterator it;
	it.init(upto[line_start..]);
	while (@ok(it.next_lossy())) column++;
	return { .offset = offset, .line = line, .column = column };
}

<*
 Where the cursor currently is.
*>
fn Location Parser.location(&self)
{
	return self.location_at(self.index);
}

<*
 The whole line the cursor sits on, without its terminator. Useful for
 printing a caret under the offending column.
*>
fn View Parser.current_line(&self)
{
	sz i = min(self.index, self.input.len);
	sz? before = view::of(self.input[:i]).last_index_of_char('\n');
	sz start = @ok(before) ? before!! + 1 : 0;
	sz? after = view::of(self.input[i..]).index_of_char('\n');
	sz end = @ok(after) ? i + after!! : self.input.len;
	return view::of(self.input[start:end - start]).chomp();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_position_and_movement() @test
{
	Parser p;
	p.init("abcdef");
	test::@check(!p.is_at_end());
	test::eq(p.rest().str(), "abcdef");

	p.advance(2);
	test::eq(p.consumed().str(), "ab");
	test::eq(p.rest().str(), "cdef");

	p.advance(999); // clamped, not out of bounds
	test::@check(p.is_at_end());
	p.reset();
	test::eq(p.index, 0);
}

fn void test_save_and_restore() @test
{
	Parser p;
	p.init("let x = 1");
	Mark mark = p.save();
	test::@check(p.eat_slice("let "));
	test::eq(p.take_identifier()!!.str(), "x");
	p.restore(mark);
	test::eq(p.rest().str(), "let x = 1");
}

fn void test_peeking_never_moves_the_cursor() @test
{
	Parser p;
	p.init("hello");
	test::eq(p.peek()!!, 'h');
	test::eq(p.peek_at(2)!!, 'l');
	test::@error(p.peek_at(99), UNEXPECTED_END);
	test::eq(p.peek_slice(3)!!.str(), "hel");
	test::@error(p.peek_slice(99), UNEXPECTED_END);
	test::@check(p.check('h'));
	test::@check(p.check_slice("hell"));
	test::eq(p.index, 0);
}

fn void test_eat_and_expect() @test
{
	Parser p;
	p.init("key=value");
	test::@check(p.eat_slice("key"));
	test::@check(!p.eat_slice("key"));
	p.expect('=')!!;
	test::eq(p.eat_any("xyzv")!!, 'v');
	test::@error(p.eat_any("xyz"), NO_MATCH);

	Parser q;
	q.init("a");
	test::@error(q.expect('b'), UNEXPECTED_BYTE);
	test::@check(q.eat('a'));
	test::@error(q.expect('a'), UNEXPECTED_END);
	test::@error(q.expect_slice("ab"), UNEXPECTED_END);
}

fn void test_next_and_next_codepoint() @test
{
	Parser p;
	p.init("aé");
	test::eq(p.next()!!, 'a');
	Decoded d = p.next_codepoint()!!;
	test::eq(d.codepoint, (Char32)0x00E9);
	test::@check(p.is_at_end());
	test::@error(p.next(), UNEXPECTED_END);

	Parser bad;
	bad.init("\xFF");
	test::@error(bad.next_codepoint(), utf8::INVALID_START_BYTE);
}

fn void test_take_spans() @test
{
	Parser p;
	p.init("abc123def");
	test::eq(p.take_while(&is_alpha).str(), "abc");
	test::eq(p.take_while(&is_digit).str(), "123");
	test::eq(p.take_while(&is_digit).str(), "");
	test::eq(p.take_rest().str(), "def");

	Parser q;
	q.init("aab!!");
	test::eq(q.take_while_any("ab").str(), "aab");
	test::eq(q.take_rest().str(), "!!");

	Parser r;
	r.init("abc");
	test::eq(r.take(2)!!.str(), "ab");
	test::@error(r.take(2), UNEXPECTED_END);
}

fn void test_take_until() @test
{
	Parser p;
	p.init("name: value");
	test::eq(p.take_until_char(':').str(), "name");
	test::eq(p.peek()!!, ':');

	Parser q;
	q.init("no delimiter here");
	test::eq(q.take_until_char(';').str(), "no delimiter here");
	test::@check(q.is_at_end());

	Parser r;
	r.init("head<!--tail");
	test::eq(r.take_until_slice("<!--")!!.str(), "head");
	test::@check(r.check_slice("<!--"));
	test::@error(r.take_until_slice("zzz"), NO_MATCH);

	Parser s;
	s.init("abc,def");
	test::eq(s.take_until_any(",;").str(), "abc");
}

fn void test_skipping() @test
{
	Parser p;
	p.init("  \n\t x");
	test::eq(p.skip_whitespace(), 5);
	test::eq(p.peek()!!, 'x');

	Parser q;
	q.init("  \n x");
	test::eq(q.skip_inline_whitespace(), 2);
	test::eq(q.peek()!!, '\n');
}

fn void test_identifiers() @test
{
	Parser p;
	p.init("_foo9 bar");
	test::eq(p.take_identifier()!!.str(), "_foo9");
	test::@error(p.take_identifier(), NO_MATCH); // on a space
	p.skip_whitespace();
	test::eq(p.take_identifier()!!.str(), "bar");

	Parser q;
	q.init("9lives");
	test::@error(q.take_identifier(), NO_MATCH);
	test::eq(q.index, 0);
}

fn void test_lines() @test
{
	Parser p;
	p.init("one\r\ntwo\nthree");
	test::eq(p.take_line()!!.str(), "one");
	test::eq(p.take_line()!!.str(), "two");
	test::eq(p.take_line()!!.str(), "three");
	test::@error(p.take_line(), UNEXPECTED_END);
}

fn void test_quoted_strings() @test
{
	Parser p;
	p.init(`"hello" rest`);
	test::eq(p.take_quoted('"')!!.str(), "hello");
	test::eq(p.rest().str(), " rest");

	// A backslash protects the quote that follows it.
	Parser esc;
	esc.init(`"a\"b"`);
	test::eq(esc.take_quoted('"')!!.str(), `a\"b`);
	test::@check(esc.is_at_end());

	Parser unterminated;
	unterminated.init(`"oops`);
	test::@error(unterminated.take_quoted('"'), UNEXPECTED_END);
	test::eq(unterminated.index, 0); // cursor restored

	Parser not_quoted;
	not_quoted.init("bare");
	test::@error(not_quoted.take_quoted('"'), NO_MATCH);
}

fn void test_numbers() @test
{
	Parser p;
	p.init("42 -1.5 0xFF true");
	test::eq(p.take_int(uint)!!, 42U);
	p.skip_whitespace();
	test::eq(p.take_float()!!, -1.5);
	p.skip_whitespace();
	test::eq(p.take_int(uint)!!, 255U);
	p.skip_whitespace();
	test::@check(p.take_bool()!!);
	test::@check(p.is_at_end());
}

fn void test_a_failed_number_leaves_the_cursor_alone() @test
{
	Parser p;
	p.init("abc");
	test::@error(p.take_int(uint), number::NO_DIGITS);
	test::eq(p.index, 0);
}

fn void test_locations() @test
{
	Parser p;
	p.init("one\ntwo\nthré e");
	p.take_line()!!;
	Location l2 = p.location();
	test::eq(l2.line, 2);
	test::eq(l2.column, 1);
	@pool()
	{
		test::eq(string::tformat("%s", &l2), "2:1");
	};

	p.take_line()!!;
	p.advance(5); // past the 2-byte e-acute on line 3
	Location l3 = p.location();
	test::eq(l3.line, 3);
	test::eq(l3.column, 5); // codepoints, not bytes
	test::eq(p.current_line().str(), "thré e");
}

struct Entry @local
{
	String key;
	String value;
}

fn void test_a_small_key_value_parser() @test
{
	Entry[3] entries;
	sz n = 0;

	Parser p;
	p.init("host = localhost\nport= 8080\n# comment\nquiet =true\n");
	while (!p.is_at_end())
	{
		p.skip_whitespace();
		if (p.is_at_end()) break;
		if (p.eat('#'))
		{
			p.take_line()!!;
			continue;
		}
		View key = p.take_identifier()!!;
		p.skip_inline_whitespace();
		p.expect('=')!!;
		p.skip_inline_whitespace();
		View value = p.take_until_char('\n');
		entries[n] = { .key = key.str(), .value = value.trim().str() };
		n++;
	}

	test::eq(n, 3);
	test::eq(entries[0].key, "host");
	test::eq(entries[0].value, "localhost");
	test::eq(entries[1].key, "port");
	test::eq(entries[1].value, "8080");
	test::eq(entries[2].key, "quiet");
	test::eq(entries[2].value, "true");
}
