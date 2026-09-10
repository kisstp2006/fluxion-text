// SPDX-License-Identifier: CC0-1.0

// Word wrapping for on-screen text.
//
// The width budget is measured by a function you supply, because an engine
// knows its own font. Return a glyph advance in pixels and you wrap to a text
// box; return 1 per character and you wrap to a column count. `monospace` is
// provided for the terminal-ish case, where East Asian characters occupy two
// cells and combining marks occupy none.
//
// The iterator yields `View`s into the original text, so wrapping a string
// costs no allocation at all.
module fluxion::text::wrap;
import fluxion::text::view, fluxion::text::utf8;

<*
 Width of one codepoint, in whatever unit `Options.width` is expressed in.
*>
alias Measure = fn ushort(Char32 codepoint);

<*
 Every codepoint counts as one, so `width` means "characters per line".
*>
fn ushort each(Char32 codepoint)
{
	return 1;
}

<*
 Terminal-style widths: zero for combining marks, two for the East Asian
 wide and fullwidth ranges, one for everything else.

 This covers the ranges that matter in practice rather than the whole of
 Unicode's East Asian Width table; if you need exactness, supply your own.
*>
fn ushort monospace(Char32 codepoint)
{
	if (codepoint == 0) return 0;
	// Combining marks and zero-width formatting characters.
	if ((codepoint >= 0x0300 && codepoint <= 0x036F) ||
		(codepoint >= 0x200B && codepoint <= 0x200F) ||
		(codepoint >= 0xFE00 && codepoint <= 0xFE0F) ||
		(codepoint >= 0x20D0 && codepoint <= 0x20FF)) return 0;
	// Wide and fullwidth.
	if ((codepoint >= 0x1100 && codepoint <= 0x115F) || // Hangul Jamo
		(codepoint >= 0x2E80 && codepoint <= 0x303E) || // CJK radicals, punctuation
		(codepoint >= 0x3041 && codepoint <= 0x33FF) || // Kana, CJK compatibility
		(codepoint >= 0x3400 && codepoint <= 0x4DBF) || // CJK extension A
		(codepoint >= 0x4E00 && codepoint <= 0x9FFF) || // CJK unified
		(codepoint >= 0xA000 && codepoint <= 0xA4CF) || // Yi
		(codepoint >= 0xAC00 && codepoint <= 0xD7A3) || // Hangul syllables
		(codepoint >= 0xF900 && codepoint <= 0xFAFF) || // CJK compatibility ideographs
		(codepoint >= 0xFE30 && codepoint <= 0xFE6F) || // CJK compatibility forms
		(codepoint >= 0xFF00 && codepoint <= 0xFF60) || // Fullwidth forms
		(codepoint >= 0xFFE0 && codepoint <= 0xFFE6) ||
		(codepoint >= 0x1F300 && codepoint <= 0x1F9FF) || // Emoji
		(codepoint >= 0x20000 && codepoint <= 0x3FFFD)) return 2;
	return 1;
}

struct Options
{
	// Budget per line, in the same unit `measure` returns.
	sz width;
	// Null means `each`, so a bare `{ .width = 40 }` wraps by character count.
	Measure measure;
	// Let a word that cannot fit on a line of its own overflow, rather than
	// cutting it. Off by default, which is to say long words are broken.
	bool no_break_long_words;
}

fn Measure Options.measure_fn(&self)
{
	return self.measure == null ? &each : self.measure;
}

<*
 Total width of `text`, by the same measure used for wrapping.
*>
fn sz measure_text(char[] text, Measure measure)
{
	sz total = 0;
	CodepointIterator it;
	it.init(text);
	while (try d = it.next_lossy()) total += measure(d.codepoint);
	return total;
}

fn bool is_breakable(Char32 codepoint) @private
{
	return codepoint == ' ' || codepoint == '\t';
}

// The text is used up.
faultdef NO_MORE_LINES;

<*
 Yields one line at a time, as a view into the original text.

 Explicit newlines are always honoured, trailing spaces are trimmed off each
 line, and the space a line was broken at is consumed rather than pushed onto
 the next line.
