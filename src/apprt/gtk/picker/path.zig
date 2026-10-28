//! Path picker rules without GTK: how the typed text names a folder, which
//! rows match it and in which order, and the text that goes into the pane.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// At most this many rows are shown; the filter still sees every name.
pub const max_rows = 200;
/// At most this many recent paths come before the folder contents.
pub const max_recent_rows = 4;

/// Typing "~/" or "/" right after a "/" starts the path again from there:
/// "~/dev/~/" becomes "~/" and "~/dev//" becomes "/". Only the end of the text
/// counts, so a folder that is named "~" can still be in the middle.
pub fn restart(input: []const u8) []const u8 {
    if (std.mem.endsWith(u8, input, "/~/") and input.len > 3) return input[input.len - 2 ..];
    if (std.mem.endsWith(u8, input, "//")) return input[input.len - 1 ..];
    return input;
}

/// The typed folder (up to and with the last "/") and the typed name after it.
pub const Split = struct { folder: []const u8, name: []const u8 };
pub fn split(input: []const u8) Split {
    const cut = if (std.mem.lastIndexOfScalar(u8, input, '/')) |i| i + 1 else 0;
    return .{ .folder = input[0..cut], .name = input[cut..] };
}

/// The full path of the typed folder, with "." and ".." resolved. "~" is the
/// home folder and other relative text is relative to the pane folder. The
/// result has no "/" at the end, except for "/" itself.
pub fn resolve(alloc: Allocator, folder: []const u8, home: []const u8, pwd: []const u8) ![]u8 {
    const tilde = std.mem.eql(u8, folder, "~") or std.mem.startsWith(u8, folder, "~/");
    return std.fs.path.resolveAllocPosix(alloc, if (tilde) &.{ home, folder[@min(folder.len, 2)..] } else &.{ pwd, folder });
}

/// Text that names `path` as briefly as possible: relative to the pane folder
/// when it is inside it, else with "~" for the home folder. A relative name
/// that starts with "-", "~" or "=" gets "./", so that a shell does not read it
/// as an option, the home folder or (in zsh) a command.
pub fn shortPath(alloc: Allocator, path: []const u8, pwd: ?[]const u8, home: []const u8) ![]u8 {
    if (pwd) |dir| if (inside(path, dir)) {
        const rest = path[below(dir)..];
        return std.mem.concat(alloc, u8, &.{ if (std.mem.indexOfScalar(u8, "-~=", rest[0]) != null) "./" else "", rest });
    };
    if (std.mem.eql(u8, path, home)) return alloc.dupe(u8, "~");
    if (inside(path, home)) return std.mem.concat(alloc, u8, &.{ "~/", path[below(home)..] });
    return alloc.dupe(u8, path);
}

/// True when `path` is below `dir`, not equal to it.
pub fn inside(path: []const u8, dir: []const u8) bool {
    return path.len > below(dir) and std.mem.startsWith(u8, path, dir) and path[below(dir) - 1] == '/';
}

/// Where the names below `dir` start in a path inside it.
fn below(dir: []const u8) usize {
    return if (std.mem.eql(u8, dir, "/")) 1 else dir.len + 1;
}

/// The letters of the query in the same order; ASCII case does not matter.
/// A lower score is a better match: an early first letter and few gaps.
/// `hits` marks the matched bytes among the first 64.
pub const Match = struct { score: u32, hits: u64 };
pub fn fuzzy(query: []const u8, text: []const u8) ?Match {
    var hits: u64 = 0;
    var first: ?usize = null;
    var last: usize = 0;
    var from: usize = 0;
    for (query) |char| {
        const at = for (text[from..], from..) |c, i| {
            if (std.ascii.toLower(c) == std.ascii.toLower(char)) break i;
        } else return null;
        if (first == null) first = at;
        if (at < 64) hits |= @as(u64, 1) << @intCast(at);
        last = at;
        from = at + 1;
    }
    const start = first orelse return .{ .score = 0, .hits = 0 };
    const gaps = last - start + 1 - query.len;
    return .{ .score = @intCast(@min(std.math.maxInt(u32), start * 2 + gaps)), .hits = hits };
}

/// A name in the folder. `dir` is true for folders and links to folders.
pub const Child = struct { name: []const u8, dir: bool };

/// A recent path: a folder a pane was in (from OSC 7), or a path picked here.
pub const Recent = struct {
    path: []const u8,
    dir: bool,
    from: From,

    pub const From = enum { pane, picked };
};

pub const Row = struct {
    /// The text in the row: the path relative to the typed folder.
    label: []const u8,
    dir: bool,
    /// The index in the recent list, or null for a name in the folder.
    recent: ?usize,
    match: Match,
};

