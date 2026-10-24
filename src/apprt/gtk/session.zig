//! Named GTK sessions. Names are display metadata; immutable IDs identify
//! sessions and panes so renaming never changes their on-disk identity.
//! Terminal snapshots can be associated with pane IDs independently of this
//! layout manifest. Only explicitly registered programs carry relaunch records.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Relaunch = @import("session_relaunch.zig").Record;

pub const version = 1;
pub const max_sessions = 256;
pub const max_nodes = 4095;
pub const max_tabs = 256;
pub const max_name_bytes = 128;

pub const Session = struct {
    version: u32 = version,
    id: u64,
    name: [:0]const u8,
    width: i32 = 800,
    height: i32 = 600,
    maximized: bool = false,
    title: ?[:0]const u8 = null,
    selected_tab: usize = 0,
    tabs: []const Tab,

    pub fn validate(self: Session) !void {
        if (self.version != version) return error.UnsupportedVersion;
        if (self.id == 0 or !validName(self.name)) return error.InvalidSession;
        if (self.tabs.len == 0 or self.tabs.len > max_tabs or
            self.selected_tab >= self.tabs.len or
            self.width < 1 or self.width > 32767 or
            self.height < 1 or self.height > 32767) return error.InvalidSession;
        for (self.tabs) |tab| try tab.validate();
    }
};

pub const Tab = struct {
    title: ?[:0]const u8 = null,
    nodes: []const Node,
    active: u32 = 0,
    zoomed: ?u32 = null,
    floating: []const Floating = &.{},
    floating_selected: usize = 0,
    floating_visible: bool = false,
    floating_geometry: FloatGeometry = .{},

    pub fn validate(self: Tab) !void {
        if (self.floating.len > max_tabs) return error.InvalidTree;
        if (self.floating.len > 0 and self.floating_selected >= self.floating.len) return error.InvalidTree;
        if (self.floating.len == 0 and (self.floating_selected != 0 or self.floating_visible)) return error.InvalidTree;
        try self.floating_geometry.validate();
        for (self.floating, 0..) |floating, i| {
            if (floating.pane != .leaf) return error.InvalidTree;
            try validateLeaf(floating.pane.leaf);
            if (floating.geometry) |geometry| try geometry.validate();
            if (floating.stacking >= self.floating.len) return error.InvalidTree;
            if (floating.name) |name| if (!validName(name)) return error.InvalidTree;
            for (self.floating[0..i]) |previous| {
                if (previous.pane.leaf.id == floating.pane.leaf.id) return error.InvalidTree;
                if (floating.name) |name| if (previous.name) |other| {
                    if (std.mem.eql(u8, name, other)) return error.InvalidTree;
                };
            }
            for (self.nodes) |node| if (node == .leaf and node.leaf.id == floating.pane.leaf.id) return error.InvalidTree;
        }
        if (self.nodes.len == 0) {
            if (self.floating.len == 0 or self.active != 0 or self.zoomed != null) return error.InvalidTree;
            return;
        }
        if (self.nodes.len > max_nodes) return error.InvalidTree;
        if (self.active >= self.nodes.len or self.nodes[self.active] != .leaf)
            return error.InvalidTree;
        if (self.zoomed) |z| {
            if (z >= self.nodes.len or self.nodes[z] != .leaf) return error.InvalidTree;
        }
        var seen: [max_nodes]bool = @splat(false);
        try self.visit(0, 0, false, &seen);
        for (seen[0..self.nodes.len]) |visited| if (!visited) return error.InvalidTree;
    }

    fn visit(self: Tab, index: u32, depth: usize, in_stack: bool, seen: []bool) error{InvalidTree}!void {
        if (depth > 64 or index >= self.nodes.len or seen[index]) return error.InvalidTree;
        seen[index] = true;
        switch (self.nodes[index]) {
            .leaf => |leaf| {
                try validateLeaf(leaf);
            },
            .split => |split| {
                if (!std.math.isFinite(split.ratio) or split.ratio < 0 or split.ratio > 1)
                    return error.InvalidTree;
                if ((in_stack and split.stacked) or (!split.stacked and split.stack_selected != null)) return error.InvalidTree;
                try self.visit(split.left, depth + 1, in_stack or split.stacked, seen);
                try self.visit(split.right, depth + 1, in_stack or split.stacked, seen);
                if (split.stacked) {
                    const info = self.stackInfo(index, split.stack_selected);
                    if (info.count > 32 or (split.stack_selected != null and info.matches != 1)) return error.InvalidTree;
                }
            },
        }
    }

    fn stackInfo(self: Tab, index: u32, selected: ?u64) struct { count: usize, matches: usize } {
        return switch (self.nodes[index]) {
            .leaf => |leaf| .{ .count = 1, .matches = @intFromBool(selected != null and selected.? == leaf.id) },
            .split => |split| result: {
                const left = self.stackInfo(split.left, selected);
                const right = self.stackInfo(split.right, selected);
                break :result .{ .count = left.count + right.count, .matches = left.matches + right.matches };
            },
        };
    }
};

