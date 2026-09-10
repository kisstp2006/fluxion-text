// SPDX-License-Identifier: CC0-1.0

// Glob matching, for asset filters and command tables.
//
// Supports `*`, `?`, character classes like `[a-z]` and `[!abc]`, and `\` to
// escape any of them. With `no_cross_separator` set, `*` stops at a path
// separator and `**` is the one that crosses it, which is the behaviour people
// expect from `textures/*.png` versus `**/*.png`.
//
// Matching is iterative rather than recursive, so a hostile pattern cannot
// blow the stack. `?` and `*` work in units of codepoints, so they behave
// sensibly on non-ASCII names; character classes are byte-oriented and are
// meant for ASCII ranges.
module fluxion::text::pattern;
import fluxion::text::utf8;

struct Options
{
	// Fold ASCII case on both sides.
	bool ignore_case;
	// Keep `*` inside one path component, so that `**` is needed to descend.
	bool no_cross_separator;
	// What counts as a component break. Zero means `/`.
	char separator;
}

fn char Options.sep(&self)
{
	return self.separator == 0 ? '/' : self.separator;
}

<*
 Match `text` against `pattern`, where `*` spans anything.
*>
fn bool match(char[] pattern, char[] text, Options options = {})
{
	if (options.no_cross_separator) return match_components(pattern, text, options);
	return match_segment(pattern, text, options);
}

<*
 Match a path, where `*` stays within one component and `**` spans them.
*>
fn bool match_path(char[] pattern, char[] text, Options options = {})
{
	options.no_cross_separator = true;
	return match_components(pattern, text, options);
}

<*
 Wildcard matching with no notion of separators, so `*` spans anything.

 This is the classic two-pointer algorithm. Keeping only the most recent star
 is sound precisely because `*` is unconstrained here: if a later star fails,
 no amount of extra text given to an earlier one would have helped.
*>
fn bool match_segment(char[] pattern, char[] text, Options options) @private
{
	sz p = 0;
	sz t = 0;

	// Where to resume from if the most recent star must swallow more text.
	sz star_p = -1;
	sz star_t = 0;

	while (t < text.len)
	{
		if (p < pattern.len && pattern[p] == '*')
		{
			while (p < pattern.len && pattern[p] == '*') p++; // collapse a run
			star_p = p;
			star_t = t;
			continue;
		}

		if (p < pattern.len)
		{
			Step step = match_one(pattern, p, text, t, options);
			if (step.matched)
			{
				p += step.pattern_len;
				t += step.text_len;
				continue;
			}
		}

		// No match here: let the last star absorb one more codepoint.
		if (star_p < 0) return false;
		if (star_t >= text.len) return false;
		star_t += codepoint_len(text, star_t);
		p = star_p;
		t = star_t;
	}

	while (p < pattern.len && pattern[p] == '*') p++;
	return p == pattern.len;
}

<*
 Match component by component, with `**` as the only thing that spans them.

 Splitting first is what makes this correct. A constrained `*` breaks the
 single-star shortcut above - once `textures/**/*.png` fails on `*.png`, the
 `**` really does need to swallow another component - but at this level the
 only wildcard is `**`, which is unconstrained again, so the same two-pointer
 argument applies. Within one component there are no separators, so `*` is
 unconstrained there too and `match_segment` handles it.

 `**` is only special as a whole component; `a**b` is just `a*b`.
*>
fn bool match_components(char[] pattern, char[] text, Options options) @private
{
	char separator = options.sep();
	sz p_off = 0;
	sz t_off = 0;
	sz star_p = -1;
	sz star_t = 0;

	while (true)
	{
		sz t_next = t_off;
		char[] t_comp;
		if (!next_component(text, &t_next, separator, &t_comp)) break;

		sz p_next = p_off;
		char[] p_comp;
		bool has_pattern = next_component(pattern, &p_next, separator, &p_comp);

		if (has_pattern)
		{
			if (p_comp == "**")
			{
				p_off = p_next;
				star_p = p_next;
				star_t = t_off;
				continue;
			}
			if (match_segment(p_comp, t_comp, options))
			{
				p_off = p_next;
				t_off = t_next;
				continue;
			}
		}

		// Hand one more component to the last `**`.
		if (star_p < 0) return false;
		sz skip = star_t;
		char[] discarded;
		if (!next_component(text, &skip, separator, &discarded)) return false;
		star_t = skip;
		t_off = skip;
		p_off = star_p;
	}

	// The text ran out; whatever is left of the pattern must match nothing.
	char[] p_comp;
	while (next_component(pattern, &p_off, separator, &p_comp))
	{
		if (p_comp != "**") return false;
	}
	return true;
}