/// The rows for a folder, best first: matching recent paths below the folder,
/// then the matching names in it. Hidden names (and recent paths with a hidden
/// part) show only when the typed name starts with ".". Labels borrow from
/// `children` and `recent`.
pub fn rank(alloc: Allocator, folder: []const u8, query: []const u8, children: []const Child, recent: []const Recent) ![]Row {
    const hidden = std.mem.startsWith(u8, query, ".");
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(alloc);

    // Recent paths come first, so the best ones are next to the search box.
    for (recent, 0..) |entry, i| {
        if (!inside(entry.path, folder)) continue;
        const label = entry.path[below(folder)..];
        if (!hidden and (label[0] == '.' or std.mem.indexOf(u8, label, "/.") != null)) continue;
        const match = fuzzy(query, label) orelse continue;
        try rows.append(alloc, .{ .label = label, .dir = entry.dir, .recent = i, .match = match });
    }
    keepBest(&rows, 0, max_recent_rows);
    const recent_rows = rows.items.len;

    // A folder can have many names. Sort only when the list holds twice the
    // rows that are kept, and then keep the best. After the first sort, a
    // name that is not better than the worst kept row is not added.
    try rows.ensureTotalCapacityPrecise(alloc, recent_rows + 2 * max_rows);
    var worst: ?Row = null;
    for (children) |child| {
        if (!hidden and child.name[0] == '.') continue;
        const shown = for (rows.items[0..recent_rows]) |row| {
            if (std.mem.eql(u8, row.label, child.name)) break true;
        } else false;
        if (shown) continue;
        const row: Row = .{ .label = child.name, .dir = child.dir, .recent = null, .match = fuzzy(query, child.name) orelse continue };
        if (worst) |w| if (!better({}, row, w)) continue;
        if (rows.items.len == rows.capacity) {
            keepBest(&rows, recent_rows, max_rows);
            worst = rows.items[rows.items.len - 1];
        }
        rows.appendAssumeCapacity(row);
    }
    keepBest(&rows, recent_rows, max_rows);
    return rows.toOwnedSlice(alloc);
}

/// Sort the rows after `start` best first, and keep at most `limit` of them.
fn keepBest(rows: *std.ArrayList(Row), start: usize, limit: usize) void {
    std.mem.sortUnstable(Row, rows.items[start..], {}, better);
    rows.shrinkRetainingCapacity(start + @min(rows.items.len - start, limit));
}

/// Better score first, then folders, then by name.
fn better(_: void, a: Row, b: Row) bool {
    if (a.match.score != b.match.score) return a.match.score < b.match.score;
    if (a.dir != b.dir) return a.dir;
    return std.mem.lessThan(u8, a.label, b.label);
}

/// A name with a control character (for example a new line) is not safe to
/// paste, so it cannot be inserted.
pub fn insertable(text: []const u8) bool {
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// How the pane reads the inserted text. `plain` is any program that is not a
/// shell at its prompt, such as Helix or Claude Code.
pub const Shell = enum { plain, posix, fish, nu };

/// The text to paste for a path. A folder ends with "/" and a file with a
/// space, the same as shell completion. At a shell prompt, a path with a
/// special character is quoted. "~" does not expand in quotes, so "~/" stays
/// out of them. Nushell cannot join "~/" to quoted text, so for nushell the
/// home folder is written out; `home` is null when the pane is on another
/// machine, with another home folder. `after_text` adds a space first.
pub const Kind = enum { folder, file, typed };
pub fn format(alloc: Allocator, path: []const u8, kind: Kind, shell: Shell, home: ?[]const u8, after_text: bool) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    if (after_text) try w.writeByte(' ');
    const end = switch (kind) {
        .folder => if (std.mem.endsWith(u8, path, "/")) "" else "/",
        .file => " ",
        .typed => "",
    };
    const safe = shell == .plain or for (path) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_./~+@%,:=-", c) == null) break false;
    } else true;
    if (safe) {
        try w.print("{s}{s}", .{ path, end });
        return out.toOwnedSliceSentinel(0);
    }

    // Single quotes are literal in bash, zsh and nushell. Fish reads "\\" and
    // "\'" in them. Nushell has no escape in single quotes, so a name with a
    // "'" uses backticks, or double quotes with escapes when it has both.
    const tilde = std.mem.startsWith(u8, path, "~/");
    const home_text = if (tilde and shell == .nu) home else null;
    if (tilde and home_text == null) try w.writeAll("~/");
    const text = if (home_text != null) path[1..] else if (tilde) path[2..] else path;
    // The home folder is inside the quotes too, so it counts for the choice.
    const parts: [2][]const u8 = .{ home_text orelse "", text };
    const has_quote = for (parts) |part| {
        if (std.mem.indexOfScalar(u8, part, '\'') != null) break true;
    } else false;
    const has_tick = for (parts) |part| {
        if (std.mem.indexOfScalar(u8, part, '`') != null) break true;
    } else false;
    const q: u8 = if (shell != .nu or !has_quote) '\'' else if (!has_tick) '`' else '"';
    try w.writeByte(q);
    for (parts) |part| for (part) |c| {
        switch (shell) {
            .plain => unreachable,
            .posix => if (c == '\'') {
                try w.writeAll("'\\''");
                continue;
            },
            .fish => if (c == '\'' or c == '\\') try w.writeByte('\\'),
            .nu => if (q == '"' and (c == '"' or c == '\\')) try w.writeByte('\\'),
        }
        try w.writeByte(c);
    };
    try w.print("{s}{c}{s}", .{ if (kind == .folder) end else "", q, if (kind == .file) end else "" });
    return out.toOwnedSliceSentinel(0);
}

