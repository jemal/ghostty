const std = @import("std");

/// Convert a drop slot (before removal) to a legal page position. Pinned
/// pages must remain before normal pages, including across window transfers.
pub fn dropPosition(count: usize, pinned_count: usize, pinned: bool, source: ?usize, slot: usize) usize {
    const remaining = count - @intFromBool(source != null);
    const remaining_pinned = pinned_count - @intFromBool(source != null and pinned);
    const position = @min(slot, count) - @intFromBool(if (source) |i| slot > i else false);
    return if (pinned)
        @min(position, remaining_pinned)
    else
        std.math.clamp(position, remaining_pinned, remaining);
}

test "compact tab drop positions in the same strip" {
    try std.testing.expectEqual(2, dropPosition(3, 0, false, 0, 3));
    try std.testing.expectEqual(0, dropPosition(3, 0, false, 2, 0));
    try std.testing.expectEqual(1, dropPosition(3, 0, false, 1, 2));
}

test "compact tab transfers respect pinned boundaries" {
    try std.testing.expectEqual(2, dropPosition(4, 2, false, null, 0));
    try std.testing.expectEqual(2, dropPosition(4, 2, true, null, 4));
    try std.testing.expectEqual(1, dropPosition(4, 2, true, 0, 4));
    try std.testing.expectEqual(2, dropPosition(4, 2, false, 3, 0));
    try std.testing.expectEqual(0, dropPosition(0, 0, false, null, 0));
}

test "compact tab drops keep every source in its legal section" {
    for (1..10) |count| {
        for (0..count + 1) |pinned_count| {
            for (0..count) |source| {
                const pinned = source < pinned_count;
                for (0..count + 1) |slot| {
                    const position = dropPosition(count, pinned_count, pinned, source, slot);
                    try std.testing.expect(position < count);
                    try std.testing.expect(if (pinned) position < pinned_count else position >= pinned_count);
                }
                try std.testing.expectEqual(source, dropPosition(count, pinned_count, pinned, source, source));
                try std.testing.expectEqual(source, dropPosition(count, pinned_count, pinned, source, source + 1));
            }
        }
    }
}
