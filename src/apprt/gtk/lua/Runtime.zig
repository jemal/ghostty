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
const global = @import("../../../global.zig");
const input = @import("../../../input.zig");

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
};

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

lua: *c.lua_State,
host: Host,
actions: std.StringArrayHashMapUnmanaged(Action) = .empty,
binds: std.ArrayList(Bind) = .empty,

/// True while `init.lua` runs. Some functions work only at load time.
loading: bool = false,

/// The time, from the awake clock, after which the hook stops Lua code.
deadline_ns: i96 = 0,

/// The number of actions that run now, including nested actions.
depth: u8 = 0,

/// The runtime ID of the surface that started the running action.
surface: u64 = 0,

pub const InitError = Allocator.Error || error{LuaInitFailed};

pub fn create(alloc: Allocator, host: Host) InitError!*Runtime {
    const self = try alloc.create(Runtime);
    errdefer alloc.destroy(self);

    const lua = c.luaL_newstate() orelse return error.LuaInitFailed;
    self.* = .{
        .alloc = alloc,
        .arena = .init(alloc),
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
    c.lua_close(self.lua);
    self.actions.deinit(self.alloc);
    self.binds.deinit(self.alloc);
    self.arena.deinit();
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
    self.startBudget(load_budget_ns);
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
    const action = self.actions.get(name) orelse {
        log.warn("no Lua action named {s}", .{name});
        return false;
    };

    if (self.depth >= max_depth) {
        self.showError(surface, "Lua actions are nested too deep");
        return true;
    }

    const L = self.lua;
    const outer_surface = self.surface;
    self.surface = surface;
    self.depth += 1;
    defer {
        self.depth -= 1;
        self.surface = outer_surface;
    }

    // Only the outermost action sets the time limit. Nested actions are
    // part of the time of the outer action.
    if (self.depth == 1) self.startBudget(action_budget_ns);
    defer if (self.depth == 1) c.lua_sethook(L, null, 0, 0);

    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, action.ref);

    // ctx
    c.lua_createtable(L, 0, 1);
    c.lua_pushinteger(L, @bitCast(surface));
    c.lua_setfield(L, -2, "surface");

    // args. Keybinds and the command palette give no arguments.
    c.lua_createtable(L, 0, 0);

    if (c.lua_pcallk(L, 2, 1, 0, 0, null) != c.LUA_OK) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrintSentinel(&buf, "Lua action {s}: {s}", .{
            name,
            popError(L),
        }, 0) catch "Lua action failed";
        self.showError(surface, msg);
        return true;
    }

    const performed = !(c.lua_type(L, -1) == c.LUA_TBOOLEAN and c.lua_toboolean(L, -1) == 0);
    c.lua_settop(L, -2);
    return performed;
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

    c.lua_createtable(L, 0, 5);
    const functions = .{
        .{ "action", luaAction },
        .{ "bind", luaBind },
        .{ "invoke", luaInvoke },
        .{ "toast", luaToast },
        .{ "log", luaLog },
    };
    inline for (functions) |entry| {
        c.lua_pushcclosure(L, entry[1], 0);
        c.lua_setfield(L, -2, entry[0]);
    }
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

fn startBudget(self: *Runtime, budget_ns: i96) void {
    self.deadline_ns = std.Io.Timestamp.now(global.io(), .awake).toNanoseconds() + budget_ns;
    c.lua_sethook(self.lua, budgetHook, c.LUA_MASKCOUNT, 10_000);
}

fn budgetHook(L: ?*c.lua_State, _: [*c]c.lua_Debug) callconv(.c) void {
    const self = fromState(L);
    const now = std.Io.Timestamp.now(global.io(), .awake).toNanoseconds();
    if (now > self.deadline_ns) _ = c.luaL_error(L, "Lua code ran for too long");
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

    fn host(self: *TestHost) Host {
        return .{ .ptr = self, .invoke = invoke, .toast = toast };
    }

    fn invoke(ptr: *anyopaque, _: u64, action: input.Binding.Action) bool {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        self.invoked = @tagName(action);
        return true;
    }

    fn toast(ptr: *anyopaque, _: u64, _: [:0]const u8) void {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        self.toasts += 1;
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