const testing = std.testing;

test "path picker restarts and splits the typed path" {
    try testing.expectEqualStrings("~/", restart("~/dev/~/"));
    try testing.expectEqualStrings("/", restart("src//"));
    // A folder named "~" in the middle is not a restart.
    try testing.expectEqualStrings("~/p/~/x", restart("~/p/~/x"));
    try testing.expectEqualStrings("src/~x", restart("src/~x"));
    try testing.expectEqualStrings("~/", restart("~/"));
    // GTK clears the text before it sets new text.
    try testing.expectEqualStrings("", restart(""));
    const parts = split("~/dev/pro");
    try testing.expectEqualStrings("~/dev/", parts.folder);
    try testing.expectEqualStrings("pro", parts.name);
    try testing.expectEqualStrings("", split("name").folder);
}

test "path picker resolves typed folders" {
    const a = testing.allocator;
    for ([_][3][]const u8{
        .{ "/home/u", "/home/u", "~/" },
        .{ "/home/u", "/home/u", "~" },
        .{ "/home/u/dev", "/home/u", "~/dev/" },
        .{ "/etc", "/home/u", "/etc/" },
        .{ "/", "/home/u", "/" },
        .{ "/p/src", "/home/u", "src/" },
        .{ "/p", "/home/u", "" },
        .{ "/", "/home/u", "../" },
        .{ "/p", "/home/u", "./" },
        .{ "/home", "/home/u", "~/../" },
    }) |case| {
        const got = try resolve(a, case[2], case[1], "/p");
        defer a.free(got);
        try testing.expectEqualStrings(case[0], got);
    }
}

test "path picker shortens paths" {
    const a = testing.allocator;
    for ([_][3][]const u8{
        .{ "src/main.zig", "/home/u/p/src/main.zig", "/home/u/p" },
        .{ "~/Downloads", "/home/u/Downloads", "/home/u/p" },
        .{ "~", "/home/u", "/home/u/p" },
        .{ "/etc", "/etc", "" },
        // A pane in "/" keeps the whole name.
        .{ "etc", "/etc", "/" },
        .{ "./~", "/home/u/p/~", "/home/u/p" },
        .{ "./=foo", "/home/u/p/=foo", "/home/u/p" },
        .{ "./-rf", "/home/u/p/-rf", "/home/u/p" },
    }) |case| {
        const got = try shortPath(a, case[1], if (case[2].len > 0) case[2] else null, "/home/u");
        defer a.free(got);
        try testing.expectEqualStrings(case[0], got);
    }
    try testing.expect(!inside("/home/user2", "/home/u"));
    try testing.expect(inside("/etc", "/"));
    try testing.expect(!inside("/", "/"));
}

test "path picker fuzzy match" {
    try testing.expect(fuzzy("fs", "FORK_STATUS.md") != null);
    try testing.expect(fuzzy("xz", "FORK_STATUS.md") == null);
    const prefix = fuzzy("src", "src").?;
    const later = fuzzy("src", "resources").?;
    try testing.expect(prefix.score < later.score);
    try testing.expectEqual(@as(u64, 0b101), fuzzy("ac", "abc").?.hits);
    try testing.expectEqual(@as(u32, 0), fuzzy("", "abc").?.score);
}

