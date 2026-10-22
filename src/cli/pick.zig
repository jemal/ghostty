const std = @import("std");
const global = @import("../global.zig");
const args = @import("args.zig");
const protocol = @import("../apprt/gtk/picker/protocol.zig");
const gio = @import("gio");
const glib = @import("glib");

pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    @"bus-name": ?[:0]const u8 = null,
    class: ?[:0]const u8 = null,
    @"surface-id": ?[:0]const u8 = null,
    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
    }
    pub fn help(_: Options) !void {
        return @import("ghostty.zig").Action.help_error;
    }
};

/// Show a searchable native picker in the requesting pane (GTK only).
/// Reads one bounded UTF-8 JSON request from stdin through EOF; writes one
/// JSON response followed by a newline to stdout. Stdin must finish in 30s.
/// Exit codes: 0 selected, 2 cancelled, 1 error, 130/143 interrupted.
/// Requires a running picker-enabled Ghostty; never launches a new instance.
/// Uses GHOSTTY_IPC_BUS_NAME, GHOSTTY_IPC_INSTANCE and GHOSTTY_SURFACE_ID.
/// Flags: --bus-name=<unique-name>, --class=<application-id>, --surface-id=<id>.
/// Explicit bus-name/class overrides inherited instance targeting. Class and
/// bus-name are mutually exclusive. Local GTK only; no SSH/tmux discovery.
/// Request: {"version":1,"request_id":"r","choices":[{"id":"a","label":"A"}]}.
pub fn run(alloc: std.mem.Allocator) !u8 {
    var options: Options = .{};
    defer options.deinit();
    var iter = try args.argsIterator(alloc, global.args());
    defer iter.deinit();
    args.parse(Options, alloc, &options, &iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => return outputFailure(alloc, null, "invalid_arguments", @errorName(err)),
    };

    if (comptime @import("../build_config.zig").app_runtime != .gtk) {
        return outputFailure(alloc, null, "unsupported_platform", "Native picker IPC requires GTK");
    } else return runGtk(alloc, options);
}

fn output(json: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(global.io(), &buf);
    try writer.interface.writeAll(json);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
fn outputFailure(alloc: std.mem.Allocator, id: ?[]const u8, code: []const u8, message: []const u8) !u8 {
    const json = try protocol.failure(alloc, id, code, message);
    defer alloc.free(json);
    try output(json);
    return 1;
}

const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
extern "c" fn poll([*]PollFd, usize, c_int) c_int;
fn readRequest(alloc: std.mem.Allocator) ![]u8 {
    const deadline = glib.getMonotonicTime() + 30 * std.time.us_per_s;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const remaining = @divTrunc(deadline - glib.getMonotonicTime(), 1000);
        if (remaining <= 0) return error.InputTimeout;
        var fd = [_]PollFd{.{ .fd = 0, .events = 1, .revents = 0 }};
        const ready = poll(&fd, 1, @intCast(remaining));
        if (ready == 0) return error.InputTimeout;
        if (ready < 0) return error.InputInterrupted;
        const n = std.Io.File.stdin().readStreaming(global.io(), &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n > protocol.max_bytes - result.items.len) return error.RequestTooLarge;
        try result.appendSlice(alloc, buffer[0..n]);
    }
    return result.toOwnedSlice(alloc);
}

