//! Session save/restore for the GTK apprt.
//!
//! This persists the set of open windows, their tabs, splits, and each
//! surface's working directory to disk when Ghostty exits, and restores them
//! on the next launch. This brings the macOS-only `window-save-state`
//! behavior to Linux. Unlike macOS, this is opt-in: `window-save-state` must
//! be set to `always` (see `shouldSaveState`/`shouldRestoreState`), since
//! there's no OS-level mechanism for `default` to defer to. The JSON schema
//! is versioned and tolerant of unknown fields so it can evolve without
//! breaking older files.

const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../../os/main.zig");
const configpkg = @import("../../config.zig");
const CoreConfig = configpkg.Config;
const Surface = @import("class/surface.zig").Surface;

const log = std.log.scoped(.gtk_session);

/// The subdirectory (under the XDG state directory) and filename we use.
const subdir = "ghostty";
const filename = "session.json";
const filename_tmp = "session.json.tmp";

/// Maximum size of the session file we're willing to read. Session files are
/// tiny (a few KB at most) so this is a generous sanity bound.
const max_read_size = 1024 * 1024;

/// The current schema version. Bump this when the structure changes in a way
/// that older Ghostty versions cannot understand. Readers reject mismatched
/// versions (treating them as "no session") and ignore unknown fields.
///
/// v2 replaced each tab's flat `working_directory`/`title` with a `root`
/// split tree (`Node`), since a tab can contain multiple surfaces. Older (v1)
/// session files are simply discarded on load rather than migrated.
pub const version: u32 = 2;

pub const Session = struct {
    version: u32 = version,
    windows: []const Window = &.{},

    pub const Window = struct {
        /// Stable random identifier for this window (see `newId`). 0 means
        /// "unset" (e.g. a session file written before ids existed).
        id: u64 = 0,

        /// Window geometry. Restored via setDefaultSize when present.
        width: ?i32 = null,
        height: ?i32 = null,

        /// The index (within `tabs`) of the tab that was selected/focused.
        focused_tab: ?u32 = null,

        tabs: []const Tab = &.{},
    };

    pub const Tab = struct {
        /// Stable random identifier for this tab (see `newId`). This is
        /// currently only used to key the tab's own state (not scrollback,
        /// which is keyed per-leaf now). 0 means "unset".
        id: u64 = 0,

        /// The tab's title override (e.g. from "prompt-tab-title"), if any.
        /// This is tab-level and distinct from each leaf's own title.
        title: ?[]const u8 = null,

        /// The root of this tab's split tree.
        root: Node,

        /// Path to the currently-zoomed leaf, if any.
        zoomed: ?Path = null,

        /// Path to the currently-focused (active) leaf, if any.
        active: ?Path = null,
    };

    pub const Node = union(enum) {
        leaf: Leaf,
        split: Split,
    };

    pub const Leaf = struct {
        /// Stable random identifier for this surface (see `newId`). Keys the
        /// surface's scrollback file (`<id>.vt`). 0 means "unset".
        id: u64 = 0,

        /// The working directory for this surface. If null, it is restored
        /// using the normal default working directory (e.g. when shell
        /// integration wasn't reporting a pwd).
        working_directory: ?[]const u8 = null,

        /// This surface's own effective title, if any was known.
        title: ?[]const u8 = null,
    };

    pub const Split = struct {
        layout: enum { horizontal, vertical },
        ratio: f32,
        left: *const Node,
        right: *const Node,
    };

    /// A path from a tab's tree root to a specific node, as a sequence of
    /// left/right choices at each split. This is the serialization-stable
    /// stand-in for a raw `Surface.Tree.Node.Handle`: handles are dense
    /// arena indices that get reassigned on every tree rebuild/mutation
    /// (`src/datastruct/split_tree.zig`), so they can't be persisted
    /// directly. A path resolves identically against the original live tree
    /// (to capture it) and a freshly rebuilt tree (to restore it), since
    /// both are built to have the same nested shape.
    pub const Path = []const Component;
    pub const Component = enum { left, right };
};

/// Generate a new stable random id for a window, tab, or surface. Kept to 52
/// bits so it round-trips exactly through JSON (and tools like jq/python
/// that use f64), and is never 0 (which is the "unset" sentinel).
/// Collisions across the small number of live windows/tabs/surfaces are
/// astronomically unlikely.
pub fn newId() u64 {
    const mask: u64 = (1 << 52) - 1;
    const id = std.crypto.random.int(u64) & mask;
    return if (id == 0) 1 else id;
}

