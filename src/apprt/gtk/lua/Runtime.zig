//! The Lua scripting runtime of the GTK app. See `../LUA_PLAN.md`.
//!
//! One runtime belongs to the application. It runs only on the GTK main
//! thread. `init.lua` defines actions and keybinds while it loads. The app
//! turns them into extra config entries with `configEntries`, so Lua
//! keybinds and command palette entries use the normal config code. A
//! binding with the `lua:<name>` action then calls `run`.
//!
//! Lua errors use longjmp. The C functions below therefore do all checks
//! that can raise a Lua error before they allocate Zig memory, and they
//! use no `defer` across calls that can raise.
const Runtime = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("lua").c;
const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const input = @import("../../../input.zig");
const session_relaunch = @import("../session_relaunch.zig");

const log = std.log.scoped(.gtk_lua);

/// The time that `init.lua` may run before it is stopped.
const load_budget_ns = 1 * std.time.ns_per_s;

/// The time that one action may run before it is stopped.
const action_budget_ns = 250 * std.time.ns_per_ms;

/// The maximum depth of Lua actions that run other Lua actions.
const max_depth = 16;

/// The prefix of the names that `ghostty.bind` gives to bound functions.
const bind_prefix = "__bind_";

/// The functions that the runtime uses to act on the app.
pub const Host = struct {
    ptr: *anyopaque,

    /// Perform a binding action on the surface with the given runtime ID.
    /// Returns true if the action was performed.
    invoke: *const fn (ptr: *anyopaque, surface: u64, action: input.Binding.Action) bool,

    /// Show a short message in the window of the given surface.
    toast: *const fn (ptr: *anyopaque, surface: u64, text: [:0]const u8) void,

    /// Get information about the surface with the given runtime ID, or null
    /// if there is no such surface. Strings are allocated with `alloc`.
    info: *const fn (ptr: *anyopaque, alloc: Allocator, surface: u64) Allocator.Error!?SurfaceInfo,

    /// Open a new split, tab or window. `surface` is the runtime ID of the
    /// surface to split, of a surface in the window to add a tab to, or of
    /// the parent of a new window. It is zero when there is no parent.
    open: *const fn (ptr: *anyopaque, surface: u64, target: OpenTarget, options: OpenOptions) OpenError!void,

    /// Start a process. When it exits, call `Runtime.complete` with an
    /// `exec` result. On failure, write the reason to `err_buf`.
    exec: *const fn (
        ptr: *anyopaque,
        callback: Callback,
        argv: []const [:0]const u8,
        options: ExecOptions,
        err_buf: *ErrorBuffer,
    ) error{ExecFailed}!Wait,

    /// Show the picker on a surface. When it closes, call
    /// `Runtime.complete` with a `pick` result.
    pick: *const fn (
        ptr: *anyopaque,
        callback: Callback,
        surface: u64,
        request: PickRequest,
        err_buf: *ErrorBuffer,
    ) error{PickFailed}!Wait,

    /// After `ms` milliseconds, call `Runtime.complete` with a `timer`
    /// result.
    timer: *const fn (ptr: *anyopaque, callback: Callback, ms: u32) Allocator.Error!Wait,
};

/// Where the host gives the result of an operation.
pub const Callback = struct {
    runtime: *Runtime,
    id: u32,
};

/// A host operation that is not finished. `cancel` stops it. After
/// `cancel`, the host must not call `Runtime.complete` for it.
pub const Wait = struct {
    ptr: *anyopaque,
    cancel: *const fn (ptr: *anyopaque) void,
};

pub const Result = union(enum) {
    exec: ExecResult,

    /// The ID of the chosen item, or null if the picker was cancelled.
    pick: ?[]const u8,

    timer,

    /// The operation failed. The task gets `nil, msg`.
    failed: [:0]const u8,
};

pub const ExecOptions = struct {
    cwd: ?[:0]const u8 = null,

    /// Zero means no limit. After the limit, the process gets SIGTERM, and
    /// SIGKILL two seconds later.
    timeout_ms: u32 = 0,

    stdin: ?[]const u8 = null,
};

pub const ExecResult = struct {
    /// The exit status, if the process exited.
    status: ?i32,

    /// The signal, if a signal stopped the process.
    signal: ?i32,

    stdout: []const u8,
    stderr: []const u8,
};

pub const PickRequest = struct {
    title: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    cursor: bool = false,
    choices: []const Choice,

    pub const Choice = struct {
        id: []const u8,
        label: []const u8,
        description: []const u8 = "",
    };
};

pub const ErrorBuffer = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *ErrorBuffer, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.fmt.bufPrint(&self.buf, fmt, args) catch &self.buf;
        self.len = text.len;
    }

    fn message(self: *const ErrorBuffer, default: []const u8) []const u8 {
        return if (self.len > 0) self.buf[0..self.len] else default;
    }
};

/// An action that runs or waits. Its coroutine stays in the Lua registry
/// while the task exists.
const Task = struct {
    thread: *c.lua_State,
    ref: c_int,

    /// The action name, for error messages.
    name: []const u8,

    surface: u64,

    /// The host operation that the task waits for. Null while it runs.
    wait: ?Wait = null,
};

const Timer = struct {
    /// The Lua function, as a reference in the Lua registry.
    ref: c_int,
    interval_ms: u32,
    repeat: bool,
    surface: u64,
    wait: ?Wait,
};

pub const SurfaceInfo = struct {
    title: ?[]const u8 = null,

    /// The directory that the shell reports with OSC 7.
    pwd: ?[]const u8 = null,

    foreground: ?Foreground = null,

    /// The process group that controls the terminal now.
    pub const Foreground = struct {
        pid: u64,
        cwd: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
};

pub const OpenTarget = union(enum) {
    split: Direction,
    tab,
    window,

    pub const Direction = enum { left, right, down, up };
};

pub const OpenOptions = struct {
    command: ?configpkg.Command = null,
    cwd: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,

    /// Keep the terminal open after the command exits. Null uses the
    /// `wait-after-command` config value.
    wait: ?bool = null,
};

pub const OpenError = Allocator.Error || error{ NoSurface, OpenFailed };

const Action = struct {
    /// The Lua function, as a reference in the Lua registry.
    ref: c_int,
    title: ?[:0]const u8,
    description: ?[:0]const u8,
};

const Bind = struct {
    table: ?[]const u8,
    trigger: []const u8,
    action: []const u8,

    /// A bound function decides if it handled the key, so its binding
    /// uses the `performable:` flag.
    performable: bool,
};

alloc: Allocator,

/// Owns action names, titles, descriptions and binds.
arena: std.heap.ArenaAllocator,

/// Temporary memory for one call of a Lua C function. Each function that
/// uses it resets it first. It needs no `defer`, so a Lua error cannot
/// leak it.
scratch: std.heap.ArenaAllocator,

lua: *c.lua_State,
host: Host,
actions: std.StringArrayHashMapUnmanaged(Action) = .empty,
binds: std.ArrayList(Bind) = .empty,
relaunch_programs: std.ArrayList([]const u8) = .empty,
relaunch_commands: std.StringHashMapUnmanaged([]const []const u8) = .empty,

/// True while `init.lua` runs. Some functions work only at load time.
loading: bool = false,

/// The time, from the awake clock, after which the hook stops Lua code.
deadline_ns: i96 = 0,

/// The number of actions that run now, including nested actions.
depth: u8 = 0,

/// The runtime ID of the surface that started the running action.
surface: u64 = 0,

/// The ID of the task that runs now, or zero.
task: u32 = 0,

tasks: std.AutoHashMapUnmanaged(u32, Task) = .empty,
timers: std.AutoHashMapUnmanaged(u32, Timer) = .empty,

/// The last ID of a task or timer. Tasks and timers share the IDs, so
/// `complete` can find either.
next_id: u32 = 0,

pub const InitError = Allocator.Error || error{LuaInitFailed};

pub fn create(alloc: Allocator, host: Host) InitError!*Runtime {
    const self = try alloc.create(Runtime);
    errdefer alloc.destroy(self);

    const lua = c.luaL_newstate() orelse return error.LuaInitFailed;
    self.* = .{
        .alloc = alloc,
        .arena = .init(alloc),
        .scratch = .init(alloc),
        .lua = lua,
        .host = host,
    };

    // The main state's extra space holds the runtime, so the C functions
    // can find it. Coroutines copy the extra space of the main state.
    extraSpace(lua).* = self;

    c.luaL_openlibs(lua);
    self.installApi();
    return self;
}

pub fn destroy(self: *Runtime) void {
    // Stop all host operations, so the host never calls `complete` on a
    // runtime that is gone.
    var tasks = self.tasks.valueIterator();
    while (tasks.next()) |task| if (task.wait) |wait| wait.cancel(wait.ptr);
    var timers = self.timers.valueIterator();
    while (timers.next()) |timer| if (timer.wait) |wait| wait.cancel(wait.ptr);
    self.tasks.deinit(self.alloc);
    self.timers.deinit(self.alloc);

    c.lua_close(self.lua);
    self.actions.deinit(self.alloc);
    self.binds.deinit(self.alloc);
    self.relaunch_programs.deinit(self.alloc);
    self.relaunch_commands.deinit(self.alloc);
    self.arena.deinit();
    self.scratch.deinit();
    self.alloc.destroy(self);
}

/// Run the Lua file at `path`. `lua_dir` becomes the search path of
/// `require`. Returns null on success. On failure, returns the Lua error
/// message, copied into `err_buf`. Actions and binds that were defined
/// before the failure stay.
pub fn load(
    self: *Runtime,
    path: [:0]const u8,
    lua_dir: []const u8,
    err_buf: []u8,
) ?[]const u8 {
    const L = self.lua;

    // Search only the Ghostty Lua directory, and never load C modules.
    package: {
        _ = c.lua_getglobal(L, "package");
        defer c.lua_settop(L, -2);
        if (c.lua_type(L, -1) != c.LUA_TTABLE) break :package;
        const search_path = std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{0s}/?.lua;{0s}/?/init.lua",
            .{lua_dir},
            0,
        ) catch break :package;
        _ = c.lua_pushstring(L, search_path.ptr);
        c.lua_setfield(L, -2, "path");
        _ = c.lua_pushstring(L, "");
        c.lua_setfield(L, -2, "cpath");
    }

    self.loading = true;
    defer self.loading = false;
    self.deadline_ns = now() + load_budget_ns;
    c.lua_sethook(L, budgetHook, c.LUA_MASKCOUNT, 10_000);
    defer c.lua_sethook(L, null, 0, 0);

    const status = status: {
        const loaded = c.luaL_loadfilex(L, path.ptr, null);
        if (loaded != c.LUA_OK) break :status loaded;
        break :status c.lua_pcallk(L, 0, 0, 0, 0, null);
    };
    if (status == c.LUA_OK) return null;

    const msg = popError(L);
    const len = @min(msg.len, err_buf.len);
    @memcpy(err_buf[0..len], msg[0..len]);
    return err_buf[0..len];
}

