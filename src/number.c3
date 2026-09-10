// SPDX-License-Identifier: CC0-1.0

// Number parsing for text that has other things in it.
//
// `String.to_int` answers "is this whole slice a number?". When you are
// walking a document you usually need the other question: "how much of what
// comes next is a number?". Every routine here comes in two flavours:
//
//   * `scan_*`   - reads a prefix and reports how many bytes it consumed.
//   * `parse_*`  - requires the entire slice to be consumed.
//
// `Parser` is built on the `scan` family; `parse` is what you want for a
// standalone string such as a config value.
//
// The integer routines are macros taking the type as a `$`-parameter, because
// the width of the type is what decides when a value has overflowed and a
// literal has no width of its own: `number::scan_int(uint, "300")`.
module fluxion::text::number;
import std::math;

// There was nothing that could start a number.
faultdef NO_DIGITS;

// A number was read, but bytes were left over (the `parse` family only).
faultdef TRAILING_BYTES;

// The value does not fit in the requested type.
faultdef OVERFLOW;

// A separator was in an illegal position, or a sign was not allowed here.
faultdef INVALID_CHARACTER;

// The radix rides along as an associated value, which is C3's way of hanging
// data off an enum: `base.radix` is a lookup, not a cast.
enum Base : (char radix)
{
	DETECT { 0 },
	BINARY { 2 },
	OCTAL { 8 },
	DECIMAL { 10 },
	HEXADECIMAL { 16 },
}

<*
 The two-character literal prefix for this base. Empty when it has none.
*>
fn String Base.prefix(self)
{
	switch (self)
	{
		case BINARY: return "0b";
		case OCTAL: return "0o";
		case HEXADECIMAL: return "0x";
		default: return "";
	}
}

<*
 How a number is read. Every field is named so that zero is the default, the
 way `fluxion-encoding`'s option structs are: `DETECT` reads a `0x` / `0o` /
 `0b` prefix and otherwise assumes decimal, and both `no_sign` and
 `no_underscores` turn something off.
*>
struct IntOptions
{
	// `DETECT` reads the base from a prefix. A concrete base still accepts
	// its own prefix.
	Base base;
	// Refuse a leading `+` or `-`.
	bool no_sign;
	// Refuse `_` between digits, as in `1_000_000`.
	bool no_underscores;
}

<*
 A value together with the number of input bytes it came from.
*>
struct Scanned <Type>
{
	Type value;
	sz len;
}

// What `digit_value` answers for a character that is not a digit in any base.
const char NOT_A_DIGIT = 0xFF;

<*
 Numeric value of an ASCII digit in any base up to 36, or `NOT_A_DIGIT`.
*>
fn char digit_value(char c)
{
	switch
	{
		case c >= '0' && c <= '9': return c - '0';
		case c >= 'a' && c <= 'z': return c - 'a' + 10;
		case c >= 'A' && c <= 'Z': return c - 'A' + 10;
		default: return NOT_A_DIGIT;
	}
}

fn char digit_in_base(char c, char radix) @private
{
	char v = digit_value(c);
	return v < radix ? v : NOT_A_DIGIT;
}

fn bool starts_with_ignore_case(char[] bytes, String needle) @private
{
	if (bytes.len < needle.len) return false;
	return ((String)bytes[:needle.len]).compare_to_ignore_case(needle) == 0;
}

// -------------------------------------------------------------------------
// Integers
// -------------------------------------------------------------------------

<*
 Read an integer from the front of `bytes`.

 A base prefix that is not followed by a valid digit is not an error: `"0x"`
 scans as the single digit `0`, leaving `"x"` for the caller. This keeps the
 scanner usable on inputs like `0xZ` where `0` really is the number.

 Overflow is checked on every digit rather than at the end, because C3
 integer arithmetic wraps silently: `acc * radix` on a full `uint` would come
 back a small number and the scan would report a value it never read.