/// Find the path from `tree`'s root to `target`. Returns null if `target`
/// is unreachable, which shouldn't happen for a handle taken from `tree`
/// itself.
pub fn findPath(
    alloc: Allocator,
    tree: *const Surface.Tree,
    target: Surface.Tree.Node.Handle,
) Allocator.Error!?Session.Path {
    var list: std.ArrayListUnmanaged(Session.Component) = .empty;
    errdefer list.deinit(alloc);
    if (try findPathRec(tree, .root, target, alloc, &list)) {
        return try list.toOwnedSlice(alloc);
    }
    list.deinit(alloc);
    return null;
}

fn findPathRec(
    tree: *const Surface.Tree,
    current: Surface.Tree.Node.Handle,
    target: Surface.Tree.Node.Handle,
    alloc: Allocator,
    list: *std.ArrayListUnmanaged(Session.Component),
) Allocator.Error!bool {
    if (current == target) return true;
    return switch (tree.nodes[current.idx()]) {
        .leaf => false,
        .split => |s| found: {
            try list.append(alloc, .left);
            if (try findPathRec(tree, s.left, target, alloc, list)) break :found true;
            _ = list.pop();

            try list.append(alloc, .right);
            if (try findPathRec(tree, s.right, target, alloc, list)) break :found true;
            _ = list.pop();

            break :found false;
        },
    };
}

/// Walk `path` down `tree` from the root, returning the resulting handle.
/// Assumes `path` was produced (via `findPath`) against a tree with the same
/// nested shape as `tree` -- true by construction when resolving a path
/// against a tree freshly built from the same `Node` it was captured from.
pub fn resolvePath(
    tree: *const Surface.Tree,
    node_path: Session.Path,
) Surface.Tree.Node.Handle {
    var current: Surface.Tree.Node.Handle = .root;
    for (node_path) |c| {
        const s = tree.nodes[current.idx()].split;
        current = switch (c) {
            .left => s.left,
            .right => s.right,
        };
    }
    return current;
}

/// Find the handle of the leaf holding `view` in `tree`, by pointer
/// identity. Used to turn `SplitTree.getActiveSurface()`'s view pointer
/// (there is no public accessor for the handle itself) into a handle we can
/// pass to `findPath`.
pub fn findHandleForView(
    tree: *const Surface.Tree,
    view: *Surface,
) ?Surface.Tree.Node.Handle {
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.view == view) return entry.handle;
    }
    return null;
}