/// Run the Lua action `name` for the surface with the runtime ID `surface`.
/// Returns false if there is no such action, or if a bound function
/// returned `false` to let the key go to the terminal. Errors in the action
/// show as a toast and the action counts as performed.
pub fn run(self: *Runtime, name: []const u8, surface: u64) bool {
    const action = self.actions.getEntry(name) orelse {
        log.warn("no Lua action named {s}", .{name});
        return false;
    };

    if (self.depth >= max_depth) {
        self.showError(surface, "Lua actions are nested too deep");
        return true;
    }

    _ = c.lua_rawgeti(self.lua, c.LUA_REGISTRYINDEX, action.value_ptr.ref);
    return self.startTask(action.key_ptr.*, surface);
}

/// Give the result of a host operation to the task or timer `id`. The
/// host calls this when an operation from `exec`, `pick` or `timer` ends.
/// Strings in `result` must stay valid only during the call.
pub fn complete(self: *Runtime, id: u32, result: Result) void {
    if (self.timers.contains(id)) return self.fireTimer(id);

    const task = self.tasks.getPtr(id) orelse return;
    task.wait = null;
    const co = task.thread;
    const nargs: c_int = switch (result) {
        .exec => |r| nargs: {
            c.lua_createtable(co, 0, 4);
            if (r.status) |v| {
                c.lua_pushinteger(co, v);
                c.lua_setfield(co, -2, "status");
            }
            if (r.signal) |v| {
                c.lua_pushinteger(co, v);
                c.lua_setfield(co, -2, "signal");
            }
            _ = c.lua_pushlstring(co, r.stdout.ptr, r.stdout.len);
            c.lua_setfield(co, -2, "stdout");
            _ = c.lua_pushlstring(co, r.stderr.ptr, r.stderr.len);
            c.lua_setfield(co, -2, "stderr");
            break :nargs 1;
        },
        .pick => |id_| nargs: {
            if (id_) |v| _ = c.lua_pushlstring(co, v.ptr, v.len) else c.lua_pushnil(co);
            break :nargs 1;
        },
        .timer => nargs: {
            c.lua_pushboolean(co, 1);
            break :nargs 1;
        },
        .failed => |msg| pushError(co, msg),
    };
    _ = self.resumeTask(id, nargs);
}

/// Start a task that runs the function on the top of the main Lua stack
/// with `ctx` and `args`. Pops the function. Returns false only if the
/// function returned `false` without waiting.
fn startTask(self: *Runtime, name: []const u8, surface: u64) bool {
    const L = self.lua;

    // Each task runs in its own coroutine, so it can wait. The registry
    // keeps the coroutine alive while the task waits.
    const co = c.lua_newthread(L).?;
    c.lua_rotate(L, -2, 1);
    c.lua_xmove(L, co, 1);
    const ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

    const id = self.nextId();
    self.tasks.put(self.alloc, id, .{
        .thread = co,
        .ref = ref,
        .name = name,
        .surface = surface,
    }) catch {
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
        self.showError(surface, "Lua: out of memory");
        return true;
    };

    // ctx
    c.lua_createtable(co, 0, 1);
    c.lua_pushinteger(co, @bitCast(surface));
    c.lua_setfield(co, -2, "surface");

    // args. Keybinds and the command palette give no arguments.
    c.lua_createtable(co, 0, 0);

    return self.resumeTask(id, 2);
}

/// Resume the task `id` with `nargs` values on its stack. Returns false
/// only if the task ended and returned `false`.
fn resumeTask(self: *Runtime, id: u32, nargs: c_int) bool {
    const task = self.tasks.get(id).?;
    const co = task.thread;

    const outer_task = self.task;
    const outer_surface = self.surface;
    self.task = id;
    self.surface = task.surface;
    self.depth += 1;
    defer {
        self.depth -= 1;
        self.task = outer_task;
        self.surface = outer_surface;
    }

    // Only the outermost resume sets the time limit. Nested actions are
    // part of the time of the outer action. Each resume after a wait
    // gets a new limit.
    if (self.depth == 1) self.deadline_ns = now() + action_budget_ns;
    c.lua_sethook(co, budgetHook, c.LUA_MASKCOUNT, 10_000);

    var nres: c_int = 0;
    switch (c.lua_resume(co, self.lua, nargs, &nres)) {
        c.LUA_YIELD => {
            c.lua_settop(co, 0);

            // Only the functions that wait for the host can yield the task.
            // Any other yield would leave it waiting for nothing.
            if (self.tasks.get(id).?.wait != null) return true;
            self.showErrorFmt(task, "the action yielded outside of a ghostty function", .{});
        },

        c.LUA_OK => {
            const performed = !(nres > 0 and
                c.lua_type(co, -nres) == c.LUA_TBOOLEAN and
                c.lua_toboolean(co, -nres) == 0);
            self.finishTask(id);
            return performed;
        },

        else => self.showErrorFmt(task, "{s}", .{popError(co)}),
    }

    self.finishTask(id);
    return true;
}

fn finishTask(self: *Runtime, id: u32) void {
    const task = self.tasks.fetchRemove(id) orelse return;
    c.luaL_unref(self.lua, c.LUA_REGISTRYINDEX, task.value.ref);
}

fn showErrorFmt(self: *Runtime, task: Task, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(
        &buf,
        "Lua action {s}: " ++ fmt,
        .{task.name} ++ args,
        0,
    ) catch "Lua action failed";
    self.showError(task.surface, msg);
}

