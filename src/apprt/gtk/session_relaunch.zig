//! Linux process capture and shell encoding for opt-in session relaunch.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_bytes = 32 * 1024;
pub const max_args = 256;

pub const Record = struct {
    program: []const u8,
    argv: []const []const u8,
    cwd: [:0]const u8,

    pub fn valid(self: Record) bool {
        if (!validProgram(self.program) or !std.fs.path.isAbsolute(self.cwd) or
            !validText(self.cwd) or self.argv.len == 0 or self.argv.len > max_args or
            !std.mem.eql(u8, self.argv[0], self.program)) return false;
        var bytes: usize = self.cwd.len + self.program.len;
        for (self.argv) |arg| {
            if (!validText(arg) or arg.len > max_bytes) return false;
            bytes += arg.len;
            if (bytes > max_bytes) return false;
        }
        return bytes <= max_bytes;
    }

    pub fn clone(self: Record, alloc: Allocator) Allocator.Error!Record {
        const argv = try alloc.alloc([]const u8, self.argv.len);
        var count: usize = 0;
        errdefer {
            for (argv[0..count]) |arg| alloc.free(arg);
            alloc.free(argv);
        }
        for (self.argv, argv) |arg, *out| {
            out.* = try alloc.dupe(u8, arg);
            count += 1;
        }
        const program = try alloc.dupe(u8, self.program);
        errdefer alloc.free(program);
        return .{ .program = program, .argv = argv, .cwd = try alloc.dupeSentinel(u8, self.cwd, 0) };
    }

    pub fn deinit(self: Record, alloc: Allocator) void {
        for (self.argv) |arg| alloc.free(arg);
        alloc.free(self.argv);
        alloc.free(self.program);
        alloc.free(self.cwd);
    }
};

pub fn validProgram(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or name[0] == '-' or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    return true;
}

pub fn validText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |ch| if (std.ascii.isControl(ch)) return false;
    return true;
}

pub fn executableName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    // Nix makeWrapper commonly execs .<program>-wrapped.
    if (std.mem.startsWith(u8, base, ".") and std.mem.endsWith(u8, base, "-wrapped"))
        return base[1 .. base.len - "-wrapped".len];
    return base;
}

pub fn processName(io: std.Io, pid: u64, buf: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/exe", .{pid}) catch return null;
    const len = std.Io.Dir.readLinkAbsolute(io, path, buf) catch return null;
    return executableName(buf[0..len]);
}

/// Returned strings belong to alloc. Use a temporary arena for a capture.
pub fn capture(alloc: Allocator, io: std.Io, pid: u64, program: []const u8) !?Record {
    if (comptime @import("builtin").target.os.tag != .linux) return null;
    var path_buf: [96]u8 = undefined;
    const proc_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}", .{pid});
    const dir = std.Io.Dir.openDirAbsolute(io, proc_path, .{}) catch return null;
    defer dir.close(io);
    // Do not attempt to reconstruct pipelines or redirected input/output.
    var input_buf: [256]u8 = undefined;
    var output_buf: [256]u8 = undefined;
    const input_len = dir.readLink(io, "fd/0", &input_buf) catch return null;
    const output_len = dir.readLink(io, "fd/1", &output_buf) catch return null;
    if (!std.mem.startsWith(u8, input_buf[0..input_len], "/dev/pts/") or
        !std.mem.eql(u8, input_buf[0..input_len], output_buf[0..output_len])) return null;
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = dir.readLink(io, "cwd", &cwd_buf) catch return null;
    const bytes = readCommandLine(alloc, io, dir) catch return null;
    defer alloc.free(bytes);
    return parse(alloc, program, bytes, cwd_buf[0..cwd_len]);
}

fn readCommandLine(alloc: Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    const file = try dir.openFile(io, "cmdline", .{});
    defer file.close(io);
    // procfs reports zero size even when cmdline contains data. The positional
    // reader may treat that as EOF; stream until actual EOF instead.
    var buffer: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(alloc, .limited(max_bytes));
}

pub fn parse(alloc: Allocator, program: []const u8, bytes: []const u8, cwd: []const u8) !?Record {
    if (bytes.len == 0 or bytes.len > max_bytes or bytes[bytes.len - 1] != 0) return null;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    var it = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 1], 0);
    while (it.next()) |arg| {
        if (args.items.len == max_args) return null;
        try args.append(alloc, arg);
    }
    if (args.items.len == 0 or args.items[0].len == 0) return null;
    if (!std.mem.eql(u8, executableName(args.items[0]), program)) return null;
    args.items[0] = program;
    const record: Record = .{ .program = program, .argv = args.items, .cwd = try alloc.dupeSentinel(u8, cwd, 0) };
    defer alloc.free(record.cwd);
    if (!record.valid()) return null;
    return try record.clone(alloc);
}

pub const Shell = enum {
    posix,
    fish,
    nushell,

    pub fn fromName(name: []const u8) ?Shell {
        if (std.mem.eql(u8, name, "nu")) return .nushell;
        if (std.mem.eql(u8, name, "fish")) return .fish;
        inline for (.{ "sh", "dash", "bash", "zsh", "ksh" }) |candidate|
            if (std.mem.eql(u8, name, candidate)) return .posix;
        return null;
    }
};