// The next non-empty component at `offset`, advancing it past that component.
// Returns false at the end, which is why the component comes back through a
// pointer: C3 has no tuple, and an optional would read as an error here.
fn bool next_component(char[] s, sz* offset, char separator, char[]* out) @private
{
	sz i = *offset;
	while (i < s.len && s[i] == separator) i++;
	if (i >= s.len)
	{
		*offset = i;
		return false;
	}
	sz start = i;
	while (i < s.len && s[i] != separator) i++;
	*offset = i;
	*out = s[start:i - start];
	return true;
}

fn sz codepoint_len(char[] text, sz index) @private
{
	Decoded? d = utf8::decode_lossy(text[index..]);
	if (catch d) return 1;
	return d.len;
}

struct Step @private
{
	bool matched;
	sz pattern_len;
	sz text_len;
}

// Match the single pattern atom at `pattern[p]` against `text[t]`, returning
// how far each side advances.
fn Step match_one(char[] pattern, sz p, char[] text, sz t, Options options) @private
{
	switch (pattern[p])
	{
		case '?':
			return { .matched = true, .pattern_len = 1, .text_len = codepoint_len(text, t) };
		case '[':
			return match_class(pattern, p, text[t], options);
		case '\\':
			// A trailing backslash matches nothing.
			if (p + 1 >= pattern.len) return {};
			if (!equal_byte(pattern[p + 1], text[t], options)) return {};
			return { .matched = true, .pattern_len = 2, .text_len = 1 };
		default:
			if (!equal_byte(pattern[p], text[t], options)) return {};
			return { .matched = true, .pattern_len = 1, .text_len = 1 };
	}
}

fn bool equal_byte(char a, char b, Options options) @private
{
	if (!options.ignore_case) return a == b;
	return a.to_lower() == b.to_lower();
}

// Match a `[...]` class. An unterminated `[` is treated as a literal bracket.
fn Step match_class(char[] pattern, sz open, char c, Options options) @private
{
	sz i = open + 1;
	bool negated = false;
	if (i < pattern.len && (pattern[i] == '!' || pattern[i] == '^'))
	{
		negated = true;
		i++;
	}

	bool found = false;
	bool first = true;
	while (i < pattern.len)
	{
		// A `]` in the first position is a literal, per the usual glob rules.
		if (pattern[i] == ']' && !first)
		{
			if (found == negated) return {};
			return { .matched = true, .pattern_len = i + 1 - open, .text_len = 1 };
		}
		first = false;

		char low = pattern[i];
		if (low == '\\' && i + 1 < pattern.len)
		{
			i++;
			low = pattern[i];
		}
		i++;

		// A range, unless the '-' is the last thing before the closing ']'.
		if (i + 1 < pattern.len && pattern[i] == '-' && pattern[i + 1] != ']')
		{
			i++;
			char high = pattern[i];
			if (high == '\\' && i + 1 < pattern.len)
			{
				i++;
				high = pattern[i];
			}
			i++;
			if (in_range(c, low, high, options)) found = true;
		}
		else if (equal_byte(low, c, options))
		{
			found = true;
		}
	}

	// Never closed: fall back to treating '[' as an ordinary character.
	if (!equal_byte('[', c, options)) return {};
	return { .matched = true, .pattern_len = 1, .text_len = 1 };
}