pub const Floating = struct {
    pane: Node,
    name: ?[:0]const u8 = null,
    geometry: ?FloatGeometry = null,
    stacking: usize = 0,
};

/// Fractions of the tab content area, independent of monitor scale and size.
pub const FloatGeometry = struct {
    x: f64 = 0.15,
    y: f64 = 0.2,
    width: f64 = 0.7,
    height: f64 = 0.6,

    pub fn anchored(anchor: anytype, width_percent: f64, height_percent: f64) FloatGeometry {
        const width = width_percent / 100;
        const height = height_percent / 100;
        const ax: f64 = switch (anchor) {
            .left, .@"top-left", .@"bottom-left" => 0,
            .right, .@"top-right", .@"bottom-right" => 1,
            else => 0.5,
        };
        const ay: f64 = switch (anchor) {
            .top, .@"top-left", .@"top-right" => 0,
            .bottom, .@"bottom-left", .@"bottom-right" => 1,
            else => 0.5,
        };
        return .{ .x = (1 - width) * ax, .y = (1 - height) * ay, .width = width, .height = height };
    }

    pub const Pixels = struct { x: i32, y: i32, width: i32, height: i32 };

    /// Zoom is a display override; saved fractions remain unchanged. Keeping
    /// this separate from pixels also preserves normal directional navigation.
    pub fn displayPixels(self: FloatGeometry, parent_width: i32, parent_height: i32, zoomed: bool) Pixels {
        if (zoomed) return .{
            .x = 0,
            .y = 0,
            .width = @max(1, parent_width),
            .height = @max(1, parent_height),
        };
        return self.pixels(parent_width, parent_height);
    }

    /// Preserve alignment within the remaining space after minimum-size
    /// expansion. In particular, centered floats must stay centered.
    pub fn pixels(self: FloatGeometry, parent_width: i32, parent_height: i32) Pixels {
        const width = @max(1, parent_width);
        const height = @max(1, parent_height);
        const w = @min(width, @max(@min(320, width), @as(i32, @intFromFloat(self.width * @as(f64, @floatFromInt(width))))));
        const h = @min(height, @max(@min(180, height), @as(i32, @intFromFloat(self.height * @as(f64, @floatFromInt(height))))));
        const ax = if (self.width < 1) std.math.clamp(self.x / (1 - self.width), 0, 1) else 0.5;
        const ay = if (self.height < 1) std.math.clamp(self.y / (1 - self.height), 0, 1) else 0.5;
        return .{
            .x = @intFromFloat(@round(@as(f64, @floatFromInt(width - w)) * ax)),
            .y = @intFromFloat(@round(@as(f64, @floatFromInt(height - h)) * ay)),
            .width = w,
            .height = h,
        };
    }

    /// Offset a new panel by 24 logical pixels, wrapping each axis when full.
    pub fn cascade(self: FloatGeometry, parent_width: i32, parent_height: i32) FloatGeometry {
        const width = @max(1, parent_width);
        const height = @max(1, parent_height);
        const rect = self.pixels(width, height);
        const available_x = width - rect.width;
        const available_y = height - rect.height;
        const x = if (rect.x + 24 <= available_x) rect.x + 24 else 0;
        const y = if (rect.y + 24 <= available_y) rect.y + 24 else 0;
        var result = self;
        result.x = if (available_x > 0) @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(available_x)) * (1 - self.width) else 0;
        result.y = if (available_y > 0) @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(available_y)) * (1 - self.height) else 0;
        return result;
    }

    /// Nearest center in the requested half-plane. If there is none, wrap to
    /// the opposite extreme, preferring the same row/column. Stable cyclic tie
    /// breaking makes even identically positioned panels reachable.
    pub fn neighbor(geometries: []const FloatGeometry, selected: usize, direction: anytype, width: i32, height: i32) ?usize {
        if (geometries.len <= 1 or selected >= geometries.len) return null;
        const horizontal = direction == .left or direction == .right;
        const forward = direction == .right or direction == .down;
        const sign: f64 = if (forward) 1 else -1;
        const source = geometries[selected].pixels(width, height);
        const sx = @as(f64, @floatFromInt(source.x)) + @as(f64, @floatFromInt(source.width)) / 2;
        const sy = @as(f64, @floatFromInt(source.y)) + @as(f64, @floatFromInt(source.height)) / 2;
        var nearest: ?usize = null;
        var nearest_distance = std.math.inf(f64);
        var wrapped: ?usize = null;
        var wrap_axis = std.math.inf(f64);
        var wrap_cross = std.math.inf(f64);
        for (1..geometries.len) |step| {
            const index = (selected + if (forward) step else geometries.len - step) % geometries.len;
            const rect = geometries[index].pixels(width, height);
            const x = @as(f64, @floatFromInt(rect.x)) + @as(f64, @floatFromInt(rect.width)) / 2;
            const y = @as(f64, @floatFromInt(rect.y)) + @as(f64, @floatFromInt(rect.height)) / 2;
            const primary = sign * (if (horizontal) x - sx else y - sy);
            const cross = if (horizontal) y - sy else x - sx;
            const distance = primary * primary + cross * cross;
            if (primary > 0 and distance < nearest_distance) {
                nearest = index;
                nearest_distance = distance;
            }
            const axis = sign * (if (horizontal) x else y);
            if (axis < wrap_axis or (axis == wrap_axis and @abs(cross) < wrap_cross)) {
                wrapped = index;
                wrap_axis = axis;
                wrap_cross = @abs(cross);
            }
        }
        return nearest orelse wrapped;
    }

    pub fn validate(self: FloatGeometry) !void {
        inline for (.{ self.x, self.y, self.width, self.height }) |v| {
            if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidTree;
        }
        if (self.x >= 1 or self.y >= 1 or self.width <= 0 or self.height <= 0 or
            self.x + self.width > 1.000001 or self.y + self.height > 1.000001) return error.InvalidTree;
    }

    pub fn adjust(self: *FloatGeometry, dx: f64, dy: f64, resize: bool) void {
        if (resize) {
            self.width = std.math.clamp(self.width + dx, @min(0.2, 1 - self.x), 1 - self.x);
            self.height = std.math.clamp(self.height + dy, @min(0.2, 1 - self.y), 1 - self.y);
        } else {
            self.x = std.math.clamp(self.x + dx, 0, 1 - self.width);
            self.y = std.math.clamp(self.y + dy, 0, 1 - self.height);
        }
    }
};