/// One literal command followed by Enter. Never interpret saved args as code.
pub fn command(alloc: Allocator, shell: Shell, record: Record) ![]u8 {
    if (!record.valid()) return error.InvalidRelaunch;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;
    // Nushell's caret explicitly selects an external executable. POSIX/fish
    // use command to bypass functions and aliases without replacing the shell.
    try writer.writeAll(if (shell == .nushell) "^" else "command ");
    for (record.argv, 0..) |arg, index| {
        if (index > 0) try writer.writeByte(' ');
        try writer.writeByte(if (shell == .nushell) '"' else '\'');
        for (arg) |ch| {
            if (shell == .nushell) {
                if (ch == '"' or ch == '\\') try writer.writeByte('\\');
                try writer.writeByte(ch);
            } else if (ch == '\'') {
                try writer.writeAll("'\\''");
            } else if (shell == .fish and ch == '\\') {
                try writer.writeAll("\\\\");
            } else try writer.writeByte(ch);
        }
        try writer.writeByte(if (shell == .nushell) '"' else '\'');
    }
    try writer.writeByte('\r');
    return out.toOwnedSlice();
}

test "session relaunch parses argv without losing empty or quoted arguments" {
    const t = std.testing;
    const record = (try parse(t.allocator, "hx", "hx\x00a b.rs\x00\x00a'b\x00", "/tmp")).?;
    defer record.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), record.argv.len);
    try t.expectEqualStrings("a b.rs", record.argv[1]);
    try t.expectEqualStrings("", record.argv[2]);
    try t.expect((try parse(t.allocator, "hx", "hx\x00bad\narg\x00", "/tmp")) == null);
    try t.expect((try parse(t.allocator, "hx", "hx", "/tmp")) == null);
    try t.expect((try parse(t.allocator, "hx", "bash\x00-c\x00echo nope\x00", "/tmp")) == null);
}

test "session relaunch reads zero-size procfs command lines" {
    if (comptime @import("builtin").target.os.tag != .linux) return error.SkipZigTest;
    const t = std.testing;
    const dir = try std.Io.Dir.openDirAbsolute(t.io, "/proc/self", .{});
    defer dir.close(t.io);
    const bytes = try readCommandLine(t.allocator, t.io, dir);
    defer t.allocator.free(bytes);
    try t.expect(bytes.len > 0);
    try t.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
}

test "session relaunch quotes shell metacharacters as data" {
    const t = std.testing;
    const r: Record = .{ .program = "hx", .argv = &.{ "hx", "a'b", "$(touch nope)", "", "a\\b\"c" }, .cwd = "/tmp" };
    const sh = try command(t.allocator, .posix, r);
    defer t.allocator.free(sh);
    try t.expectEqualStrings("command 'hx' 'a'\\''b' '$(touch nope)' '' 'a\\b\"c'\r", sh);
    const nu = try command(t.allocator, .nushell, r);
    defer t.allocator.free(nu);
    try t.expectEqualStrings("^\"hx\" \"a'b\" \"$(touch nope)\" \"\" \"a\\\\b\\\"c\"\r", nu);
    const fish = try command(t.allocator, .fish, r);
    defer t.allocator.free(fish);
    try t.expectEqualStrings("command 'hx' 'a'\\''b' '$(touch nope)' '' 'a\\\\b\"c'\r", fish);
    try t.expectEqualStrings("hx", executableName("/nix/store/example/bin/.hx-wrapped"));
}

fn shellRoundTrip(shell: Shell) !void {
    if (comptime @import("builtin").target.os.tag != .linux) return error.SkipZigTest;
    const t = std.testing;
    const record: Record = .{ .program = "printf", .cwd = "/tmp", .argv = &.{
        "printf", "%s\\0", "a'b", "$(printf injected)", "*.rs", "", "a\\b\"c", "x; printf nope",
    } };
    const encoded = try command(t.allocator, shell, record);
    defer t.allocator.free(encoded);
    const script = encoded[0 .. encoded.len - 1];
    const argv: []const []const u8 = switch (shell) {
        .posix => &.{ "bash", "--noprofile", "--norc", "-c", script },
        .fish => &.{ "fish", "--no-config", "-c", script },
        .nushell => &.{ "nu", "--no-config-file", "-c", script },
    };
    const result = std.process.run(t.allocator, t.io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer t.allocator.free(result.stdout);
    defer t.allocator.free(result.stderr);
    try t.expect(result.term == .exited and result.term.exited == 0);
    try t.expectEqualStrings("a'b\x00$(printf injected)\x00*.rs\x00\x00a\\b\"c\x00x; printf nope\x00", result.stdout);
}

test "session relaunch bash argument round trip" {
    try shellRoundTrip(.posix);
}

test "session relaunch Nushell argument round trip" {
    try shellRoundTrip(.nushell);
}

test "session relaunch fish argument round trip" {
    try shellRoundTrip(.fish);
}