/// Run timer `id`. A repeating timer is armed again first, so its function
/// can cancel it.
fn fireTimer(self: *Runtime, id: u32) void {
    const timer = self.timers.getPtr(id).?;
    timer.wait = null;
    const ref = timer.ref;
    const surface = timer.surface;

    _ = c.lua_rawgeti(self.lua, c.LUA_REGISTRYINDEX, ref);
    if (timer.repeat) {
        timer.wait = self.host.timer(self.host.ptr, .{ .runtime = self, .id = id }, timer.interval_ms) catch null;
        if (timer.wait == null) self.removeTimer(id);
    } else self.removeTimer(id);

    _ = self.startTask("timer", surface);
}

fn removeTimer(self: *Runtime, id: u32) void {
    const timer = self.timers.fetchRemove(id) orelse return;
    if (timer.value.wait) |wait| wait.cancel(wait.ptr);
    c.luaL_unref(self.lua, c.LUA_REGISTRYINDEX, timer.value.ref);
}

fn nextId(self: *Runtime) u32 {
    self.next_id +%= 1;
    if (self.next_id == 0) self.next_id = 1;
    return self.next_id;
}

fn now() i96 {
    return std.Io.Timestamp.now(global.io(), .awake).toNanoseconds();
}

/// Build the config entries for the actions and binds that `init.lua`
/// defined, in the CLI form that `Config.loadWithExtra` takes. The result
/// and its strings are allocated with `alloc`.
pub fn configEntries(self: *const Runtime, alloc: Allocator) Allocator.Error![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (entries.items) |entry| alloc.free(entry);
        entries.deinit(alloc);
    }

    var it = self.actions.iterator();
    while (it.next()) |entry| {
        const title = entry.value_ptr.title orelse continue;
        try entries.append(alloc, try std.fmt.allocPrint(
            alloc,
            "--command-palette-entry=title:\"{f}\",description:\"{f}\",action:\"lua:{f}\"",
            .{
                std.zig.fmtString(title),
                std.zig.fmtString(entry.value_ptr.description orelse ""),
                std.zig.fmtString(entry.key_ptr.*),
            },
        ));
    }

    for (self.binds.items) |bind| {
        try entries.append(alloc, try std.fmt.allocPrint(
            alloc,
            "--keybind={s}{s}{s}{s}=lua:{s}",
            .{
                bind.table orelse "",
                if (bind.table != null) "/" else "",
                if (bind.performable) "performable:" else "",
                bind.trigger,
                bind.action,
            },
        ));
    }

    return try entries.toOwnedSlice(alloc);
}

fn installApi(self: *Runtime) void {
    const L = self.lua;

    c.lua_createtable(L, 0, 15);
    const functions = .{
        .{ "action", luaAction },
        .{ "bind", luaBind },
        .{ "invoke", luaInvoke },
        .{ "toast", luaToast },
        .{ "log", luaLog },
        .{ "split", luaSplit },
        .{ "tab", luaTab },
        .{ "window", luaWindow },
        .{ "exec", luaExec },
        .{ "pick", luaPick },
        .{ "sleep", luaSleep },
        .{ "after", luaAfter },
        .{ "every", luaEvery },
        .{ "cancel", luaCancel },
    };
    inline for (functions) |entry| {
        c.lua_pushcclosure(L, entry[1], 0);
        c.lua_setfield(L, -2, entry[0]);
    }

    // ghostty.surface
    c.lua_createtable(L, 0, 1);
    c.lua_pushcclosure(L, luaSurfaceInfo, 0);
    c.lua_setfield(L, -2, "info");
    c.lua_setfield(L, -2, "surface");

    c.lua_createtable(L, 0, 1);
    c.lua_pushcclosure(L, luaSessionRelaunch, 0);
    c.lua_setfield(L, -2, "relaunch");
    c.lua_setfield(L, -2, "session");

    c.lua_setglobal(L, "ghostty");

    // These functions block the GTK main thread or stop the app.
    const disabled = .{
        .{ "io", "popen" },
        .{ "os", "execute" },
        .{ "os", "exit" },
    };
    inline for (disabled) |entry| {
        _ = c.lua_getglobal(L, entry[0]);
        _ = c.lua_pushstring(L, entry[0] ++ "." ++ entry[1] ++ " is disabled in Ghostty");
        c.lua_pushcclosure(L, luaDisabled, 1);
        c.lua_setfield(L, -2, entry[1]);
        c.lua_settop(L, -2);
    }
}

fn budgetHook(L: ?*c.lua_State, _: [*c]c.lua_Debug) callconv(.c) void {
    const self = fromState(L);
    if (now() > self.deadline_ns) _ = c.luaL_error(L, "Lua code ran for too long");
}

fn showError(self: *Runtime, surface: u64, msg: [:0]const u8) void {
    log.warn("{s}", .{msg});
    self.host.toast(self.host.ptr, surface, msg);
}

/// ghostty.action{ name, title?, description?, keywords?, run }
fn luaAction(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    if (!self.loading) return c.luaL_error(L, "ghostty.action works only while init.lua loads");
    c.luaL_checktype(L, 1, c.LUA_TTABLE);

    const name = fieldString(L, 1, "name") orelse
        return c.luaL_error(L, "ghostty.action: name must be a string");
    if (!validName(name)) return c.luaL_error(
        L,
        "ghostty.action: name may contain only letters, digits, '_', '-' and '.'",
    );
    if (std.mem.startsWith(u8, name, bind_prefix)) return c.luaL_error(
        L,
        "ghostty.action: names that start with " ++ bind_prefix ++ " are reserved",
    );
    if (self.actions.contains(name)) return c.luaL_error(L, "ghostty.action: %s is already defined", name.ptr);
    const title = fieldString(L, 1, "title");
    const description = fieldString(L, 1, "description");
    if (c.lua_getfield(L, 1, "run") != c.LUA_TFUNCTION)
        return c.luaL_error(L, "ghostty.action: run must be a function");

    // No Lua errors can happen after this point, except out of memory.
    self.addAction(name, title, description) catch return c.luaL_error(L, "out of memory");
    return 0;
}

pub fn relaunchAllowed(self: *const Runtime, program: []const u8) bool {
    for (self.relaunch_programs.items) |name| if (std.mem.eql(u8, name, program)) return true;
    return false;
}

pub fn relaunchArguments(self: *const Runtime, program: []const u8) ?[]const []const u8 {
    return self.relaunch_commands.get(program);
}

fn relaunchListContains(L: ?*c.lua_State, name: []const u8) bool {
    for (0..c.lua_rawlen(L, 2)) |i| {
        _ = c.lua_rawgeti(L, 2, @intCast(i + 1));
        const matches = std.mem.eql(u8, name, toString(L, -1));
        c.lua_settop(L, -2);
        if (matches) return true;
    }
    return false;
}

