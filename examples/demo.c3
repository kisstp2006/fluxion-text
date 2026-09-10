// SPDX-License-Identifier: CC0-1.0

// A tour of Fluxion Text. Run it with `c3c run demo`.
module demo;
import std::io;
import fluxion::text;

// A backtick string is C3's raw literal: no escape processing, so the
// backslashes and quotes below are exactly the bytes a config file would hold.
const String SOURCE = `# server settings
host    = localhost
port    = 8080
retries = 0x1F
timeout = 2.5
debug   = false
name    = "café 漢字"
`;

enum ValueKind
{
	STRING,
	BOOLEAN,
	INT,
	FLOAT,
	RAW,
}

struct Value
{
	ValueKind kind;
	View text;
	bool boolean;
	long integer;
	double real;
}

// Try each value shape in turn, rewinding the cursor between attempts. This
// is what `save`/`restore` is for: a value that starts with digits might be
// an integer or a float, and only the byte after them says which.
fn Value parse_value(Parser* p)
{
	if (try s = p.take_quoted('"')) return { .kind = STRING, .text = s };
	if (try b = p.take_bool()) return { .kind = BOOLEAN, .boolean = b };

	Mark mark = p.save();
	if (try n = p.take_int(long))
	{
		// A '.' or exponent right after the digits means it was really a float.
		char? next = p.peek();
		if (catch next) return { .kind = INT, .integer = n };
		if (next != '.' && next != 'e' && next != 'E') return { .kind = INT, .integer = n };
		p.restore(mark);
	}

	if (try f = p.take_float()) return { .kind = FLOAT, .real = f };
	p.restore(mark);

	return { .kind = RAW, .text = p.take_until_char('\n') };
}

fn void main()
{
	Interner symbols;
	symbols.init(mem);
	defer symbols.free();

	// A Builder is an OutStream, so anything that can print can print here.
	Builder report = text::build(mem);
	defer report.free();

	Parser p = text::parse(SOURCE);
	while (!p.is_at_end())
	{
		p.skip_whitespace();
		if (p.is_at_end()) break;

		if (p.eat('#'))
		{
			report.printf("comment  %s\n", p.take_line()!!.trim());
			continue;
		}

		View? key = p.take_identifier();
		if (catch key)
		{
			report.printf("junk at %s\n", &&p.location());
			p.take_line()!!;
			continue;
		}
		StringId id = symbols.intern_view(key);

		p.skip_inline_whitespace();
		p.expect('=')!!;
		p.skip_inline_whitespace();

		report.printf("%s %s = ", id, symbols.resolve(id));
		Value value = parse_value(&p);
		switch (value.kind)
		{
			case STRING:
				report.printf("string %s (%d codepoints)\n", value.text, value.text.codepoint_len()!!);
			case BOOLEAN:
				report.printf("bool %s\n", value.boolean);
			case INT:
				report.printf("int %d\n", value.integer);
			case FLOAT:
				report.printf("float %s\n", value.real);
			case RAW:
				report.printf("raw %s\n", value.text.trim());
		}
	}

	io::printfn("--- parser + interner + builder ---\n%s", &report);

	// Views slice without copying.
	View line = text::of("  host    = localhost  ");
	Pair pair = line.trim().split_once("=")!!;
	io::printfn("\n--- view ---\nkey=%s value=%s", pair.before.trim(), pair.after.trim());

	// UTF-8 aware truncation never splits a character in half.
	View label = text::of("café 漢字");
	io::printfn("\n--- utf8 ---\n%d bytes, %d codepoints, cut to 5 bytes: %s",
		label.len(), label.codepoint_len()!!, label.truncate_bytes(5));

	// Interned ids compare as integers and resolve back to text.
	io::printfn("\n--- interned keys (%d) ---", symbols.count());
	EntryIterator it = symbols.iterator();
	while (try entry = it.next()) io::printfn("  %s -> %s", entry.id, entry.text);

	// The path, pattern, fuzzy and wrap modules, on the sort of data a loader
	// actually sees.
	io::printn("\n--- paths and patterns ---");
	char[64] buf;
	char[] asset = path::normalize_buf(&buf, "assets\\textures\\..\\ui\\cursor.PNG")!!;
	io::printfn("  normalised  %s", (String)asset);
	io::printfn("  stem        %s", path::stem(asset));
	io::printfn("  extension   %s   png? %s", path::extension(asset), path::has_extension(asset, "png"));
	io::printfn("  matches assets/**/*.PNG  %s", pattern::match_path("assets/**/*.PNG", asset));

	io::printn("\n--- a console ---");
	String[] commands = { "spawn_enemy", "set_gravity", "screenshot", "quit" };
	Ranked[4] ranked;
	Ranked[] hits = fuzzy::rank("spw", commands, &ranked);
	foreach (hit : hits) io::printfn("  spw -> %s (score %d)", commands[hit.index], hit.score);
	Match suggestion = fuzzy::closest("screenshto", commands, 2)!!;
	io::printfn("  screenshto -> did you mean %s?", commands[suggestion.index]);

	io::printn("\n--- wrapped to 28 columns ---");
	LineWrapper wrapped = wrap::wrapper(
		"Fluxion Text is a UTF-8 string toolkit for C3, and every line here is a view into that one sentence.",
		{ .width = 28 });
	while (try wrapped_line = wrapped.next()) io::printfn("  |%s|", wrapped_line);
}