fn validateLeaf(leaf: @FieldType(Node, "leaf")) !void {
    if (leaf.id == 0) return error.InvalidTree;
    if (leaf.working_directory) |cwd| {
        if (!std.fs.path.isAbsolute(cwd) or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidTree;
    }
}

pub const Node = union(enum) {
    leaf: struct {
        id: u64,
        snapshot: ?u64 = null,
        working_directory: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,
        relaunch: ?Relaunch = null,
    },
    split: struct {
        layout: enum { horizontal, vertical },
        ratio: f32,
        left: u32,
        right: u32,
        stacked: bool = false,
        stack_selected: ?u64 = null,
    },
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes or !std.unicode.utf8ValidateSlice(name))
        return false;
    if (std.mem.trim(u8, name, &std.ascii.whitespace).len != name.len) return false;
    for (name) |c| if (std.ascii.isControl(c)) return false;
    return true;
}

/// The longest name that `haikuName` can make.
pub const max_haiku_name_bytes = 15;

/// A short, readable name made from a session ID, such as "misty-pond".
/// The same ID always gives the same name.
pub fn haikuName(buf: *[max_haiku_name_bytes]u8, id: u64) []const u8 {
    const adjectives = [_][]const u8{
        "amber",   "autumn", "bold",   "brave",  "bright", "calm",   "cold",   "cool",
        "crimson", "dawn",   "dry",    "dusty",  "early",  "faded",  "fresh",  "frosty",
        "gentle",  "golden", "green",  "hidden", "hollow", "icy",    "lively", "lone",
        "lucky",   "misty",  "mossy",  "muddy",  "nimble", "noble",  "old",    "pale",
        "patient", "plain",  "proud",  "quiet",  "rapid",  "rough",  "rustic", "sandy",
        "shy",     "silent", "silver", "sleepy", "slow",   "small",  "snowy",  "soft",
        "solar",   "spring", "steady", "still",  "stormy", "summer", "sunny",  "swift",
        "tidy",    "twilit", "velvet", "woven",  "warm",   "wild",   "windy",  "winter",
    };
    const nouns = [_][]const u8{
        "bay",    "birch", "bloom",  "brook", "cedar", "cliff", "cloud",  "comet",
        "creek",  "dew",   "dune",   "dusk",  "ember", "fern",  "field",  "fire",
        "flame",  "fog",   "forest", "frog",  "frost", "glade", "grove",  "hare",
        "haze",   "heron", "hill",   "lake",  "leaf",  "maple", "marsh",  "meadow",
        "moon",   "moss",  "night",  "oak",   "otter", "owl",   "path",   "peak",
        "pine",   "pond",  "rain",   "reed",  "ridge", "river", "sea",    "shadow",
        "shore",  "sky",   "snow",   "sound", "spark", "star",  "stone",  "storm",
        "stream", "sun",   "thorn",  "tide",  "trail", "wave",  "willow", "wind",
    };

    const adjective = adjectives[@intCast(id % adjectives.len)];
    const noun = nouns[@intCast((id / adjectives.len) % nouns.len)];
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ adjective, noun }) catch unreachable;
}

test "haiku names are stable and short" {
    const testing = std.testing;
    var a: [max_haiku_name_bytes]u8 = undefined;
    var b: [max_haiku_name_bytes]u8 = undefined;
    try testing.expectEqualStrings(haikuName(&a, 42), haikuName(&b, 42));
    try testing.expect(validName(haikuName(&a, 42)));

    // Every pair of words fits in the buffer.
    var id: u64 = 0;
    while (id < 64 * 64) : (id += 1) _ = haikuName(&a, id);
}

