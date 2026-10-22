//! Pane-scoped D-Bus picker service. All state belongs to GTK's main context.
const Self = @This();
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gtk = @import("gtk");
const global = @import("../../../global.zig");
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const Window = @import("../class/window.zig").Window;
const ext = @import("../ext.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const List = @import("list.zig");
const protocol = @import("protocol.zig");

app: *Application,
alloc: std.mem.Allocator,
bus: *gio.DBusConnection,
registration: c_uint,
instance: [:0]const u8,
requests: std.ArrayList(*Entry) = .empty,

const Entry = struct {
    service: *Self,
    request: std.json.Parsed(protocol.Request),
    sender: [:0]const u8,
    surface: WeakRef(Surface) = .empty,
    // Comparison only: GObject clears weak refs before dispose is invoked.
    surface_identity: *Surface,
    invocation: ?*gio.DBusMethodInvocation,
    list: List,
    timer: c_uint = 0,
    watch: c_uint = 0,
};
const xml =
    \\<node><interface name="com.mitchellh.ghostty.Picker1">
    \\<method name="GetCapabilities"><arg type="s" direction="out"/></method>
    \\<method name="Select"><arg name="request" type="s" direction="in"/><arg name="response" type="s" direction="out"/></method>
    \\<method name="Cancel"><arg name="request_id" type="s" direction="in"/></method>
    \\</interface></node>
;
// The generated binding declares reserved pointers non-nullable. Keep the C ABI
// layout while allowing its reserved slots to be correctly zero-initialized.
const vtable = extern struct {
    method: ?gio.DBusInterfaceMethodCallFunc,
    get: ?gio.DBusInterfaceGetPropertyFunc,
    set: ?gio.DBusInterfaceSetPropertyFunc,
    padding: [8]?*anyopaque,
}{ .method = method, .get = null, .set = null, .padding = @splat(null) };

pub fn create(app: *Application) !*Self {
    const alloc = app.allocator();
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();
    const bus = gio.busGetSync(.session, null, &err) orelse return error.BusUnavailable;
    errdefer bus.unref();
    const info = gio.DBusNodeInfo.newForXml(xml, &err) orelse return error.InvalidIntrospection;
    defer info.unref();
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    const rng_impl: std.Random.IoSource = .{ .io = global.io() };
    const instance = try alloc.printSentinel("{x:0>16}{x:0>16}", .{ rng_impl.interface().int(u64), rng_impl.interface().int(u64) }, 0);
    errdefer alloc.free(instance);
    self.* = .{ .app = app, .alloc = alloc, .bus = bus, .instance = instance, .registration = 0 };
    self.registration = bus.registerObject(protocol.path, info.lookupInterface(protocol.interface).?, @ptrCast(&vtable), self, noDestroy, &err);
    if (self.registration == 0) return error.ExportFailed;
    return self;
}

pub fn destroy(self: *Self) void {
    while (self.requests.items.len > 0) self.finish(self.requests.items[0], null, "shutdown", false);
    _ = self.bus.unregisterObject(self.registration);
    self.requests.deinit(self.alloc);
    self.bus.unref();
    self.alloc.free(self.instance);
    self.alloc.destroy(self);
}

pub fn addEnv(self: *Self, env: *std.process.Environ.Map) !void {
    try env.put("GHOSTTY_IPC_BUS_NAME", std.mem.span(self.bus.getUniqueName() orelse return error.BusUnavailable));
    try env.put("GHOSTTY_IPC_INSTANCE", self.instance);
}

pub fn cancelSurface(self: *Self, surface: *Surface, reason: []const u8) void {
    var i: usize = 0;
    while (i < self.requests.items.len) {
        const entry = self.requests.items[i];
        if (entry.surface_identity == surface) self.finish(entry, null, reason, false) else i += 1;
    }
}

pub fn cancelWindow(self: *Self, window: *Window) void {
    var i: usize = 0;
    while (i < self.requests.items.len) {
        const entry = self.requests.items[i];
        const surface = entry.surface.get() orelse {
            i += 1;
            continue;
        };
        const owner = ext.getAncestor(Window, surface.as(gtk.Widget));
        surface.unref();
        if (owner == window) self.finish(entry, null, "replaced", false) else i += 1;
    }
}

fn reply(invocation: *gio.DBusMethodInvocation, json: [:0]const u8) void {
    invocation.returnValue(glib.Variant.newTuple(&.{glib.Variant.newString(json)}, 1));
}
fn reject(self: *Self, invocation: *gio.DBusMethodInvocation, id: ?[]const u8, code: []const u8) void {
    const json = protocol.failure(self.alloc, id, code, code) catch {
        invocation.returnDbusError("com.mitchellh.ghostty.Picker1.NoMemory", "Cannot allocate picker response");
        return;
    };
    defer self.alloc.free(json);
    reply(invocation, json);
}
fn method(_: *gio.DBusConnection, sender_: ?[*:0]const u8, _: [*:0]const u8, _: ?[*:0]const u8, name: [*:0]const u8, parameters: *glib.Variant, invocation: *gio.DBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data.?));
    const sender = sender_ orelse {
        self.reject(invocation, null, "invalid_sender");
        return;
    };
    if (std.mem.eql(u8, std.mem.span(name), "GetCapabilities")) {
        const json = protocol.encode(self.alloc, .{ .version = @as(u32, 1), .instance = self.instance, .kinds = [_][]const u8{"select"}, .max_bytes = protocol.max_bytes, .max_choices = protocol.max_choices, .placements = [_][]const u8{ "center", "cursor" } }) catch {
            self.reject(invocation, null, "out_of_memory");
            return;
        };
        defer self.alloc.free(json);
        reply(invocation, json);
        return;
    }
    const value = parameters.getChildValue(0);
    defer value.unref();
    const text = std.mem.span(value.getString(null));
    if (std.mem.eql(u8, std.mem.span(name), "Cancel")) {
        for (self.requests.items) |entry| {
            if (std.mem.eql(u8, entry.sender, std.mem.span(sender)) and std.mem.eql(u8, entry.request.value.request_id, text)) {
                self.finish(entry, null, "caller", true);
                break;
            }
        }
        invocation.returnValue(null);
        return;
    }
    self.select(sender, text, invocation);
}