/// Recursively capture a live split tree into a serializable `Node`.
pub fn captureNode(
    alloc: Allocator,
    tree: *const Surface.Tree,
    handle: Surface.Tree.Node.Handle,
) Allocator.Error!Session.Node {
    return switch (tree.nodes[handle.idx()]) {
        .leaf => |surface| .{ .leaf = try captureLeaf(alloc, surface) },
        .split => |s| split: {
            const left = try alloc.create(Session.Node);
            left.* = try captureNode(alloc, tree, s.left);
            const right = try alloc.create(Session.Node);
            right.* = try captureNode(alloc, tree, s.right);
            break :split .{ .split = .{
                .layout = switch (s.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @floatCast(s.ratio),
                .left = left,
                .right = right,
            } };
        },
    };
}

fn captureLeaf(alloc: Allocator, surface: *Surface) Allocator.Error!Session.Leaf {
    const wd_src = surface.getPwd() orelse surface.getOverrideWorkingDirectory();
    const title_src = surface.getEffectiveTitle();

    return .{
        .id = surface.getId(),
        .working_directory = if (wd_src) |v| try alloc.dupe(u8, v) else null,
        .title = if (title_src) |v| try alloc.dupe(u8, v) else null,
    };
}

/// Recursively build a live `Surface.Tree` from a captured `Node`, spawning
/// a new surface per leaf (with its saved working directory and title) and
/// grafting subtrees together with the tree's
/// existing `split` primitive. This constructs the tree bottom-up, off to
/// the side, rather than replaying interactive splits: `split` already
/// handles the grafting and view ref-counting, and building this way avoids
/// N redundant widget relayouts and the "split relative to the active
/// surface" semantics that the interactive path relies on.
///
/// `tree_alloc` MUST be a stable, long-lived allocator (in practice,
/// `Application.default().allocator()`) -- the same one used everywhere else
/// a `Surface.Tree` is constructed (e.g. `SplitTree.newSplit`). A `Tree`'s
/// GObject boxed-copy (used internally by `SplitTree.setTree` to clone the
/// tree into the widget's own long-lived storage) clones using
/// `self.arena.child_allocator`, i.e. whatever allocator built the tree in
/// the first place. Passing a transient/request-scoped arena here would
/// leave the *widget's* clone transitively backed by memory that gets freed
/// as soon as that arena is deinited -- a dangling-pointer crash the next
/// time the tree is read (this was caught via manual testing: the segfault
/// only reproduced on the very next session save after a restore).
///
/// `scratch_alloc` is used for short-lived override strings (working
/// directory, title, scrollback bytes) that `Surface.new` synchronously
/// deep-copies into its own storage -- these are safe to source from a
/// transient arena freed after this call returns.
pub fn buildTree(
    tree_alloc: Allocator,
    scratch_alloc: Allocator,
    node: Session.Node,
    scrollback_size: usize,
) !Surface.Tree {
    switch (node) {
        .leaf => |leaf| {
            const surface: *Surface = .new(.{
                .working_directory = if (leaf.working_directory) |wd|
                    scratch_alloc.dupeZ(u8, wd) catch null
                else
                    null,
                .title = if (leaf.title) |t| scratch_alloc.dupeZ(u8, t) catch null else null,
                .restore_scrollback = if (scrollback_size > 0)
                    readScrollback(scratch_alloc, leaf.id) catch null
                else
                    null,
                .id = if (leaf.id != 0) leaf.id else null,
            });
            defer surface.unref();
            _ = surface.refSink();
            return try Surface.Tree.init(tree_alloc, surface);
        },
        .split => |s| {
            var left = try buildTree(tree_alloc, scratch_alloc, s.left.*, scrollback_size);
            errdefer left.deinit();
            var right = try buildTree(tree_alloc, scratch_alloc, s.right.*, scrollback_size);
            defer right.deinit();

            const direction: Surface.Tree.Split.Direction = switch (s.layout) {
                .horizontal => .right,
                .vertical => .down,
            };
            const combined = try left.split(tree_alloc, .root, direction, @floatCast(s.ratio), &right);
            left.deinit();
            return combined;
        },
    }
}

/// Returns true if window state should be written to disk on exit.
///
/// On Linux there is no OS-level restoration mechanism to defer to, so
/// `default` means off: session save/restore is opt-in via `always`. `never`
/// disables saving entirely (and is also the effective behavior of `default`).
pub fn shouldSaveState(config: *const CoreConfig) bool {
    return switch (config.@"window-save-state") {
        .never, .default => false,
        .always => true,
    };
}

/// Returns true if a previously saved session should be restored on launch.
pub fn shouldRestoreState(config: *const CoreConfig) bool {
    return switch (config.@"window-save-state") {
        .never, .default => false,
        .always => true,
    };
}

/// Compute the absolute path to the session file. Caller owns the memory.
pub fn path(alloc: Allocator) ![]u8 {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = subdir });
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, filename });
}

/// Serialize a session to indented JSON. Caller owns the returned memory.
pub fn serialize(alloc: Allocator, session: Session) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    errdefer buffer.deinit();
    try buffer.writer.print("{f}", .{std.json.fmt(
        session,
        .{ .whitespace = .indent_2 },
    )});
    return try buffer.toOwnedSlice();
}

/// Atomically write pre-serialized session bytes to the session file,
/// creating the state directory (and any missing parents) if needed. Errors
/// are returned to the caller, which is expected to log and swallow them.
pub fn writeBytes(alloc: Allocator, bytes: []const u8) !void {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = subdir });
    defer alloc.free(dir);

    // Create/open the state directory, creating any missing parent dirs.
    var d = try std.fs.cwd().makeOpenPath(dir, .{});
    defer d.close();

    // Write to a temp file then rename over the target so a crash mid-write
    // never leaves a corrupt session file.
    try d.writeFile(.{ .sub_path = filename_tmp, .data = bytes });
    try d.rename(filename_tmp, filename);

    log.info("session written to {s}/{s} ({d} bytes)", .{ dir, filename, bytes.len });
}

/// Serialize and atomically write a session to disk in one step.
pub fn save(alloc: Allocator, session: Session) !void {
    const bytes = try serialize(alloc, session);
    defer alloc.free(bytes);
    try writeBytes(alloc, bytes);
}

