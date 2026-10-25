//! The program in the foreground of a pane: its name, shown in bold before the
//! title, and its icon. Only a few programs have their own icon; every other
//! program uses the terminal icon.
const std = @import("std");
const session_relaunch = @import("session_relaunch.zig");

pub const Program = enum {
    terminal,
    claude,
    codex,
    helix,

    pub fn fromName(name: []const u8) Program {
        const eql = std.mem.eql;
        if (eql(u8, name, "claude")) return .claude;
        if (eql(u8, name, "codex")) return .codex;
        if (eql(u8, name, "hx") or eql(u8, name, "helix")) return .helix;
        return .terminal;
    }

    /// The icon for pane headers. Program icons have their own colour; the
    /// terminal icon is symbolic and follows the theme.
    pub fn glyph(self: Program) [:0]const u8 {
        return switch (self) {
            .terminal => "ghostty-program-terminal-symbolic",
            .claude => "ghostty-program-claude",
            .codex => "ghostty-program-codex",
            .helix => "ghostty-program-helix",
        };
    }

    /// The icon for tabs: the glyph in white on a coloured tile.
    pub fn tile(self: Program) [:0]const u8 {
        return switch (self) {
            .terminal => "ghostty-program-terminal-tile",
            .claude => "ghostty-program-claude-tile",
            .codex => "ghostty-program-codex-tile",
            .helix => "ghostty-program-helix-tile",
        };
    }
};

/// The name of a process, from its executable (Linux only). The result is
/// a slice of buf.
pub fn processName(io: std.Io, pid: u64, buf: []u8) ?[]const u8 {
    if (comptime @import("builtin").target.os.tag != .linux) return null;
    return session_relaunch.processName(io, pid, buf);
}

/// Pango markup for a tab or pane label: the program name in bold, then the
/// title. When the title already starts with the name, the name is not
/// repeated.
pub fn writeLabelMarkup(writer: *std.Io.Writer, name: []const u8, title: []const u8) std.Io.Writer.Error!void {
    if (name.len == 0) return writeEscaped(writer, title);
    try writer.writeAll("<span weight=\"600\">");
    try writeEscaped(writer, name);
    try writer.writeAll("</span>");
    const rest = if (std.mem.startsWith(u8, title, name) and
        (title.len == name.len or title[name.len] == ' '))
        title[name.len..]
    else if (title.len > 0) title: {
        try writer.writeByte(' ');
        break :title title;
    } else "";
    try writeEscaped(writer, rest);
}

/// The same markup, in memory that the caller frees with alloc.
pub fn labelMarkup(alloc: std.mem.Allocator, name: []const u8, title: []const u8) std.mem.Allocator.Error![:0]u8 {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    writeLabelMarkup(&writer.writer, name, title) catch return error.OutOfMemory;
    return writer.toOwnedSliceSentinel(0);
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        else => try writer.writeByte(c),
    };
}

test "program label markup" {
    const testing = std.testing;
    const cases = [_]struct { name: []const u8, title: []const u8, markup: []const u8 }{
        .{ .name = "nu", .title = "~/dev", .markup = "<span weight=\"600\">nu</span> ~/dev" },
        .{ .name = "hx", .title = "hx README.md", .markup = "<span weight=\"600\">hx</span> README.md" },
        .{ .name = "hx", .title = "hx", .markup = "<span weight=\"600\">hx</span>" },
        .{ .name = "hx", .title = "hxd file", .markup = "<span weight=\"600\">hx</span> hxd file" },
        .{ .name = "", .title = "a <b> & c", .markup = "a &lt;b&gt; &amp; c" },
        .{ .name = "nu", .title = "", .markup = "<span weight=\"600\">nu</span>" },
    };
    for (cases) |case| {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try writeLabelMarkup(&writer, case.name, case.title);
        try testing.expectEqualStrings(case.markup, writer.buffered());
    }
}

test "program icon names" {
    const testing = std.testing;
    try testing.expectEqual(Program.helix, Program.fromName("hx"));
    try testing.expectEqual(Program.claude, Program.fromName("claude"));
    try testing.expectEqual(Program.codex, Program.fromName("codex"));
    try testing.expectEqual(Program.terminal, Program.fromName("nu"));
    try testing.expectEqual(Program.terminal, Program.fromName(""));
    // Nix wrappers exec `.<program>-wrapped`; the executable name removes that.
    try testing.expectEqual(Program.claude, Program.fromName(session_relaunch.executableName("/nix/store/x/bin/.claude-wrapped")));
}
