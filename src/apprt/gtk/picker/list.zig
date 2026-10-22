//! Reusable searchable single-choice widget. IDs remain in the caller's model.
const Self = @This();
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const glib = @import("glib");
const gdk = @import("gdk");
const placement = @import("placement.zig");
const gobject = @import("gobject");
const protocol = @import("protocol.zig");
const i18n = @import("../../../os/main.zig").i18n;

alloc: std.mem.Allocator,
box: *gtk.Box,
frame: *adw.Clamp,
search: *gtk.SearchEntry,
list: *gtk.ListBox,
scroll: *gtk.ScrolledWindow,
empty: *gtk.Label,
rows: []Row,
callback: *const fn (?usize, *anyopaque) void,
userdata: *anyopaque,
anchor: ?placement.Rect = null,
anchor_overlay: ?*gtk.Overlay = null,
anchor_handler: c_ulong = 0,
input_offset: ?i32 = null,
const Row = struct { widget: *gtk.ListBoxRow, folded: [*:0]u8 };

pub fn init(self: *Self, alloc: std.mem.Allocator, request: protocol.Request, callback: *const fn (?usize, *anyopaque) void, userdata: *anyopaque) !void {
    const rows = try alloc.alloc(Row, request.choices.len);
    errdefer alloc.free(rows);
    // Clamp the card's width while still allowing it to shrink in small panes.
    // The result list contributes its natural height up to a scrolling limit.
    const frame = adw.Clamp.new();
    _ = frame.as(@import("gobject").Object).refSink();
    errdefer frame.as(@import("gobject").Object).unref();
    const max_width: c_int = if (request.placement == .cursor) 360 else 480;
    frame.setMaximumSize(max_width);
    frame.setTighteningThreshold(max_width);
    const frame_widget = frame.as(gtk.Widget);
    frame_widget.setValign(.center);
    frame_widget.setMarginStart(16);
    frame_widget.setMarginEnd(16);
    frame_widget.setMarginTop(16);
    frame_widget.setMarginBottom(16);
    const box = gtk.Box.new(.vertical, 8);
    const widget = box.as(gtk.Widget);
    widget.addCssClass("card");
    widget.addCssClass("native-picker");
    frame.setChild(widget);
    const title_z = try alloc.dupeSentinel(u8, request.title, 0);
    defer alloc.free(title_z);
    const search = gtk.SearchEntry.new();
    const hint = if (std.mem.eql(u8, request.placeholder, "Search…")) request.title else request.placeholder;
    const placeholder = try alloc.dupeSentinel(u8, hint, 0);
    defer alloc.free(placeholder);
    search.setPlaceholderText(placeholder);
    search.as(gtk.Widget).setTooltipText(title_z);
    box.append(search.as(gtk.Widget));
    const list = gtk.ListBox.new();
    list.setSelectionMode(.single);
    list.setActivateOnSingleClick(1);
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.setPropagateNaturalHeight(1);
    scroll.setMaxContentHeight(280);
    scroll.setChild(list.as(gtk.Widget));
    box.append(scroll.as(gtk.Widget));
    const empty = gtk.Label.new(i18n._("No matches"));
    empty.as(gtk.Widget).setVisible(0);
    box.append(empty.as(gtk.Widget));
    var initialized: usize = 0;
    errdefer for (rows[0..initialized]) |row| glib.free(row.folded);
    for (request.choices, 0..) |choice, i| {
        const text = try alloc.dupeSentinel(u8, choice.label, 0);
        defer alloc.free(text);
        const description = try alloc.dupeSentinel(u8, choice.description, 0);
        defer alloc.free(description);
        const row = gtk.ListBoxRow.new();
        const content = gtk.Box.new(.horizontal, 12);
        content.as(gtk.Widget).setMarginStart(10);
        content.as(gtk.Widget).setMarginEnd(10);
        content.as(gtk.Widget).setMarginTop(6);
        content.as(gtk.Widget).setMarginBottom(6);
        const label = gtk.Label.new(text);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        label.setEllipsize(.end);
        content.append(label.as(gtk.Widget));
        if (choice.description.len > 0) {
            const subtitle = gtk.Label.new(description);
            subtitle.setXalign(1);
            subtitle.setMaxWidthChars(28);
            subtitle.as(gtk.Widget).addCssClass("caption");
            subtitle.setEllipsize(.end);
            subtitle.as(gtk.Widget).addCssClass("dim-label");
            content.append(subtitle.as(gtk.Widget));
        }
        row.setChild(content.as(gtk.Widget));
        list.append(row.as(gtk.Widget));
        const combined = try std.fmt.allocPrintSentinel(alloc, "{s} {s}", .{ choice.label, choice.description }, 0);
        defer alloc.free(combined);
        rows[i] = .{ .widget = row, .folded = glib.utf8Casefold(combined, -1) };
        initialized += 1;
    }
    if (request.placement == .cursor) {
        // Measure rows so six fit with the current font/theme, including their
        // margins. Keep long lists scrollable rather than changing row spacing.
        var six_rows: c_int = 0;
        for (rows[0..@min(rows.len, 6)]) |row| {
            var height: c_int = 0;
            row.widget.as(gtk.Widget).measure(.vertical, max_width - 12, null, &height, null, null);
            six_rows += height;
        }
        scroll.setMaxContentHeight(@max(1, six_rows));
    }
    self.* = .{ .alloc = alloc, .box = box, .frame = frame, .search = search, .list = list, .scroll = scroll, .empty = empty, .rows = rows, .callback = callback, .userdata = userdata };
    _ = gtk.Editable.signals.changed.connect(search.as(gtk.Editable), *Self, changed, self, .{});
    _ = gtk.SearchEntry.signals.activate.connect(search, *Self, activated, self, .{});
    _ = gtk.SearchEntry.signals.stop_search.connect(search, *Self, stopped, self, .{});
    _ = gtk.ListBox.signals.row_activated.connect(list, *Self, rowActivated, self, .{});
    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Self, keyPressed, self, .{});
    widget.addController(keys.as(gtk.EventController));
    list.selectRow(rows[0].widget);
}