*>
struct LineWrapper
{
	char[] text;
	sz index;
	Options options;
}

fn View? LineWrapper.next(&self)
{
	if (self.index >= self.text.len) return NO_MORE_LINES~;

	Measure measure = self.options.measure_fn();
	sz start = self.index;
	sz used = 0;
	// End of the last complete word, i.e. where the line may be cut. -1 until
	// a word has ended.
	sz word_end = -1;
	bool previous_was_space = false;
	sz i = start;

	while (i < self.text.len)
	{
		Decoded d = utf8::decode_lossy(self.text[i..])!!;

		if (d.codepoint == '\n')
		{
			self.index = i + d.len;
			return view::of(trim_trailing(self.text[start:i - start]));
		}

		bool is_space = is_breakable(d.codepoint);
		sz w = measure(d.codepoint);

		// Only a visible character can overflow a line. A space that runs past
		// the edge is simply trimmed, so "Fluxion Text" still fits a width of
		// 12 rather than breaking after "Fluxion".
		if (!is_space && used + w > self.options.width && i > start)
		{
			if (word_end > start)
			{
				self.index = skip_spaces(self.text, word_end);
				return view::of(self.text[start:word_end - start]);
			}
			if (!self.options.no_break_long_words)
			{
				self.index = i;
				return view::of(trim_trailing(self.text[start:i - start]));
			}
			// Let the oversized word run over, and break after it.
			sz end = end_of_word(self.text, i);
			self.index = skip_spaces(self.text, end);
			return view::of(self.text[start:end - start]);
		}

		// The first space after a word marks where that word ended.
		if (is_space && !previous_was_space) word_end = i;
		previous_was_space = is_space;

		used += w;
		i += d.len;
	}

	self.index = self.text.len;
	return view::of(trim_trailing(self.text[start..]));
}

fn void LineWrapper.reset(&self)
{
	self.index = 0;
}

fn char[] trim_trailing(char[] line) @private
{
	sz end = line.len;
	while (end > 0 && (line[end - 1] == ' ' || line[end - 1] == '\t')) end--;
	return line[:end];
}

fn sz skip_spaces(char[] text, sz from) @private
{
	sz i = from;
	while (i < text.len && (text[i] == ' ' || text[i] == '\t')) i++;
	return i;
}

fn sz end_of_word(char[] text, sz from) @private
{
	sz i = from;
	while (i < text.len && text[i] != ' ' && text[i] != '\t' && text[i] != '\n') i++;
	return i;
}

fn LineWrapper wrapper(char[] text, Options options)
{
	return { .text = text, .options = options };
}

<*
 Wrap into a newly allocated string with `\n` between lines. Caller owns the
 result.