*>
macro scan_int($Type, char[] bytes, IntOptions options = {})
{
	const bool SIGNED = $Type::kind == SIGNED_INT;

	sz i = 0;
	bool negative = false;
	if (i < bytes.len && (bytes[i] == '+' || bytes[i] == '-'))
	{
		if (options.no_sign) return INVALID_CHARACTER~;
		negative = bytes[i] == '-';
		i++;
	}
	$if !SIGNED:
		if (negative) return INVALID_CHARACTER~;
	$endif

	Base base = options.base == DETECT ? Base.DECIMAL : options.base;
	// A leading zero may introduce a base prefix. `fallback` remembers where
	// to stop if no digit follows it.
	sz fallback = 0;
	bool has_fallback = false;
	if (i + 1 < bytes.len && bytes[i] == '0')
	{
		Base detected;
		switch (bytes[i + 1].to_lower())
		{
			case 'b': detected = BINARY;
			case 'o': detected = OCTAL;
			case 'x': detected = HEXADECIMAL;
			default: detected = DETECT;
		}
		if (detected != DETECT && (options.base == DETECT || options.base == detected))
		{
			base = detected;
			fallback = i + 1;
			has_fallback = true;
			i += 2;
		}
	}

	char radix = base.radix;
	$Type acc = 0;
	sz digits = 0;
	bool last_was_digit = false;

	for (; i < bytes.len; i++)
	{
		char c = bytes[i];
		if (c == '_')
		{
			if (options.no_underscores || !last_was_digit) break;
			last_was_digit = false;
			continue;
		}
		char d = digit_in_base(c, radix);
		if (d == NOT_A_DIGIT) break;

		if (acc > ($Type)(($Type::max - ($Type)d) / ($Type)radix)) return OVERFLOW~;
		$if SIGNED:
			if (negative)
			{
				if (acc < ($Type)(($Type::min + ($Type)d) / ($Type)radix)) return OVERFLOW~;
			}
		$endif
		acc = negative ? acc * ($Type)radix - ($Type)d : acc * ($Type)radix + ($Type)d;
		digits++;
		last_was_digit = true;
	}

	if (digits == 0)
	{
		if (has_fallback) return (Scanned{$Type}){ .value = 0, .len = fallback };
		return NO_DIGITS~;
	}
	// Do not let a number end on a separator: "1_" consumes only "1".
	if (!last_was_digit) i--;

	return (Scanned{$Type}){ .value = acc, .len = i };
}

<*
 Parse `bytes` in full as an integer.
*>
macro parse_int($Type, char[] bytes, IntOptions options = {})
{
	Scanned{$Type} scanned = scan_int($Type, bytes, options)!;
	if (scanned.len != bytes.len) return TRAILING_BYTES~;
	return scanned.value;
}

// -------------------------------------------------------------------------
// Floats
// -------------------------------------------------------------------------

struct Run @private
{
	sz end;
	sz digits;
}

// End index of a run of digits (and, if permitted, `_` between them), plus
// how many real digits it contained.
fn Run digit_run(char[] bytes, sz start, bool allow_underscores) @private
{
	sz i = start;
	sz digits = 0;
	bool last_was_digit = false;
	for (; i < bytes.len; i++)
	{
		if (bytes[i].is_digit())
		{
			digits++;
			last_was_digit = true;
		}
		else if (bytes[i] == '_' && allow_underscores && last_was_digit)
		{
			last_was_digit = false;
		}
		else
		{
			break;
		}
	}
	if (!last_was_digit && digits > 0) i--;
	return { .end = i, .digits = digits };
}

struct FloatOptions
{
	bool no_sign;
	bool no_underscores;
	// Refuse `inf`, `infinity` and `nan` (which are otherwise accepted,
	// case-insensitively).
	bool no_special;
}

<*
 Read a decimal floating point number from the front of `bytes`.

 Accepts `[+-] digits [. digits] [eE [+-] digits]` plus, unless turned off,
 the special forms `inf`, `infinity` and `nan`. Hexadecimal float literals
 are not scanned.

 The underscores are stripped into a scratch buffer before the standard
 library sees the text, since `String.to_double` does not know about them.