pub fn newId(io: std.Io) u64 {
    var id: u64 = 0;
    while (id == 0) io.random(std.mem.asBytes(&id));
    return id;
}

pub fn serialize(alloc: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    return out.toOwnedSlice();
}

pub fn parse(alloc: Allocator, bytes: []const u8) !std.json.Parsed(Session) {
    const result = try std.json.parseFromSlice(Session, alloc, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .max_value_len = 1024 * 1024,
    });
    errdefer result.deinit();
    try result.value.validate();
    return result;
}

/// Caller owns the directory. App IDs isolate release/debug/custom instances.
pub fn open(io: std.Io, alloc: Allocator, base: []const u8, app_id: []const u8) !std.Io.Dir {
    const path = try std.fs.path.join(alloc, &.{ base, app_id });
    defer alloc.free(path);
    return std.Io.Dir.cwd().createDirPathOpen(io, path, .{
        .permissions = .fromMode(0o700),
        .open_options = .{ .iterate = true },
    });
}

pub fn fileName(buf: []u8, id: u64) ![]const u8 {
    return std.mem.print(buf, "{x}.json", .{id});
}

pub fn snapshotFileName(buf: []u8, session: u64, pane: u64, generation: u64) ![]const u8 {
    return std.mem.print(buf, "{x}-{x}-{x}.snapshot", .{ session, pane, generation });
}

/// Commit a complete file with rename; interrupted writes leave the old file.
pub fn write(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    var buf: [128]u8 = undefined;
    const temp = try std.mem.print(&buf, ".{s}.{x}.tmp", .{ name, newId(io) });
    errdefer dir.deleteFile(io, temp) catch {};
    const file = try dir.createFile(io, temp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    {
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try dir.rename(temp, dir, name, io);
}

pub fn load(dir: std.Io.Dir, io: std.Io, alloc: Allocator, id: u64) !std.json.Parsed(Session) {
    var buf: [32]u8 = undefined;
    const name = try fileName(&buf, id);
    const bytes = try dir.readFileAlloc(io, name, alloc, .limited(8 * 1024 * 1024));
    defer alloc.free(bytes);
    const result = try parse(alloc, bytes);
    errdefer result.deinit();
    if (result.value.id != id) return error.InvalidSession;
    return result;
}

pub const Entry = struct { id: u64, name: [:0]const u8 };

/// Move only the manifest. Immutable snapshots remain available in the main
/// store and are still identified by the same session and pane IDs.
pub fn setArchived(dir: std.Io.Dir, io: std.Io, id: u64, archived: bool) !void {
    if (id == 0) return error.InvalidSession;
    const archive = try dir.createDirPathOpen(io, "archived", .{
        .permissions = .fromMode(0o700),
        .open_options = .{ .iterate = true },
    });
    defer archive.close(io);
    var buf: [32]u8 = undefined;
    const name = try fileName(&buf, id);
    const source = if (archived) dir else archive;
    const dest = if (archived) archive else dir;
    // Never overwrite another manifest when recovering inconsistent stores.
    try source.renamePreserve(name, dest, name, io);
}

pub fn listArchived(dir: std.Io.Dir, io: std.Io, alloc: Allocator) ![]Entry {
    const archive = dir.openDir(io, "archived", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer archive.close(io);
    return list(archive, io, alloc);
}

pub fn rename(dir: std.Io.Dir, io: std.Io, alloc: Allocator, id: u64, archived: bool, name: [:0]const u8) !void {
    if (!validName(name)) return error.InvalidSession;
    const source = if (archived) try dir.openDir(io, "archived", .{}) else dir;
    defer if (archived) source.close(io);
    var manifest = try load(source, io, alloc, id);
    defer manifest.deinit();
    manifest.value.name = name;
    const bytes = try serialize(alloc, manifest.value);
    defer alloc.free(bytes);
    var buf: [32]u8 = undefined;
    try write(source, io, try fileName(&buf, id), bytes);
}

/// Remove the manifest first so a partial snapshot cleanup never leaves a
/// restorable session referring to deleted contents. Retrying is harmless.
pub fn delete(dir: std.Io.Dir, io: std.Io, id: u64) !void {
    if (id == 0) return error.InvalidSession;
    var buf: [32]u8 = undefined;
    const name = try fileName(&buf, id);
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    if (dir.openDir(io, "archived", .{})) |archive| {
        defer archive.close(io);
        archive.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const prefix = try std.mem.print(&buf, "{x}-", .{id});
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, prefix) and
            std.mem.endsWith(u8, entry.name, ".snapshot"))
            try dir.deleteFile(io, entry.name);
    }
}

/// Result strings belong to alloc (normally a short-lived arena). A corrupt
/// session is skipped without hiding the remaining sessions.
pub fn list(dir: std.Io.Dir, io: std.Io, alloc: Allocator) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id = std.fmt.parseInt(u64, entry.name[0 .. entry.name.len - 5], 16) catch continue;
        const parsed = load(dir, io, alloc, id) catch continue;
        defer parsed.deinit();
        try entries.append(alloc, .{ .id = id, .name = try alloc.dupeSentinel(u8, parsed.value.name, 0) });
        if (entries.items.len == max_sessions) break;
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            const order = std.mem.order(u8, a.name, b.name);
            return if (order == .eq) a.id < b.id else order == .lt;
        }
    }.less);
    return entries.toOwnedSlice(alloc);
}