test "path picker ranks recent paths first and hides dot names" {
    const a = testing.allocator;
    const children = [_]Child{
        .{ .name = "src", .dir = true },
        .{ .name = "README.md", .dir = false },
        .{ .name = ".git", .dir = true },
        .{ .name = "scripts", .dir = true },
    };
    const recent = [_]Recent{
        .{ .path = "/p/src", .dir = true, .from = .pane },
        .{ .path = "/p/src/apprt/gtk", .dir = true, .from = .pane },
        .{ .path = "/p/.config/x", .dir = true, .from = .pane },
        .{ .path = "/other/src", .dir = true, .from = .pane },
    };
    const rows = try rank(a, "/p", "s", &children, &recent);
    defer a.free(rows);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("src", rows[0].label);
    try testing.expectEqual(@as(?usize, 0), rows[0].recent);
    try testing.expectEqualStrings("src/apprt/gtk", rows[1].label);
    // "src" is already a recent row, so only "scripts" is left from the folder.
    try testing.expectEqualStrings("scripts", rows[2].label);

    const dotted = try rank(a, "/p", ".", &children, &recent);
    defer a.free(dotted);
    try testing.expectEqualStrings(".config/x", dotted[0].label);
    try testing.expectEqualStrings(".git", dotted[1].label);

    const root = try rank(a, "/", "e", &.{}, &.{.{ .path = "/etc", .dir = true, .from = .pane }});
    defer a.free(root);
    try testing.expectEqualStrings("etc", root[0].label);
}

test "path picker keeps only the best rows of a large folder" {
    const a = testing.allocator;
    var names: [max_rows * 2][8]u8 = undefined;
    var children: [max_rows * 2]Child = undefined;
    // Add the names from the last to the first, so the order must come from the rank.
    for (&names, &children, 0..) |*name, *child, i| {
        child.* = .{ .name = try std.fmt.bufPrint(name, "f{d:0>4}", .{names.len - 1 - i}), .dir = i == 0 };
    }
    const rows = try rank(a, "/p", "", &children, &.{});
    defer a.free(rows);
    try testing.expectEqual(@as(usize, max_rows), rows.len);
    // The one folder comes first, then the files by name.
    try testing.expectEqualStrings("f0399", rows[0].label);
    try testing.expectEqualStrings("f0000", rows[1].label);
    try testing.expectEqualStrings("f0198", rows[max_rows - 1].label);
}

test "path picker shows folders before files with the same score" {
    const a = testing.allocator;
    const rows = try rank(a, "/p", "", &.{ .{ .name = "a", .dir = false }, .{ .name = "b", .dir = true } }, &.{});
    defer a.free(rows);
    try testing.expectEqualStrings("b", rows[0].label);
}

test "path picker formats text for each shell" {
    const a = testing.allocator;
    for ([_]struct { path: []const u8, kind: Kind, shell: Shell, after: bool, want: []const u8 }{
        .{ .path = "src/main.zig", .kind = .file, .shell = .posix, .after = false, .want = "src/main.zig " },
        .{ .path = "~/go", .kind = .folder, .shell = .posix, .after = true, .want = " ~/go/" },
        .{ .path = "./-rf", .kind = .file, .shell = .posix, .after = false, .want = "./-rf " },
        .{ .path = "~/Screen Shots", .kind = .folder, .shell = .posix, .after = false, .want = "~/'Screen Shots/'" },
        .{ .path = "~/a b", .kind = .file, .shell = .nu, .after = false, .want = "'/home/u/a b' " },
        .{ .path = "~/a b.png", .kind = .file, .shell = .plain, .after = false, .want = "~/a b.png " },
        .{ .path = "it's", .kind = .file, .shell = .posix, .after = false, .want = "'it'\\''s' " },
        .{ .path = "it's", .kind = .file, .shell = .nu, .after = false, .want = "`it's` " },
        .{ .path = "a b", .kind = .folder, .shell = .nu, .after = false, .want = "'a b/'" },
        .{ .path = "a'`\"b", .kind = .typed, .shell = .nu, .after = false, .want = "\"a'`\\\"b\"" },
        .{ .path = "$HOME x", .kind = .typed, .shell = .posix, .after = false, .want = "'$HOME x'" },
        // Fish reads "\\" and "\'" in single quotes.
        .{ .path = "a\\ 'b", .kind = .file, .shell = .fish, .after = false, .want = "'a\\\\ \\'b' " },
        .{ .path = "a\\", .kind = .file, .shell = .posix, .after = false, .want = "'a\\' " },
    }) |case| {
        const got = try format(a, case.path, case.kind, case.shell, "/home/u", case.after);
        defer a.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
    // A "'" in the home folder needs other quotes in nushell.
    const quoted_home = try format(a, "~/a b", .typed, .nu, "/home/o'neil", false);
    defer a.free(quoted_home);
    try testing.expectEqualStrings("`/home/o'neil/a b`", quoted_home);
    // On another machine the home folder is not known.
    const remote = try format(a, "~/a b", .typed, .nu, null, false);
    defer a.free(remote);
    try testing.expectEqualStrings("~/'a b'", remote);
    try testing.expect(!insertable("a\nb"));
    try testing.expect(insertable("a b"));
}