/// Snapshot the cursor once; filtering and background terminal output must not
/// move the anchor. GTK remeasures the card on filter changes and pane resize.
pub fn anchorAt(self: *Self, overlay: *gtk.Overlay, rect: placement.Rect) void {
    self.anchor = rect;
    _ = overlay.as(gobject.Object).ref();
    self.anchor_overlay = overlay;
    const widget = self.frame.as(gtk.Widget);
    widget.setMarginStart(0);
    widget.setMarginEnd(0);
    widget.setMarginTop(0);
    widget.setMarginBottom(0);
    self.anchor_handler = gtk.Overlay.signals.get_child_position.connect(overlay, *Self, position, self, .{});
}

fn position(overlay: *gtk.Overlay, widget: *gtk.Widget, allocation: *gdk.Rectangle, self: *Self) callconv(.c) c_int {
    if (widget != self.frame.as(gtk.Widget)) return 0;
    const pane = overlay.as(gtk.Widget);
    const width = @max(1, @min(360, pane.getWidth() - 32));
    var minimum: c_int = 0;
    var natural: c_int = 0;
    widget.measure(.vertical, width, &minimum, &natural, null, null);
    if (self.input_offset == null) {
        // The overlay asks for position before allocating this child. Lay out
        // its contents at the requested width first, then measure the actual
        // GtkText insertion point, including the icon, CSS padding and border.
        // GTK applies the final translated allocation after this callback.
        widget.allocate(width, natural, -1, null);
        if (self.search.as(gtk.Editable).getDelegate()) |delegate| {
            if (gobject.ext.cast(gtk.Text, delegate)) |text| {
                var caret: @import("graphene").Rect = undefined;
                text.computeCursorExtents(0, &caret, null);
                var origin: @import("graphene").Point = undefined;
                if (text.as(gtk.Widget).computePoint(widget, &caret.f_origin, &origin) != 0)
                    self.input_offset = @intFromFloat(@round(origin.f_x));
            }
        }
    }
    const rect = placement.place(pane.getWidth(), pane.getHeight(), self.anchor.?, self.input_offset orelse 0, natural, @max(minimum, 96));
    allocation.* = .{ .f_x = rect.x, .f_y = rect.y, .f_width = rect.width, .f_height = rect.height };
    return 1;
}

pub fn deinit(self: *Self) void {
    if (self.anchor_overlay) |overlay| {
        gobject.signalHandlerDisconnect(overlay.as(gobject.Object), self.anchor_handler);
        overlay.unref();
    }
    for (self.rows) |row| glib.free(row.folded);
    self.alloc.free(self.rows);
    self.frame.as(@import("gobject").Object).unref();
}