test "session stacked panes round trip and reject invalid membership" {
    const t = std.testing;
    var nodes = [_]Node{
        .{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = 1, .right = 2, .stacked = true, .stack_selected = 2 } },
        .{ .leaf = .{ .id = 1, .snapshot = 123 } },
        .{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = 3, .right = 4 } },
        .{ .leaf = .{ .id = 2, .working_directory = "/tmp" } },
        .{ .leaf = .{ .id = 3 } },
    };
    const session: Session = .{ .id = 42, .name = "Stack", .tabs = &.{.{ .nodes = &nodes, .active = 3 }} };
    const bytes = try serialize(t.allocator, session);
    defer t.allocator.free(bytes);
    const restored = try parse(t.allocator, bytes);
    defer restored.deinit();
    try t.expectEqualDeep(session, restored.value);
    nodes[0].split.stack_selected = 999;
    try t.expectError(error.InvalidTree, session.validate());
    nodes[0].split.stack_selected = 2;
    nodes[2].split.stacked = true;
    try t.expectError(error.InvalidTree, session.validate());
    nodes[2].split.stacked = false;
    nodes[0].split.stacked = false;
    try t.expectError(error.InvalidTree, session.validate());
    // Older manifests omit stack fields and remain ordinary split layouts.
    nodes[0].split.stack_selected = null;
    try session.validate();
}

test "session manifest round trip and validation" {
    const alloc = std.testing.allocator;
    const original: Session = .{
        .id = 42,
        .name = "Work / Ghostty",
        .tabs = &.{.{
            .title = "Code",
            .nodes = &.{
                .{ .split = .{ .layout = .horizontal, .ratio = 0.3, .left = 1, .right = 2 } },
                .{ .leaf = .{ .id = 1, .working_directory = "/tmp", .relaunch = .{
                    .program = "hx",
                    .argv = &.{ "hx", "a b.rs", "" },
                    .cwd = "/tmp",
                } } },
                .{ .leaf = .{ .id = 2 } },
            },
            .active = 2,
            .zoomed = 2,
        }},
    };
    const bytes = try serialize(alloc, original);
    defer alloc.free(bytes);
    const restored = try parse(alloc, bytes);
    defer restored.deinit();
    try std.testing.expectEqualDeep(original, restored.value);

    var invalid = original;
    invalid.version = version + 1;
    try std.testing.expectError(error.UnsupportedVersion, invalid.validate());
    invalid = original;
    invalid.selected_tab = 1;
    try std.testing.expectError(error.InvalidSession, invalid.validate());
}

test "session rejects invalid names and malformed split trees" {
    const testing = std.testing;
    for ([_][]const u8{ "", " work", "work ", "a\nb", "\xff" }) |name|
        try testing.expect(!validName(name));
    try testing.expect(validName("Work / personal"));
    try testing.expect(validName("Développement"));

    var nodes = [_]Node{
        .{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = 1, .right = 2 } },
        .{ .leaf = .{ .id = 1 } },
        .{ .leaf = .{ .id = 2 } },
    };
    const tab: Tab = .{ .nodes = &nodes, .active = 1 };
    try tab.validate();
    nodes[0].split.left = 0;
    try testing.expectError(error.InvalidTree, tab.validate());
    nodes[0].split.left = 1;
    nodes[0].split.right = 1;
    try testing.expectError(error.InvalidTree, tab.validate());
    nodes[0].split.right = 9;
    try testing.expectError(error.InvalidTree, tab.validate());
    nodes[0].split.right = 2;
    nodes[0].split.ratio = std.math.nan(f32);
    try testing.expectError(error.InvalidTree, tab.validate());
}

test "session storage commits atomically and isolates corrupt sessions" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const value: Session = .{ .id = 1, .name = "Work", .tabs = &.{.{ .nodes = &.{.{ .leaf = .{ .id = 2 } }} }} };
    const bytes = try serialize(testing.allocator, value);
    defer testing.allocator.free(bytes);
    try write(tmp.dir, testing.io, "1.json", bytes);
    try write(tmp.dir, testing.io, "2.json", "broken");
    const restored = try load(tmp.dir, testing.io, testing.allocator, 1);
    defer restored.deinit();
    try testing.expectEqualDeep(value, restored.value);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const entries = try list(tmp.dir, testing.io, arena.allocator());
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("Work", entries[0].name);
}