*>
fn String wrap_alloc(Allocator allocator, char[] text, Options options)
{
	DString out;
	out.init(allocator);
	defer out.free();

	LineWrapper it = wrapper(text, options);
	bool first = true;
	while (try line = it.next())
	{
		if (!first) out.append_char('\n');
		out.append_bytes(line.bytes);
		first = false;
	}
	return out.copy_str(allocator);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

// A `@body` macro rather than a helper function: the expected lines and the
// input read better next to each other, and the failure message can name the
// line that went wrong.
macro void @expect_lines(String[] expected, char[] text, Options options)
{
	LineWrapper it = wrapper(text, options);
	foreach (i, want : expected)
	{
		View? line = it.next();
		if (catch line)
		{
			test::@check(false, "ran out of lines, wanted \"%s\"", want);
			return;
		}
		test::eq(line.str(), want);
	}
	if (try extra = it.next())
	{
		test::@check(false, "unexpected extra line \"%s\"", extra.str());
	}
}

fn void test_wraps_at_spaces() @test
{
	@expect_lines({ "the quick", "brown fox" }, "the quick brown fox", { .width = 10 });
}

fn void test_text_that_fits_stays_on_one_line() @test
{
	@expect_lines({ "short" }, "short", { .width = 40 });
}

fn void test_empty_input_yields_no_lines() @test
{
	@expect_lines({}, "", { .width = 10 });
}

fn void test_explicit_newlines_are_honoured() @test
{
	@expect_lines({ "one", "two", "three" }, "one\ntwo\nthree", { .width = 40 });
}

fn void test_blank_lines_survive() @test
{
	@expect_lines({ "a", "", "b" }, "a\n\nb", { .width = 40 });
}

fn void test_trailing_spaces_are_trimmed_from_each_line() @test
{
	@expect_lines({ "aaa", "bbb" }, "aaa   bbb", { .width = 4 });
}

fn void test_runs_of_spaces_collapse_at_a_break() @test
{
	@expect_lines({ "aaa", "bbb" }, "aaa     bbb", { .width = 5 });
}

fn void test_long_words_are_broken_by_default() @test
{
	@expect_lines({ "abcde", "fghij", "klm" }, "abcdefghijklm", { .width = 5 });
}

fn void test_long_words_overflow_when_breaking_is_off() @test
{
	@expect_lines({ "abcdefghijklm", "next" }, "abcdefghijklm next",
		{ .width = 5, .no_break_long_words = true });
}

fn void test_a_long_word_after_a_short_one_starts_its_own_line() @test
{
	@expect_lines({ "hi", "abcde", "fgh" }, "hi abcdefgh", { .width = 5 });
}

fn void test_breaking_a_long_word_respects_codepoint_boundaries() @test
{
	// Six 2-byte characters; a byte-based break would split one in half.
	LineWrapper it = wrapper("éééééé", { .width = 2 });
	while (try line = it.next())
	{
		test::@check(line.is_valid_utf8());
		test::eq(line.codepoint_len()!!, 2);
	}
}

fn void test_measure_controls_the_unit() @test
{
	// With `each`, width is a character count.
	test::eq(measure_text("abc", &each), 3);
	// With `monospace`, CJK characters take two cells.
	test::eq(measure_text("漢字", &monospace), 4);
	// Combining marks take none.
	test::eq(measure_text("é", &monospace), 1);
}

fn void test_wraps_by_display_width_not_character_count() @test
{
	// Four CJK characters at two cells each will not fit a width of 6.
	@expect_lines({ "漢字", "漢字" }, "漢字 漢字", { .width = 5, .measure = &monospace });
}

// A stand-in for font metrics: 'i' is narrow, 'W' is wide.
fn ushort advance(Char32 codepoint)
{
	switch (codepoint)
	{
		case 'i':
		case 'l':
		case ' ':
			return 4;
		case 'W':
		case 'M':
			return 20;
		default:
			return 10;
	}
}

fn void test_a_proportional_measure_wraps_by_pixel_budget() @test
{
	// "Wi" is 24px, "ill" 12px; a 30px box fits "Wi" but not "Wi ill".
	@expect_lines({ "Wi", "ill" }, "Wi ill", { .width = 30, .measure = &advance });
}

fn void test_wrap_alloc_joins_with_newlines() @test
{
	String wrapped = wrap_alloc(mem, "the quick brown fox jumps", { .width = 10 });
	defer free(wrapped);
	test::eq(wrapped, "the quick\nbrown fox\njumps");
}

fn void test_lines_are_views_into_the_original_text() @test
{
	String text = "alpha beta";
	LineWrapper it = wrapper(text, { .width = 5 });
	View first = it.next()!!;
	// Same backing memory, not a copy.
	test::@check(first.bytes.ptr == text.ptr);
}

fn void test_a_paragraph_round_trips_through_wrapping() @test
{
	String text = "Fluxion Text is a UTF-8 string toolkit for C3.";
	String wrapped = wrap_alloc(mem, text, { .width = 12 });
	defer free(wrapped);

	LineIterator lines = view::of(wrapped).lines();
	while (try line = lines.next())
	{
		test::@check(measure_text(line.bytes, &each) <= 12);
	}
	// No words were lost or invented.
	Splitter original_words = view::of(text).words();
	Splitter wrapped_words = view::of(wrapped).words();
	while (try want = original_words.next())
	{
		test::eq(wrapped_words.next()!!.str(), want.str());
	}
	test::@error(wrapped_words.next(), view::NO_MORE_PIECES);
}
