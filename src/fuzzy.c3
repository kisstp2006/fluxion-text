// SPDX-License-Identifier: CC0-1.0

// Fuzzy matching, for developer consoles and asset browsers.
//
// Two different jobs live here:
//
//   * `score` ranks candidates against what the user has typed so far, the
//     way a command palette does. `spwn` should find `spawn_enemy`.
//   * `edit_distance` and `closest` answer "did you mean?" after a command
//     has already failed.
//
// Neither allocates.
module fluxion::text::fuzzy;

struct Options
{
	// Match case exactly. Off by default, because a console is typed in
	// lower case and the commands are not always.
	bool case_sensitive;
}

// Longest input `edit_distance` will consider. Command and asset names are
// far below this; anything longer is rejected rather than silently truncated.
const sz MAX_DISTANCE_LEN = 255;

// `needle` is not a subsequence of the candidate.
faultdef NO_MATCH;

// The two strings are further apart than the budget allowed.
faultdef TOO_FAR;

// One of the inputs is longer than `MAX_DISTANCE_LEN`.
faultdef INPUT_TOO_LONG;

// Nothing was close enough to suggest.
faultdef NO_CANDIDATE;

// -------------------------------------------------------------------------
// Subsequence scoring
// -------------------------------------------------------------------------

// Tuned so that, given several candidates containing the typed letters, the
// ones a human would pick first come out on top.
const int SCORE_MATCH = 16;
const int BONUS_CONSECUTIVE = 15;
const int BONUS_WORD_START = 30;
const int BONUS_FIRST_CHAR = 20;
const int PENALTY_GAP = -4;
const int PENALTY_UNMATCHED_TAIL = -1;

fn bool equal_byte(char a, char b, Options options) @private
{
	if (options.case_sensitive) return a == b;
	return a.to_lower() == b.to_lower();
}

fn bool is_word_start(char[] haystack, sz i) @private
{
	if (i == 0) return true;
	char prev = haystack[i - 1];
	char cur = haystack[i];
	if (prev == '_' || prev == '-' || prev == '.' || prev == '/' || prev == ' ') return true;
	// camelCase transition.
	return prev.is_lower() && cur.is_upper();
}

<*
 Score how well `needle` matches `haystack`, or `NO_MATCH` when `needle` is
 not a subsequence of it. Higher is better; scores are only comparable
 between candidates scored against the same needle.

 An empty needle scores 0, so "nothing typed yet" ranks everything equally.
*>
fn int? score(char[] needle, char[] haystack, Options options = {})
{
	if (needle.len == 0) return 0;
	if (needle.len > haystack.len) return NO_MATCH~;

	int total = 0;
	sz h = 0;
	sz previous_match = -1;

	foreach (want : needle)
	{
		// Walk forward to the next occurrence.
		while (h < haystack.len && !equal_byte(want, haystack[h], options)) h++;
		if (h >= haystack.len) return NO_MATCH~;

		total += SCORE_MATCH;
		if (h == 0) total += BONUS_FIRST_CHAR;
		if (is_word_start(haystack, h)) total += BONUS_WORD_START;
		if (previous_match >= 0)
		{
			if (h == previous_match + 1)
			{
				total += BONUS_CONSECUTIVE;
			}
			else
			{
				total += PENALTY_GAP * (int)min(h - previous_match - 1, (sz)32);
			}
		}

		previous_match = h;
		h++;
	}

	// Prefer the tighter candidate when two otherwise score alike.
	total += PENALTY_UNMATCHED_TAIL * (int)min(haystack.len - needle.len, (sz)64);
	return total;
}

<*
 Whether `needle` appears in `haystack` as a subsequence.
*>
fn bool matches(char[] needle, char[] haystack, Options options = {})
{
	return @ok(score(needle, haystack, options));
}

struct Ranked
{
	sz index;
	int score;
}

<*
 Score every candidate, keeping the ones that match, best first.

 Results are written into `out` and the filled prefix is returned, so this
 never allocates. Candidates beyond `out.len` are still considered: the
 weakest result is dropped to make room.
*>
fn Ranked[] rank(char[] needle, String[] candidates, Ranked[] out, Options options = {})
{
	if (out.len == 0) return out[:0];
	sz n = 0;

	foreach (i, candidate : candidates)
	{
		int? s = score(needle, candidate, options);
		if (catch s) continue;

		if (n < out.len)
		{
			out[n] = { .index = i, .score = s };
			n++;
		}
		else if (s > out[n - 1].score)
		{
			out[n - 1] = { .index = i, .score = s };
		}
		else
		{
			continue;
		}

		// Bubble the new entry into place; `out` stays sorted at all times.
		sz j = n - 1;
		while (j > 0 && out[j].score > out[j - 1].score)
		{
			Ranked swap = out[j];
			out[j] = out[j - 1];
			out[j - 1] = swap;
			j--;
		}
	}
	return out[:n];
}

