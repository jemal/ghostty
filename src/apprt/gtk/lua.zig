//! The connection between the GTK application and the Lua runtime. See
//! `LUA_PLAN.md`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gtk = @import("gtk");

const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const ext = @import("ext.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Overrides = @import("class/Overrides.zig");
const SplitTree = @import("class/split_tree.zig").SplitTree;
const Surface = @import("class/surface.zig").Surface;
pub const Runtime = @import("lua/Runtime.zig");

const log = std.log.scoped(.gtk_lua);

pub const Loaded = struct {
    config: configpkg.Config,

    /// Null when there is no `init.lua`.
    runtime: ?*Runtime,
};

/// Load the configuration and `init.lua` from the Ghostty config directory.
/// The keybinds and command palette entries that `init.lua` defines are
/// added to the configuration. An error in `init.lua` becomes a
/// configuration diagnostic. It does not stop the load.
pub fn loadConfig(alloc: Allocator) !Loaded {
    const dir = dir: {
        var env = try global.environMap();
        defer env.deinit();
        break :dir try internal_os.xdg.config(
            global.io(),
            alloc,
            &env,
            .{ .subdir = "ghostty" },
        );
    };
    defer alloc.free(dir);

    const init_path = try std.fs.path.joinZ(alloc, &.{ dir, "init.lua" });
    defer alloc.free(init_path);

    // Without init.lua, the configuration loads as usual. Other open errors
    // go to Lua, which reports them as a diagnostic.
    if (std.Io.Dir.openFileAbsolute(global.io(), init_path, .{})) |file| {
        file.close(global.io());
    } else |err| switch (err) {
        error.FileNotFound => return .{ .config = try .load(alloc), .runtime = null },
        else => {},
    }

    const runtime = try Runtime.create(alloc, host);
    errdefer runtime.destroy();

    var err_buf: [512]u8 = undefined;
    const load_error = load: {
        const lua_dir = try std.fs.path.join(alloc, &.{ dir, "lua" });
        defer alloc.free(lua_dir);
        break :load runtime.load(init_path, lua_dir, &err_buf);
    };

    const entries = try runtime.configEntries(alloc);
    defer {
        for (entries) |entry| alloc.free(entry);
        alloc.free(entries);
    }

    var config: configpkg.Config = try .loadWithExtra(alloc, entries);
    errdefer config.deinit();
    if (load_error) |msg| {
        log.warn("init.lua failed: {s}", .{msg});
        try config.addDiagnosticFmt("init.lua: {s}", .{msg});
    }

    return .{ .config = config, .runtime = runtime };
}

/// Free a runtime that a new configuration replaced. If one of its actions
/// runs now, for example an action that reloads the configuration, the
/// runtime is freed later, when GTK is idle.
pub fn retire(runtime: *Runtime) void {
    if (runtime.depth == 0) return runtime.destroy();
    _ = glib.idleAdd(destroyLater, runtime);
}

fn destroyLater(ud: ?*anyopaque) callconv(.c) c_int {
    const runtime: *Runtime = @ptrCast(@alignCast(ud orelse return 0));
    runtime.destroy();
    return 0;
}

// The host functions find the application through its global instance, so
// they need no context of their own.
var host_context: u8 = 0;
const host: Runtime.Host = .{
    .ptr = &host_context,
    .invoke = invoke,
    .toast = toast,
    .info = info,
    .open = open,
};

fn invoke(_: *anyopaque, surface_id: u64, action: input.Binding.Action) bool {
    const surface = Application.default().core().findSurfaceByID(surface_id) orelse return false;
    return surface.performBindingAction(action) catch |err| {
        log.warn("Lua action {t} failed err={}", .{ action, err });
        return false;
    };
}

fn toast(_: *anyopaque, surface_id: u64, text: [:0]const u8) void {
    const surface = Application.default().core().findSurfaceByID(surface_id) orelse return;
    const window = ext.getAncestor(
        Window,
        surface.rt_surface.surface.as(gtk.Widget),
    ) orelse return;
    window.showLuaToast(text);
}

fn info(_: *anyopaque, alloc: Allocator, surface_id: u64) Allocator.Error!?Runtime.SurfaceInfo {
    const surface = Application.default().core().findSurfaceByID(surface_id) orelse return null;

    const foreground: ?Runtime.SurfaceInfo.Foreground = foreground: {
        const pid = surface.getProcessInfo(.foreground_pid) orelse break :foreground null;
        break :foreground .{
            .pid = pid,
            .cwd = try procCwd(alloc, pid),
            .name = try procName(alloc, pid),
        };
    };

    return .{
        .title = if (surface.rt_surface.surface.getEffectiveTitle()) |title|
            try alloc.dupe(u8, title)
        else
            null,
        .pwd = try surface.pwd(alloc),
        .foreground = foreground,
    };
}

/// The working directory of the process, from `/proc` (Linux only).
fn procCwd(alloc: Allocator, pid: u64) Allocator.Error!?[]const u8 {
    if (comptime @import("builtin").target.os.tag != .linux) return null;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid}) catch return null;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(global.io(), path, &buf) catch return null;
    return try alloc.dupe(u8, buf[0..len]);
}

/// The command name of the process, from `/proc` (Linux only).
fn procName(alloc: Allocator, pid: u64) Allocator.Error!?[]const u8 {
    if (comptime @import("builtin").target.os.tag != .linux) return null;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
    const file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch return null;
    defer file.close(global.io());

    var read_buf: [64]u8 = undefined;
    var file_reader = file.reader(global.io(), &read_buf);
    var buf: [64]u8 = undefined;
    const len = file_reader.interface.readSliceShort(&buf) catch return null;
    return try alloc.dupe(u8, std.mem.trimEnd(u8, buf[0..len], "\n"));
}

fn open(
    _: *anyopaque,
    surface_id: u64,
    target: Runtime.OpenTarget,
    options: Runtime.OpenOptions,
) Runtime.OpenError!void {
    const app = Application.default();
    const parent = if (surface_id == 0)
        null
    else
        app.core().findSurfaceByID(surface_id) orelse return error.NoSurface;

    const overrides: Overrides = .{
        .command = options.command,
        .shell_integration = null,
        .working_directory = options.cwd,
        .title = options.title,
        .wait_after_command = options.wait,
    };

    switch (target) {
        .split => |direction| {
            const surface = (parent orelse return error.NoSurface).rt_surface.surface;
            const tree = ext.getAncestor(SplitTree, surface.as(gtk.Widget)) orelse
                return error.OpenFailed;
            try tree.newSplit(switch (direction) {
                inline else => |tag| @field(Surface.Tree.Split.Direction, @tagName(tag)),
            }, surface, overrides);
        },

        .tab => {
            const surface = parent orelse return error.NoSurface;
            const window = ext.getAncestor(Window, surface.rt_surface.surface.as(gtk.Widget)) orelse
                return error.OpenFailed;
            window.newTab(surface, overrides);
        },

        .window => app.newWindow(parent, overrides) catch |err| {
            log.warn("Lua window failed err={}", .{err});
            return error.OpenFailed;
        },
    }
}
