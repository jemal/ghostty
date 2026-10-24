//! Main-thread layout capture followed by background terminal/disk work.
//! GTK references are acquired and released only on the main thread. They
//! keep core surfaces alive while the worker reads their locked terminals.
const std = @import("std");
const gtk = @import("gtk");
const glib = @import("glib");
const gobject = @import("gobject");
const global = @import("../../global.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Surface = @import("class/surface.zig").Surface;
const Tab = @import("class/tab.zig").Tab;
const sessions = @import("session.zig");
const log = std.log.scoped(.gtk_session_save);
const Self = @This();

alloc: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
dir: std.Io.Dir,
windows: std.ArrayList(SavedWindow) = .empty,
limit: usize,
index_hash: ?u64,
thread: ?std.Thread = null,
done: std.atomic.Value(bool) = .init(false),

const Pane = struct {
    widget: *Surface,
    core: ?*CoreSurface,
    node: *sessions.Node,
};
const SavedWindow = struct {
    widget: *Window,
    manifest: sessions.Session,
    panes: []Pane,
    hash: ?u64,
    committed: bool = false,
};

pub fn create(app: *Application, index_hash: ?u64) !*Self {
    const alloc = app.allocator();
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    const config = app.getConfig();
    defer config.unref();
    self.* = .{
        .alloc = alloc,
        .arena = .init(alloc),
        .dir = try app.sessionDir(),
        .limit = config.get().@"window-save-state-snapshot-limit",
        .index_hash = index_hash,
    };
    errdefer self.release();
    const arena = self.arena.allocator();
    var current: ?*glib.List = app.as(gtk.Application).getWindows();
    while (current) |link| : (current = link.f_next) {
        const ptr: *gtk.Window = @ptrCast(@alignCast(link.f_data orelse continue));
        const window = gobject.ext.cast(Window, ptr) orelse continue;
        if (window.isQuickTerminal() or !window.isSessionSaved() or window.isSessionArchived() or window.getTabView().getNPages() == 0) continue;
        const manifest = try window.captureSession(arena);
        if (manifest.tabs.len == 0) continue;
        try manifest.validate();
        var panes: std.ArrayList(Pane) = .empty;
        const view = window.getTabView();
        for (0..@intCast(view.getNPages())) |i| {
            const tab = gobject.ext.cast(Tab, view.getNthPage(@intCast(i)).getChild()) orelse continue;
            var it = tab.surfaces();
            while (it.next()) |surface| {
                const node = node: for (manifest.tabs) |saved_tab| {
                    for (@constCast(saved_tab.nodes)) |*node| {
                        if (node.* == .leaf and node.leaf.id == surface.sessionId()) break :node node;
                    }
                    for (@constCast(saved_tab.floating)) |*floating| {
                        if (floating.pane.leaf.id == surface.sessionId()) break :node &floating.pane;
                    }
                } else unreachable;
                try panes.append(arena, .{ .widget = surface, .core = surface.core(), .node = node });
            }
        }
        try self.windows.append(arena, .{
            .widget = window,
            .manifest = manifest,
            .panes = try panes.toOwnedSlice(arena),
            .hash = window.sessionHash(),
        });
        _ = window.ref();
        for (self.windows.items[self.windows.items.len - 1].panes) |pane| _ = pane.widget.ref();
    }
    return self;
}

pub fn start(self: *Self) !void {
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn run(self: *Self) void {
    defer self.done.store(true, .release);
    self.save() catch |err| log.warn("unable to save sessions err={}", .{err});
}

/// Join and publish metadata on the main thread before releasing GTK objects.
pub fn finish(self: *Self) ?u64 {
    if (self.thread) |thread| thread.join();
    for (self.windows.items) |window| {
        if (!window.committed) continue;
        window.widget.setSessionHash(window.hash);
        for (window.panes) |pane| pane.widget.setSessionSnapshotId(pane.node.leaf.snapshot);
    }
    const hash = self.index_hash;
    self.release();
    self.alloc.destroy(self);
    return hash;
}

fn release(self: *Self) void {
    for (self.windows.items) |window| {
        for (window.panes) |pane| pane.widget.unref();
        window.widget.unref();
    }
    self.dir.close(global.io());
    self.arena.deinit();
}

fn save(self: *Self) !void {
    const arena = self.arena.allocator();
    var ids: std.ArrayList(u64) = .empty;
    for (self.windows.items) |*window| {
        for (window.panes) |pane| {
            if (self.limit == 0) {
                pane.node.leaf.snapshot = null;
                continue;
            }
            const core = pane.core orelse continue;
            self.savePane(window.manifest.id, pane, core) catch |err| {
                log.warn("unable to save pane {x} snapshot err={}", .{ pane.node.leaf.id, err });
                // Preserve the last durable generation on failure.
            };
        }
        const bytes = try sessions.serialize(arena, window.manifest);
        const hash = std.hash.Wyhash.hash(0, bytes);
        if (window.hash != hash) {
            var buf: [32]u8 = undefined;
            try sessions.write(self.dir, global.io(), try sessions.fileName(&buf, window.manifest.id), bytes);
        }
        window.hash = hash;
        window.committed = true;
        self.prune(window.*) catch |err| log.warn("unable to prune snapshots err={}", .{err});
        try ids.append(arena, window.manifest.id);
    }
    // Preserve the last session when there are no regular windows.
    if (ids.items.len == 0) return;
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    const bytes = try sessions.serialize(arena, .{ .version = sessions.version, .sessions = ids.items });
    const hash = std.hash.Wyhash.hash(0, bytes);
    if (self.index_hash == hash) return;
    try sessions.write(self.dir, global.io(), "active.json", bytes);
    self.index_hash = hash;
}

fn savePane(self: *Self, session: u64, pane: Pane, core: *CoreSurface) !void {
    const bytes = bytes: {
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        break :bytes try terminal.session.encode(self.alloc, &core.io.terminal, self.limit);
    };
    defer self.alloc.free(bytes);
    const generation = std.hash.Wyhash.hash(0, bytes);
    if (pane.node.leaf.snapshot == generation) return;
    var buf: [96]u8 = undefined;
    const name = try sessions.snapshotFileName(&buf, session, pane.node.leaf.id, generation);
    try sessions.write(self.dir, global.io(), name, bytes);
    pane.node.leaf.snapshot = generation;
}

fn prune(self: *Self, window: SavedWindow) !void {
    var prefix_buf: [32]u8 = undefined;
    const prefix = try std.mem.print(&prefix_buf, "{x}-", .{window.manifest.id});
    var it = self.dir.iterate();
    next: while (try it.next(global.io())) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix) or
            !std.mem.endsWith(u8, entry.name, ".snapshot")) continue;
        for (window.panes) |pane| {
            const generation = pane.node.leaf.snapshot orelse continue;
            var buf: [96]u8 = undefined;
            const name = try sessions.snapshotFileName(&buf, window.manifest.id, pane.node.leaf.id, generation);
            if (std.mem.eql(u8, name, entry.name)) continue :next;
        }
        try self.dir.deleteFile(global.io(), entry.name);
    }
}
