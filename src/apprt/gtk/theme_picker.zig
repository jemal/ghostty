//! Window-owned, reversible theme previews. No config files are written.
const std = @import("std");
const gtk = @import("gtk");
const glib = @import("glib");
const gobject = @import("gobject");
const Config = @import("../../config/Config.zig");
const themes = @import("../../config/theme.zig");
const List = @import("picker/list.zig");
const protocol = @import("picker/protocol.zig");
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Application = @import("class/application.zig").Application;
const i18n = @import("../../os/i18n.zig");

pub const State = struct {
    appearance: ?Config.ThemeAppearance = null,
    name: ?[:0]u8 = null,
    picker: ?*Picker = null,
    css: ?*gtk.CssProvider = null,

    pub fn cancel(self: *State) void {
        if (self.picker) |picker| picker.finish(null);
    }

    pub fn clear(self: *State, window: *Window) void {
        self.cancel();
        self.appearance = null;
        if (self.name) |name| Application.default().allocator().free(name);
        self.name = null;
        self.refresh(window) catch |err| std.log.warn("clearing theme: {}", .{err});
    }

    pub fn deinit(self: *State, window: *Window) void {
        // No rollback needed when all the owning window's widgets are going away.
        if (self.picker) |picker| picker.destroy();
        if (self.name) |name| Application.default().allocator().free(name);
        self.name = null;
        if (self.css) |css| {
            gtk.StyleContext.removeProviderForDisplay(window.as(gtk.Widget).getDisplay(), css.as(gtk.StyleProvider));
            css.unref();
            self.css = null;
        }
    }

    pub fn refresh(self: *State, window: *Window) !void {
        const alloc = Application.default().allocator();
        if (self.css == null and self.appearance != null) {
            self.css = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(window.as(gtk.Widget).getDisplay(), self.css.?.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 4);
        }
        if (self.css) |css| {
            var buffer: std.Io.Writer.Allocating = .init(alloc);
            defer buffer.deinit();
            if (self.appearance) |appearance| {
                var config = window.themeConfig().shallowClone(alloc);
                defer config.deinit();
                appearance.apply(&config);
                const selector = try alloc.printSentinel(".theme-window-{x}", .{@intFromPtr(window)}, 0);
                defer alloc.free(selector);
                window.as(gtk.Widget).addCssClass(selector[1.. :0]);
                if (config.@"window-theme" == .ghostty)
                    try @import("theme_css.zig").write(&buffer.writer, &config, selector);
                const divider = config.@"split-divider-color" orelse config.background;
                const fill = config.@"unfocused-split-fill" orelse config.background;
                try buffer.writer.print(
                    "{s} .split paned > separator {{ background-color: rgb({d},{d},{d}); }}\n" ++
                        "{s} widget.unfocused-split {{ background-color: rgb({d},{d},{d}); }}\n",
                    .{ selector, divider.r, divider.g, divider.b, selector, fill.r, fill.g, fill.b },
                );
            }
            const bytes = glib.Bytes.new(buffer.written().ptr, buffer.written().len);
            defer bytes.unref();
            css.loadFromBytes(bytes);
        }
        const view = window.getTabView();
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const tab = gobject.ext.cast(Tab, view.getNthPage(i).getChild()) orelse continue;
            var it = tab.surfaces();
            while (it.next()) |surface| try surface.applyTheme(self.appearance);
        }
    }

    pub fn open(self: *State, window: *Window, overlay: *gtk.Overlay) !void {
        if (self.picker != null) {
            self.cancel();
            return;
        }
        if (Application.default().picker()) |service| service.cancelWindow(window);
        const alloc = Application.default().allocator();
        const picker = try alloc.create(Picker);
        errdefer alloc.destroy(picker);
        picker.* = .{ .window = window, .state = self, .overlay = overlay, .arena = .init(alloc), .baseline = self.appearance };
        errdefer picker.arena.deinit();
        const arena = picker.arena.allocator();
        const catalog = try themes.list(arena);
        picker.choices = try arena.alloc(protocol.Choice, catalog.len + 1);
        picker.cache = try arena.alloc(?Config.ThemeAppearance, catalog.len + 1);
        @memset(picker.cache, null);
        picker.choices[0] = .{ .id = "configured", .label = std.mem.span(i18n._("Configured theme")), .description = std.mem.span(i18n._("Follow configuration")) };
        var initial: usize = 0;
        for (catalog, 1..) |entry, i| {
            picker.choices[i] = .{ .id = entry.name, .label = entry.name, .description = std.mem.span(if (entry.location == .user) i18n._("User") else i18n._("Bundled")) };
            if (self.name) |name| if (std.mem.eql(u8, name, entry.name)) {
                initial = i;
            };
        }
        try picker.list.init(alloc, .{ .version = 1, .request_id = "theme", .title = std.mem.span(i18n._("Pick Theme")), .placeholder = std.mem.span(i18n._("Search themes…")), .choices = picker.choices }, completed, picker);
        errdefer picker.list.deinit();
        picker.list.list.selectRow(picker.list.rows[initial].widget);
        picker.list.last_selection = initial;
        picker.list.selection_callback = selectionChanged;
        picker.message = gtk.Label.new(null);
        picker.message.setWrap(1);
        picker.message.as(gtk.Widget).addCssClass("error");
        picker.message.as(gtk.Widget).setVisible(0);
        picker.list.box.append(picker.message.as(gtk.Widget));
        const hint = gtk.Label.new(i18n._("This window only · Enter to keep · Escape to cancel"));
        hint.setWrap(1);
        hint.as(gtk.Widget).addCssClass("caption");
        hint.as(gtk.Widget).addCssClass("dim-label");
        picker.list.box.append(hint.as(gtk.Widget));
        self.picker = picker;
        overlay.addOverlay(picker.list.frame.as(gtk.Widget));
        const focus = gtk.EventControllerFocus.new();
        picker.focus = focus;
        picker.focus_handler = gtk.EventControllerFocus.signals.leave.connect(focus, *Picker, focusLeft, picker, .{});
        picker.list.box.as(gtk.Widget).addController(focus.as(gtk.EventController));
        _ = picker.list.search.as(gtk.Widget).grabFocus();
    }
};

