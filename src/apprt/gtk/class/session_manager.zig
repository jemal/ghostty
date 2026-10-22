const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const global = @import("../../../global.zig");
const i18n = @import("../../../os/main.zig").i18n;
const sessions = @import("../session.zig");
const ext = @import("../ext.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const log = std.log.scoped(.gtk_session_manager);

/// Independent application window: archiving the last terminal must not close
/// its manager or require the user to create a temporary terminal first.
pub const SessionManager = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySessionManager",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    const Private = struct {
        list: *gtk.ListBox,
        archived: *gtk.CheckButton,
        overlay: *adw.ToastOverlay,
        empty: *gtk.Label,
        timer: ?c_uint = null,
        hash: ?u64 = null,
        rename_id: u64 = 0,
        closing: bool = false,
        pub var offset: c_int = 0;
    };
    const Item = struct { id: u64, name: [:0]const u8, archived: bool, open: bool };

    pub fn present() void {
        const app = Application.default();
        if (!app.sessionsEnabled()) return;
        var current: ?*glib.List = app.as(gtk.Application).getWindows();
        while (current) |link| : (current = link.f_next) {
            const ptr: *gtk.Window = @ptrCast(@alignCast(link.f_data orelse continue));
            if (gobject.ext.cast(Self, ptr)) |manager| {
                manager.refresh(true);
                manager.as(gtk.Window).present();
                return;
            }
        }
        app.saveSessions();
        const self = gobject.ext.newInstance(Self, .{});
        self.as(gtk.Window).setApplication(app.as(gtk.Application));
        self.refresh(true);
        self.as(gtk.Window).present();
    }

    pub fn isClosing(self: *Self) bool {
        return self.private().closing;
    }

    fn closeRequest(_: *gtk.Window, self: *Self) callconv(.c) c_int {
        self.private().closing = true;
        Application.default().sessionManagerClosed();
        return 0;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        const window = self.as(gtk.Window);
        window.setTitle(i18n._("Sessions"));
        window.setDefaultSize(900, 520);
        _ = gtk.Window.signals.close_request.connect(window, *Self, closeRequest, self, .{});
        const toolbar = adw.ToolbarView.new();
        const header = adw.HeaderBar.new();
        const title = adw.WindowTitle.new(i18n._("Sessions"), "");
        header.setTitleWidget(title.as(gtk.Widget));
        const create = gtk.Button.newWithLabel(i18n._("New Session"));
        create.as(gtk.Actionable).setActionName("win.new");
        header.packStart(create.as(gtk.Widget));
        toolbar.addTopBar(header.as(gtk.Widget));
        const box = gtk.Box.new(.vertical, 12);
        const widget = box.as(gtk.Widget);
        widget.setMarginStart(18);
        widget.setMarginEnd(18);
        widget.setMarginTop(12);
        widget.setMarginBottom(18);
        priv.archived = gtk.CheckButton.newWithLabel(i18n._("Show archived sessions"));
        box.append(priv.archived.as(gtk.Widget));
        priv.list = gtk.ListBox.new();
        priv.list.setSelectionMode(.none);
        priv.list.as(gtk.Widget).setValign(.start);
        priv.list.as(gtk.Widget).addCssClass("boxed-list");
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setChild(priv.list.as(gtk.Widget));
        box.append(scroll.as(gtk.Widget));
        priv.empty = gtk.Label.new(i18n._("No saved sessions. Create a session or show archived sessions."));
        priv.empty.setWrap(1);
        box.append(priv.empty.as(gtk.Widget));
        toolbar.setContent(widget);
        priv.overlay = adw.ToastOverlay.new();
        priv.overlay.setChild(toolbar.as(gtk.Widget));
        self.as(adw.ApplicationWindow).setContent(priv.overlay.as(gtk.Widget));
        const target = glib.ext.VariantType.newFor(u64);
        defer target.free();
        const actions = [_]ext.actions.Action(Self){
            .init("new", actionNew, null),
            .init("open", actionOpen, target),
            .init("rename", actionRename, target),
            .init("archive", actionArchive, target),
            .init("delete", actionDelete, target),
        };
        ext.actions.add(Self, self, &actions);
        _ = gtk.CheckButton.signals.toggled.connect(priv.archived, *Self, toggled, self, .{});
        priv.timer = glib.timeoutAdd(1000, tick, self);
    }

    fn items(alloc: std.mem.Allocator) ![]Item {
        const app = Application.default();
        const dir = try app.sessionDir();
        defer dir.close(global.io());
        var result: std.ArrayList(Item) = .empty;
        for ([_]bool{ false, true }) |archived| {
            const entries = if (archived) try sessions.listArchived(dir, global.io(), alloc) else try sessions.list(dir, global.io(), alloc);
            for (entries) |entry| try result.append(alloc, .{
                .id = entry.id,
                .name = entry.name,
                .archived = archived,
                .open = app.sessionWindow(entry.id) != null,
            });
        }
        return result.toOwnedSlice(alloc);
    }

    fn find(alloc: std.mem.Allocator, id: u64) !Item {
        for (try items(alloc)) |item| if (item.id == id) return item;
        return error.FileNotFound;
    }

    fn refresh(self: *Self, force: bool) void {
        var arena: std.heap.ArenaAllocator = .init(Application.default().allocator());
        defer arena.deinit();
        const entries = items(arena.allocator()) catch |err| {
            self.failed(err);
            return;
        };
        const priv = self.private();
        const show_archived = priv.archived.getActive() != 0;
        var hash = std.hash.Wyhash.init(@intFromBool(show_archived));
        for (entries) |item| {
            hash.update(std.mem.asBytes(&item.id));
            hash.update(item.name);
            hash.update(&.{ @intFromBool(item.open), @intFromBool(item.archived) });
        }
        const value = hash.final();
        if (!force and priv.hash == value) return;
        priv.hash = value;
        priv.list.removeAll();
        var count: usize = 0;
        for (entries) |item| {
            if (item.archived and !show_archived) continue;
            const row = adw.ActionRow.new();
            row.as(adw.PreferencesRow).setUseMarkup(0);
            row.as(adw.PreferencesRow).setTitle(item.name);
            row.setTitleLines(1);
            row.setSubtitle(if (item.archived) i18n._("Archived") else if (item.open) i18n._("Open") else i18n._("Saved"));
            self.button(row, if (item.open) i18n._("Focus") else i18n._("Open"), "win.open", item.id, true);
            self.button(row, i18n._("Rename…"), "win.rename", item.id, true);
            self.button(row, if (item.archived) i18n._("Unarchive") else if (item.open) i18n._("Archive and Close…") else i18n._("Archive"), "win.archive", item.id, true);
            self.button(row, i18n._("Delete…"), "win.delete", item.id, !item.open);
            priv.list.append(row.as(gtk.Widget));
            count += 1;
        }
        priv.empty.as(gtk.Widget).setVisible(@intFromBool(count == 0));
    }

    fn button(_: *Self, row: *adw.ActionRow, label: [*:0]const u8, action: [*:0]const u8, id: u64, enabled: bool) void {
        const control = gtk.Button.newWithLabel(label);
        control.as(gtk.Widget).setValign(.center);
        if (enabled) {
            control.as(gtk.Actionable).setActionName(action);
            control.as(gtk.Actionable).setActionTargetValue(glib.Variant.newUint64(id));
        } else {
            // Binding an enabled action would override widget sensitivity
            // when the row is rooted. Keep disabled controls unbound.
            control.as(gtk.Widget).setSensitive(0);
        }
        row.addSuffix(control.as(gtk.Widget));
    }

    fn failed(self: *Self, err: anyerror) void {
        log.warn("session management failed err={}", .{err});
        self.private().overlay.addToast(adw.Toast.new(if (err == error.SessionOpen)
            i18n._("This session is open. Close it before deleting it.")
        else
            i18n._("Unable to update this saved session.")));
    }
    fn tick(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        self.refresh(false);
        return 1;
    }
    fn toggled(_: *gtk.CheckButton, self: *Self) callconv(.c) void {
        self.refresh(true);
    }
    fn actionNew(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        Window.createSession();
    }
    fn actionOpen(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        const id = (param orelse return).getUint64();
        var arena: std.heap.ArenaAllocator = .init(Application.default().allocator());
        defer arena.deinit();
        const item = find(arena.allocator(), id) catch |err| {
            self.failed(err);
            return;
        };
        const app = Application.default();
        if (item.archived) app.archiveSession(id, false) catch |err| {
            self.failed(err);
            return;
        };
        app.openSession(id) catch |err| {
            self.failed(err);
            return;
        };
        self.refresh(true);
    }
    fn actionArchive(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        const id = (param orelse return).getUint64();
        const app = Application.default();
        if (app.sessionWindow(id)) |window| {
            window.archiveAndClose();
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(app.allocator());
        defer arena.deinit();
        const item = find(arena.allocator(), id) catch |err| {
            self.failed(err);
            return;
        };
        app.archiveSession(id, !item.archived) catch |err| {
            self.failed(err);
            return;
        };
        self.refresh(true);
    }
    fn actionRename(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        const id = (param orelse return).getUint64();
        var arena: std.heap.ArenaAllocator = .init(Application.default().allocator());
        defer arena.deinit();
        const item = find(arena.allocator(), id) catch |err| {
            self.failed(err);
            return;
        };
        self.private().rename_id = id;
        const dialog = TitleDialog.new(.session, item.name);
        _ = TitleDialog.signals.set.connect(dialog, *Self, renamed, self, .{});
        dialog.present(self.as(gtk.Widget));
    }
    fn renamed(_: *TitleDialog, text: [*:0]const u8, self: *Self) callconv(.c) void {
        var arena: std.heap.ArenaAllocator = .init(Application.default().allocator());
        defer arena.deinit();
        const name = arena.allocator().dupeSentinel(u8, std.mem.trim(u8, std.mem.span(text), &std.ascii.whitespace), 0) catch return;
        if (!sessions.validName(name)) {
            self.private().overlay.addToast(adw.Toast.new(i18n._("Enter a short session name without line breaks.")));
            return;
        }
        const app = Application.default();
        const id = self.private().rename_id;
        if (app.sessionWindow(id)) |window| window.renameSession(name) else {
            const item = find(arena.allocator(), id) catch |err| {
                self.failed(err);
                return;
            };
            const dir = app.sessionDir() catch |err| {
                self.failed(err);
                return;
            };
            defer dir.close(global.io());
            sessions.rename(dir, global.io(), app.allocator(), id, item.archived, name) catch |err| {
                self.failed(err);
                return;
            };
        }
        self.refresh(true);
    }

    const DeleteRequest = struct { manager: *Self, id: u64 };
    fn actionDelete(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        const id = (param orelse return).getUint64();
        const app = Application.default();
        if (app.sessionWindow(id) != null) {
            self.failed(error.SessionOpen);
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(app.allocator());
        defer arena.deinit();
        const item = find(arena.allocator(), id) catch |err| {
            self.failed(err);
            return;
        };
        const body = arena.allocator().printSentinel("{s}\n\n{s}", .{ item.name, i18n._("Permanently delete this saved layout and all of its terminal snapshots? This cannot be undone.") }, 0) catch return;
        const data = app.allocator().create(DeleteRequest) catch return;
        data.* = .{ .manager = self.ref(), .id = id };
        const dialog = adw.AlertDialog.new(i18n._("Delete Saved Session?"), body);
        dialog.setBodyUseMarkup(0);
        dialog.addResponse("cancel", i18n._("Cancel"));
        dialog.addResponse("delete", i18n._("Delete"));
        dialog.setResponseAppearance("delete", .destructive);
        dialog.setDefaultResponse("cancel");
        dialog.setCloseResponse("cancel");
        dialog.choose(self.as(gtk.Widget), null, deleted, data);
    }
    fn deleted(source: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const data: *DeleteRequest = @ptrCast(@alignCast(ud orelse return));
        const self = data.manager;
        defer self.unref();
        defer Application.default().allocator().destroy(data);
        const dialog = gobject.ext.cast(adw.AlertDialog, source orelse return) orelse return;
        if (std.mem.orderZ(u8, dialog.chooseFinish(result), "delete") != .eq) return;
        Application.default().deleteSession(data.id) catch |err| {
            self.failed(err);
            return;
        };
        self.refresh(true);
    }
    fn dispose(self: *Self) callconv(.c) void {
        if (self.private().timer) |timer| {
            _ = glib.Source.remove(timer);
            self.private().timer = null;
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;
    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
        pub const as = C.Class.as;
    };
};