test "session archive preserves contents and deletion stays within its ID" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const value: Session = .{ .id = 1, .name = "Work", .tabs = &.{.{
        .nodes = &.{.{ .leaf = .{ .id = 2, .snapshot = 3 } }},
    }} };
    const bytes = try serialize(alloc, value);
    try write(tmp.dir, testing.io, "1.json", bytes);
    try write(tmp.dir, testing.io, "1-2-3.snapshot", "saved contents");
    try write(tmp.dir, testing.io, "1-2-4.snapshot", "obsolete generation");
    try write(tmp.dir, testing.io, "10-2-3.snapshot", "other session");
    try write(tmp.dir, testing.io, "active.json", "index");
    try testing.expectEqual(@as(usize, 0), (try listArchived(tmp.dir, testing.io, alloc)).len);
    try setArchived(tmp.dir, testing.io, 1, true);
    try rename(tmp.dir, testing.io, testing.allocator, 1, true, "Archived Work");
    try testing.expectEqualStrings("Archived Work", (try listArchived(tmp.dir, testing.io, alloc))[0].name);
    try rename(tmp.dir, testing.io, testing.allocator, 1, true, "Work");
    try testing.expectEqual(@as(usize, 0), (try list(tmp.dir, testing.io, alloc)).len);
    const entries = try listArchived(tmp.dir, testing.io, alloc);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("Work", entries[0].name);
    try testing.expectEqualStrings("saved contents", try tmp.dir.readFileAlloc(testing.io, "1-2-3.snapshot", alloc, .limited(100)));

    // Unarchiving refuses to overwrite an existing manifest.
    try write(tmp.dir, testing.io, "1.json", bytes);
    try testing.expectError(error.PathAlreadyExists, setArchived(tmp.dir, testing.io, 1, false));
    try tmp.dir.deleteFile(testing.io, "1.json");
    try setArchived(tmp.dir, testing.io, 1, false);
    const restored = try load(tmp.dir, testing.io, testing.allocator, 1);
    defer restored.deinit();
    try testing.expectEqualDeep(value, restored.value);
    try rename(tmp.dir, testing.io, testing.allocator, 1, false, "Renamed Work");
    const renamed = try load(tmp.dir, testing.io, testing.allocator, 1);
    defer renamed.deinit();
    try testing.expectEqualStrings("Renamed Work", renamed.value.name);
    try testing.expectEqualDeep(value.tabs, renamed.value.tabs);
    try testing.expectError(error.InvalidSession, rename(tmp.dir, testing.io, testing.allocator, 1, false, "bad\nname"));
    try testing.expectEqual(@as(usize, 0), (try listArchived(tmp.dir, testing.io, alloc)).len);
    try setArchived(tmp.dir, testing.io, 1, true);
    try delete(tmp.dir, testing.io, 1);
    try delete(tmp.dir, testing.io, 1);
    try testing.expectEqual(@as(usize, 0), (try listArchived(tmp.dir, testing.io, alloc)).len);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "1-2-3.snapshot", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "1-2-4.snapshot", .{}));
    try testing.expectEqualStrings("other session", try tmp.dir.readFileAlloc(testing.io, "10-2-3.snapshot", alloc, .limited(100)));
    try testing.expectEqualStrings("index", try tmp.dir.readFileAlloc(testing.io, "active.json", alloc, .limited(100)));
    // Non-archived sessions are deleted through the same operation.
    try write(tmp.dir, testing.io, "1.json", bytes);
    try delete(tmp.dir, testing.io, 1);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "1.json", .{}));
}

test "session floating tabs round trip alongside tiles and without tiles" {
    const alloc = std.testing.allocator;
    const value: Session = .{
        .id = 1,
        .name = "Work",
        .tabs = &.{
            .{
                .nodes = &.{.{ .leaf = .{ .id = 2 } }},
                .floating = &.{
                    .{ .name = "git", .pane = .{ .leaf = .{ .id = 3, .snapshot = 7, .working_directory = "/tmp", .title = "Git" } } },
                    .{ .pane = .{ .leaf = .{ .id = 4, .relaunch = .{ .program = "hx", .argv = &.{"hx"}, .cwd = "/tmp" } } } },
                },
                .floating_selected = 1,
                .floating_visible = true,
                .floating_geometry = .{ .x = 0.1, .y = 0.1, .width = 0.8, .height = 0.8 },
            },
            .{ .nodes = &.{}, .floating = &.{.{ .pane = .{ .leaf = .{ .id = 5 } } }} },
        },
    };
    try value.validate();
    const bytes = try serialize(alloc, value);
    defer alloc.free(bytes);
    const restored = try parse(alloc, bytes);
    defer restored.deinit();
    try std.testing.expectEqualDeep(value, restored.value);

    // Old manifests need no floating fields.
    const old = try parse(alloc,
        \\{"id":1,"name":"Old","tabs":[{"nodes":[{"leaf":{"id":2}}]}]}
    );
    defer old.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.value.tabs[0].floating.len);
}

