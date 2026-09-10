// SPDX-License-Identifier: CC0-1.0

// Virtual asset paths.
//
// This is deliberately *not* the standard library's `std::io::path`. A game's
// asset paths are a platform-independent namespace: `textures/ui/cursor.png`
// means the same thing whether it comes out of a directory on Windows, a pak
// file, or a console filesystem. So separators are always `/` on output, drive
// letters are none of our business, and nothing here touches the filesystem.
//
// Backslashes are accepted on input, because that is what a Windows drag and
// drop or a directory listing will hand you.
module fluxion::text::path;
import fluxion::text::view;

// The separator used in output. Input accepts `\` as well.
const char SEPARATOR = '/';

fn bool is_separator(char c)
{
	return c == '/' || c == '\\';
}

// The path has no separator, so there is no directory part to name.
faultdef NO_DIRECTORY;

// The destination buffer is too small.
faultdef NO_SPACE;

// A `..` tried to escape above the root of an absolute path.
faultdef ESCAPES_ROOT;

fn sz last_separator(char[] p, sz end) @private
{
	sz i = end;
	while (i > 0)
	{
		i--;
		if (is_separator(p[i])) return i;
	}
	return -1;
}

<*
 True if the path starts at the root of its namespace.
*>
fn bool is_absolute(char[] p)
{
	return p.len > 0 && is_separator(p[0]);
}

<*
 The final component: `"a/b/c.png"` -> `"c.png"`.
*>
fn View basename(char[] p)
{
	// A trailing separator is ignored, so "a/b/" has basename "b".
	sz end = p.len;
	while (end > 0 && is_separator(p[end - 1])) end--;
	sz cut = last_separator(p, end);
	sz start = cut < 0 ? 0 : cut + 1;
	return view::of(p[start:end - start]);
}

<*
 Everything before the final component: `"a/b/c.png"` -> `"a/b"`.
 `NO_DIRECTORY` when there is no separator at all.
*>
fn View? dirname(char[] p)
{
	sz end = p.len;
	while (end > 0 && is_separator(p[end - 1])) end--;
	sz cut = last_separator(p, end);
	if (cut < 0) return NO_DIRECTORY~;
	if (cut == 0) return view::of(p[:1]); // keep the root "/"
	return view::of(p[:cut]);
}

<*
 The extension including its dot: `"c.png"` -> `".png"`. Empty when there is
 none. A leading dot does not count, so `".gitignore"` has no extension.
*>
fn View extension(char[] p)
{
	char[] base = basename(p).bytes;
	if (base.len == 0) return view::of(base[:0]);
	sz dot = -1;
	foreach (i, c : base)
	{
		if (c == '.') dot = i;
	}
	if (dot <= 0) return view::of(base[base.len..]);
	return view::of(base[dot..]);
}

<*
 The final component without its extension: `"a/b/c.png"` -> `"c"`.
*>
fn View stem(char[] p)
{
	char[] base = basename(p).bytes;
	sz ext = extension(p).len();
	return view::of(base[:base.len - ext]);
}

<*
 The whole path minus the extension: `"a/b/c.png"` -> `"a/b/c"`.
*>
fn View without_extension(char[] p)
{
	return view::of(p[:p.len - extension(p).len()]);
}

<*
 Case-insensitive extension test. `ext` may be given with or without its dot.
*>
fn bool has_extension(char[] p, char[] ext)
{
	View actual = extension(p);
	if (actual.is_empty()) return ext.len == 0;
	if (ext.len > 0 && ext[0] == '.') return actual.equals_ignore_case(view::of(ext));
	return actual.slice_from(1).equals_ignore_case(view::of(ext));
}

// The walk is finished.
faultdef NO_MORE_COMPONENTS;

<*
 Walk the non-empty components of a path, treating both separators alike.
*>
struct ComponentIterator
{
	char[] bytes;
	sz index;
}

fn View? ComponentIterator.next(&self)
{
	while (self.index < self.bytes.len && is_separator(self.bytes[self.index])) self.index++;
	if (self.index >= self.bytes.len) return NO_MORE_COMPONENTS~;

	sz start = self.index;
	while (self.index < self.bytes.len && !is_separator(self.bytes[self.index])) self.index++;
	return view::of(self.bytes[start:self.index - start]);
}

fn void ComponentIterator.reset(&self)
{
	self.index = 0;
}

fn ComponentIterator components(char[] p)
{
	return { .bytes = p };
}

<*
 Join `parts` with `/` into `buf`, skipping empty parts and collapsing
 separators. Returns the slice of `buf` that was written.
