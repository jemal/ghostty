//! Recent paths for the path picker, newest first: folders that panes were
//! in (from OSC 7) and paths picked in the picker. Saved as JSON in the state
//! folder. Only the GTK main thread uses it.
const Self = @This();
const std = @import("std");
const glib = @import("glib");
const Allocator = std.mem.Allocator;
const path = @import("path.zig");
const sessions = @import("../session.zig");
const log = std.log.scoped(.gtk_recent_paths);

pub const version = 1;
pub const max = 200;

alloc: Allocator,
/// Each path is owned.
entries: std.ArrayList(path.Recent) = .empty,

pub fn init(alloc: Allocator) Self {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *Self) void {
    for (self.entries.items) |entry| self.alloc.free(entry.path);
    self.entries.deinit(self.alloc);
}

/// Put the path first. A path that is already in the list moves to the front.
/// Paths that are not absolute or not safe to paste are ignored.
pub fn add(self: *Self, value: []const u8, dir: bool, from: path.Recent.From) !void {
    if (value.len < 2 or value.len > std.Io.Dir.max_path_bytes or value[0] != '/' or !path.insertable(value)) return;
    const owned = try self.alloc.dupe(u8, value);
    errdefer self.alloc.free(owned);
    try self.entries.ensureUnusedCapacity(self.alloc, 1);
    _ = self.remove(value);
    self.entries.insertAssumeCapacity(0, .{ .path = owned, .dir = dir, .from = from });
    while (self.entries.items.len > max) self.alloc.free(self.entries.pop().?.path);
}

/// Returns true if the path was in the list.
pub fn remove(self: *Self, value: []const u8) bool {
    for (self.entries.items, 0..) |entry, i| if (std.mem.eql(u8, entry.path, value)) {
        self.alloc.free(self.entries.orderedRemove(i).path);
        return true;
    };
    return false;
}

const File = struct { version: u32, paths: []const path.Recent };

pub fn serialize(self: *const Self, alloc: Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, File{ .version = version, .paths = self.entries.items }, .{});
}

/// Replace the list with the saved one. Bad entries are left out; a file
/// with another version is an error.
pub fn load(self: *Self, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(File, self.alloc, bytes, .{ .ignore_unknown_fields = true, .max_value_len = 64 * 1024 });
    defer parsed.deinit();
    if (parsed.value.version != version) return error.UnsupportedVersion;
    var loaded: Self = .init(self.alloc);
    errdefer loaded.deinit();
    // Add the oldest first, so the newest ends up first.
    var it = std.mem.reverseIterator(parsed.value.paths);
    while (it.next()) |entry| try loaded.add(entry.path, entry.dir, entry.from);
    self.deinit();
    self.* = loaded;
}

/// The list and its file. The file is read once when the store is made, and
/// written a short time after a change, so that a run of changes (for
/// example a `cd` in each pane) writes it once.
pub const Store = struct {
    list: Self,
    dir: std.Io.Dir,
    io: std.Io,
    timer: c_uint = 0,

    const name = "recent.json";
    const delay_seconds = 3;

    /// Takes ownership of `dir`. A file that cannot be read starts an empty list.
    pub fn create(alloc: Allocator, io: std.Io, dir: std.Io.Dir) !*Store {
        const self = try alloc.create(Store);
        self.* = .{ .list = .init(alloc), .dir = dir, .io = io };
        const bytes = dir.readFileAlloc(io, name, alloc, .limited(1024 * 1024)) catch |err| {
            if (err != error.FileNotFound) log.warn("unable to read recent paths err={}", .{err});
            return self;
        };
        defer alloc.free(bytes);
        self.list.load(bytes) catch |err| log.warn("unable to load recent paths err={}", .{err});
        return self;
    }

    /// Writes a change that is not saved yet.
    pub fn destroy(self: *Store) void {
        if (self.timer != 0) {
            _ = glib.Source.remove(self.timer);
            self.write();
        }
        self.dir.close(self.io);
        self.list.deinit();
        self.list.alloc.destroy(self);
    }

    pub fn add(self: *Store, value: []const u8, dir: bool, from: path.Recent.From) void {
        if (self.list.entries.items.len > 0 and std.mem.eql(u8, self.list.entries.items[0].path, value) and
            self.list.entries.items[0].from == from) return;
        self.list.add(value, dir, from) catch |err| {
            log.warn("unable to add recent path err={}", .{err});
            return;
        };
        self.changed();
    }

    pub fn remove(self: *Store, value: []const u8) void {
        if (self.list.remove(value)) self.changed();
    }

    fn changed(self: *Store) void {
        if (self.timer == 0) self.timer = glib.timeoutAddSeconds(delay_seconds, saveLater, self);
    }

    fn saveLater(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Store = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.write();
        return 0;
    }

    /// Write a new file and rename it over the old one. The file is small, so
    /// this runs on the main thread. There is no sync to disk: losing the
    /// last change after a power cut is acceptable for this list.
    fn write(self: *Store) void {
        const alloc = self.list.alloc;
        const bytes = self.list.serialize(alloc) catch |err| {
            log.warn("unable to save recent paths err={}", .{err});
            return;
        };
        defer alloc.free(bytes);
        // A name of its own, because another Ghostty with the same app ID
        // can write at the same time.
        var buf: [64]u8 = undefined;
        const temp = std.fmt.bufPrint(&buf, ".{s}.{x}.tmp", .{ name, sessions.newId(self.io) }) catch unreachable;
        self.dir.writeFile(self.io, .{ .sub_path = temp, .data = bytes, .flags = .{ .permissions = .fromMode(0o600), .exclusive = true } }) catch |err| {
            log.warn("unable to save recent paths err={}", .{err});
            return;
        };
        self.dir.rename(temp, self.dir, name, self.io) catch |err| {
            log.warn("unable to save recent paths err={}", .{err});
            self.dir.deleteFile(self.io, temp) catch {};
        };
    }
};