test "session rejects invalid floating identities selection and geometry" {
    const testing = std.testing;
    var floats = [_]Floating{
        .{ .name = "git", .pane = .{ .leaf = .{ .id = 3 } } },
        .{ .name = "test", .pane = .{ .leaf = .{ .id = 4 } } },
    };
    var tab: Tab = .{ .nodes = &.{.{ .leaf = .{ .id = 2 } }}, .floating = &floats };
    try tab.validate();
    floats[1].name = "git";
    try testing.expectError(error.InvalidTree, tab.validate());
    floats[1].name = "test";
    floats[1].pane.leaf.id = 3;
    try testing.expectError(error.InvalidTree, tab.validate());
    floats[1].pane.leaf.id = 2;
    try testing.expectError(error.InvalidTree, tab.validate());
    floats[1].pane.leaf.id = 4;
    tab.floating_selected = 2;
    try testing.expectError(error.InvalidTree, tab.validate());
    tab.floating_selected = 0;
    tab.floating_geometry.x = std.math.nan(f64);
    try testing.expectError(error.InvalidTree, tab.validate());
    tab.floating_geometry = .{ .x = 0.9 };
    try testing.expectError(error.InvalidTree, tab.validate());
    tab.floating_geometry = .{ .x = 1, .width = 0.0000001 };
    try testing.expectError(error.InvalidTree, tab.validate());
    tab.floating_geometry = .{};
    floats[1].pane.leaf.working_directory = "relative";
    try testing.expectError(error.InvalidTree, tab.validate());
    const empty: Tab = .{ .nodes = &.{} };
    try testing.expectError(error.InvalidTree, empty.validate());
}

test "floating zoom fills content and preserves normal geometry" {
    const testing = std.testing;
    const geometry: FloatGeometry = .{ .x = 0.1, .y = 0.15, .width = 0.5, .height = 0.4 };
    const before = geometry.pixels(1000, 800);
    try testing.expectEqualDeep(FloatGeometry.Pixels{ .x = 0, .y = 0, .width = 1000, .height = 800 }, geometry.displayPixels(1000, 800, true));
    try testing.expectEqualDeep(FloatGeometry.Pixels{ .x = 0, .y = 0, .width = 600, .height = 400 }, geometry.displayPixels(600, 400, true));
    try testing.expectEqualDeep(before, geometry.displayPixels(1000, 800, false));
    try testing.expectEqualDeep(geometry.pixels(600, 400), geometry.displayPixels(600, 400, false));
    try testing.expectEqualDeep(FloatGeometry.Pixels{ .x = 0, .y = 0, .width = 1, .height = 1 }, geometry.displayPixels(0, 0, true));
}

test "session floating geometry clamps movement and resizing" {
    var geometry: FloatGeometry = .{};
    geometry.adjust(-10, 10, false);
    try geometry.validate();
    try std.testing.expectEqual(@as(f64, 0), geometry.x);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), geometry.y, 0.000001);
    geometry.adjust(10, 10, true);
    try geometry.validate();
    geometry.adjust(-10, -10, true);
    try geometry.validate();
    try std.testing.expectEqual(@as(f64, 0.2), geometry.width);
    try std.testing.expectEqual(@as(f64, 0.2), geometry.height);
    geometry = .{ .x = 0.95, .width = 0.05 };
    geometry.adjust(-10, 0, true);
    try geometry.validate();
}

test "floating terminal anchors stay aligned when minimum size grows" {
    const testing = std.testing;
    const center = FloatGeometry.anchored(.center, 70, 60);
    try center.validate();
    try testing.expectEqual(FloatGeometry.Pixels{ .x = 150, .y = 160, .width = 700, .height = 480 }, center.pixels(1000, 800));
    try testing.expectEqual(FloatGeometry.Pixels{ .x = 40, .y = 10, .width = 320, .height = 180 }, center.pixels(400, 200));
    try testing.expectEqual(FloatGeometry.Pixels{ .x = 0, .y = 0, .width = 200, .height = 100 }, center.pixels(200, 100));
    const corner = FloatGeometry.anchored(.@"bottom-right", 50, 50);
    try corner.validate();
    try testing.expectEqual(FloatGeometry.Pixels{ .x = 80, .y = 20, .width = 320, .height = 180 }, corner.pixels(400, 200));
    const full = FloatGeometry.anchored(.center, 100, 100);
    try full.validate();
    try testing.expectEqual(FloatGeometry.Pixels{ .x = 0, .y = 0, .width = 1000, .height = 800 }, full.pixels(1000, 800));
    inline for (.{ .center, .top, .bottom, .left, .right, .@"top-left", .@"top-right", .@"bottom-left", .@"bottom-right" }) |anchor| {
        const geometry = FloatGeometry.anchored(anchor, 80, 65);
        try geometry.validate();
        const rect = geometry.pixels(1000, 800);
        try testing.expect(rect.x >= 0 and rect.y >= 0 and rect.x + rect.width <= 1000 and rect.y + rect.height <= 800);
    }
}