// -------------------------------------------------------------------------
// Edit distance
// -------------------------------------------------------------------------

<*
 Levenshtein distance between `a` and `b`, or `TOO_FAR` when it exceeds
 `max`.

 Bailing out at `max` is not just an optimisation: a "did you mean?" prompt
 only cares about near misses, and stopping early keeps the cost down.
*>
fn sz? edit_distance(char[] a, char[] b, sz max)
{
	// Keep the shorter string on the row axis so the buffer stays small.
	char[] shorter = a.len <= b.len ? a : b;
	char[] longer = a.len <= b.len ? b : a;
	if (longer.len > MAX_DISTANCE_LEN) return INPUT_TOO_LONG~;

	if (longer.len - shorter.len > max) return TOO_FAR~;
	if (shorter.len == 0)
	{
		if (longer.len > max) return TOO_FAR~;
		return longer.len;
	}

	sz[MAX_DISTANCE_LEN + 1] row;
	for (sz i = 0; i <= shorter.len; i++) row[i] = i;

	foreach (li, lc : longer)
	{
		sz i = li + 1;
		sz previous_diagonal = row[0];
		row[0] = i;
		sz best = row[0];

		foreach (sj, sc : shorter)
		{
			sz j = sj + 1;
			sz cost = lc == sc ? 0 : 1;
			sz substitute = previous_diagonal + cost;
			sz insert = row[j] + 1;
			sz delete_one = row[j - 1] + 1;
			previous_diagonal = row[j];
			row[j] = min(substitute, min(insert, delete_one));
			best = min(best, row[j]);
		}

		// Every remaining row can only grow this minimum, so we can stop.
		if (best > max) return TOO_FAR~;
	}

	sz result = row[shorter.len];
	if (result > max) return TOO_FAR~;
	return result;
}

struct Match
{
	sz index;
	sz distance;
}

<*
 The candidate nearest to `needle` within `max_edits`, for suggesting a
 correction. Ties go to the earlier candidate.