/// ghostty.session.relaunch{ programs = { "hx", "lazygit" } }
fn luaSessionRelaunch(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    if (!self.loading) return c.luaL_error(L, "ghostty.session.relaunch works only while init.lua loads");
    c.luaL_checktype(L, 1, c.LUA_TTABLE);
    c.lua_settop(L, 1);
    if (c.lua_getfield(L, 1, "programs") != c.LUA_TTABLE)
        return c.luaL_error(L, "ghostty.session.relaunch: programs must be a list");
    const len = c.lua_rawlen(L, 2);
    if (len + self.relaunch_programs.items.len > 64)
        return c.luaL_error(L, "ghostty.session.relaunch: at most 64 programs");
    for (0..len) |i| {
        if (c.lua_rawgeti(L, 2, @intCast(i + 1)) != c.LUA_TSTRING or
            !session_relaunch.validProgram(toString(L, -1)))
            return c.luaL_error(L, "ghostty.session.relaunch: expected executable names, without paths");
        c.lua_settop(L, -2);
    }
    const commands_kind = c.lua_getfield(L, 1, "commands");
    if (commands_kind != c.LUA_TNIL and commands_kind != c.LUA_TTABLE)
        return c.luaL_error(L, "ghostty.session.relaunch: commands must be a table");
    if (commands_kind == c.LUA_TTABLE) {
        c.lua_pushnil(L);
        while (c.lua_next(L, 3) != 0) {
            if (c.lua_type(L, -2) != c.LUA_TSTRING or c.lua_type(L, -1) != c.LUA_TTABLE)
                return c.luaL_error(L, "ghostty.session.relaunch: commands must map program names to argument lists");
            const name = toString(L, -2);
            if (!self.relaunchAllowed(name) and !relaunchListContains(L, name))
                return c.luaL_error(L, "ghostty.session.relaunch: command program must also be registered");
            const argv_index = c.lua_absindex(L, -1);
            const count = c.lua_rawlen(L, argv_index);
            if (count == 0 or count > session_relaunch.max_args)
                return c.luaL_error(L, "ghostty.session.relaunch: command must have 1 to 256 arguments");
            var bytes: usize = 0;
            for (0..count) |i| {
                if (c.lua_rawgeti(L, argv_index, @intCast(i + 1)) != c.LUA_TSTRING)
                    return c.luaL_error(L, "ghostty.session.relaunch: command arguments must be strings");
                const arg = toString(L, -1);
                if (!session_relaunch.validText(arg) or (i == 0 and !std.mem.eql(u8, arg, name)))
                    return c.luaL_error(L, "ghostty.session.relaunch: command must start with its program name and contain no control characters");
                if (arg.len > session_relaunch.max_bytes - bytes)
                    return c.luaL_error(L, "ghostty.session.relaunch: command exceeds 32 KiB");
                bytes += arg.len;
                c.lua_settop(L, -2);
            }
            c.lua_settop(L, -2);
        }
    }
    // Validate the whole registration before allocating or changing policy.
    for (0..len) |i| {
        _ = c.lua_rawgeti(L, 2, @intCast(i + 1));
        const name = toString(L, -1);
        if (!self.relaunchAllowed(name)) {
            const copy = self.arena.allocator().dupe(u8, name) catch return c.luaL_error(L, "out of memory");
            self.relaunch_programs.append(self.alloc, copy) catch return c.luaL_error(L, "out of memory");
        }
        c.lua_settop(L, -2);
    }
    if (commands_kind == c.LUA_TTABLE) {
        c.lua_pushnil(L);
        while (c.lua_next(L, 3) != 0) {
            const name = self.arena.allocator().dupe(u8, toString(L, -2)) catch return c.luaL_error(L, "out of memory");
            const argv_index = c.lua_absindex(L, -1);
            const argv = self.arena.allocator().alloc([]const u8, c.lua_rawlen(L, argv_index)) catch return c.luaL_error(L, "out of memory");
            for (argv, 1..) |*arg, i| {
                _ = c.lua_rawgeti(L, argv_index, @intCast(i));
                arg.* = self.arena.allocator().dupe(u8, toString(L, -1)) catch return c.luaL_error(L, "out of memory");
                c.lua_settop(L, -2);
            }
            self.relaunch_commands.put(self.alloc, name, argv) catch return c.luaL_error(L, "out of memory");
            c.lua_settop(L, -2);
        }
    }
    return 0;
}

/// ghostty.bind(key, name | fn [, { table = name }])
fn luaBind(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    if (!self.loading) return c.luaL_error(L, "ghostty.bind works only while init.lua loads");

    const trigger = checkString(L, 1);
    if (trigger.len == 0 or std.mem.indexOfScalar(u8, trigger, '=') != null)
        return c.luaL_argerror(L, 1, "must be a key trigger such as \"super+r\"");

    const table: ?[]const u8 = table: {
        if (c.lua_type(L, 3) <= c.LUA_TNIL) break :table null;
        c.luaL_checktype(L, 3, c.LUA_TTABLE);
        const table = fieldString(L, 3, "table") orelse break :table null;
        if (table.len == 0 or !validName(table)) return c.luaL_argerror(L, 3, "table must be a key table name");
        break :table table;
    };

    switch (c.lua_type(L, 2)) {
        c.LUA_TSTRING => {
            const name = checkString(L, 2);
            if (!validName(name)) return c.luaL_argerror(L, 2, "must be an action name");
            self.addBind(table, trigger, name, false) catch return c.luaL_error(L, "out of memory");
        },

        c.LUA_TFUNCTION => {
            var buf: [32]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&buf, bind_prefix ++ "{d}", .{
                self.binds.items.len,
            }, 0) catch unreachable;
            // Copy the function to the top. The options table must stay on
            // the stack, because `table` points into one of its strings.
            c.lua_pushvalue(L, 2);
            self.addAction(name, null, null) catch return c.luaL_error(L, "out of memory");
            self.addBind(table, trigger, self.actions.keys()[self.actions.count() - 1], true) catch
                return c.luaL_error(L, "out of memory");
        },

        else => return c.luaL_argerror(L, 2, "must be an action name or a function"),
    }

    return 0;
}

/// ghostty.invoke(action) -> performed | nil, err
fn luaInvoke(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    const text = checkString(L, 1);
    if (self.depth == 0) {
        c.lua_pushnil(L);
        _ = c.lua_pushstring(L, "ghostty.invoke works only inside an action");
        return 2;
    }

    const action = input.Binding.Action.parse(text) catch {
        c.lua_pushnil(L);
        _ = c.lua_pushfstring(L, "not a valid action: %s", text.ptr);
        return 2;
    };

    c.lua_pushboolean(L, @intFromBool(self.host.invoke(self.host.ptr, self.surface, action)));
    return 1;
}

/// ghostty.toast(text)
fn luaToast(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    const text = checkString(L, 1);
    if (self.depth == 0) {
        c.lua_pushnil(L);
        _ = c.lua_pushstring(L, "ghostty.toast works only inside an action");
        return 2;
    }

    self.host.toast(self.host.ptr, self.surface, text);
    c.lua_pushboolean(L, 1);
    return 1;
}

/// ghostty.log(text)
fn luaLog(L: ?*c.lua_State) callconv(.c) c_int {
    log.info("{s}", .{checkString(L, 1)});
    return 0;
}

/// ghostty.surface.info([id]) -> { id, title, pwd, foreground } | nil, err
fn luaSurfaceInfo(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    const id: u64 = if (c.lua_type(L, 1) <= c.LUA_TNIL)
        self.surface
    else
        @bitCast(c.luaL_checkinteger(L, 1));
    if (self.depth == 0) return pushError(L, "ghostty.surface.info works only inside an action");

    _ = self.scratch.reset(.retain_capacity);
    const info = (self.host.info(self.host.ptr, self.scratch.allocator(), id) catch
        return pushError(L, "out of memory")) orelse
        return pushError(L, "no surface with that ID");

    c.lua_createtable(L, 0, 4);
    c.lua_pushinteger(L, @bitCast(id));
    c.lua_setfield(L, -2, "id");
    setStringField(L, "title", info.title);
    setStringField(L, "pwd", info.pwd);
    if (info.foreground) |fg| {
        c.lua_createtable(L, 0, 3);
        c.lua_pushinteger(L, @bitCast(fg.pid));
        c.lua_setfield(L, -2, "pid");
        setStringField(L, "cwd", fg.cwd);
        setStringField(L, "name", fg.name);
        c.lua_setfield(L, -2, "foreground");
    }
    return 1;
}

/// ghostty.split{ surface?, direction?, command?, cwd?, title? } -> true | nil, err
fn luaSplit(L: ?*c.lua_State) callconv(.c) c_int {
    return open(L, .split);
}

/// ghostty.tab{ surface?, command?, cwd?, title? } -> true | nil, err
fn luaTab(L: ?*c.lua_State) callconv(.c) c_int {
    return open(L, .tab);
}

/// ghostty.window{ surface?, command?, cwd?, title? } -> true | nil, err
fn luaWindow(L: ?*c.lua_State) callconv(.c) c_int {
    return open(L, .window);
}

