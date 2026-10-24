//! The connection between the GTK application and the Lua runtime. See
//! `LUA_PLAN.md`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
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
const protocol = @import("picker/protocol.zig");
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
    runtime.retired = true;
    if (runtime.depth == 0 and !runtime.dispatching) return runtime.destroy();
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
    .exec = exec,
    .pick = pick,
    .timer = timer,
    .status = status,
};

fn status(_: *anyopaque, surface_id: u64, text: [:0]const u8) bool {
    const app = Application.default();
    if (surface_id == 0) {
        var windows: ?*glib.List = app.as(gtk.Application).getWindows();
        while (windows) |link| : (windows = link.f_next) {
            const window = gobject.ext.cast(Window, @as(*gtk.Window, @ptrCast(@alignCast(link.f_data orelse continue)))) orelse continue;
            window.setLuaStatus(text);
        }
        return true;
    }
    const surface = app.core().findSurfaceByID(surface_id) orelse return false;
    const window = ext.getAncestor(Window, surface.rt_surface.surface.as(gtk.Widget)) orelse return false;
    window.setLuaStatus(text);
    return true;
}

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

/// A process that `ghostty.exec` started. The completion callback always
/// runs, also after `cancel`, and frees it.
const ExecOp = struct {
    callback: Runtime.Callback,
    process: *gio.Subprocess,
    cancellable: *gio.Cancellable,
    timeout_source: c_uint = 0,
    kill_source: c_uint = 0,
    cancelled: bool = false,

    fn cancel(ptr: *anyopaque) void {
        const op: *ExecOp = @ptrCast(@alignCast(ptr));
        op.cancelled = true;
        op.process.forceExit();
        op.cancellable.cancel();
    }

    fn destroy(op: *ExecOp) void {
        if (op.timeout_source != 0) _ = glib.Source.remove(op.timeout_source);
        if (op.kill_source != 0) _ = glib.Source.remove(op.kill_source);
        op.process.unref();
        op.cancellable.unref();
        Application.default().allocator().destroy(op);
    }
};

fn exec(
    _: *anyopaque,
    callback: Runtime.Callback,
    argv: []const [:0]const u8,
    options: Runtime.ExecOptions,
    err_buf: *Runtime.ErrorBuffer,
) error{ExecFailed}!Runtime.Wait {
    const alloc = Application.default().allocator();

    const process = process: {
        const c_argv = alloc.allocSentinel(?[*:0]const u8, argv.len, null) catch {
            err_buf.set("out of memory", .{});
            return error.ExecFailed;
        };
        defer alloc.free(c_argv);
        for (argv, c_argv) |arg, *ptr| ptr.* = arg.ptr;

        // The process gets Ghostty's environment, like a new terminal.
        const launcher = gio.SubprocessLauncher.new(.{
            .stdin_pipe = options.stdin != null,
            .stdout_pipe = true,
            .stderr_pipe = true,
        });
        defer launcher.unref();
        if (options.cwd) |cwd| launcher.setCwd(cwd);

        var gerr: ?*glib.Error = null;
        break :process launcher.spawnv(@ptrCast(c_argv.ptr), &gerr) orelse {
            defer if (gerr) |e| e.free();
            const msg = if (gerr) |e| std.mem.span(e.f_message orelse "unknown error") else "unknown error";
            err_buf.set("{s}", .{msg});
            return error.ExecFailed;
        };
    };

    const op = alloc.create(ExecOp) catch {
        process.forceExit();
        process.unref();
        err_buf.set("out of memory", .{});
        return error.ExecFailed;
    };
    op.* = .{
        .callback = callback,
        .process = process,
        .cancellable = gio.Cancellable.new(),
    };

    const stdin: ?*glib.Bytes = if (options.stdin) |data| glib.Bytes.new(data.ptr, data.len) else null;
    defer if (stdin) |bytes| bytes.unref();
    process.communicateAsync(stdin, op.cancellable, execDone, op);
    if (options.timeout_ms > 0) op.timeout_source = glib.timeoutAdd(options.timeout_ms, execTimeout, op);

    return .{ .ptr = op, .cancel = ExecOp.cancel };
}

fn execDone(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const op: *ExecOp = @ptrCast(@alignCast(data.?));
    defer op.destroy();

    var stdout: ?*glib.Bytes = null;
    var stderr: ?*glib.Bytes = null;
    var gerr: ?*glib.Error = null;
    const ok = op.process.communicateFinish(result, @ptrCast(&stdout), @ptrCast(&stderr), &gerr) != 0;
    defer {
        if (stdout) |bytes| bytes.unref();
        if (stderr) |bytes| bytes.unref();
        if (gerr) |e| e.free();
    }
    if (op.cancelled) return;

    const callback = op.callback;
    if (!ok) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintSentinel(&buf, "command failed: {s}", .{
            if (gerr) |e| std.mem.span(e.f_message orelse "unknown error") else "unknown error",
        }, 0) catch "command failed";
        return callback.runtime.complete(callback.id, .{ .failed = msg });
    }

    const process = op.process;
    callback.runtime.complete(callback.id, .{ .exec = .{
        .status = if (process.getIfExited() != 0) process.getExitStatus() else null,
        .signal = if (process.getIfSignaled() != 0) process.getTermSig() else null,
        .stdout = bytesSlice(stdout),
        .stderr = bytesSlice(stderr),
    } });
}