test "floating panels cascade in pixels and wrap within content bounds" {
    const testing = std.testing;
    const initial = FloatGeometry.anchored(.center, 70, 60);
    const second = initial.cascade(1000, 800);
    try second.validate();
    try testing.expectEqual(FloatGeometry.Pixels{ .x = 174, .y = 184, .width = 700, .height = 480 }, second.pixels(1000, 800));
    const third = second.cascade(1000, 800);
    try testing.expectEqual(FloatGeometry.Pixels{ .x = 198, .y = 208, .width = 700, .height = 480 }, third.pixels(1000, 800));
    const edge = FloatGeometry.anchored(.@"bottom-right", 70, 60).cascade(1000, 800);
    try edge.validate();
    try testing.expectEqual(@as(i32, 0), edge.pixels(1000, 800).x);
    try testing.expectEqual(@as(i32, 0), edge.pixels(1000, 800).y);
    const tiny = initial.cascade(200, 100);
    try tiny.validate();
    try testing.expectEqual(FloatGeometry.Pixels{ .x = 0, .y = 0, .width = 200, .height = 100 }, tiny.pixels(200, 100));
}

test "floating directional focus finds nearest panels and wraps on each axis" {
    const testing = std.testing;
    const grid = [_]FloatGeometry{
        .{ .x = 0, .y = 0, .width = 0.3, .height = 0.3 },
        .{ .x = 0.65, .y = 0, .width = 0.3, .height = 0.3 },
        .{ .x = 0, .y = 0.65, .width = 0.3, .height = 0.3 },
        .{ .x = 0.65, .y = 0.65, .width = 0.3, .height = 0.3 },
    };
    try testing.expectEqual(@as(?usize, 1), FloatGeometry.neighbor(&grid, 0, .right, 2000, 1200));
    try testing.expectEqual(@as(?usize, 2), FloatGeometry.neighbor(&grid, 0, .down, 2000, 1200));
    try testing.expectEqual(@as(?usize, 0), FloatGeometry.neighbor(&grid, 1, .left, 2000, 1200));
    try testing.expectEqual(@as(?usize, 0), FloatGeometry.neighbor(&grid, 2, .up, 2000, 1200));
    try testing.expectEqual(@as(?usize, 1), FloatGeometry.neighbor(&grid, 0, .left, 2000, 1200));
    try testing.expectEqual(@as(?usize, 0), FloatGeometry.neighbor(&grid, 1, .right, 2000, 1200));
    try testing.expectEqual(@as(?usize, 2), FloatGeometry.neighbor(&grid, 0, .up, 2000, 1200));
    try testing.expectEqual(@as(?usize, 0), FloatGeometry.neighbor(&grid, 2, .down, 2000, 1200));
    const identical = [_]FloatGeometry{ .{}, .{}, .{} };
    try testing.expectEqual(@as(?usize, 1), FloatGeometry.neighbor(&identical, 0, .right, 800, 600));
    try testing.expectEqual(@as(?usize, 2), FloatGeometry.neighbor(&identical, 1, .right, 800, 600));
    try testing.expectEqual(@as(?usize, 0), FloatGeometry.neighbor(&identical, 2, .right, 800, 600));
    try testing.expectEqual(@as(?usize, 2), FloatGeometry.neighbor(&identical, 0, .left, 800, 600));
    try testing.expectEqual(@as(?usize, null), FloatGeometry.neighbor(identical[0..1], 0, .left, 800, 600));
    try testing.expectEqual(@as(?usize, null), FloatGeometry.neighbor(&.{}, 0, .left, 800, 600));
}

test "floating panel sessions preserve individual geometry and stacking" {
    const alloc = std.testing.allocator;
    const value: Session = .{ .id = 10, .name = "Panels", .tabs = &.{.{
        .nodes = &.{},
        .floating_visible = true,
        .floating_selected = 1,
        .floating = &.{
            .{ .name = "git", .pane = .{ .leaf = .{ .id = 20, .snapshot = 7 } }, .geometry = FloatGeometry.anchored(.center, 70, 60), .stacking = 1 },
            .{ .pane = .{ .leaf = .{ .id = 21 } }, .geometry = .{ .x = 0.1, .y = 0.1, .width = 0.5, .height = 0.5 }, .stacking = 0 },
        },
    }} };
    const bytes = try serialize(alloc, value);
    defer alloc.free(bytes);
    const restored = try parse(alloc, bytes);
    defer restored.deinit();
    try std.testing.expectEqualDeep(value, restored.value);
    var invalid = value.tabs[0].floating[0];
    invalid.geometry.?.x = std.math.nan(f64);
    const bad: Tab = .{ .nodes = &.{}, .floating = &.{invalid} };
    try std.testing.expectError(error.InvalidTree, bad.validate());
    invalid.geometry = .{};
    invalid.stacking = 3;
    const bad_stack: Tab = .{ .nodes = &.{}, .floating = &.{invalid} };
    try std.testing.expectError(error.InvalidTree, bad_stack.validate());
}