*>
fn Match? closest(char[] needle, String[] candidates, sz max_edits)
{
	Match best;
	bool found = false;
	foreach (i, candidate : candidates)
	{
		// Each hit narrows the budget, so later candidates are cheaper to
		// reject: only something strictly nearer is worth measuring.
		sz limit = found ? min(max_edits, best.distance == 0 ? 0 : best.distance - 1) : max_edits;
		sz? d = edit_distance(needle, candidate, limit);
		if (catch err = d)
		{
			if (err == INPUT_TOO_LONG) return err~;
			continue;
		}
		if (!found || d < best.distance)
		{
			best = { .index = i, .distance = d };
			found = true;
		}
	}
	if (!found) return NO_CANDIDATE~;
	return best;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_score_finds_subsequences() @test
{
	test::@check(matches("spwn", "spawn_enemy"));
	test::@check(matches("se", "spawn_enemy"));
	test::@check(!matches("xyz", "spawn_enemy"));
	// Order matters: the letters must appear in sequence.
	test::@check(!matches("nwps", "spawn_enemy"));
}

fn void test_an_empty_needle_matches_everything() @test
{
	test::eq(score("", "anything")!!, 0);
	test::eq(score("", "")!!, 0);
}

fn void test_a_needle_longer_than_the_haystack_cannot_match() @test
{
	test::@error(score("spawn_enemy", "spwn"), NO_MATCH);
}

fn void test_case_sensitivity() @test
{
	test::@check(matches("SPWN", "spawn_enemy"));
	test::@check(!matches("SPWN", "spawn_enemy", { .case_sensitive = true }));
}

fn void test_consecutive_matches_beat_scattered_ones() @test
{
	int tight = score("spa", "spawn")!!;
	int loose = score("spa", "set_player_alpha")!!;
	test::@check(tight > loose);
}

fn void test_word_starts_are_rewarded() @test
{
	// 'se' as two word initials should beat 'se' buried inside one word.
	int initials = score("se", "spawn_enemy")!!;
	int buried = score("se", "unset")!!;
	test::@check(initials > buried);
}

fn void test_camel_case_counts_as_a_word_start() @test
{
	int camel = score("se", "spawnEnemy")!!;
	int flat = score("se", "spawnenemy")!!;
	test::@check(camel > flat);
}

fn void test_a_prefix_match_beats_a_later_one() @test
{
	int prefix = score("spa", "spawn")!!;
	int later = score("spa", "respawn")!!;
	test::@check(prefix > later);
}

fn void test_shorter_candidates_win_ties() @test
{
	int short_one = score("ab", "ab")!!;
	int long_one = score("ab", "ab_with_a_long_tail")!!;
	test::@check(short_one > long_one);
}

fn void test_rank_orders_candidates_best_first() @test
{
	String[] commands = { "quit", "spawn_enemy", "set_gravity", "screenshot", "reload_shaders" };
	Ranked[8] buf;
	Ranked[] results = rank("se", commands, &buf);

	test::@check(results.len >= 2);
	// Sorted descending.
	for (sz i = 1; i < results.len; i++) test::@check(results[i - 1].score >= results[i].score);
	// "set_gravity" and "spawn_enemy" both hit word starts; "screenshot" does
	// not, so it must not come first.
	test::@check(results[0].index == 1 || results[0].index == 2);
	// "quit" has no 's', so it is filtered out entirely.
	foreach (r : results) test::@check(r.index != 0);
}

fn void test_rank_respects_a_small_output_buffer() @test
{
	String[] commands = { "aaa", "aab", "aac", "aad" };
	Ranked[2] buf;
	Ranked[] results = rank("aa", commands, &buf);
	test::eq(results.len, 2);
	test::@check(results[0].score >= results[1].score);

	Ranked[] none;
	test::eq(rank("aa", commands, none).len, 0);
}

fn void test_edit_distance() @test
{
	test::eq(edit_distance("spawn", "spawn", 4)!!, 0);
	test::eq(edit_distance("spawn", "spwn", 4)!!, 1);
	test::eq(edit_distance("spwn", "spawn", 4)!!, 1);
	test::eq(edit_distance("kitten", "sitting", 4)!!, 3);
	test::eq(edit_distance("", "spawn", 8)!!, 5);
	test::eq(edit_distance("", "", 0)!!, 0);
}

fn void test_edit_distance_bails_out_past_the_limit() @test
{
	test::@error(edit_distance("kitten", "sitting", 2), TOO_FAR);
	test::@error(edit_distance("abc", "xyz", 2), TOO_FAR);
	// A length difference alone can exceed the budget.
	test::@error(edit_distance("a", "abcdefgh", 3), TOO_FAR);
}

fn void test_edit_distance_is_symmetric() @test
{
	test::eq(edit_distance("reload_shaders", "reload_shader", 4)!!,
		edit_distance("reload_shader", "reload_shaders", 4)!!);
}

fn void test_edit_distance_rejects_overlong_input() @test
{
	char[MAX_DISTANCE_LEN + 1] long_one;
	long_one[..] = 'a';
	test::@error(edit_distance(&long_one, "a", 4), INPUT_TOO_LONG);
	test::@error(edit_distance("a", &long_one, 4), INPUT_TOO_LONG);
}

fn void test_closest_suggests_a_correction() @test
{
	String[] commands = { "quit", "spawn_enemy", "set_gravity", "screenshot" };

	Match hit = closest("spawn_enemey", commands, 3)!!;
	test::eq(hit.index, 1);
	test::eq(hit.distance, 1);

	// Nothing is close enough to be worth suggesting.
	test::@error(closest("zzzzzzzz", commands, 2), NO_CANDIDATE);
	test::@error(closest("anything", {}, 4), NO_CANDIDATE);
}

fn void test_closest_picks_the_nearest_of_several() @test
{
	String[] candidates = { "spawn", "spawns", "spwn" };
	Match hit = closest("spawn", candidates, 3)!!;
	test::eq(hit.index, 0);
	test::eq(hit.distance, 0);
}

fn void test_a_console_flow_rank_while_typing_suggest_on_failure() @test
{
	String[] commands = { "spawn_enemy", "set_gravity", "screenshot", "quit" };

	// The user has typed "spw" - offer completions.
	Ranked[4] buf;
	Ranked[] suggestions = rank("spw", commands, &buf);
	test::eq(suggestions.len, 1);
	test::eq(commands[suggestions[0].index], "spawn_enemy");

	// They committed a typo instead - offer the nearest real command.
	test::@check(!matches("screenshto", "screenshot"));
	Match did_you_mean = closest("screenshto", commands, 2)!!;
	test::eq(commands[did_you_mean.index], "screenshot");
}