/// Ask the process to stop, then stop it two seconds later.
fn execTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const op: *ExecOp = @ptrCast(@alignCast(data.?));
    op.timeout_source = 0;
    op.process.sendSignal(@backingInt(std.posix.SIG.TERM));
    op.kill_source = glib.timeoutAdd(2000, execKill, op);
    return 0;
}

fn execKill(data: ?*anyopaque) callconv(.c) c_int {
    const op: *ExecOp = @ptrCast(@alignCast(data.?));
    op.kill_source = 0;
    op.process.forceExit();
    return 0;
}

fn bytesSlice(bytes: ?*glib.Bytes) []const u8 {
    const b = bytes orelse return "";
    var len: usize = 0;
    const ptr = b.getData(&len) orelse return "";
    return ptr[0..len];
}

/// A picker that `ghostty.pick` opened.
const PickOp = struct {
    callback: Runtime.Callback,

    fn cancel(ptr: *anyopaque) void {
        const op: *PickOp = @ptrCast(@alignCast(ptr));
        if (Application.default().picker()) |service| service.cancelNative(op);
        Application.default().allocator().destroy(op);
    }
};

fn pick(
    _: *anyopaque,
    callback: Runtime.Callback,
    surface_id: u64,
    request: Runtime.PickRequest,
    err_buf: *Runtime.ErrorBuffer,
) error{PickFailed}!Runtime.Wait {
    const app = Application.default();
    const alloc = app.allocator();
    const service = app.picker() orelse {
        err_buf.set("the picker is not available", .{});
        return error.PickFailed;
    };
    const surface = app.core().findSurfaceByID(surface_id) orelse {
        err_buf.set("no surface with that ID", .{});
        return error.PickFailed;
    };

    // Go through the JSON protocol, so the request gets the same checks
    // and limits as a request from `ghostty +pick`.
    const parsed = parsed: {
        const choices = alloc.alloc(protocol.Choice, request.choices.len) catch {
            err_buf.set("out of memory", .{});
            return error.PickFailed;
        };
        defer alloc.free(choices);
        for (request.choices, choices) |from, *to| to.* = .{
            .id = from.id,
            .label = from.label,
            .description = from.description,
        };

        var value: protocol.Request = .{
            .version = 1,
            .request_id = "lua",
            .choices = choices,
            .placement = if (request.cursor) .cursor else .center,
        };
        if (request.title) |v| value.title = v;
        if (request.placeholder) |v| value.placeholder = v;

        const json = protocol.encode(alloc, value) catch {
            err_buf.set("out of memory", .{});
            return error.PickFailed;
        };
        defer alloc.free(json);
        break :parsed protocol.parse(alloc, json) catch |err| {
            err_buf.set("invalid picker request: {t}", .{err});
            return error.PickFailed;
        };
    };

    const op = alloc.create(PickOp) catch {
        var owned = parsed;
        owned.deinit();
        err_buf.set("out of memory", .{});
        return error.PickFailed;
    };
    op.* = .{ .callback = callback };

    service.presentNative(surface.rt_surface.gobj(), parsed, .{ .ptr = op, .done = pickDone }) catch |err| {
        var owned = parsed;
        owned.deinit();
        alloc.destroy(op);
        err_buf.set("unable to open the picker: {t}", .{err});
        return error.PickFailed;
    };
    return .{ .ptr = op, .cancel = PickOp.cancel };
}

fn pickDone(ptr: *anyopaque, id: ?[]const u8) void {
    const op: *PickOp = @ptrCast(@alignCast(ptr));
    const callback = op.callback;
    Application.default().allocator().destroy(op);
    callback.runtime.complete(callback.id, .{ .pick = id });
}

/// A GLib timer for `ghostty.sleep`, `ghostty.after` and `ghostty.every`.
const TimerOp = struct {
    alloc: Allocator,
    callback: Runtime.Callback,
    source: c_uint = 0,

    fn cancel(ptr: *anyopaque) void {
        const op: *TimerOp = @ptrCast(@alignCast(ptr));
        _ = glib.Source.remove(op.source);
        op.alloc.destroy(op);
    }
};

fn timer(_: *anyopaque, callback: Runtime.Callback, ms: u32) Allocator.Error!Runtime.Wait {
    // init.lua can register timers before Application.new has created the
    // default GTK application. Keep the runtime allocator through cleanup too.
    const alloc = callback.runtime.alloc;
    const op = try alloc.create(TimerOp);
    op.* = .{ .alloc = alloc, .callback = callback };
    op.source = glib.timeoutAdd(ms, timerFired, op);
    return .{ .ptr = op, .cancel = TimerOp.cancel };
}

fn timerFired(data: ?*anyopaque) callconv(.c) c_int {
    const op: *TimerOp = @ptrCast(@alignCast(data.?));
    const callback = op.callback;
    op.alloc.destroy(op);
    callback.runtime.complete(callback.id, .timer);
    return 0;
}

test "Lua host timers allocate and cancel before the GTK application exists" {
    const runtime = try Runtime.create(std.testing.allocator, host);
    defer runtime.destroy();
    const wait = try timer(host.ptr, .{ .runtime = runtime, .id = 1 }, 60_000);
    wait.cancel(wait.ptr);
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
