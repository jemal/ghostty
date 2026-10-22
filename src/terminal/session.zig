//! Durable terminal contents for a new process. Unlike a live checkpoint,
//! a session never resumes parser state, alternate-screen programs or modes.
const std = @import("std");
const Terminal = @import("Terminal.zig");
const Screen = @import("Screen.zig");
const snapshot = @import("snapshot/main.zig");

pub fn encode(alloc: std.mem.Allocator, term: *const Terminal, limit: usize) ![]u8 {
    var out: Limited = .{ .out = .init(alloc), .limit = limit };
    defer out.out.deinit();
    // This view borrows storage and is only read while the terminal is locked.
    var primary = term.*;
    primary.screens.active_key = .primary;
    primary.screens.active = term.screens.get(.primary).?;
    primary.screens.all = .init(.{ .primary = primary.screens.active });
    snapshot.encode(alloc, &out.writer, &primary, .{ .continuation = .ground }) catch |err| {
        if (out.exceeded) return error.SnapshotTooLarge;
        return err;
    };
    return out.out.toOwnedSlice();
}

pub fn restore(alloc: std.mem.Allocator, io: std.Io, bytes: []const u8, opts: Terminal.Options) !Terminal {
    var reader: std.Io.Reader = .fixed(bytes);
    var decoded = try snapshot.decodeExact(alloc, io, &reader, .{
        .max_continuation_bytes = 0,
        .compress_history = true,
        .kitty_image_storage_limit = opts.kitty_image_storage_limit,
    });
    defer decoded.deinit(alloc);
    var saved = decoded.toOwned();
    defer saved.deinit(alloc);
    var initial = opts;
    initial.cols = saved.cols;
    initial.rows = saved.rows;
    var result = try Terminal.init(io, alloc, initial);
    errdefer result.deinit(alloc);
    const screen = result.screens.active;
    std.mem.swap(Screen, screen, saved.screens.get(.primary).?);

    // Shell integration identifies an unfinished prompt/input. Remove only
    // those cells, retaining output before a prompt on the same row.
    const prompt = prompt: {
        if (screen.cursor.semantic_content == .output) break :prompt null;
        var y = screen.cursor.y;
        while (true) {
            const pin = screen.pages.pin(.{ .active = .{ .y = y } }).?;
            const rac = pin.rowAndCell();
            if (rac.row.semantic_prompt == .prompt) {
                for (pin.node.page().getCells(rac.row), 0..) |cell, x| {
                    if (cell.semantic_content == .prompt) break :prompt @as(?@import("point.zig").Coordinate, .{ .x = @intCast(x), .y = y });
                }
            }
            if (y == 0) break;
            y -= 1;
        }
        break :prompt null;
    };

    // Release cursor references through the normal setters before replacing
    // the pen. Previously printed cell styles and hyperlinks remain intact.
    screen.cursor.style = .{};
    try screen.manualStyleUpdate();
    screen.endHyperlink();
    screen.cursor.pending_wrap = false;
    screen.cursor.protected = false;
    screen.cursor.semantic_content = .output;
    screen.cursor.semantic_content_clear_eol = false;
    screen.cursor.cursor_style = opts.default_cursor_style;
    screen.saved_cursor = null;
    screen.charset = .{};
    screen.kitty_keyboard = .{};
    screen.protected_mode = .off;
    screen.semantic_prompt = .disabled;
    screen.clearSelection();
    if (comptime @import("terminal_options").kitty_graphics)
        result.setKittyGraphicsLoadingLimits(opts.kitty_image_loading_limits);
    if (prompt) |position| {
        screen.cursorAbsolute(position.x, @intCast(position.y));
        result.eraseDisplay(.below, false);
    }

    // Append the new shell below the last visible output. Never resume an
    // old input line or overwrite saved output with the startup prompt.
    var last: ?u16 = if (screen.cursor.x != 0)
        screen.cursor.y
    else if (screen.cursor.y > 0)
        screen.cursor.y - 1
    else
        null;
    var y: u16 = 0;
    while (y < result.rows) : (y += 1) {
        const pin = screen.pages.pin(.{ .active = .{ .y = y } }).?;
        const rac = pin.rowAndCell();
        const cells = pin.node.page().getCells(rac.row);
        for (cells) |cell| if (cell.hasText() or cell.hasStyling()) {
            last = y;
            break;
        };
    }
    screen.cursorAbsolute(0, last orelse 0);
    if (last != null) try result.linefeed();
    result.setScrollbackMaxBytes(opts.max_scrollback_bytes);
    result.setScrollbackMaxLines(opts.max_scrollback_lines);
    try result.resize(alloc, .{ .cols = opts.cols, .rows = opts.rows });
    return result;
}