/// Load and parse the session file. Returns null if there is no session file,
/// it can't be read/parsed, or its version doesn't match the current schema.
/// The returned value must be freed with `.deinit()`.
pub fn load(alloc: Allocator) !?std.json.Parsed(Session) {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = subdir });
    defer alloc.free(dir);

    var d = std.fs.cwd().openDir(dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no session directory at {s}", .{dir});
            return null;
        },
        else => return err,
    };
    defer d.close();

    const file = d.openFile(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no session file at {s}/{s}", .{ dir, filename });
            return null;
        },
        else => return err,
    };
    defer file.close();

    log.info("loading session from {s}/{s}", .{ dir, filename });

    const bytes = try file.readToEndAlloc(alloc, max_read_size);
    defer alloc.free(bytes);

    const parsed = std.json.parseFromSlice(
        Session,
        alloc,
        bytes,
        .{
            .ignore_unknown_fields = true,
            // Copy all strings into the parsed arena so the result is fully
            // self-contained and we can free `bytes` below without dangling.
            .allocate = .alloc_always,
        },
    ) catch |err| {
        log.warn("failed to parse session file, ignoring err={}", .{err});
        return null;
    };

    // Reject a session written by an incompatible schema version.
    if (parsed.value.version != version) {
        log.info(
            "ignoring session file with unsupported version={}",
            .{parsed.value.version},
        );
        parsed.deinit();
        return null;
    }

    return parsed;
}

/// Delete the session file if it exists. Used when saving is disabled
/// (`window-save-state = never`) so that a stale file is not restored.
pub fn delete(alloc: Allocator) void {
    const p = path(alloc) catch return;
    defer alloc.free(p);
    std.fs.cwd().deleteFile(p) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.warn("failed to delete session file err={}", .{err});
            return;
        },
    };
    log.info("deleted session file {s}", .{p});
}

// ---------------------------------------------------------------------------
// Scrollback persistence
//
// Each tab's scrollback is stored in its own file under a `scrollback`
// subdirectory, named `<id>.vt` (keyed by the tab's stable id), holding styled
// VT bytes. Keying by a stable id (rather than an enumeration index) means a
// tab always reads/writes the same file regardless of how windows/tabs are
// added or reordered, and lets the save path safely skip never-realized tabs.

const scrollback_subdir = "scrollback";

/// Open (creating if needed) the scrollback directory. Caller closes the Dir.
///
/// Opened with `.iterate = true` since `pruneScrollback` needs to list its
/// entries; without it, the returned Dir's fd isn't set up for iteration
/// (`getdents`/`lseek`) and iterating it panics with an EBADF-driven
/// `unreachable` in `std.fs.Dir.Iterator.next`.
fn scrollbackDir(alloc: Allocator) !std.fs.Dir {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = subdir });
    defer alloc.free(dir);
    var base = try std.fs.cwd().makeOpenPath(dir, .{});
    defer base.close();
    return try base.makeOpenPath(scrollback_subdir, .{ .iterate = true });
}

/// Write a tab's scrollback bytes to its id-keyed file.
pub fn writeScrollback(alloc: Allocator, id: u64, bytes: []const u8) !void {
    var dir = try scrollbackDir(alloc);
    defer dir.close();

    var name_buf: [32]u8 = undefined;
    var tmp_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}.vt", .{id});
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{d}.vt.tmp", .{id});

    try dir.writeFile(.{ .sub_path = tmp, .data = bytes });
    try dir.rename(tmp, name);
    log.info("scrollback id {d} written ({d} bytes)", .{ id, bytes.len });
}

/// Read a tab's scrollback bytes from its id-keyed file. Returns null if there
/// is no scrollback for that id. Caller owns the returned memory.
pub fn readScrollback(alloc: Allocator, id: u64) !?[]u8 {
    var dir = scrollbackDir(alloc) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}.vt", .{id});

    const file = dir.openFile(name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    // Generous bound; scrollback is capped by the config size anyway.
    const bytes = try file.readToEndAlloc(alloc, 64 * 1024 * 1024);
    if (bytes.len == 0) {
        alloc.free(bytes);
        return null;
    }
    return bytes;
}

/// Delete a tab's scrollback file, if it exists (e.g. a realized tab whose
/// scrollback is now empty).
pub fn deleteScrollback(alloc: Allocator, id: u64) void {
    var dir = scrollbackDir(alloc) catch return;
    defer dir.close();
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.vt", .{id}) catch return;
    dir.deleteFile(name) catch {};
}

