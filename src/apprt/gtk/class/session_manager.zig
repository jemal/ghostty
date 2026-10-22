const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");
const global = @import("../../../global.zig");
const i18n = @import("../../../os/main.zig").i18n;
const sessions = @import("../session.zig");
const ext = @import("../ext.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const log = std.log.scoped(.gtk_session_manager);

/// Floating, window-owned session manager. Closing its host closes the dialog.
pub const SessionManager = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Dialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySessionManager",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    const Private = struct {
        list: *gtk.ListBox,
        search: *gtk.SearchEntry,
        scroll: *gtk.ScrolledWindow,
        ids: std.ArrayList(u64) = .empty,
        current_id: u64 = 0,
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

    pub fn present(parent: *Window) void {
        const app = Application.default();
        if (!app.sessionsEnabled()) return;
        const dialogs = parent.as(adw.ApplicationWindow).getDialogs();
        var index: c_uint = 0;
        while (index < dialogs.getNItems()) : (index += 1) {
            const object = dialogs.getObject(index) orelse continue;
            defer object.unref();
            if (gobject.ext.cast(Self, object)) |manager| {
                if (manager.private().closing) continue;
                manager.refresh(true);
                manager.as(adw.Dialog).present(parent.as(gtk.Widget));
                return;
            }
        }
        parent.cancelThemePicker();
        if (app.picker()) |service| service.cancelWindow(parent);
        app.saveSessions();
        const self = gobject.ext.newInstance(Self, .{});
        self.private().current_id = parent.sessionId();
        self.refresh(true);
        self.as(adw.Dialog).present(parent.as(gtk.Widget));
        _ = self.private().search.as(gtk.Widget).grabFocus();
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        self.private().closing = true;
        self.stopTimer();
    }

    fn stopTimer(self: *Self) void {
        if (self.private().timer) |timer| {
            _ = glib.Source.remove(timer);
            self.private().timer = null;
        }
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        const dialog = self.as(adw.Dialog);
        dialog.setTitle(i18n._("Sessions"));
        dialog.setContentWidth(620);
        dialog.setContentHeight(520);
        dialog.setPresentationMode(.floating);
        _ = adw.Dialog.signals.closed.connect(dialog, *Self, closed, self, .{});
        const toolbar = adw.ToolbarView.new();
        const header = adw.HeaderBar.new();
        const title = adw.WindowTitle.new(i18n._("Sessions"), "");
        header.setTitleWidget(title.as(gtk.Widget));
        const create = gtk.Button.newWithLabel(i18n._("New Session"));
        create.as(gtk.Actionable).setActionName("sessions.new");
        header.packStart(create.as(gtk.Widget));
        toolbar.addTopBar(header.as(gtk.Widget));
        const box = gtk.Box.new(.vertical, 12);
        const widget = box.as(gtk.Widget);
        widget.setMarginStart(18);
        widget.setMarginEnd(18);
        widget.setMarginTop(12);
        widget.setMarginBottom(18);
        priv.search = gtk.SearchEntry.new();
        priv.search.setPlaceholderText(i18n._("Search sessions…"));
        box.append(priv.search.as(gtk.Widget));
        priv.archived = gtk.CheckButton.newWithLabel(i18n._("Show archived sessions"));
        box.append(priv.archived.as(gtk.Widget));
        priv.list = gtk.ListBox.new();
        priv.list.setSelectionMode(.single);
        priv.list.setActivateOnSingleClick(0);
        priv.list.as(gtk.Widget).setValign(.start);
        priv.list.as(gtk.Widget).addCssClass("boxed-list");
        const scroll = gtk.ScrolledWindow.new();
        priv.scroll = scroll;
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setChild(priv.list.as(gtk.Widget));
        box.append(scroll.as(gtk.Widget));
        priv.empty = gtk.Label.new(i18n._("No saved sessions. Create a session or show archived sessions."));
        priv.empty.setWrap(1);
        box.append(priv.empty.as(gtk.Widget));
        const hint = gtk.Label.new(i18n._("Enter Open · Ctrl+A Archive / Unarchive · Ctrl+R Rename · Ctrl+K Delete · Esc Close"));
        hint.setWrap(1);
        hint.as(gtk.Widget).addCssClass("caption");
        hint.as(gtk.Widget).addCssClass("dim-label");
        box.append(hint.as(gtk.Widget));
        toolbar.setContent(widget);
        priv.overlay = adw.ToastOverlay.new();
        priv.overlay.setChild(toolbar.as(gtk.Widget));
        dialog.setChild(priv.overlay.as(gtk.Widget));
        const target = glib.ext.VariantType.newFor(u64);
        defer target.free();
        const actions = [_]ext.actions.Action(Self){
            .init("new", actionNew, null),
            .init("open", actionOpen, target),
            .init("rename", actionRename, target),
            .init("archive", actionArchive, target),
            .init("delete", actionDelete, target),
        };
        const group = ext.actions.addAsGroup(Self, self, "sessions", &actions);
        group.unref();
        _ = gtk.CheckButton.signals.toggled.connect(priv.archived, *Self, toggled, self, .{});
        _ = gtk.Editable.signals.changed.connect(priv.search.as(gtk.Editable), *Self, searchChanged, self, .{});
        _ = gtk.ListBox.signals.row_activated.connect(priv.list, *Self, rowActivated, self, .{});
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Self, keyPressed, self, .{});
        self.as(gtk.Widget).addController(keys.as(gtk.EventController));
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
        const query = glib.utf8Casefold(priv.search.as(gtk.Editable).getText(), -1);
        defer glib.free(query);
        hash.update(std.mem.span(query));
        const filtered_hash = hash.final();
        if (!force and priv.hash == filtered_hash) return;
        const selected_id = self.selectedId();
        const selected_index = if (priv.list.getSelectedRow()) |row| row.getIndex() else 0;
        priv.hash = filtered_hash;
        priv.ids.clearRetainingCapacity();
        priv.list.removeAll();
        var selected: ?*gtk.ListBoxRow = null;
        var count: usize = 0;
        for (entries) |item| {
            if (item.archived and !show_archived) continue;
            const name = glib.utf8Casefold(item.name, -1);
            defer glib.free(name);
            if (std.mem.indexOf(u8, std.mem.span(name), std.mem.span(query)) == null) continue;
            priv.ids.append(Application.default().allocator(), item.id) catch |err| {
                self.failed(err);
                return;
            };
            const row = adw.ActionRow.new();
            row.as(adw.PreferencesRow).setUseMarkup(0);
            row.as(adw.PreferencesRow).setTitle(item.name);
            row.setTitleLines(1);
            row.setSubtitle(if (item.archived) i18n._("Archived") else if (item.id == priv.current_id) i18n._("Current") else if (item.open) i18n._("Open") else i18n._("Saved"));
            const list_row = row.as(gtk.ListBoxRow);
            list_row.setActivatable(1);
            list_row.setSelectable(1);
            priv.list.append(row.as(gtk.Widget));
            if (selected_id == item.id) selected = list_row;
            count += 1;
        }
        const fallback_index: c_int = if (count == 0) 0 else @intCast(@min(@as(usize, @intCast(@max(0, selected_index))), count - 1));
        priv.list.selectRow(selected orelse priv.list.getRowAtIndex(fallback_index));
        priv.empty.setText(if (std.mem.span(query).len > 0) i18n._("No matching sessions.") else i18n._("No saved sessions. Create a session or show archived sessions."));
        priv.empty.as(gtk.Widget).setVisible(@intFromBool(count == 0));
    }

    fn selectedId(self: *Self) ?u64 {
        const priv = self.private();
        const row = priv.list.getSelectedRow() orelse return null;
        const index = row.getIndex();
        if (index < 0 or index >= priv.ids.items.len) return null;
        return priv.ids.items[@intCast(index)];
    }

    fn selectedAction(self: *Self, name: [:0]const u8) void {
        const id = self.selectedId() orelse return;
        const target = glib.Variant.newUint64(id);
        defer target.unref();
        _ = self.as(gtk.Widget).activateActionVariant(name, target);
    }

    fn searchChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.refresh(false);
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        self.private().list.selectRow(row);
        self.selectedAction("sessions.open");
    }

    fn keyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, mods: gdk.ModifierType, self: *Self) callconv(.c) c_int {
        const priv = self.private();
        if (keyval == gdk.KEY_Escape) {
            _ = self.as(adw.Dialog).close();
            return 1;
        }
        if (mods.control_mask and !mods.alt_mask and !mods.super_mask) {
            const action: [:0]const u8 = switch (keyval) {
                gdk.KEY_a, gdk.KEY_A => "sessions.archive",
                gdk.KEY_k, gdk.KEY_K => "sessions.delete",
                gdk.KEY_r, gdk.KEY_R => "sessions.rename",
                else => return 0,
            };
            self.selectedAction(action);
            return 1;
        }
        if (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter) {
            self.selectedAction("sessions.open");
            return 1;
        }
        if (keyval != gdk.KEY_Up and keyval != gdk.KEY_Down and keyval != gdk.KEY_Tab and keyval != gdk.KEY_ISO_Left_Tab) return 0;
        if (priv.ids.items.len == 0) return 1;
        const backwards = keyval == gdk.KEY_Up or keyval == gdk.KEY_ISO_Left_Tab or (keyval == gdk.KEY_Tab and mods.shift_mask);
        const count: c_int = @intCast(priv.ids.items.len);
        const current = if (priv.list.getSelectedRow()) |row| row.getIndex() else if (backwards) @as(c_int, 0) else count - 1;
        const index = @mod(current + (if (backwards) @as(c_int, -1) else 1), count);
        if (priv.list.getRowAtIndex(index)) |row| {
            priv.list.selectRow(row);
            var rect: gtk.Allocation = undefined;
            row.as(gtk.Widget).getAllocation(&rect);
            const adjustment = priv.scroll.getVadjustment();
            const top: f64 = @floatFromInt(rect.f_y);
            const bottom: f64 = @floatFromInt(rect.f_y + rect.f_height);
            const value = adjustment.getValue();
            if (top < value) adjustment.setValue(top) else if (bottom > value + adjustment.getPageSize()) adjustment.setValue(bottom - adjustment.getPageSize());
        }
        _ = priv.search.as(gtk.Widget).grabFocus();
        return 1;
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
    fn actionNew(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        Window.createSession();
        _ = self.as(adw.Dialog).close();
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
        _ = self.as(adw.Dialog).close();
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
        _ = TitleDialog.signals.set.connect(dialog, *Self, renamed, self.ref(), .{});
        _ = adw.Dialog.signals.closed.connect(dialog.as(adw.Dialog), *Self, renameClosed, self, .{ .after = true });
        dialog.present(self.as(gtk.Widget));
    }
    fn renameClosed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        self.unref();
    }
    fn renamed(_: *TitleDialog, text: [*:0]const u8, self: *Self) callconv(.c) void {
        if (self.private().closing) return;
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
        self.stopTimer();
        self.private().ids.deinit(Application.default().allocator());
        self.private().ids = .empty;
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