fn changed(_: *gtk.Editable, self: *Self) callconv(.c) void {
    const query = glib.utf8Casefold(self.search.as(gtk.Editable).getText(), -1);
    defer glib.free(query);
    var first: ?*gtk.ListBoxRow = null;
    for (self.rows) |row| {
        const matches = std.mem.indexOf(u8, std.mem.span(row.folded), std.mem.span(query)) != null;
        row.widget.as(gtk.Widget).setVisible(@intFromBool(matches));
        if (matches and first == null) first = row.widget;
    }
    self.list.selectRow(first);
    self.scroll.getVadjustment().setValue(0);
    self.empty.as(gtk.Widget).setVisible(@intFromBool(first == null));
}
fn activated(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
    rowActivated(self.list, self.list.getSelectedRow() orelse return, self);
}
fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
    for (self.rows, 0..) |entry, i| if (entry.widget == row) {
        self.callback(i, self.userdata);
        return;
    };
}
fn stopped(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
    self.callback(null, self.userdata);
}
fn keyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, mods: gdk.ModifierType, self: *Self) callconv(.c) c_int {
    if (keyval == gdk.KEY_Escape) {
        self.callback(null, self.userdata);
        return 1;
    }
    if (keyval == gdk.KEY_Tab or keyval == gdk.KEY_ISO_Left_Tab) {
        // Tab cycles every visible choice, wrapping at either end. Keep the
        // query focused so typing can refine it without traversing other panes.
        const backwards = keyval == gdk.KEY_ISO_Left_Tab or mods.shift_mask;
        const current = self.list.getSelectedRow();
        var first: ?*gtk.ListBoxRow = null;
        var last: ?*gtk.ListBoxRow = null;
        var previous: ?*gtk.ListBoxRow = null;
        var next: ?*gtk.ListBoxRow = null;
        var seen_current = false;
        for (self.rows) |entry| {
            if (entry.widget.as(gtk.Widget).getVisible() == 0) continue;
            if (first == null) first = entry.widget;
            last = entry.widget;
            if (entry.widget == current) {
                if (backwards) next = previous;
                seen_current = true;
            } else if (!backwards and seen_current and next == null) next = entry.widget;
            previous = entry.widget;
        }
        if (next orelse (if (backwards) last else first)) |row| self.selectRow(row);
        if (!self.focusWithin(self.search.as(gtk.Widget))) _ = self.search.as(gtk.Widget).grabFocus();
        return 1;
    }
    if (keyval != gdk.KEY_Up and keyval != gdk.KEY_Down) return 0;
    const current = self.list.getSelectedRow();
    var next: ?*gtk.ListBoxRow = null;
    if (keyval == gdk.KEY_Down) {
        var seen = current == null;
        for (self.rows) |row| {
            if (seen and row.widget.as(gtk.Widget).getVisible() != 0) {
                next = row.widget;
                break;
            }
            if (row.widget == current) seen = true;
        }
    } else {
        for (self.rows) |row| {
            if (row.widget == current) break;
            if (row.widget.as(gtk.Widget).getVisible() != 0) next = row.widget;
        }
    }
    if (next) |row| self.selectRow(row);
    return 1;
}

fn focusWithin(self: *Self, widget: *gtk.Widget) bool {
    const root = self.frame.as(gtk.Widget).getRoot() orelse return false;
    const focus = root.getFocus() orelse return false;
    return focus == widget or focus.isAncestor(widget) != 0;
}

fn selectRow(self: *Self, row: *gtk.ListBoxRow) void {
    self.list.selectRow(row);
    if (self.focusWithin(self.list.as(gtk.Widget))) _ = row.as(gtk.Widget).grabFocus();
    var rect: gtk.Allocation = undefined;
    row.as(gtk.Widget).getAllocation(&rect);
    const adjustment = self.scroll.getVadjustment();
    const top: f64 = @floatFromInt(rect.f_y);
    const bottom: f64 = @floatFromInt(rect.f_y + rect.f_height);
    const value = adjustment.getValue();
    if (top < value) adjustment.setValue(top) else if (bottom > value + adjustment.getPageSize()) adjustment.setValue(bottom - adjustment.getPageSize());
}
