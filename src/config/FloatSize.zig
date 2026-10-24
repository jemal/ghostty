//! Percentage dimensions for floating terminal panels.
const std = @import("std");
const formatterpkg = @import("formatter.zig");
const Self = @This();

width: f64 = 70,
height: f64 = 60,

pub const Anchor = enum {
    center,
    top,
    bottom,
    left,
    right,
    @"top-left",
    @"top-right",
    @"bottom-left",
    @"bottom-right",
};

pub fn parseCLI(self: *Self, input: ?[]const u8) !void {
    var it = std.mem.splitScalar(u8, input orelse return error.ValueRequired, ',');
    const width = try percentage(it.next().?);
    const height = try percentage(it.next() orelse return error.ValueRequired);
    if (it.next() != null) return error.TooManyArguments;
    // Commit only after both dimensions validate.
    self.* = .{ .width = width, .height = height };
}

fn percentage(input: []const u8) !f64 {
    const text = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.endsWith(u8, text, "%")) return error.MissingUnit;
    const value = std.fmt.parseFloat(f64, text[0 .. text.len - 1]) catch return error.InvalidValue;
    if (!std.math.isFinite(value) or value <= 0 or value > 100 or value / 100 == 0) return error.InvalidValue;
    return value;
}

pub fn clone(self: *const Self, _: std.mem.Allocator) std.mem.Allocator.Error!Self {
    return self.*;
}

pub const C = extern struct { width: f64, height: f64 };

pub fn cval(self: Self) C {
    return .{ .width = self.width, .height = self.height };
}

pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
    var buf: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}%,{d}%", .{ self.width, self.height });
    try formatter.formatEntry([]const u8, text);
}

test "floating terminal size parses percentages atomically" {
    var size: Self = .{};
    try size.parseCLI(" 80%, 65.5% ");
    try std.testing.expectEqual(Self{ .width = 80, .height = 65.5 }, size);
    for ([_][]const u8{ "0%,60%", "70%,101%", "nan%,60%", "inf%,60%", "-1%,60%", "70%,", "70%", "70%,60%,50%", "700px,60%", "70,60" }) |invalid| {
        if (size.parseCLI(invalid)) |_| return error.ExpectedInvalidSize else |_| {}
        try std.testing.expectEqual(Self{ .width = 80, .height = 65.5 }, size);
    }
    try std.testing.expectError(error.ValueRequired, size.parseCLI(null));
    try size.parseCLI("100%,100%");
}