fn open(L: ?*c.lua_State, comptime kind: std.meta.Tag(OpenTarget)) c_int {
    const self = fromState(L);
    if (c.lua_type(L, 1) > c.LUA_TNIL) c.luaL_checktype(L, 1, c.LUA_TTABLE);
    if (self.depth == 0) return pushError(L, "ghostty." ++ @tagName(kind) ++ " works only inside an action");

    // Without a table, use an empty one, so the fields below are all nil.
    c.lua_settop(L, 1);
    if (c.lua_type(L, 1) <= c.LUA_TNIL) {
        c.lua_settop(L, 0);
        c.lua_createtable(L, 0, 0);
    }

    // A window has no surface by default. It does not inherit anything.
    const surface: u64 = surface: {
        defer c.lua_settop(L, 1);
        switch (c.lua_getfield(L, 1, "surface")) {
            c.LUA_TNIL => break :surface if (kind == .window) 0 else self.surface,
            c.LUA_TNUMBER => if (c.lua_isinteger(L, -1) != 0)
                break :surface @bitCast(c.lua_tointegerx(L, -1, null)),
            else => {},
        }
        return pushError(L, "surface must be a surface ID");
    };

    const target: OpenTarget = switch (kind) {
        .split => split: {
            const direction = fieldString(L, 1, "direction") orelse "right";
            break :split .{ .split = std.meta.stringToEnum(OpenTarget.Direction, direction) orelse
                return pushError(L, "direction must be left, right, up or down") };
        },
        .tab => .tab,
        .window => .window,
    };

    _ = self.scratch.reset(.retain_capacity);
    const options = openOptions(L, self.scratch.allocator()) catch |err| return pushError(L, switch (err) {
        error.OutOfMemory => "out of memory",
        error.InvalidCommand => "command must be a string or a non-empty list of strings",
        error.InvalidCwd => "cwd must be a string",
        error.InvalidTitle => "title must be a string",
        error.InvalidWait => "wait must be a boolean",
    });

    self.host.open(self.host.ptr, surface, target, options) catch |err| return pushError(L, switch (err) {
        error.OutOfMemory => "out of memory",
        error.NoSurface => "no surface with that ID",
        error.OpenFailed => "unable to open the " ++ @tagName(kind),
    });

    c.lua_pushboolean(L, 1);
    return 1;
}

/// Read the `command`, `cwd`, `title` and `wait` fields of the table at
/// index 1.
fn openOptions(
    L: ?*c.lua_State,
    alloc: Allocator,
) (Allocator.Error || error{ InvalidCommand, InvalidCwd, InvalidTitle, InvalidWait })!OpenOptions {
    var options: OpenOptions = .{};

    options.command = command: {
        defer c.lua_settop(L, 1);
        switch (c.lua_getfield(L, 1, "command")) {
            c.LUA_TNIL => break :command null,
            c.LUA_TSTRING => break :command .{ .shell = try alloc.dupeSentinel(u8, toString(L, -1), 0) },
            c.LUA_TTABLE => {
                const len = c.lua_rawlen(L, -1);
                if (len == 0) return error.InvalidCommand;
                const argv = try alloc.alloc([:0]const u8, @intCast(len));
                for (argv, 1..) |*arg, i| {
                    if (c.lua_rawgeti(L, -1, @intCast(i)) != c.LUA_TSTRING) return error.InvalidCommand;
                    arg.* = try alloc.dupeSentinel(u8, toString(L, -1), 0);
                    c.lua_settop(L, -2);
                }
                break :command .{ .direct = argv };
            },
            else => return error.InvalidCommand,
        }
    };

    inline for (.{
        .{ "cwd", error.InvalidCwd },
        .{ "title", error.InvalidTitle },
    }) |entry| {
        defer c.lua_settop(L, 1);
        switch (c.lua_getfield(L, 1, entry[0])) {
            c.LUA_TNIL => {},
            c.LUA_TSTRING => @field(options, entry[0]) = try alloc.dupeSentinel(u8, toString(L, -1), 0),
            else => return entry[1],
        }
    }

    options.wait = wait: {
        defer c.lua_settop(L, 1);
        break :wait switch (c.lua_getfield(L, 1, "wait")) {
            c.LUA_TNIL => null,
            c.LUA_TBOOLEAN => c.lua_toboolean(L, -1) != 0,
            else => return error.InvalidWait,
        };
    };

    return options;
}

/// The task that runs in `L`, if `L` can wait for the host. A task can
/// wait only in its own coroutine, not in a coroutine that the action made.
fn waitingTask(self: *Runtime, L: ?*c.lua_State) ?*Task {
    if (self.task == 0 or c.lua_isyieldable(L) == 0) return null;
    const task = self.tasks.getPtr(self.task) orelse return null;
    return if (task.thread == L.?) task else null;
}

/// Wait for `wait` in `task`. Returns the result of `lua_yield`.
fn yieldTask(L: ?*c.lua_State, task: *Task, wait: Wait) c_int {
    task.wait = wait;
    return c.lua_yieldk(L, 0, 0, null);
}

/// A time in seconds as milliseconds, from 1 ms to one day.
fn checkSeconds(L: ?*c.lua_State, idx: c_int) u32 {
    const seconds = c.luaL_checknumber(L, idx);
    if (!(seconds >= 0 and seconds <= 24 * 60 * 60))
        _ = c.luaL_argerror(L, idx, "must be from 0 to 86400 seconds");
    return @max(1, @as(u32, @intFromFloat(seconds * 1000)));
}

/// ghostty.exec(argv, { cwd?, timeout?, stdin? }) -> { status, signal, stdout, stderr } | nil, err
fn luaExec(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    c.luaL_checktype(L, 1, c.LUA_TTABLE);
    const has_options = c.lua_type(L, 2) > c.LUA_TNIL;
    if (has_options) c.luaL_checktype(L, 2, c.LUA_TTABLE);
    c.lua_settop(L, 2);
    const task = self.waitingTask(L) orelse
        return pushError(L, "ghostty.exec works only inside an action, outside of other coroutines");

    _ = self.scratch.reset(.retain_capacity);
    const alloc = self.scratch.allocator();

    const argv = argv: {
        const len: usize = @intCast(c.lua_rawlen(L, 1));
        if (len == 0) return pushError(L, "argv must be a non-empty list of strings");
        const argv = alloc.alloc([:0]const u8, len) catch return pushError(L, "out of memory");
        for (argv, 1..) |*arg, i| {
            defer c.lua_settop(L, 2);
            if (c.lua_rawgeti(L, 1, @intCast(i)) != c.LUA_TSTRING)
                return pushError(L, "argv must be a non-empty list of strings");
            arg.* = alloc.dupeSentinel(u8, toString(L, -1), 0) catch return pushError(L, "out of memory");
        }
        break :argv argv;
    };

    var options: ExecOptions = .{};
    if (has_options) {
        if (fieldString(L, 2, "cwd")) |cwd|
            options.cwd = alloc.dupeSentinel(u8, cwd, 0) catch return pushError(L, "out of memory");
        if (fieldString(L, 2, "stdin")) |stdin|
            options.stdin = alloc.dupe(u8, stdin) catch return pushError(L, "out of memory");
        timeout: {
            defer c.lua_settop(L, 2);
            if (c.lua_getfield(L, 2, "timeout") != c.LUA_TNUMBER) break :timeout;
            const seconds = c.lua_tonumberx(L, -1, null);
            if (!(seconds > 0 and seconds <= 24 * 60 * 60))
                return pushError(L, "timeout must be from 0 to 86400 seconds");
            options.timeout_ms = @max(1, @as(u32, @intFromFloat(seconds * 1000)));
        }
    }

    var err_buf: ErrorBuffer = .{};
    const wait = self.host.exec(self.host.ptr, .{ .runtime = self, .id = self.task }, argv, options, &err_buf) catch
        return pushError(L, err_buf.message("unable to start the command"));
    return yieldTask(L, task, wait);
}