const testing = std.testing;

test "recent paths move to the front and keep at most the limit" {
    var recent: Self = .init(testing.allocator);
    defer recent.deinit();
    try recent.add("/a", true, .pane);
    try recent.add("/b", false, .picked);
    try recent.add("/a", true, .picked);
    try recent.add("relative", true, .pane);
    try recent.add("/bad\nname", true, .pane);
    try testing.expectEqual(@as(usize, 2), recent.entries.items.len);
    try testing.expectEqualStrings("/a", recent.entries.items[0].path);
    try testing.expectEqual(.picked, recent.entries.items[0].from);
    for (0..max + 5) |i| {
        var buf: [16]u8 = undefined;
        try recent.add(try std.fmt.bufPrint(&buf, "/{d}", .{i}), true, .pane);
    }
    try testing.expectEqual(@as(usize, max), recent.entries.items.len);
    try testing.expectEqualStrings("/204", recent.entries.items[0].path);
    try testing.expect(recent.remove("/204"));
    try testing.expect(!recent.remove("/204"));
    try testing.expectEqualStrings("/203", recent.entries.items[0].path);
}

test "recent paths save and load in the same order" {
    const a = testing.allocator;
    var recent: Self = .init(a);
    defer recent.deinit();
    try recent.add("/old", true, .pane);
    try recent.add("/new file", false, .picked);
    const bytes = try recent.serialize(a);
    defer a.free(bytes);

    var loaded: Self = .init(a);
    defer loaded.deinit();
    try loaded.add("/replaced", true, .pane);
    try loaded.load(bytes);
    try testing.expectEqual(@as(usize, 2), loaded.entries.items.len);
    try testing.expectEqualStrings("/new file", loaded.entries.items[0].path);
    try testing.expect(!loaded.entries.items[0].dir);
    try testing.expectEqualStrings("/old", loaded.entries.items[1].path);

    try testing.expectError(error.UnsupportedVersion, loaded.load("{\"version\":2,\"paths\":[]}"));
    try testing.expectEqual(@as(usize, 2), loaded.entries.items.len);
    try loaded.load("{\"version\":1,\"paths\":[{\"path\":\"x\",\"dir\":true,\"from\":\"pane\"}]}");
    try testing.expectEqual(@as(usize, 0), loaded.entries.items.len);
}

test "recent paths free memory when loading fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: Allocator) !void {
            var recent: Self = .init(a);
            defer recent.deinit();
            try recent.load("{\"version\":1,\"paths\":[{\"path\":\"/a\",\"dir\":true,\"from\":\"pane\"},{\"path\":\"/b\",\"dir\":false,\"from\":\"picked\"}]}");
        }
    }.run, .{});
}

test "recent path store writes its file and reads it again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    {
        const store = try Store.create(a, testing.io, try tmp.dir.openDir(testing.io, ".", .{}));
        store.add("/a", true, .pane);
        store.add("/b", false, .picked);
        // Destroy writes the change that is waiting for the timer.
        store.destroy();
    }
    const store = try Store.create(a, testing.io, try tmp.dir.openDir(testing.io, ".", .{}));
    defer store.destroy();
    try testing.expectEqual(@as(usize, 2), store.list.entries.items.len);
    try testing.expectEqualStrings("/b", store.list.entries.items[0].path);
}