*>
fn char[]? join_buf(char[] buf, String[] parts)
{
	sz written = 0;
	foreach (part : parts)
	{
		char[] trimmed = view::of(part).trim_chars("/\\").bytes;
		if (trimmed.len == 0) continue;
		if (written != 0)
		{
			if (written + 1 > buf.len) return NO_SPACE~;
			buf[written] = SEPARATOR;
			written++;
		}
		if (written + trimmed.len > buf.len) return NO_SPACE~;
		mem::copy(&buf[written], trimmed.ptr, (usz)trimmed.len);
		written += trimmed.len;
	}
	return buf[:written];
}

<*
 Like `join_buf`, but allocating. Caller owns the result.
*>
fn String? join(Allocator allocator, String[] parts)
{
	sz total = 0;
	foreach (part : parts) total += part.len + 1;
	char[] buf = alloc::alloc_array(allocator, char, total == 0 ? 1 : total);
	char[]? written = join_buf(buf, parts);
	if (catch err = written)
	{
		alloc::free(allocator, buf.ptr);
		return err~;
	}
	String result = ((String)written).copy(allocator);
	alloc::free(allocator, buf.ptr);
	return result;
}

// Offset where the final component of `buf[:written]` begins, or -1 when
// there is no component to speak of.
fn sz last_component_start(char[] buf, sz written, sz root_len) @private
{
	if (written <= root_len) return -1;
	sz i = written;
	while (i > root_len)
	{
		i--;
		if (buf[i] == SEPARATOR) return i + 1;
	}
	return root_len;
}

<*
 Resolve `.` and `..`, collapse repeated separators, and emit `/` throughout.
 Returns the slice of `buf` that was written.

 A relative path may keep leading `..` components, because there is nothing
 above it to resolve them against. An absolute path may not: `/..` is an error
 rather than a silent no-op, since it usually means a bad asset id.
*>
fn char[]? normalize_buf(char[] buf, char[] p)
{
	bool absolute = is_absolute(p);
	// Bytes at the front that `..` may never eat into: the leading "/", if any.
	sz root_len = absolute ? 1 : 0;
	sz written = 0;

	if (absolute)
	{
		if (buf.len < 1) return NO_SPACE~;
		buf[0] = SEPARATOR;
		written = 1;
	}

	ComponentIterator it = components(p);
	while (try component = it.next())
	{
		char[] c = component.bytes;
		if (c == ".") continue;

		if (c == "..")
		{
			sz start = last_component_start(buf, written, root_len);
			if (start >= 0)
			{
				if (buf[start:written - start] != "..")
				{
					// Drop the previous component along with its separator.
					written = start <= root_len ? root_len : start - 1;
					continue;
				}
				// The previous component is itself a "..", so it cannot be
				// popped through; fall through and stack another one.
			}
			else if (absolute)
			{
				return ESCAPES_ROOT~;
			}
		}

		if (written > root_len)
		{
			if (written + 1 > buf.len) return NO_SPACE~;
			buf[written] = SEPARATOR;
			written++;
		}
		if (written + c.len > buf.len) return NO_SPACE~;
		mem::copy(&buf[written], c.ptr, (usz)c.len);
		written += c.len;
	}

	if (written == 0)
	{
		if (buf.len < 1) return NO_SPACE~;
		buf[0] = '.';
		return buf[:1];
	}
	return buf[:written];
}

<*
 Like `normalize_buf`, but allocating. Caller owns the result.