/// ghostty.pick{ surface?, title?, placeholder?, placement?, choices } -> id | nil [, err]
fn luaPick(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    c.luaL_checktype(L, 1, c.LUA_TTABLE);
    c.lua_settop(L, 1);
    const task = self.waitingTask(L) orelse
        return pushError(L, "ghostty.pick works only inside an action, outside of other coroutines");

    _ = self.scratch.reset(.retain_capacity);
    const alloc = self.scratch.allocator();

    const surface: u64 = surface: {
        defer c.lua_settop(L, 1);
        switch (c.lua_getfield(L, 1, "surface")) {
            c.LUA_TNIL => break :surface self.surface,
            c.LUA_TNUMBER => if (c.lua_isinteger(L, -1) != 0)
                break :surface @bitCast(c.lua_tointegerx(L, -1, null)),
            else => {},
        }
        return pushError(L, "surface must be a surface ID");
    };

    var request: PickRequest = .{ .choices = &.{} };
    if (fieldString(L, 1, "title")) |v| request.title = alloc.dupe(u8, v) catch return pushError(L, "out of memory");
    if (fieldString(L, 1, "placeholder")) |v| request.placeholder = alloc.dupe(u8, v) catch return pushError(L, "out of memory");
    if (fieldString(L, 1, "placement")) |v| {
        if (std.mem.eql(u8, v, "cursor")) request.cursor = true else if (!std.mem.eql(u8, v, "center"))
            return pushError(L, "placement must be center or cursor");
    }

    request.choices = choices: {
        defer c.lua_settop(L, 1);
        if (c.lua_getfield(L, 1, "choices") != c.LUA_TTABLE) return pushError(L, "choices must be a list");
        const len: usize = @intCast(c.lua_rawlen(L, 2));
        if (len == 0) return pushError(L, "choices must not be empty");
        const choices = alloc.alloc(PickRequest.Choice, len) catch return pushError(L, "out of memory");
        for (choices, 1..) |*choice, i| {
            defer c.lua_settop(L, 2);
            switch (c.lua_rawgeti(L, 2, @intCast(i))) {
                // A string is both the ID and the label.
                c.LUA_TSTRING => {
                    const text = alloc.dupe(u8, toString(L, -1)) catch return pushError(L, "out of memory");
                    choice.* = .{ .id = text, .label = text };
                },
                c.LUA_TTABLE => {
                    const label = fieldString(L, 3, "label") orelse
                        return pushError(L, "each choice needs a label");
                    choice.* = .{
                        .label = alloc.dupe(u8, label) catch return pushError(L, "out of memory"),
                        .id = alloc.dupe(u8, fieldString(L, 3, "id") orelse label) catch
                            return pushError(L, "out of memory"),
                        .description = alloc.dupe(u8, fieldString(L, 3, "description") orelse "") catch
                            return pushError(L, "out of memory"),
                    };
                },
                else => return pushError(L, "each choice must be a string or a table"),
            }
        }
        break :choices choices;
    };

    var err_buf: ErrorBuffer = .{};
    const wait = self.host.pick(self.host.ptr, .{ .runtime = self, .id = self.task }, surface, request, &err_buf) catch
        return pushError(L, err_buf.message("unable to open the picker"));
    return yieldTask(L, task, wait);
}

/// ghostty.sleep(seconds) -> true | nil, err
fn luaSleep(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    const ms = checkSeconds(L, 1);
    const task = self.waitingTask(L) orelse
        return pushError(L, "ghostty.sleep works only inside an action, outside of other coroutines");
    const wait = self.host.timer(self.host.ptr, .{ .runtime = self, .id = self.task }, ms) catch
        return pushError(L, "out of memory");
    return yieldTask(L, task, wait);
}

/// ghostty.after(seconds, fn) -> id
fn luaAfter(L: ?*c.lua_State) callconv(.c) c_int {
    return addTimer(L, false);
}

/// ghostty.every(seconds, fn) -> id
fn luaEvery(L: ?*c.lua_State) callconv(.c) c_int {
    return addTimer(L, true);
}

fn addTimer(L: ?*c.lua_State, repeat: bool) c_int {
    const self = fromState(L);
    const ms = checkSeconds(L, 1);
    if (repeat and ms < 10) return c.luaL_argerror(L, 1, "must be at least 0.01 seconds");
    c.luaL_checktype(L, 2, c.LUA_TFUNCTION);
    c.lua_settop(L, 2);

    const id = self.nextId();
    self.timers.ensureUnusedCapacity(self.alloc, 1) catch return pushError(L, "out of memory");
    const wait = self.host.timer(self.host.ptr, .{ .runtime = self, .id = id }, ms) catch
        return pushError(L, "out of memory");

    // No Lua errors can happen after this point, except out of memory.
    self.timers.putAssumeCapacity(id, .{
        .ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX),
        .interval_ms = ms,
        .repeat = repeat,
        .surface = self.surface,
        .wait = wait,
    });
    c.lua_pushinteger(L, id);
    return 1;
}

/// ghostty.cancel(id) -> true if a timer was cancelled
fn luaCancel(L: ?*c.lua_State) callconv(.c) c_int {
    const self = fromState(L);
    const id = std.math.cast(u32, c.luaL_checkinteger(L, 1)) orelse 0;
    const found = self.timers.contains(id);
    if (found) self.removeTimer(id);
    c.lua_pushboolean(L, @intFromBool(found));
    return 1;
}

/// Push `nil, msg`, the result of a failed call.
fn pushError(L: ?*c.lua_State, msg: []const u8) c_int {
    c.lua_pushnil(L);
    _ = c.lua_pushlstring(L, msg.ptr, msg.len);
    return 2;
}

/// Set the field `key` of the table on the top of the stack, if `value` is
/// not null.
fn setStringField(L: ?*c.lua_State, key: [:0]const u8, value: ?[]const u8) void {
    const v = value orelse return;
    _ = c.lua_pushlstring(L, v.ptr, v.len);
    c.lua_setfield(L, -2, key.ptr);
}

/// The string on the top of the stack. The caller checked its type.
fn toString(L: ?*c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len);
    return ptr[0..len];
}

fn luaDisabled(L: ?*c.lua_State) callconv(.c) c_int {
    return c.luaL_error(L, "%s", c.lua_tolstring(L, c.lua_upvalueindex(1), null));
}

/// Add an action whose function is on the top of the Lua stack. Pops the
/// function.
fn addAction(
    self: *Runtime,
    name: []const u8,
    title: ?[:0]const u8,
    description: ?[:0]const u8,
) Allocator.Error!void {
    const arena = self.arena.allocator();
    const name_copy = try arena.dupe(u8, name);
    const title_copy = if (title) |v| try arena.dupeSentinel(u8, v, 0) else null;
    const description_copy = if (description) |v| try arena.dupeSentinel(u8, v, 0) else null;
    try self.actions.ensureUnusedCapacity(self.alloc, 1);
    self.actions.putAssumeCapacity(name_copy, .{
        .ref = c.luaL_ref(self.lua, c.LUA_REGISTRYINDEX),
        .title = title_copy,
        .description = description_copy,
    });
}

fn addBind(
    self: *Runtime,
    table: ?[]const u8,
    trigger: []const u8,
    action: []const u8,
    performable: bool,
) Allocator.Error!void {
    const arena = self.arena.allocator();
    try self.binds.append(self.alloc, .{
        .table = if (table) |v| try arena.dupe(u8, v) else null,
        .trigger = try arena.dupe(u8, trigger),
        .action = try arena.dupe(u8, action),
        .performable = performable,
    });
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

fn fromState(L: ?*c.lua_State) *Runtime {
    return extraSpace(L.?).*;
}

/// The LUA_EXTRASPACE bytes before the state. They hold one pointer.
fn extraSpace(L: *c.lua_State) **Runtime {
    return @ptrFromInt(@intFromPtr(L) - @sizeOf(*anyopaque));
}

/// The string argument at `idx`, or a Lua error.
fn checkString(L: ?*c.lua_State, idx: c_int) [:0]const u8 {
    var len: usize = 0;
    const ptr = c.luaL_checklstring(L, idx, &len);
    return ptr[0..len :0];
}

/// The string field `key` of the table at `idx`, or null if it is not a
/// string. The string stays valid while the table is on the stack.
fn fieldString(L: ?*c.lua_State, idx: c_int, key: [:0]const u8) ?[:0]const u8 {
    const kind = c.lua_getfield(L, idx, key.ptr);
    defer c.lua_settop(L, -2);
    if (kind != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len);
    return ptr[0..len :0];
}

/// Pop the error message on the top of the stack.
fn popError(L: ?*c.lua_State) [:0]const u8 {
    defer c.lua_settop(L, -2);
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return "unknown Lua error";
    return ptr[0..len :0];
}

const TestHost = struct {
    invoked: ?[]const u8 = null,
    toasts: usize = 0,

    /// The last `open` call, with copies of its strings.
    opened: ?struct {
        surface: u64,
        target: OpenTarget,
        argv: usize,
        first_arg: [32]u8,
        cwd: [32]u8,
        wait: ?bool,
    } = null,

    /// The text of the last toast.
    last_toast: [64]u8 = @splat(0),

    /// The callback of the last `exec`, `pick` or `timer` call.
    callback: ?Callback = null,
    exec_argc: usize = 0,
    pick_count: usize = 0,
    timer_ms: u32 = 0,
    cancels: usize = 0,

    fn host(self: *TestHost) Host {
        return .{
            .ptr = self,
            .invoke = invoke,
            .toast = toast,
            .info = info,
            .open = openSurface,
            .exec = exec,
            .pick = pick,
            .timer = timer,
        };
    }

    fn wait(self: *TestHost) Wait {
        return .{ .ptr = self, .cancel = cancel };
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        self.cancels += 1;
    }

    fn exec(
        ptr: *anyopaque,
        callback: Callback,
        argv: []const [:0]const u8,
        _: ExecOptions,
        err_buf: *ErrorBuffer,
    ) error{ExecFailed}!Wait {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, argv[0], "missing")) {
            err_buf.set("{s}: not found", .{argv[0]});
            return error.ExecFailed;
        }
        self.callback = callback;
        self.exec_argc = argv.len;
        return self.wait();
    }

    fn pick(
        ptr: *anyopaque,
        callback: Callback,
        _: u64,
        request: PickRequest,
        _: *ErrorBuffer,
    ) error{PickFailed}!Wait {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        self.callback = callback;
        self.pick_count = request.choices.len;
        return self.wait();
    }

    fn timer(ptr: *anyopaque, callback: Callback, ms: u32) Allocator.Error!Wait {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        self.callback = callback;
        self.timer_ms = ms;
        return self.wait();
    }

    fn lastToast(self: *const TestHost) []const u8 {
        return std.mem.sliceTo(&self.last_toast, 0);
    }

    fn info(_: *anyopaque, alloc: Allocator, surface: u64) Allocator.Error!?SurfaceInfo {
        if (surface != 7) return null;
        return .{
            .title = try alloc.dupe(u8, "shell"),
            .pwd = try alloc.dupe(u8, "/home/me"),
            .foreground = .{ .pid = 42, .cwd = try alloc.dupe(u8, "/home/me/project") },
        };
    }

    fn openSurface(ptr: *anyopaque, surface: u64, target: OpenTarget, options: OpenOptions) OpenError!void {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        if (surface != 0 and surface != 7) return error.NoSurface;
        self.opened = .{
            .surface = surface,
            .target = target,
            .argv = 0,
            .first_arg = @splat(0),
            .cwd = @splat(0),
            .wait = options.wait,
        };
        const opened = &self.opened.?;
        if (options.command) |command| switch (command) {
            .direct => |argv| {
                opened.argv = argv.len;
                @memcpy(opened.first_arg[0..argv[0].len], argv[0]);
            },
            .shell => |shell| @memcpy(opened.first_arg[0..shell.len], shell),
        };
        if (options.cwd) |cwd| @memcpy(opened.cwd[0..cwd.len], cwd);
    }

    fn invoke(ptr: *anyopaque, _: u64, action: input.Binding.Action) bool {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        self.invoked = @tagName(action);
        return true;
    }

    fn toast(ptr: *anyopaque, _: u64, text: [:0]const u8) void {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        self.toasts += 1;
        self.last_toast = @splat(0);
        const len = @min(text.len, self.last_toast.len - 1);
        @memcpy(self.last_toast[0..len], text[0..len]);
    }
};

