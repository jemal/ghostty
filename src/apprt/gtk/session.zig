//! Named GTK sessions. Names are display metadata; immutable IDs identify
//! sessions and panes so renaming never changes their on-disk identity.
//! Terminal snapshots can be associated with pane IDs independently of this
//! layout manifest. This module deliberately does not persist commands.
const std = @import("std");
const Allocator = std.mem.Allocator;

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

    pub fn validate(self: Tab) !void {
        if (self.nodes.len == 0 or self.nodes.len > max_nodes) return error.InvalidTree;
        if (self.active >= self.nodes.len or self.nodes[self.active] != .leaf)
            return error.InvalidTree;
        if (self.zoomed) |z| {
            if (z >= self.nodes.len or self.nodes[z] != .leaf) return error.InvalidTree;
        }
        var seen: [max_nodes]bool = @splat(false);
        try self.visit(0, 0, &seen);
        for (seen[0..self.nodes.len]) |visited| if (!visited) return error.InvalidTree;
    }

    fn visit(self: Tab, index: u32, depth: usize, seen: []bool) error{InvalidTree}!void {
        if (depth > 64 or index >= self.nodes.len or seen[index]) return error.InvalidTree;
        seen[index] = true;
        switch (self.nodes[index]) {
            .leaf => |leaf| {
                if (leaf.id == 0) return error.InvalidTree;
                if (leaf.working_directory) |cwd| {
                    if (!std.fs.path.isAbsolute(cwd) or std.mem.indexOfScalar(u8, cwd, 0) != null)
                        return error.InvalidTree;
                }
            },
            .split => |split| {
                if (!std.math.isFinite(split.ratio) or split.ratio < 0 or split.ratio > 1)
                    return error.InvalidTree;
                try self.visit(split.left, depth + 1, seen);
                try self.visit(split.right, depth + 1, seen);
            },
        }
    }
};

pub const Node = union(enum) {
    leaf: struct {
        id: u64,
        snapshot: ?u64 = null,
        working_directory: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,
    },
    split: struct {
        layout: enum { horizontal, vertical },
        ratio: f32,
        left: u32,
        right: u32,
    },
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes or !std.unicode.utf8ValidateSlice(name))
        return false;
    if (std.mem.trim(u8, name, &std.ascii.whitespace).len != name.len) return false;
    for (name) |c| if (std.ascii.isControl(c)) return false;
    return true;
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

test "session manifest round trip and validation" {
    const alloc = std.testing.allocator;
    const original: Session = .{
        .id = 42,
        .name = "Work / Ghostty",
        .tabs = &.{.{
            .title = "Code",
            .nodes = &.{
                .{ .split = .{ .layout = .horizontal, .ratio = 0.3, .left = 1, .right = 2 } },
                .{ .leaf = .{ .id = 1, .working_directory = "/tmp" } },
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