fn select(self: *Self, sender: [*:0]const u8, text: []const u8, invocation: *gio.DBusMethodInvocation) void {
    var parsed = protocol.parse(self.alloc, text) catch |err| {
        const id = protocol.recoverRequestId(self.alloc, text) catch null;
        defer if (id) |v| self.alloc.free(v);
        self.reject(invocation, id, @errorName(err));
        return;
    };
    var transferred = false;
    defer if (!transferred) parsed.deinit();
    const request = parsed.value;
    if (request.instance == null or !std.mem.eql(u8, request.instance.?, self.instance)) {
        self.reject(invocation, request.request_id, "stale_instance");
        return;
    }
    const id = request.surfaceId() catch {
        self.reject(invocation, request.request_id, "invalid_surface");
        return;
    };
    const core = self.app.core().findSurfaceByID(id) orelse {
        self.reject(invocation, request.request_id, "surface_not_found");
        return;
    };
    self.present(core.rt_surface.gobj(), parsed, std.mem.span(sender), invocation) catch |err| {
        self.reject(invocation, request.request_id, switch (err) {
            error.Busy => "busy",
            error.DuplicateRequest => "duplicate_request",
            error.NotActive => "not_active",
            error.ChildExited => "child_exited",
            else => "out_of_memory",
        });
        return;
    };
    transferred = true;
}