fn testLoad(self: *Runtime, source: []const u8) !void {
    const L = self.lua;
    self.loading = true;
    defer self.loading = false;
    if (c.luaL_loadbufferx(L, source.ptr, source.len, "test", null) != c.LUA_OK or
        c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK)
    {
        log.warn("test load failed: {s}", .{popError(L)});
        return error.TestLoadFailed;
    }
}

test "actions and binds become config entries" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\ghostty.action{ name = "cargo", title = "Run \"Cargo\"", run = function() end }
        \\ghostty.action{ name = "hidden", run = function() end }
        \\ghostty.bind("super+r", "cargo")
        \\ghostty.bind("ctrl+x", function() return false end, { table = "vim" })
    );

    const entries = try rt.configEntries(testing.allocator);
    defer {
        for (entries) |entry| testing.allocator.free(entry);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings(
        "--command-palette-entry=title:\"Run \\\"Cargo\\\"\",description:\"\",action:\"lua:cargo\"",
        entries[0],
    );
    try testing.expectEqualStrings("--keybind=super+r=lua:cargo", entries[1]);
    try testing.expectEqualStrings("--keybind=vim/performable:ctrl+x=lua:__bind_1", entries[2]);

    // The config parser accepts all entries.
    const Config = @import("../../../config.zig").Config;
    var config: Config = try .default(testing.allocator);
    defer config.deinit();
    var it = @import("../../../cli.zig").args.sliceIterator(entries);
    try config.loadIter(testing.allocator, &it);
    try testing.expect(config._diagnostics.empty());
    try testing.expectEqualStrings(
        "Run \"Cargo\"",
        config.@"command-palette-entry".value.items[config.@"command-palette-entry".value.items.len - 1].title,
    );
}

test "session relaunch registration validates programs and is load-time only" {
    const t = std.testing;
    var host: TestHost = .{};
    const rt = try create(t.allocator, host.host());
    defer rt.destroy();
    try testLoad(rt,
        \\ghostty.session.relaunch{ programs = { "hx", "lazygit", "hx" } }
        \\assert(not pcall(ghostty.session.relaunch, { programs = { "btop", "bad/name" } }))
        \\assert(not pcall(ghostty.session.relaunch, { programs = { "hx\0oops" } }))
        \\ghostty.action{ name = "late", run = function()
        \\  assert(not pcall(ghostty.session.relaunch, { programs = { "btop" } }))
        \\end }
    );
    try t.expect(rt.relaunchAllowed("hx"));
    try t.expect(rt.relaunchAllowed("lazygit"));
    try t.expect(!rt.relaunchAllowed("btop"));
    try t.expect(rt.run("late", 1));
    try t.expect(!rt.relaunchAllowed("btop"));
    const replacement = try create(t.allocator, host.host());
    defer replacement.destroy();
    try t.expect(!replacement.relaunchAllowed("hx"));
}

test "session relaunch commands resume latest without retaining original prompts" {
    const t = std.testing;
    var host: TestHost = .{};
    const rt = try create(t.allocator, host.host());
    defer rt.destroy();
    try testLoad(rt,
        \\ghostty.session.relaunch{
        \\  programs = { "hx", "claude", "codex" },
        \\  commands = {
        \\    claude = { "claude", "--continue" },
        \\    codex = { "codex", "resume", "--last" },
        \\  },
        \\}
        \\assert(not pcall(ghostty.session.relaunch, { programs = { "btop" }, commands = { btop = { "hx" } } }))
        \\assert(not pcall(ghostty.session.relaunch, { programs = {}, commands = { unknown = { "unknown" } } }))
        \\assert(not pcall(ghostty.session.relaunch, { programs = {}, commands = { claude = {} } }))
        \\assert(not pcall(ghostty.session.relaunch, { programs = {}, commands = { claude = { "claude", "bad\narg" } } }))
        \\assert(not pcall(ghostty.session.relaunch, { programs = {}, commands = { claude = { "claude", 4 } } }))
        \\ghostty.session.relaunch({ programs = { "jjui" } }, "ignored extra argument")
    );
    try t.expect(!rt.relaunchAllowed("btop"));
    try t.expect(rt.relaunchAllowed("jjui"));
    try t.expect(rt.relaunchArguments("hx") == null);
    const captured: session_relaunch.Record = .{ .program = "codex", .argv = &.{ "codex", "original prompt" }, .cwd = "/tmp" };
    var launch = captured;
    launch.argv = rt.relaunchArguments(captured.program) orelse captured.argv;
    const cmd = try session_relaunch.command(t.allocator, .nushell, launch);
    defer t.allocator.free(cmd);
    try t.expectEqualStrings("^\"codex\" \"resume\" \"--last\"\r", cmd);
    try t.expectEqualStrings("original prompt", captured.argv[1]);
    try t.expectEqualStrings("--continue", rt.relaunchArguments("claude").?[1]);
    try testLoad(rt,
        \\ghostty.session.relaunch{ programs = {}, commands = { codex = { "codex", "resume", "selected-id" } } }
    );
    try t.expectEqualStrings("selected-id", rt.relaunchArguments("codex").?[2]);
    const fresh = try create(t.allocator, host.host());
    defer fresh.destroy();
    try t.expect(fresh.relaunchArguments("codex") == null);
}

test "run returns false when a bound function returns false" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\ghostty.bind("a", function(ctx) return ctx.surface == 7 end)
    );
    try testing.expect(rt.run("__bind_0", 7));
    try testing.expect(!rt.run("__bind_0", 8));
    try testing.expect(!rt.run("missing", 7));
}