*>
fn String? normalize(Allocator allocator, char[] p)
{
	char[] buf = alloc::alloc_array(allocator, char, max(p.len + 1, (sz)2));
	char[]? written = normalize_buf(buf, p);
	if (catch err = written)
	{
		alloc::free(allocator, buf.ptr);
		return err~;
	}
	String result = ((String)written).copy(allocator);
	alloc::free(allocator, buf.ptr);
	return result;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_basename() @test
{
	test::eq(basename("textures/ui/cursor.png").str(), "cursor.png");
	test::eq(basename("cursor.png").str(), "cursor.png");
	test::eq(basename("textures/ui/").str(), "ui");
	test::eq(basename("textures\\ui\\cursor.png").str(), "cursor.png");
	test::eq(basename("").str(), "");
	test::eq(basename("/").str(), "");
}

fn void test_dirname() @test
{
	test::eq(dirname("textures/ui/cursor.png")!!.str(), "textures/ui");
	test::eq(dirname("textures/ui/")!!.str(), "textures");
	test::eq(dirname("/cursor.png")!!.str(), "/");
	test::@error(dirname("cursor.png"), NO_DIRECTORY);
}

fn void test_extension_and_stem() @test
{
	test::eq(extension("textures/cursor.png").str(), ".png");
	test::eq(stem("textures/cursor.png").str(), "cursor");
	test::eq(without_extension("textures/cursor.png").str(), "textures/cursor");

	// Only the last extension counts.
	test::eq(extension("archive.tar.gz").str(), ".gz");
	test::eq(stem("archive.tar.gz").str(), "archive.tar");

	// No extension at all.
	test::eq(extension("README").str(), "");
	test::eq(stem("README").str(), "README");

	// A leading dot is a hidden file, not an extension.
	test::eq(extension(".gitignore").str(), "");
	test::eq(stem(".gitignore").str(), ".gitignore");

	// A dot in a directory name does not leak into the basename's extension.
	test::eq(extension("v1.2/README").str(), "");
}

fn void test_has_extension() @test
{
	test::@check(has_extension("cursor.PNG", ".png"));
	test::@check(has_extension("cursor.PNG", "png"));
	test::@check(!has_extension("cursor.png", ".jpg"));
	test::@check(has_extension("README", ""));
	test::@check(!has_extension("README", "md"));
}

fn void test_is_absolute() @test
{
	test::@check(is_absolute("/assets/x"));
	test::@check(is_absolute("\\assets\\x"));
	test::@check(!is_absolute("assets/x"));
	test::@check(!is_absolute(""));
}

fn void test_components() @test
{
	ComponentIterator it = components("//textures\\ui//cursor.png");
	test::eq(it.next()!!.str(), "textures");
	test::eq(it.next()!!.str(), "ui");
	test::eq(it.next()!!.str(), "cursor.png");
	test::@error(it.next(), NO_MORE_COMPONENTS);
}

fn void test_join_buf() @test
{
	char[64] buf;
	test::eq((String)join_buf(&buf, { "textures", "ui", "cursor.png" })!!, "textures/ui/cursor.png");
	// Stray separators and empty parts are absorbed.
	test::eq((String)join_buf(&buf, { "textures/", "", "/ui/" })!!, "textures/ui");
	test::eq((String)join_buf(&buf, {})!!, "");

	char[4] tiny;
	test::@error(join_buf(&tiny, { "textures", "ui" }), NO_SPACE);
}

fn void test_join_allocates() @test
{
	String joined = join(mem, { "sounds", "sfx", "hit.wav" })!!;
	defer free(joined);
	test::eq(joined, "sounds/sfx/hit.wav");
}

fn void test_normalize_resolves_dot_and_dot_dot() @test
{
	char[64] buf;
	test::eq((String)normalize_buf(&buf, "a/./b")!!, "a/b");
	test::eq((String)normalize_buf(&buf, "a/b/../c")!!, "a/c");
	test::eq((String)normalize_buf(&buf, "a/b/../../c")!!, "c");
	test::eq((String)normalize_buf(&buf, "a/b/..")!!, "a");
	test::eq((String)normalize_buf(&buf, "a//b//")!!, "a/b");
	test::eq((String)normalize_buf(&buf, "a\\b")!!, "a/b");
}

fn void test_normalize_keeps_absolute_roots_and_rejects_escapes() @test
{
	char[64] buf;
	test::eq((String)normalize_buf(&buf, "/a/b/../c")!!, "/a/c");
	test::eq((String)normalize_buf(&buf, "/a/b/..")!!, "/a");
	test::eq((String)normalize_buf(&buf, "//a//")!!, "/a");
	test::@error(normalize_buf(&buf, "/.."), ESCAPES_ROOT);
	test::@error(normalize_buf(&buf, "/a/../.."), ESCAPES_ROOT);
}

fn void test_normalize_keeps_leading_dot_dot_on_relative_paths() @test
{
	char[64] buf;
	test::eq((String)normalize_buf(&buf, "..")!!, "..");
	test::eq((String)normalize_buf(&buf, "../a")!!, "../a");
	test::eq((String)normalize_buf(&buf, "../..")!!, "../..");
	test::eq((String)normalize_buf(&buf, "a/../..")!!, "..");
}

fn void test_normalize_collapses_to_a_dot_when_nothing_is_left() @test
{
	char[64] buf;
	test::eq((String)normalize_buf(&buf, "")!!, ".");
	test::eq((String)normalize_buf(&buf, ".")!!, ".");
	test::eq((String)normalize_buf(&buf, "a/..")!!, ".");
}

fn void test_normalize_allocates() @test
{
	String n = normalize(mem, "textures/../sounds/./hit.wav")!!;
	defer free(n);
	test::eq(n, "sounds/hit.wav");
}

fn void test_normalized_output_feeds_the_other_helpers() @test
{
	char[64] buf;
	char[] p = normalize_buf(&buf, "assets\\textures\\..\\ui\\cursor.PNG")!!;
	test::eq((String)p, "assets/ui/cursor.PNG");
	test::eq(stem(p).str(), "cursor");
	test::@check(has_extension(p, "png"));
}