/// Delete any scrollback files whose id is not in `keep`. Used to clean up
/// files for tabs that have been closed (and legacy index-named files). We
/// collect names first and delete afterwards so we never mutate the directory
/// mid-iteration.
pub fn pruneScrollback(alloc: Allocator, keep: []const u64) void {
    var dir = scrollbackDir(alloc) catch return;
    defer dir.close();

    var to_delete: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (to_delete.items) |n| alloc.free(n);
        to_delete.deinit(alloc);
    }

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        const del = del: {
            // Remove stale temp files unconditionally.
            if (std.mem.endsWith(u8, name, ".vt.tmp")) break :del true;
            // Only "<id>.vt" files are candidates.
            if (!std.mem.endsWith(u8, name, ".vt")) break :del false;
            const id = std.fmt.parseInt(u64, name[0 .. name.len - 3], 10) catch
                break :del false;
            for (keep) |k| if (k == id) break :del false;
            break :del true;
        };
        if (del) {
            const dup = alloc.dupe(u8, name) catch continue;
            to_delete.append(alloc, dup) catch alloc.free(dup);
        }
    }

    for (to_delete.items) |n| dir.deleteFile(n) catch {};
}

test "shouldSaveState mapping" {
    const testing = std.testing;
    var c = try CoreConfig.default(testing.allocator);
    defer c.deinit();

    c.@"window-save-state" = .never;
    try testing.expect(!shouldSaveState(&c));
    try testing.expect(!shouldRestoreState(&c));

    c.@"window-save-state" = .default;
    try testing.expect(!shouldSaveState(&c));
    try testing.expect(!shouldRestoreState(&c));

    c.@"window-save-state" = .always;
    try testing.expect(shouldSaveState(&c));
    try testing.expect(shouldRestoreState(&c));
}

test "Session JSON round trip with nested splits" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var right_split_right: Session.Node = .{ .leaf = .{
        .id = 3,
        .working_directory = "/tmp/c",
        .title = "C",
    } };
    var right_split_left: Session.Node = .{ .leaf = .{
        .id = 2,
        .working_directory = "/tmp/b",
    } };
    var right_split: Session.Node = .{ .split = .{
        .layout = .vertical,
        .ratio = 0.5,
        .left = &right_split_left,
        .right = &right_split_right,
    } };
    var left_leaf: Session.Node = .{ .leaf = .{
        .id = 1,
        .working_directory = "/tmp/a",
    } };
    const root: Session.Node = .{ .split = .{
        .layout = .horizontal,
        .ratio = 0.25,
        .left = &left_leaf,
        .right = &right_split,
    } };

    const original: Session = .{
        .windows = &.{.{
            .id = 100,
            .width = 800,
            .height = 600,
            .focused_tab = 0,
            .tabs = &.{.{
                .id = 200,
                .title = "my tab",
                .root = root,
                .zoomed = &.{ .right, .right },
                .active = &.{ .right, .left },
            }},
        }},
    };

    const bytes = try serialize(alloc, original);
    defer alloc.free(bytes);

    const parsed = try std.json.parseFromSlice(
        Session,
        alloc,
        bytes,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, version), parsed.value.version);
    try testing.expectEqual(@as(usize, 1), parsed.value.windows.len);
    const win = parsed.value.windows[0];
    try testing.expectEqual(@as(u64, 100), win.id);
    try testing.expectEqual(@as(usize, 1), win.tabs.len);

    const tab = win.tabs[0];
    try testing.expectEqualStrings("my tab", tab.title.?);
    try testing.expectEqualSlices(Session.Component, &.{ .right, .right }, tab.zoomed.?);
    try testing.expectEqualSlices(Session.Component, &.{ .right, .left }, tab.active.?);

    // Walk the round-tripped tree and confirm the shape and data survived.
    try testing.expect(tab.root == .split);
    const top = tab.root.split;
    try testing.expectEqual(.horizontal, top.layout);
    try testing.expectApproxEqAbs(@as(f32, 0.25), top.ratio, 0.0001);

    try testing.expect(top.left.* == .leaf);
    try testing.expectEqualStrings("/tmp/a", top.left.leaf.working_directory.?);

    try testing.expect(top.right.* == .split);
    const inner = top.right.split;
    try testing.expectEqual(.vertical, inner.layout);

    try testing.expect(inner.right.* == .leaf);
    try testing.expectEqualStrings("/tmp/c", inner.right.leaf.working_directory.?);
    try testing.expectEqualStrings("C", inner.right.leaf.title.?);
}