/// Takes ownership of parsed only on success.
fn present(self: *Self, surface: *Surface, parsed: std.json.Parsed(protocol.Request), sender: []const u8, invocation: ?*gio.DBusMethodInvocation) !void {
    const request = parsed.value;
    if (ext.getAncestor(Window, surface.as(gtk.Widget))) |window| window.cancelThemePicker();
    if (surface.hasChildExited()) return error.ChildExited;
    for (self.requests.items) |entry| {
        if (sender.len > 0 and std.mem.eql(u8, entry.sender, sender) and std.mem.eql(u8, entry.request.value.request_id, request.request_id)) return error.DuplicateRequest;
        if (entry.surface.get()) |owner| {
            defer owner.unref();
            if (owner == surface) return error.Busy;
        }
    }
    if (self.requests.items.len >= 32) return error.Busy;
    if (surface.as(gtk.Widget).getMapped() == 0 or (invocation != null and !surface.getFocused())) return error.NotActive;
    if (invocation != null) {
        const window = @import("../ext.zig").getAncestor(gtk.Window, surface.as(gtk.Widget)) orelse return error.NotActive;
        if (window.isActive() == 0) return error.NotActive;
    }
    const entry = try self.alloc.create(Entry);
    errdefer self.alloc.destroy(entry);
    const sender_copy = try self.alloc.dupeSentinel(u8, sender, 0);
    errdefer self.alloc.free(sender_copy);
    entry.* = .{ .service = self, .request = parsed, .sender = sender_copy, .surface_identity = surface, .invocation = invocation, .list = undefined };
    try entry.list.init(self.alloc, request, selected, entry);
    errdefer entry.list.deinit();
    try self.requests.append(self.alloc, entry);
    entry.surface.set(surface);
    if (invocation != null) entry.watch = gio.busWatchNameOnConnection(self.bus, sender_copy, .{}, null, vanished, entry, null);
    if (request.timeout_ms != 0) entry.timer = glib.timeoutAdd(request.timeout_ms, timeout, entry);
    if (request.placement == .cursor) surface.anchorPickerAtCursor(&entry.list);
    surface.showPicker(entry.list.frame.as(gtk.Widget));
    _ = entry.list.search.as(gtk.Widget).grabFocus();
}

fn selected(index: ?usize, data: *anyopaque) void {
    const entry: *Entry = @ptrCast(@alignCast(data));
    entry.service.finish(entry, index, "user", true);
}
fn vanished(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const entry: *Entry = @ptrCast(@alignCast(data.?));
    entry.service.finish(entry, null, "caller_gone", true);
}
fn timeout(data: ?*anyopaque) callconv(.c) c_int {
    const entry: *Entry = @ptrCast(@alignCast(data.?));
    entry.timer = 0;
    entry.service.finish(entry, null, "timeout", true);
    return 0;
}
fn finish(self: *Self, entry: *Entry, index: ?usize, reason: []const u8, restore_focus: bool) void {
    // Remove admission first; guard against reentrant completion during teardown.
    var found = false;
    for (self.requests.items, 0..) |current, i| if (current == entry) {
        _ = self.requests.swapRemove(i);
        found = true;
        break;
    };
    if (!found) return;
    if (entry.timer != 0) _ = glib.Source.remove(entry.timer);
    if (entry.watch != 0) gio.busUnwatchName(entry.watch);
    if (entry.surface.get()) |surface| {
        surface.hidePicker(entry.list.frame.as(gtk.Widget), restore_focus);
        surface.unref();
    }
    entry.surface.deinit();
    if (entry.invocation) |invocation| {
        const response: protocol.Response = if (index) |i| .{
            .request_id = entry.request.value.request_id,
            .status = .selected,
            .result = .{ .ids = &.{entry.request.value.choices[i].id} },
        } else .{ .request_id = entry.request.value.request_id, .status = .cancelled, .reason = reason };
        const json = protocol.encode(self.alloc, response) catch null;
        if (json) |bytes| {
            reply(invocation, bytes);
            self.alloc.free(bytes);
        } else invocation.returnDbusError("com.mitchellh.ghostty.Picker1.NoMemory", "Cannot allocate picker response");
    }
    entry.list.deinit();
    entry.request.deinit();
    self.alloc.free(entry.sender);
    self.alloc.destroy(entry);
}

fn noDestroy(_: ?*anyopaque) callconv(.c) void {}