const Limited = struct {
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    out: std.Io.Writer.Allocating,
    limit: usize,
    exceeded: bool = false,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Limited = @fieldParentPtr("writer", w);
        var remaining = self.limit - self.out.written().len;
        for (data, 0..) |part, i| {
            const count = if (i + 1 == data.len) splat else 1;
            if (count != 0 and part.len > remaining / count) {
                self.exceeded = true;
                return error.WriteFailed;
            }
            remaining -= part.len * count;
        }
        return self.out.writer.writeSplat(data, splat);
    }
};

test "session snapshot restores output with fresh modes and bounded encoding" {
    const t = std.testing;
    var original = try Terminal.init(t.io, t.allocator, .{ .cols = 20, .rows = 3 });
    defer original.deinit(t.allocator);
    for (0..8) |_| {
        try original.printString("saved output");
        original.carriageReturn();
        try original.linefeed();
    }
    original.modes.set(.mouse_event_button, true);
    const bytes = try encode(t.allocator, &original, 1024 * 1024);
    defer t.allocator.free(bytes);
    try t.expectError(error.SnapshotTooLarge, encode(t.allocator, &original, 32));
    var restored = try restore(t.allocator, t.io, bytes, .{ .cols = 30, .rows = 5 });
    defer restored.deinit(t.allocator);
    try t.expect(!restored.modes.get(.mouse_event_button));
    try t.expectEqual(@as(u16, 30), restored.cols);
    const text = try restored.screens.active.dumpStringAlloc(t.allocator, .{ .screen = .{} });
    defer t.allocator.free(text);
    try t.expect(std.mem.count(u8, text, "saved output") >= 8);
    try restored.printString("fresh shell");
}

test "session snapshot keeps primary styles and links while discarding alternate screen" {
    const t = std.testing;
    var original = try Terminal.init(t.io, t.allocator, .{ .cols = 30, .rows = 5 });
    defer original.deinit(t.allocator);
    var stream = original.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[31;1m\x1b]8;;https://example.com\x1b\\saved link\x1b]8;;\x1b\\\x1b[0m\r\n");
    stream.nextSlice("\x1b[?1049hALTERNATE PROGRAM\x1b[?1000h\x1b[?2004h");
    const bytes = try encode(t.allocator, &original, 1024 * 1024);
    defer t.allocator.free(bytes);
    try t.expectEqual(.alternate, original.screens.active_key);
    var restored = try restore(t.allocator, t.io, bytes, .{ .cols = 30, .rows = 5 });
    defer restored.deinit(t.allocator);
    try t.expectEqual(.primary, restored.screens.active_key);
    try t.expect(restored.screens.get(.alternate) == null);
    const cell = restored.screens.active.pages.getCell(.{ .screen = .{} }).?;
    try t.expect(cell.cell.hasStyling());
    try t.expect(cell.cell.hyperlink);
    try t.expect(restored.screens.active.cursor.style.default());
    try t.expectEqual(@as(u32, 0), restored.screens.active.cursor.hyperlink_id);
    try t.expect(!restored.modes.get(.mouse_event_button));
    try t.expect(!restored.modes.get(.bracketed_paste));
    const text = try restored.plainString(t.allocator);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "saved link") != null);
    try t.expect(std.mem.indexOf(u8, text, "ALTERNATE PROGRAM") == null);
    // A truncated or corrupt snapshot must fail before a terminal is exposed.
    if (restore(t.allocator, t.io, bytes[0 .. bytes.len / 2], .{ .cols = 30, .rows = 5 })) |value| {
        var unexpected = value;
        unexpected.deinit(t.allocator);
        return error.ExpectedDecodeFailure;
    } else |_| {}
}

test "session snapshot removes unfinished integrated prompt without executing input" {
    const t = std.testing;
    var original = try Terminal.init(t.io, t.allocator, .{ .cols = 30, .rows = 5 });
    defer original.deinit(t.allocator);
    var stream = original.vtStream();
    defer stream.deinit();
    stream.nextSlice("saved output\r\n\x1b]133;A\x1b\\old prompt> \x1b]133;B\x1b\\unfinished command");
    const bytes = try encode(t.allocator, &original, 1024 * 1024);
    defer t.allocator.free(bytes);
    var restored = try restore(t.allocator, t.io, bytes, .{ .cols = 30, .rows = 5 });
    defer restored.deinit(t.allocator);
    try restored.printString("fresh prompt> ");
    const text = try restored.plainString(t.allocator);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "saved output\nfresh prompt>") != null);
    try t.expect(std.mem.indexOf(u8, text, "old prompt") == null);
    try t.expect(std.mem.indexOf(u8, text, "unfinished command") == null);
}