fn runGtk(alloc: std.mem.Allocator, options: Options) !u8 {
    const bytes = readRequest(alloc) catch |err| return outputFailure(alloc, null, "invalid_input", @errorName(err));
    defer alloc.free(bytes);
    var parsed = protocol.parse(alloc, bytes) catch |err| {
        const id = protocol.recoverRequestId(alloc, bytes) catch null;
        defer if (id) |v| alloc.free(v);
        return outputFailure(alloc, id, "invalid_request", @errorName(err));
    };
    defer parsed.deinit();
    const request_id = parsed.value.request_id;
    var env = try global.environMap();
    defer env.deinit();
    if (options.class != null and options.@"bus-name" != null) return outputFailure(alloc, request_id, "invalid_arguments", "Choose either --class or --bus-name");
    parsed.value.surface_id = options.@"surface-id" orelse parsed.value.surface_id orelse env.get("GHOSTTY_SURFACE_ID");
    _ = parsed.value.surfaceId() catch |err| return outputFailure(alloc, request_id, "invalid_surface", @errorName(err));
    const explicit = options.class != null or options.@"bus-name" != null;
    const target = options.class orelse options.@"bus-name" orelse env.get("GHOSTTY_IPC_BUS_NAME") orelse return outputFailure(alloc, request_id, "endpoint_required", "Run inside a picker-enabled Ghostty pane or specify a target");
    const target_z = try alloc.dupeSentinel(u8, target, 0);
    defer alloc.free(target_z);
    if (gio.dbusIsName(target_z) == 0) return outputFailure(alloc, request_id, "invalid_target", "Invalid D-Bus name");
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();
    const bus = gio.busGetSync(.session, null, &err) orelse return outputFailure(alloc, request_id, "unavailable", "Cannot connect to session bus");
    defer bus.unref();
    // Resolve a well-known name once. All calls use the same unique owner.
    var owner: [:0]const u8 = undefined;
    if (target_z[0] == ':') {
        owner = try alloc.dupeSentinel(u8, target_z, 0);
    } else {
        const response = bus.callSync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", glib.Variant.newTuple(&.{glib.Variant.newString(target_z)}, 1), null, .{ .no_auto_start = true }, 3000, null, &err) orelse return outputFailure(alloc, request_id, "unavailable", "Ghostty instance is not running");
        defer response.unref();
        const value = response.getChildValue(0);
        defer value.unref();
        owner = try alloc.dupeSentinel(u8, std.mem.span(value.getString(null)), 0);
    }
    defer alloc.free(owner);
    const caps_reply = bus.callSync(owner, protocol.path, protocol.interface, "GetCapabilities", null, null, .{ .no_auto_start = true }, 3000, null, &err) orelse return outputFailure(alloc, request_id, "unavailable", "This instance does not expose the picker API");
    defer caps_reply.unref();
    const caps_value = caps_reply.getChildValue(0);
    defer caps_value.unref();
    const caps = try std.json.parseFromSlice(struct { version: u32, instance: []const u8 }, alloc, std.mem.span(caps_value.getString(null)), .{ .ignore_unknown_fields = true });
    defer caps.deinit();
    if (caps.value.version != 1) return outputFailure(alloc, request_id, "unsupported_version", "Unsupported picker service version");
    if (!explicit) {
        const expected = env.get("GHOSTTY_IPC_INSTANCE") orelse return outputFailure(alloc, request_id, "endpoint_required", "Missing instance identity");
        if (!std.mem.eql(u8, expected, caps.value.instance)) return outputFailure(alloc, request_id, "stale_instance", "Ghostty instance has changed");
    }
    parsed.value.instance = caps.value.instance;
    const request_json = try protocol.encode(alloc, parsed.value);
    defer alloc.free(request_json);
    if (request_json.len > protocol.max_bytes) return outputFailure(alloc, request_id, "request_too_large", "Request exceeds the wire limit after adding target identity");
    const loop = glib.MainLoop.new(null, 0);
    defer loop.unref();
    const cancellable = gio.Cancellable.new();
    defer cancellable.unref();
    const id_z = try alloc.dupeSentinel(u8, request_id, 0);
    defer alloc.free(id_z);
    var state: State = .{ .loop = loop, .bus = bus, .owner = owner, .id = id_z, .cancellable = cancellable };
    const interrupt_source = @import("glibunix").signalAdd(2, interrupted, &state);
    defer _ = glib.Source.remove(interrupt_source);
    const terminate_source = @import("glibunix").signalAdd(15, terminated, &state);
    defer _ = glib.Source.remove(terminate_source);
    bus.call(owner, protocol.path, protocol.interface, "Select", glib.Variant.newTuple(&.{glib.Variant.newString(request_json)}, 1), null, .{ .no_auto_start = true }, std.math.maxInt(c_int), cancellable, completed, &state);
    loop.run();
    if (state.reply) |response| {
        defer response.unref();
        const value = response.getChildValue(0);
        defer value.unref();
        const json = std.mem.span(value.getString(null));
        const decoded = try std.json.parseFromSlice(protocol.Response, alloc, json, .{});
        defer decoded.deinit();
        if (decoded.value.request_id == null or !std.mem.eql(u8, decoded.value.request_id.?, request_id)) return outputFailure(alloc, request_id, "invalid_response", "Response request ID mismatch");
        try output(json);
        return if (state.signal != 0) 128 + state.signal else switch (decoded.value.status) {
            .selected => 0,
            .cancelled => 2,
            .@"error" => 1,
        };
    }
    if (state.signal != 0) {
        const json = try protocol.encode(alloc, protocol.Response{ .request_id = request_id, .status = .cancelled, .reason = "signal" });
        defer alloc.free(json);
        try output(json);
        return 128 + state.signal;
    }
    return outputFailure(alloc, request_id, "transport_error", "Ghostty disconnected or the picker call failed");
}

const State = struct {
    loop: *glib.MainLoop,
    bus: *gio.DBusConnection,
    owner: [:0]const u8,
    id: [:0]const u8,
    cancellable: *gio.Cancellable,
    reply: ?*glib.Variant = null,
    signal: u8 = 0,
};
fn completed(_: ?*@import("gobject").Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data.?));
    var err: ?*glib.Error = null;
    state.reply = state.bus.callFinish(result, &err);
    if (err) |e| e.free();
    state.loop.quit();
}
fn cancel(data: ?*anyopaque, signal: u8) c_int {
    const state: *State = @ptrCast(@alignCast(data.?));
    state.signal = signal;
    var err: ?*glib.Error = null;
    const result = state.bus.callSync(state.owner, protocol.path, protocol.interface, "Cancel", glib.Variant.newTuple(&.{glib.Variant.newString(state.id)}, 1), null, .{ .no_auto_start = true }, 1000, null, &err);
    if (result) |v| v.unref();
    if (err) |e| e.free();
    state.cancellable.cancel();
    return 1;
}
fn interrupted(data: ?*anyopaque) callconv(.c) c_int {
    return cancel(data, 2);
}
fn terminated(data: ?*anyopaque) callconv(.c) c_int {
    return cancel(data, 15);
}
