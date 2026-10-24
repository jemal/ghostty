//! Directional tiled-pane navigation: shared edges first, then focus recency.
//! Geometry is normalized to the tab's content area, excluding decorations.
const std = @import("std");

pub const Direction = enum { left, right, up, down };

pub const Pane = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    focus_serial: u64 = 0,
};

// SplitTree calculates normalized boundaries independently in f16.
const tolerance: f32 = 2 * std.math.floatEps(f16);

/// Returns an index into panes. Wrapping considers overlapping panes on the
/// opposite outer edge only, so it cannot introduce a diagonal jump.
pub fn target(panes: []const Pane, from: usize, direction: Direction) ?usize {
    const source = panes[from];
    if (adjacent(panes, from, source, direction)) |index| return index;

    // Wrap only at an outer edge. An interior geometry gap must not teleport
    // focus to the opposite edge.
    var wrapped = source;
    switch (direction) {
        .left => {
            if (@abs(source.x) > tolerance) return null;
            wrapped.x = 1;
        },
        .right => {
            if (@abs(source.x + source.width - 1) > tolerance) return null;
            wrapped.x = -source.width;
        },
        .up => {
            if (@abs(source.y) > tolerance) return null;
            wrapped.y = 1;
        },
        .down => {
            if (@abs(source.y + source.height - 1) > tolerance) return null;
            wrapped.y = -source.height;
        },
    }
    return adjacent(panes, from, wrapped, direction);
}

fn adjacent(panes: []const Pane, from: usize, source: Pane, direction: Direction) ?usize {
    var best: ?usize = null;
    for (panes, 0..) |pane, index| {
        if (index == from) continue;
        const horizontal = direction == .left or direction == .right;
        const overlap = if (horizontal)
            @min(source.y + source.height, pane.y + pane.height) - @max(source.y, pane.y)
        else
            @min(source.x + source.width, pane.x + pane.width) - @max(source.x, pane.x);
        if (overlap <= 0) continue;
        const gap = switch (direction) {
            .left => source.x - (pane.x + pane.width),
            .right => pane.x - (source.x + source.width),
            .up => source.y - (pane.y + pane.height),
            .down => pane.y - (source.y + source.height),
        };
        if (@abs(gap) > tolerance) continue;
        // Equal or absent history keeps stable tree order.
        if (best) |previous| {
            if (pane.focus_serial <= panes[previous].focus_serial) continue;
        }
        best = index;
    }
    return best;
}

test "pane focus returns to the last used adjacent pane" {
    var panes = [_]Pane{
        .{ .x = 0, .y = 0, .width = 0.5, .height = 1, .focus_serial = 3 },
        .{ .x = 0.5, .y = 0, .width = 0.5, .height = 0.5, .focus_serial = 1 },
        .{ .x = 0.5, .y = 0.5, .width = 0.5, .height = 0.5, .focus_serial = 2 },
    };
    try std.testing.expectEqual(@as(?usize, 0), target(&panes, 2, .left));
    try std.testing.expectEqual(@as(?usize, 2), target(&panes, 0, .right));
    panes[1].focus_serial = 4;
    try std.testing.expectEqual(@as(?usize, 1), target(&panes, 0, .right));
    panes[1].focus_serial = 0;
    panes[2].focus_serial = 0;
    try std.testing.expectEqual(@as(?usize, 1), target(&panes, 0, .right));
}

test "pane focus excludes diagonal and nonadjacent panes" {
    const panes = [_]Pane{
        .{ .x = 0, .y = 0, .width = 0.5, .height = 0.5 },
        .{ .x = 0.5, .y = 0, .width = 0.25, .height = 0.5, .focus_serial = 1 },
        .{ .x = 0.5, .y = 0.5, .width = 0.5, .height = 0.5, .focus_serial = 100 },
        .{ .x = 0.75, .y = 0, .width = 0.25, .height = 0.5, .focus_serial = 200 },
    };
    try std.testing.expectEqual(@as(?usize, 1), target(&panes, 0, .right));
}

test "pane focus vertical navigation and edge wrapping" {
    const panes = [_]Pane{
        .{ .x = 0, .y = 0, .width = 1, .height = 0.5 },
        .{ .x = 0, .y = 0.5, .width = 0.5, .height = 0.5, .focus_serial = 1 },
        .{ .x = 0.5, .y = 0.5, .width = 0.5, .height = 0.5, .focus_serial = 2 },
    };
    try std.testing.expectEqual(@as(?usize, 2), target(&panes, 0, .down));
    try std.testing.expectEqual(@as(?usize, 2), target(&panes, 0, .up));
    try std.testing.expectEqual(@as(?usize, 0), target(&panes, 1, .up));
    try std.testing.expectEqual(@as(?usize, 0), target(&panes, 1, .down));
    try std.testing.expectEqual(@as(?usize, 2), target(&panes, 1, .left));
    try std.testing.expectEqual(@as(?usize, 1), target(&panes, 2, .right));
}

test "pane focus tolerates split rounding and handles a single pane" {
    const panes = [_]Pane{
        .{ .x = 0, .y = 0, .width = 0.33325, .height = 1 },
        .{ .x = 0.3335, .y = 0, .width = 0.6665, .height = 1 },
    };
    try std.testing.expectEqual(@as(?usize, 1), target(&panes, 0, .right));
    try std.testing.expectEqual(@as(?usize, 0), target(&panes, 1, .left));
    try std.testing.expectEqual(@as(?usize, null), target(panes[0..1], 0, .left));
}
