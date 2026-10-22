//! Pane-local picker placement in GTK logical pixels.
const std = @import("std");
pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };

/// Prefer below the captured terminal cursor. Flip above when necessary and
/// constrain both axes to the pane. Tall lists use the larger available side;
/// in very short panes the card may overlap the cursor to keep input usable.
pub fn place(pane_width: i32, pane_height: i32, anchor: Rect, input_offset: i32, desired_height: i32, minimum_height: i32) Rect {
    const margin = @min(16, @divTrunc(@min(pane_width, pane_height), 4));
    const left = margin;
    const top = margin;
    const right = @max(left + 1, pane_width - margin);
    const bottom = @max(top + 1, pane_height - margin);
    const width = @min(360, right - left);
    const anchor_top = std.math.clamp(anchor.y, top, bottom);
    const anchor_bottom = std.math.clamp(anchor.y + anchor.height, top, bottom);
    const below = @max(0, bottom - anchor_bottom - 6);
    const above = @max(0, anchor_top - top - 6);
    const use_below = desired_height <= below or below >= above;
    const available = if (use_below) below else above;
    const height = @max(1, @min(desired_height, if (available >= minimum_height) available else bottom - top));
    const y = if (use_below) anchor_bottom + 6 else anchor_top - 6 - height;
    return .{
        .x = std.math.clamp(anchor.x - input_offset, left, right - width),
        .y = std.math.clamp(y, top, bottom - height),
        .width = width,
        .height = height,
    };
}

test "picker placement flips and stays within the pane" {
    const below = place(800, 600, .{ .x = 100, .y = 80, .width = 10, .height = 20 }, 32, 180, 80);
    try std.testing.expectEqual(Rect{ .x = 68, .y = 106, .width = 360, .height = 180 }, below);
    const above = place(800, 600, .{ .x = 760, .y = 550, .width = 10, .height = 20 }, 32, 180, 80);
    try std.testing.expectEqual(Rect{ .x = 424, .y = 364, .width = 360, .height = 180 }, above);
    const tall = place(800, 400, .{ .x = 20, .y = 180, .width = 10, .height = 20 }, 32, 340, 80);
    try std.testing.expectEqual(@as(i32, 178), tall.height);
    for ([_][2]i32{ .{ 280, 180 }, .{ 90, 60 }, .{ 1, 1 } }) |size| {
        const rect = place(size[0], size[1], .{ .x = 1000, .y = 1000, .width = 10, .height = 20 }, 32, 340, 80);
        try std.testing.expect(rect.x >= 0 and rect.y >= 0);
        try std.testing.expect(rect.x + rect.width <= size[0]);
        try std.testing.expect(rect.y + rect.height <= size[1]);
    }
}

test "picker placement aligns input start and only shifts at pane edges" {
    for ([_]i32{ 24, 32, 44 }) |offset| {
        const rect = place(800, 600, .{ .x = 200, .y = 80, .width = 10, .height = 20 }, offset, 180, 80);
        try std.testing.expectEqual(@as(i32, 200), rect.x + offset);
    }
    const edge = place(800, 600, .{ .x = 5, .y = 80, .width = 10, .height = 20 }, 32, 180, 80);
    try std.testing.expectEqual(@as(i32, 16), edge.x);
}