fn bool in_range(char c, char low, char high, Options options) @private
{
	if (!options.ignore_case) return c >= low && c <= high;
	char lc = c.to_lower();
	char uc = c.to_upper();
	return (lc >= low.to_lower() && lc <= high.to_lower()) ||
		(uc >= low.to_upper() && uc <= high.to_upper());
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_literals() @test
{
	test::@check(match("cursor.png", "cursor.png"));
	test::@check(!match("cursor.png", "cursor.jpg"));
	test::@check(!match("cursor", "cursor.png"));
	test::@check(match("", ""));
	test::@check(!match("", "x"));
}

fn void test_star() @test
{
	test::@check(match("*.png", "cursor.png"));
	test::@check(match("*", "anything"));
	test::@check(match("*", ""));
	test::@check(match("cursor.*", "cursor.png"));
	test::@check(match("*cursor*", "ui_cursor_2x"));
	test::@check(!match("*.png", "cursor.jpg"));

	// A star may match nothing at all.
	test::@check(match("a*b", "ab"));
	test::@check(match("a*", "a"));
}

fn void test_several_stars_backtrack_correctly() @test
{
	test::@check(match("*a*b*c*", "xxaxxbxxcxx"));
	test::@check(!match("*a*b*c*", "xxaxxcxxbxx"));
	test::@check(match("**", "anything"));
	test::@check(match("a**b", "aXXXb"));
}

fn void test_question_mark_matches_one_codepoint() @test
{
	test::@check(match("?", "a"));
	test::@check(match("?", "é")); // one character, two bytes
	test::@check(match("???", "abc"));
	test::@check(!match("?", ""));
	test::@check(!match("?", "ab"));
	test::@check(match("caf?", "café"));
}

fn void test_character_classes() @test
{
	test::@check(match("[abc]", "b"));
	test::@check(!match("[abc]", "d"));
	test::@check(match("[a-z]", "q"));
	test::@check(!match("[a-z]", "Q"));
	test::@check(match("[0-9a-f]", "e"));
	test::@check(match("tile_[0-9][0-9].png", "tile_07.png"));
	test::@check(!match("tile_[0-9][0-9].png", "tile_7x.png"));
}

fn void test_negated_classes() @test
{
	test::@check(match("[!abc]", "d"));
	test::@check(!match("[!abc]", "a"));
	test::@check(match("[^0-9]", "x"));
	test::@check(!match("[^0-9]", "5"));
}

fn void test_class_edge_cases() @test
{
	// A ']' straight after '[' is a literal.
	test::@check(match("[]]", "]"));
	// A '-' at the end of a class is a literal.
	test::@check(match("[a-]", "-"));
	test::@check(match("[a-]", "a"));
	// An unterminated '[' is a literal bracket.
	test::@check(match("[abc", "[abc"));
}

fn void test_escaping() @test
{
	test::@check(match(`\*`, "*"));
	test::@check(!match(`\*`, "star"));
	test::@check(match(`\?`, "?"));
	test::@check(match(`\[a\]`, "[a]"));
	test::@check(match(`[\]]`, "]"));
}

fn void test_case_insensitivity() @test
{
	test::@check(match("*.PNG", "cursor.png", { .ignore_case = true }));
	test::@check(match("[A-Z]*", "cursor", { .ignore_case = true }));
	test::@check(!match("*.PNG", "cursor.png"));
}

fn void test_path_mode_keeps_star_inside_one_component() @test
{
	test::@check(match_path("textures/*.png", "textures/cursor.png"));
	test::@check(!match_path("textures/*.png", "textures/ui/cursor.png"));
	test::@check(!match_path("*.png", "ui/cursor.png"));

	// '?' will not eat a separator either.
	test::@check(!match_path("a?b", "a/b"));
}

fn void test_double_star_descends() @test
{
	test::@check(match_path("**/*.wav", "sounds/sfx/hit.wav"));
	test::@check(match_path("**/*.wav", "sounds/hit.wav"));
	test::@check(match_path("sounds/**", "sounds/sfx/hit.wav"));
	test::@check(match_path("**", "a/b/c"));
	test::@check(!match_path("**/*.wav", "sounds/sfx/hit.ogg"));
}

fn void test_a_nested_star_must_be_able_to_give_ground_to_an_outer_one() @test
{
	// The regression this covers: matching "ui" against "*.png" fails, and the
	// only way forward is for the preceding "**" to swallow another component.
	// Single-star backtracking cannot do that, which is why path mode splits
	// into components first.
	test::@check(match_path("textures/**/*.png", "textures/ui/icons/close.png"));
	test::@check(match_path("**/*.png", "a/b/c/d/e.png"));
	test::@check(!match_path("textures/**/*.png", "textures/ui/icons/close.jpg"));
}

fn void test_several_double_stars() @test
{
	test::@check(match_path("a/**/b/**/c", "a/x/y/b/z/c"));
	test::@check(match_path("**/**/*.png", "a/b/c.png"));
	test::@check(!match_path("a/**/b/**/c", "a/x/y/b/z/d"));
}

fn void test_double_star_matches_zero_components() @test
{
	test::@check(match_path("a/**/c", "a/c"));
	test::@check(match_path("**/a", "a"));
	test::@check(!match_path("a/**/c", "a/b/d"));
}

fn void test_path_mode_handles_empty_and_separator_only_input() @test
{
	test::@check(match_path("", ""));
	test::@check(!match_path("", "a"));
	test::@check(!match_path("a", ""));
	// Repeated and trailing separators are absorbed.
	test::@check(match_path("a/b", "a//b/"));
	test::@check(match_path("**", ""));
}

fn void test_default_mode_lets_star_cross_separators() @test
{
	test::@check(match("textures/*.png", "textures/ui/cursor.png"));
	test::@check(match("*.png", "a/b/c.png"));
}

fn void test_a_pathological_pattern_still_terminates() @test
{
	// The classic exponential-backtracking case for a recursive matcher.
	char[64] text;
	text[..] = 'a';
	test::@check(!match("*a*a*a*a*a*a*a*a*b", &text));
}

fn void test_realistic_asset_filters() @test
{
	test::@check(match_path("textures/**/*.png", "textures/ui/icons/close.png"));
	test::@check(match_path("*.[oa]", "libfoo.a"));
	test::@check(match("Enemy_*", "enemy_goblin", { .ignore_case = true }));
	test::@check(!match_path("textures/**/*.png", "sounds/ui/click.wav"));
}