test "invoke parses binding actions" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\ghostty.action{ name = "split", run = function()
        \\  assert(ghostty.invoke("new_split:right"))
        \\  local ok, err = ghostty.invoke("not_an_action")
        \\  assert(ok == nil and err)
        \\end }
    );
    try testing.expect(rt.run("split", 1));
    try testing.expectEqualStrings("new_split", host.invoked.?);
    try testing.expectEqual(@as(usize, 0), host.toasts);
}

test "errors and long loops become toasts" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\ghostty.action{ name = "fail", run = function() error("boom") end }
        \\ghostty.action{ name = "loop", run = function() while true do end end }
    );
    try testing.expect(rt.run("fail", 1));
    try testing.expect(rt.run("loop", 1));
    try testing.expectEqual(@as(usize, 2), host.toasts);
}

test "load-time functions fail at run time" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\ghostty.action{ name = "late", run = function()
        \\  ghostty.bind("b", "late")
        \\end }
    );
    try testing.expect(rt.run("late", 1));
    try testing.expectEqual(@as(usize, 1), host.toasts);
    try testing.expectEqual(@as(usize, 0), rt.binds.items.len);
}

test "blocking functions are disabled" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testing.expectError(error.TestLoadFailed, testLoad(rt, "os.execute('true')"));
    try testing.expectError(error.TestLoadFailed, testLoad(rt, "io.popen('true')"));
}

test "surface.info returns the host information" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\ghostty.action{ name = "info", run = function(ctx)
        \\  local info = assert(ghostty.surface.info())
        \\  assert(info.id == 7 and info.title == "shell" and info.pwd == "/home/me")
        \\  assert(info.foreground.pid == 42 and info.foreground.cwd == "/home/me/project")
        \\  assert(info.foreground.name == nil)
        \\  local none, err = ghostty.surface.info(8)
        \\  assert(none == nil and err)
        \\end }
    );
    try testing.expect(rt.run("info", 7));
    try testing.expectEqual(@as(usize, 0), host.toasts);
}

test "split, tab and window pass their options to the host" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\ghostty.action{ name = "split", run = function()
        \\  assert(ghostty.split{ direction = "down", command = { "cargo", "run" }, cwd = "/src", wait = true })
        \\end }
        \\ghostty.action{ name = "tab", run = function()
        \\  assert(ghostty.tab{ command = "htop" })
        \\end }
        \\ghostty.action{ name = "window", run = function()
        \\  assert(ghostty.window())
        \\end }
        \\ghostty.action{ name = "bad", run = function()
        \\  assert(ghostty.split{ direction = "sideways" } == nil)
        \\  assert(ghostty.split{ command = {} } == nil)
        \\  assert(ghostty.split{ command = { 1 } } == nil)
        \\  assert(ghostty.split{ surface = 8 } == nil)
        \\  assert(ghostty.tab{ cwd = 3 } == nil)
        \\  assert(ghostty.tab{ wait = "yes" } == nil)
        \\end }
    );

    try testing.expect(rt.run("split", 7));
    {
        const opened = host.opened.?;
        try testing.expectEqual(@as(u64, 7), opened.surface);
        try testing.expectEqual(OpenTarget{ .split = .down }, opened.target);
        try testing.expectEqual(@as(usize, 2), opened.argv);
        try testing.expectEqualStrings("cargo", std.mem.sliceTo(&opened.first_arg, 0));
        try testing.expectEqualStrings("/src", std.mem.sliceTo(&opened.cwd, 0));
        try testing.expectEqual(@as(?bool, true), opened.wait);
    }

    try testing.expect(rt.run("tab", 7));
    {
        const opened = host.opened.?;
        try testing.expectEqual(OpenTarget.tab, opened.target);
        try testing.expectEqualStrings("htop", std.mem.sliceTo(&opened.first_arg, 0));
    }

    try testing.expect(rt.run("window", 7));
    {
        const opened = host.opened.?;
        try testing.expectEqual(OpenTarget.window, opened.target);
        try testing.expectEqual(@as(u64, 0), opened.surface);
    }

    try testing.expect(rt.run("bad", 7));
    try testing.expectEqual(@as(usize, 0), host.toasts);
}

test "exec waits for the host and gives the result to the action" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\ghostty.action{ name = "run", run = function()
        \\  local r = assert(ghostty.exec({ "cargo", "metadata" }, { cwd = "/src", timeout = 5 }))
        \\  ghostty.toast(r.stdout .. ":" .. r.status)
        \\  local none, err = ghostty.exec({ "missing" })
        \\  ghostty.toast(err)
        \\end }
    );

    // The action waits, so the key counts as handled.
    try testing.expect(rt.run("run", 7));
    try testing.expectEqual(@as(usize, 2), host.exec_argc);
    try testing.expectEqual(@as(usize, 1), rt.tasks.count());

    rt.complete(host.callback.?.id, .{ .exec = .{
        .status = 0,
        .signal = null,
        .stdout = "out",
        .stderr = "",
    } });
    try testing.expectEqual(@as(usize, 2), host.toasts);
    try testing.expectEqualStrings("missing: not found", host.lastToast());
    try testing.expectEqual(@as(usize, 0), rt.tasks.count());
}

test "pick gives the chosen ID, or nil when cancelled" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\ghostty.action{ name = "pick", run = function()
        \\  local id = ghostty.pick{ choices = { "a", { id = "b", label = "B", description = "bee" } } }
        \\  ghostty.toast(tostring(id))
        \\end }
    );

    try testing.expect(rt.run("pick", 7));
    try testing.expectEqual(@as(usize, 2), host.pick_count);
    rt.complete(host.callback.?.id, .{ .pick = "b" });
    try testing.expectEqualStrings("b", host.lastToast());

    try testing.expect(rt.run("pick", 7));
    rt.complete(host.callback.?.id, .{ .pick = null });
    try testing.expectEqualStrings("nil", host.lastToast());
}

test "sleep, after, every and cancel use host timers" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\count = 0
        \\ghostty.action{ name = "sleep", run = function()
        \\  assert(ghostty.sleep(0.5))
        \\  ghostty.toast("woke")
        \\end }
        \\ghostty.action{ name = "every", run = function()
        \\  timer = ghostty.every(2, function()
        \\    count = count + 1
        \\    ghostty.toast("tick " .. count)
        \\    if count == 2 then ghostty.cancel(timer) end
        \\  end)
        \\end }
    );

    try testing.expect(rt.run("sleep", 7));
    try testing.expectEqual(@as(u32, 500), host.timer_ms);
    rt.complete(host.callback.?.id, .timer);
    try testing.expectEqualStrings("woke", host.lastToast());

    try testing.expect(rt.run("every", 7));
    try testing.expectEqual(@as(u32, 2000), host.timer_ms);
    const id = host.callback.?.id;
    rt.complete(id, .timer);
    try testing.expectEqualStrings("tick 1", host.lastToast());
    rt.complete(id, .timer);
    try testing.expectEqualStrings("tick 2", host.lastToast());

    // The second tick cancelled the timer that it armed again.
    try testing.expectEqual(@as(usize, 1), host.cancels);
    try testing.expectEqual(@as(usize, 0), rt.timers.count());
    rt.complete(id, .timer);
    try testing.expectEqualStrings("tick 2", host.lastToast());
}

test "destroy cancels waiting operations" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());

    try testLoad(rt,
        \\ghostty.after(60, function() end)
        \\ghostty.action{ name = "wait", run = function() ghostty.sleep(60) end }
    );
    try testing.expect(rt.run("wait", 7));
    rt.destroy();
    try testing.expectEqual(@as(usize, 2), host.cancels);
}

test "waiting fails outside the task coroutine" {
    const testing = std.testing;
    var host: TestHost = .{};
    const rt = try create(testing.allocator, host.host());
    defer rt.destroy();

    try testLoad(rt,
        \\assert(ghostty.sleep(1) == nil)
        \\ghostty.action{ name = "inner", run = function()
        \\  local ok, err = coroutine.wrap(function() return ghostty.sleep(1) end)()
        \\  assert(ok == nil and err)
        \\end }
        \\ghostty.action{ name = "yield", run = function() coroutine.yield() end }
    );
    try testing.expect(rt.run("inner", 7));
    try testing.expectEqual(@as(usize, 0), host.toasts);

    // A bare yield would wait forever, so it ends the action with an error.
    try testing.expect(rt.run("yield", 7));
    try testing.expectEqual(@as(usize, 1), host.toasts);
    try testing.expectEqual(@as(usize, 0), rt.tasks.count());
}