*>
fn Scanned{double}? scan_float(char[] bytes, FloatOptions options = {})
{
	sz i = 0;
	if (i < bytes.len && (bytes[i] == '+' || bytes[i] == '-'))
	{
		if (options.no_sign) return INVALID_CHARACTER~;
		i++;
	}

	if (!options.no_special)
	{
		char[] rest = bytes[i..];
		sz special = 0;
		if (starts_with_ignore_case(rest, "infinity"))
		{
			special = 8;
		}
		else if (starts_with_ignore_case(rest, "inf"))
		{
			special = 3;
		}
		else if (starts_with_ignore_case(rest, "nan"))
		{
			special = 3;
		}
		if (special != 0)
		{
			sz end = i + special;
			bool negative = bytes[0] == '-';
			double value = starts_with_ignore_case(bytes[i..], "nan") ? double::nan : double::inf;
			return { .value = negative ? -value : value, .len = end };
		}
	}

	Run whole = digit_run(bytes, i, !options.no_underscores);
	i = whole.end;
	sz digits = whole.digits;

	if (i < bytes.len && bytes[i] == '.')
	{
		Run frac = digit_run(bytes, i + 1, !options.no_underscores);
		if (frac.digits > 0 || digits > 0)
		{
			i = frac.end;
			digits += frac.digits;
		}
	}
	if (digits == 0) return NO_DIGITS~;

	// Only consume the exponent if it is well formed; "1e" is the number 1.
	if (i < bytes.len && (bytes[i] == 'e' || bytes[i] == 'E'))
	{
		sz j = i + 1;
		if (j < bytes.len && (bytes[j] == '+' || bytes[j] == '-')) j++;
		Run exp = digit_run(bytes, j, !options.no_underscores);
		if (exp.digits > 0) i = exp.end;
	}

	// A literal with separators in it has to lose them before the standard
	// library will read it. 64 bytes is far past the point where more digits
	// change a `double`.
	char[64] scratch;
	sz n = 0;
	foreach (c : bytes[:i])
	{
		if (c == '_') continue;
		if (n == scratch.len) return OVERFLOW~;
		scratch[n] = c;
		n++;
	}

	double? value = ((String)scratch[:n]).to_double();
	if (catch value) return INVALID_CHARACTER~;
	return { .value = value, .len = i };
}

<*
 Parse `bytes` in full as a float.
*>
fn double? parse_float(char[] bytes, FloatOptions options = {})
{
	Scanned{double} scanned = scan_float(bytes, options)!;
	if (scanned.len != bytes.len) return TRAILING_BYTES~;
	return scanned.value;
}

// -------------------------------------------------------------------------
// Booleans
// -------------------------------------------------------------------------

// The text is neither `true` nor `false`.
faultdef NOT_A_BOOL;

<*
 Read `true` or `false` (case-insensitive) from the front of `bytes`.
*>
fn Scanned{bool}? scan_bool(char[] bytes)
{
	if (starts_with_ignore_case(bytes, "true")) return { .value = true, .len = 4 };
	if (starts_with_ignore_case(bytes, "false")) return { .value = false, .len = 5 };
	return NOT_A_BOOL~;
}