const Picker = struct {
    window: *Window,
    state: *State,
    overlay: *gtk.Overlay,
    arena: std.heap.ArenaAllocator,
    baseline: ?Config.ThemeAppearance,
    list: List = undefined,
    choices: []protocol.Choice = &.{},
    cache: []?Config.ThemeAppearance = &.{},
    message: *gtk.Label = undefined,
    timer: c_uint = 0,
    pending: ?usize = null,
    applied: ?usize = null,
    closing: bool = false,
    focus: *gtk.EventControllerFocus = undefined,
    focus_handler: c_ulong = 0,
    focus_leave_source: c_uint = 0,

    fn preview(self: *Picker, index: usize) bool {
        if (self.applied == index) {
            self.message.as(gtk.Widget).setVisible(0);
            return true;
        }
        var appearance: ?Config.ThemeAppearance = null;
        if (index > 0) {
            if (self.cache[index] == null) {
                self.cache[index] = self.window.themeConfig().themeAppearance(self.choices[index].id) catch {
                    self.message.setText(i18n._("Unable to preview this theme"));
                    self.message.as(gtk.Widget).setVisible(1);
                    return false;
                };
            }
            appearance = self.cache[index];
        }
        const previous = self.state.appearance;
        self.state.appearance = appearance;
        self.state.refresh(self.window) catch {
            self.state.appearance = previous;
            self.state.refresh(self.window) catch {};
            self.message.setText(i18n._("Unable to apply this theme"));
            self.message.as(gtk.Widget).setVisible(1);
            return false;
        };
        self.message.as(gtk.Widget).setVisible(0);
        self.applied = index;
        return true;
    }

    fn finish(self: *Picker, index: ?usize) void {
        if (self.closing) return;
        if (self.timer != 0) {
            _ = glib.Source.remove(self.timer);
            self.timer = 0;
        }
        if (index) |i| {
            if (!self.preview(i)) return;
            const alloc = Application.default().allocator();
            const name = if (i == 0) null else alloc.dupeSentinel(u8, self.choices[i].id, 0) catch return;
            if (self.state.name) |old| alloc.free(old);
            self.state.name = name;
        } else {
            self.state.appearance = self.baseline;
            self.state.refresh(self.window) catch |err| std.log.warn("restoring theme: {}", .{err});
        }
        // Only return focus when the picker still owns it. A focus-loss
        // dismissal must not steal focus from a new tab, menu, or another pane.
        const frame = self.list.frame.as(gtk.Widget);
        const root = frame.getRoot();
        const focus = if (root) |r| r.getFocus() else null;
        const restore_focus = if (focus) |f| f == frame or f.isAncestor(frame) != 0 else false;
        const window = self.window;
        self.destroy();
        if (restore_focus) {
            if (window.getActiveSurface()) |surface| surface.grabFocus();
        }
    }

    fn destroy(self: *Picker) void {
        self.closing = true;
        self.state.picker = null;
        gobject.signalHandlerDisconnect(self.focus.as(gobject.Object), self.focus_handler);
        if (self.focus_leave_source != 0) _ = glib.Source.remove(self.focus_leave_source);
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.overlay.removeOverlay(self.list.frame.as(gtk.Widget));
        self.list.deinit();
        self.arena.deinit();
        Application.default().allocator().destroy(self);
    }
};

fn completed(index: ?usize, data: *anyopaque) void {
    const picker: *Picker = @ptrCast(@alignCast(data));
    picker.finish(index);
}
fn selectionChanged(index: ?usize, data: *anyopaque) void {
    const picker: *Picker = @ptrCast(@alignCast(data));
    if (picker.closing) return;
    if (picker.timer != 0) {
        _ = glib.Source.remove(picker.timer);
        picker.timer = 0;
    }
    picker.pending = index;
    if (index == null) picker.message.as(gtk.Widget).setVisible(0);
    if (index != null) picker.timer = glib.timeoutAdd(75, previewPending, picker);
}
fn previewPending(data: ?*anyopaque) callconv(.c) c_int {
    const picker: *Picker = @ptrCast(@alignCast(data.?));
    picker.timer = 0;
    if (picker.pending) |i| _ = picker.preview(i);
    return 0;
}
fn focusLeft(_: *gtk.EventControllerFocus, picker: *Picker) callconv(.c) void {
    // This signal runs inside GTK's synthesize_focus_change_events. Removing
    // focused widgets or grabbing focus here re-enters the same traversal and
    // violates GTK's crossing invariants. Wait until it has unwound instead.
    if (!picker.closing and picker.focus_leave_source == 0)
        picker.focus_leave_source = glib.idleAdd(dismissAfterFocusChange, picker);
}

fn dismissAfterFocusChange(data: ?*anyopaque) callconv(.c) c_int {
    const picker: *Picker = @ptrCast(@alignCast(data.?));
    picker.focus_leave_source = 0;
    // Focus may have returned before the idle callback ran.
    if (picker.closing or picker.focus.containsFocus() != 0) return 0;
    picker.finish(null);
    return 0;
}