fn bool? parse_bool(char[] bytes)
{
	Scanned{bool} scanned = scan_bool(bytes)!;
	if (scanned.len != bytes.len) return TRAILING_BYTES~;
	return scanned.value;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_scan_int_reports_how_far_it_got() @test
{
	Scanned{uint} r = scan_int(uint, "123abc")!!;
	test::eq(r.value, 123U);
	test::eq(r.len, 3);

	test::@error(scan_int(uint, "abc"), NO_DIGITS);
}

fn void test_parse_int_requires_the_whole_slice() @test
{
	test::eq(parse_int(uint, "123")!!, 123U);
	test::@error(parse_int(uint, "123abc"), TRAILING_BYTES);
}

fn void test_signs() @test
{
	test::eq(parse_int(int, "-42")!!, -42);
	test::eq(parse_int(int, "+42")!!, 42);
	test::@error(parse_int(uint, "-42"), INVALID_CHARACTER);
	test::@error(parse_int(int, "-42", { .no_sign = true }), INVALID_CHARACTER);
}

fn void test_signed_minimum_does_not_overflow() @test
{
	test::eq(parse_int(ichar, "-128")!!, (ichar)-128);
	test::@error(parse_int(ichar, "128"), OVERFLOW);
	test::@error(parse_int(ichar, "-129"), OVERFLOW);
	test::eq(parse_int(long, "-9223372036854775808")!!, long::min);
}

fn void test_base_detection() @test
{
	test::eq(parse_int(uint, "0xFF")!!, 0xFFU);
	test::eq(parse_int(uint, "0o17")!!, 0o17U);
	test::eq(parse_int(uint, "0b1011")!!, 0b1011U);
	test::eq(parse_int(int, "-0xFF")!!, -0xFF);
	test::eq(parse_int(uint, "10")!!, 10U);
}

fn void test_explicit_base_wins() @test
{
	test::eq(parse_int(uint, "FF", { .base = HEXADECIMAL })!!, 255U);
	test::eq(parse_int(uint, "0xFF", { .base = HEXADECIMAL })!!, 255U);
	// 'x' is not a decimal digit, so only the leading 0 is a number here.
	test::@error(parse_int(uint, "0x10", { .base = DECIMAL }), TRAILING_BYTES);
}

fn void test_a_bare_prefix_scans_as_zero() @test
{
	Scanned{uint} r = scan_int(uint, "0x")!!;
	test::eq(r.value, 0U);
	test::eq(r.len, 1);

	Scanned{uint} z = scan_int(uint, "0xZZ")!!;
	test::eq(z.value, 0U);
	test::eq(z.len, 1);
}

fn void test_underscore_separators() @test
{
	test::eq(parse_int(uint, "1_000_000")!!, 1000000U);
	test::eq(parse_int(uint, "0xDEAD_BEEF")!!, 0xDEAD_BEEFU);

	// A trailing or doubled separator ends the number rather than joining it.
	Scanned{uint} trailing = scan_int(uint, "1_")!!;
	test::eq(trailing.value, 1U);
	test::eq(trailing.len, 1);

	Scanned{uint} doubled = scan_int(uint, "1__0")!!;
	test::eq(doubled.value, 1U);
	test::eq(doubled.len, 1);

	test::@error(parse_int(uint, "1_0", { .no_underscores = true }), TRAILING_BYTES);
}

fn void test_overflow_is_detected() @test
{
	test::@error(parse_int(char, "256"), OVERFLOW);
	test::@error(parse_int(uint, "99999999999999999999"), OVERFLOW);
}

fn void test_scan_float() @test
{
	Scanned{double} a = scan_float("3.5rest")!!;
	test::eq(a.value, 3.5);
	test::eq(a.len, 3);

	test::eq(parse_float("-0.25")!!, -0.25);
	test::eq(parse_float("1.5e3")!!, 1.5e3);
	test::eq(parse_float("1.5E-3")!!, 1.5e-3);
	test::eq(parse_float("42")!!, 42.0);
	test::eq(parse_float(".5")!!, 0.5);
	test::eq(parse_float("5.")!!, 5.0);
	test::eq(parse_float("1_000.5")!!, 1000.5);
}

fn void test_a_dangling_exponent_is_not_consumed() @test
{
	Scanned{double} r = scan_float("1e")!!;
	test::eq(r.value, 1.0);
	test::eq(r.len, 1);

	Scanned{double} s = scan_float("1e+")!!;
	test::eq(s.len, 1);
}

fn void test_float_special_values() @test
{
	test::@check(parse_float("inf")!! > 0 && math::is_inf(parse_float("inf")!!));
	test::@check(math::is_inf(parse_float("-Infinity")!!) && parse_float("-Infinity")!! < 0);
	test::@check(math::is_nan(parse_float("NaN")!!));
	test::@error(parse_float("inf", { .no_special = true }), NO_DIGITS);
}

fn void test_float_errors() @test
{
	test::@error(scan_float("abc"), NO_DIGITS);
	test::@error(scan_float("."), NO_DIGITS);
	test::@error(parse_float("3.5rest"), TRAILING_BYTES);
}

fn void test_booleans() @test
{
	test::@check(parse_bool("true")!!);
	test::@check(!parse_bool("FALSE")!!);
	// "truthy" does not start with "true" - its fourth byte is a 't' - so the
	// scan never gets as far as having trailing bytes to complain about.
	test::@error(parse_bool("truthy"), NOT_A_BOOL);
	test::@error(parse_bool("maybe"), NOT_A_BOOL);
	test::@error(parse_bool("true story"), TRAILING_BYTES);
	test::eq(scan_bool("true story")!!.len, 4);
}

fn void test_digit_value() @test
{
	test::eq(digit_value('0'), (char)0);
	test::eq(digit_value('9'), (char)9);
	test::eq(digit_value('a'), (char)10);
	test::eq(digit_value('Z'), (char)35);
	test::eq(digit_value('!'), NOT_A_DIGIT);
}
