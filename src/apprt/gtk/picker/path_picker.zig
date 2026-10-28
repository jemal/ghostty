//! The path picker card. It opens at the terminal cursor, lists the files and
//! folders of the typed folder after the recent paths, and pastes the chosen
//! path into the pane. Above the cursor the search box is at the bottom and
//! the best row is next to it. The surface owns the card. Everything runs on
//! the GTK main thread, except `Load`, which reads a folder on its own thread.
const Self = @This();
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const global = @import("../../../global.zig");
const i18n = @import("../../../os/main.zig").i18n;
const key = @import("../key.zig");
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const path = @import("path.zig");
const placement = @import("placement.zig");
const List = @import("list.zig");
const log = std.log.scoped(.gtk_path_picker);

/// When one of these programs runs in the pane, its files are on another
/// machine (Ghostty ignores OSC 7 from other hosts), so the card has no list.
const remote_programs = [_][]const u8{ "ssh", "mosh-client", "et", "docker", "podman", "kubectl", "incus", "lxc" };
/// A folder with more names than this shows only the first ones.
const max_names = 100_000;
const max_visible_rows = 10;
/// With room for fewer rows than this in the pane, the card opens in the
/// middle of the window.
const min_visible_rows = 3;
const width = 360;

/// What the surface knows about the pane when the card opens.
pub const Context = struct {
    pwd: ?[]const u8,
    /// The cursor is at a shell prompt (OSC 133).
    at_prompt: bool,
    /// The cell left of the cursor has text, so the path needs a space first.
    after_text: bool,
    /// The program in the foreground.
    program: ?[]const u8,
    /// The cursor in `pane` coordinates, if it is on the screen.
    anchor: ?placement.Rect,
    pane: *gtk.Overlay,
    /// For panes with too little room.
    window: ?*gtk.Overlay,
};

alloc: std.mem.Allocator,
surface: *Surface,
/// Copies of the context and the recent paths, so that changes to them while
/// the card is open do not move the rows.
arena: std.heap.ArenaAllocator,
home: []const u8,
pwd: ?[]const u8,
shell: path.Shell,
after_text: bool,
remote: bool,
recent: []path.Recent,
/// The accelerator of `insert_path`, so that it also closes the card.
toggle: ?struct { keyval: c_uint, mods: gdk.ModifierType },

frame: *adw.Clamp,
search: *gtk.SearchEntry,
list: *gtk.ListBox,
scroll: *gtk.ScrolledWindow,
message: *gtk.Label,
keys: *gtk.EventControllerKey,
focus: *gtk.EventControllerFocus,
focus_source: c_uint = 0,
scroll_source: c_uint = 0,
overlay: *gtk.Overlay,
anchor: placement.Rect = undefined,
side: placement.Side,
input_offset: ?i32 = null,
/// The card sets the search text itself, so it is not typed text.
setting_text: bool = false,
/// The list rows. They are made when a search first needs them, and kept and
/// filled again for later searches. Above the cursor the rows are filled from
/// the end, so the best row is the last one.
row_widgets: [path.max_rows]RowWidgets = undefined,
made: usize = 0,
/// The markup of a row label, kept between rows.
markup: std.ArrayList(u8) = .empty,

/// The folder of the current names, and the names. `load` is the read in
/// progress, if any.
folder: ?[]u8 = null,
names: ?*Load = null,
load: ?*Load = null,
rows: []path.Row = &.{},

const RowWidgets = struct {
    row: *gtk.ListBoxRow,
    icon: *gtk.Image,
    label: *gtk.Label,
    clock: *gtk.Image,
    /// What the row shows now, so that a row that does not change is not filled again.
    shown: ?path.Row = null,
};

pub fn create(alloc: std.mem.Allocator, surface: *Surface, ctx: Context) !*Self {
    // Copy what the card needs from the pane and the recent list first. These
    // steps can fail; nothing after them can, so no GTK object needs cleanup
    // on an error.
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const home = home: {
        const home = std.mem.trimEnd(u8, std.mem.span(glib.getHomeDir()), "/");
        break :home try arena.allocator().dupe(u8, if (home.len == 0) "/" else home);
    };
    // An empty OSC 7 path is not a folder.
    const pwd: ?[]const u8 = if (ctx.pwd) |pwd| (if (pwd.len > 0) try arena.allocator().dupe(u8, pwd) else null) else null;
    const program = std.fs.path.basename(ctx.program orelse "");
    const remote = for (remote_programs) |name| {
        if (std.mem.eql(u8, program, name)) break true;
    } else false;
    const recent: []path.Recent = recent: {
        if (remote) break :recent &.{};
        const store = Application.default().recentPaths() orelse break :recent &.{};
        const copies = try arena.allocator().alloc(path.Recent, store.list.entries.items.len);
        for (store.list.entries.items, copies) |entry, *copy|
            copy.* = .{ .path = try arena.allocator().dupe(u8, entry.path), .dir = entry.dir, .from = entry.from };
        break :recent copies;
    };
    const self = try alloc.create(Self);
    self.* = .{
        .alloc = alloc,
        .surface = surface,
        .arena = arena,
        .home = home,
        .pwd = pwd,
        .shell = if (!ctx.at_prompt) .plain else if (std.mem.eql(u8, program, "nu")) .nu else if (std.mem.eql(u8, program, "fish")) .fish else .posix,
        .after_text = ctx.after_text,
        .remote = remote,
        .recent = recent,
        .toggle = toggle: {
            const config = Application.default().getConfig();
            defer config.unref();
            const trigger = config.get().keybind.set.getTrigger(.insert_path) orelse break :toggle null;
            var buf: [256]u8 = undefined;
            const accel = (key.accelFromTrigger(&buf, trigger) catch null) orelse break :toggle null;
            var keyval: c_uint = 0;
            var mods: gdk.ModifierType = .{};
            if (gtk.acceleratorParse(accel, &keyval, &mods) == 0) break :toggle null;
            break :toggle .{ .keyval = gdk.keyvalToLower(keyval), .mods = mods };
        },
        .frame = adw.Clamp.new(),
        .search = gtk.SearchEntry.new(),
        .list = gtk.ListBox.new(),
        .scroll = gtk.ScrolledWindow.new(),
        .message = gtk.Label.new(null),
        .keys = gtk.EventControllerKey.new(),
        .focus = gtk.EventControllerFocus.new(),
        .overlay = ctx.pane,
        .side = .below,
    };
    _ = self.frame.as(gobject.Object).refSink();

    // Build the card: the list and the search box, with a line for "Loading…"
    // and other messages. The order depends on the side of the cursor.
    self.frame.setMaximumSize(width);
    self.frame.setTighteningThreshold(width);
    const box = gtk.Box.new(.vertical, 6);
    box.as(gtk.Widget).addCssClass("card");
    box.as(gtk.Widget).addCssClass("native-picker");
    box.as(gtk.Widget).addCssClass("path-picker");
    self.frame.setChild(box.as(gtk.Widget));
    self.search.as(gtk.Widget).setTooltipText(i18n._("Insert Path"));
    self.list.setSelectionMode(.single);
    self.list.setActivateOnSingleClick(1);
    self.scroll.setPolicy(.never, .automatic);
    self.scroll.setPropagateNaturalHeight(1);
    self.scroll.setChild(self.list.as(gtk.Widget));
    self.message.as(gtk.Widget).addCssClass("dim-label");
    self.message.setXalign(0);
    self.message.setWrap(1);
    self.message.as(gtk.Widget).setMarginStart(10);
    self.message.as(gtk.Widget).setMarginEnd(10);
    self.row_widgets[0] = makeRow();
    self.list.append(self.row_widgets[0].row.as(gtk.Widget));
    self.made = 1;

    // Choose the side and the number of rows from the room in the pane.
    // Rex puts the card above the cursor, so that side comes first.
    const row_height = height: {
        self.row_widgets[0].label.setText("Wg");
        var height: c_int = 0;
        self.row_widgets[0].row.as(gtk.Widget).measure(.vertical, width, null, &height, null, null);
        break :height @max(height, 24);
    };
    var search_height: c_int = 0;
    self.search.as(gtk.Widget).measure(.vertical, width, null, &search_height, null, null);
    const chrome = search_height + 6 + 12;
    const pane_height = ctx.pane.as(gtk.Widget).getHeight();
    const margin = 16;
    var rows: c_int = 0;
    if (ctx.anchor) |anchor| {
        self.anchor = anchor;
        const above = @divFloor(anchor.y - margin - 6 - chrome, row_height);
        const below = @divFloor(pane_height - margin - anchor.y - anchor.height - 6 - chrome, row_height);
        self.side = if (above >= @min(4, below)) .above else .below;
        rows = if (self.side == .above) above else below;
    } else {
        self.anchor = .{ .x = 0, .y = margin, .width = 0, .height = 0 };
        rows = @divFloor(pane_height - 2 * margin - chrome, row_height);
    }
    if (rows < min_visible_rows) {
        if (ctx.window) |window| {
            self.overlay = window;
            self.side = .below;
            rows = max_visible_rows;
        }
    }
    self.scroll.setMaxContentHeight(@max(1, @min(rows, max_visible_rows)) * row_height);
    switch (self.side) {
        .below => {
            box.append(self.search.as(gtk.Widget));
            box.append(self.message.as(gtk.Widget));
            box.append(self.scroll.as(gtk.Widget));
        },
        .above => {
            box.append(self.scroll.as(gtk.Widget));
            box.append(self.message.as(gtk.Widget));
            box.append(self.search.as(gtk.Widget));
            self.list.as(gtk.Widget).setValign(.end);
        },
    }

    _ = gtk.Editable.signals.changed.connect(self.search.as(gtk.Editable), *Self, changed, self, .{});
    _ = gtk.SearchEntry.signals.activate.connect(self.search, *Self, activated, self, .{});
    _ = gtk.ListBox.signals.row_activated.connect(self.list, *Self, rowActivated, self, .{});
    _ = gtk.Adjustment.signals.changed.connect(self.scroll.getVadjustment(), *Self, adjustmentChanged, self, .{});
    self.keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(self.keys, *Self, keyPressed, self, .{});
    box.as(gtk.Widget).addController(self.keys.as(gtk.EventController));
    _ = gtk.EventControllerFocus.signals.leave.connect(self.focus, *Self, focusLeft, self, .{});
    box.as(gtk.Widget).addController(self.focus.as(gtk.EventController));

    // Place the card. In the pane it follows the cursor; in the window it is
    // near the top in the middle.
    const frame = self.frame.as(gtk.Widget);
    _ = self.overlay.as(gobject.Object).ref();
    if (self.overlay == ctx.pane) {
        _ = gtk.Overlay.signals.get_child_position.connect(self.overlay, *Self, position, self, .{});
    } else {
        frame.setHalign(.center);
        frame.setValign(.start);
        frame.setSizeRequest(width, -1);
        frame.setMarginTop(48);
    }
    self.overlay.addOverlay(frame);

    // Start with the pane folder, like a shell completion would.
    self.openFolder(pwd orelse home);
    _ = self.search.as(gtk.Widget).grabFocus();
    return self;
}

/// Put a folder in the search box, with "/" at the end, which shows its
/// names. A folder named "~" is not a restart, because the card sets this text.
fn openFolder(self: *Self, dir: []const u8) void {
    const short = path.shortPath(self.alloc, dir, null, self.home) catch return;
    defer self.alloc.free(short);
    const text = std.fmt.allocPrintSentinel(self.alloc, "{s}{s}", .{ short, if (std.mem.endsWith(u8, short, "/")) "" else "/" }, 0) catch return;
    defer self.alloc.free(text);
    const editable = self.search.as(gtk.Editable);
    self.setting_text = true;
    defer self.setting_text = false;
    editable.setText(text);
    editable.setPosition(-1);
}

/// Close the card without pasting. Focus goes back to the pane if the card had it.
pub fn destroy(self: *Self) void {
    if (self.load) |load| load.cancel();
    if (self.names) |names| names.free();
    if (self.focus_source != 0) _ = glib.Source.remove(self.focus_source);
    if (self.scroll_source != 0) _ = glib.Source.remove(self.scroll_source);
    const objects = [_]*gobject.Object{
        self.search.as(gobject.Object),
        self.list.as(gobject.Object),
        self.keys.as(gobject.Object),
        self.focus.as(gobject.Object),
        self.scroll.getVadjustment().as(gobject.Object),
        self.overlay.as(gobject.Object),
    };
    for (objects) |object| _ = gobject.signalHandlersDisconnectMatched(object, .{ .data = true }, 0, 0, null, null, self);

    const frame = self.frame.as(gtk.Widget);
    const root = frame.getRoot();
    const focus = if (root) |r| r.getFocus() else null;
    const had_focus = if (focus) |f| f == frame or f.isAncestor(frame) != 0 else false;
    self.overlay.removeOverlay(frame);
    self.overlay.unref();
    if (had_focus) _ = self.surface.as(gtk.Widget).grabFocus();

    self.alloc.free(self.rows);
    self.markup.deinit(self.alloc);
    if (self.folder) |folder| self.alloc.free(folder);
    self.frame.as(gobject.Object).unref();
    self.arena.deinit();
    self.alloc.destroy(self);
}

/// Read the typed text again: restart the path if needed, read a new folder,
/// and show the rows.
fn changed(_: *gtk.Editable, self: *Self) callconv(.c) void {
    const editable = self.search.as(gtk.Editable);
    const text = std.mem.span(editable.getText());
    const kept = if (self.setting_text) text else path.restart(text);
    if (kept.len != text.len) {
        // Setting the text calls this function again.
        const copy = self.alloc.dupeSentinel(u8, kept, 0) catch return;
        defer self.alloc.free(copy);
        editable.setText(copy);
        editable.setPosition(-1);
        return;
    }
    if (self.remote) return self.showRows();

    const folder = path.resolve(self.alloc, path.split(text).folder, self.home, self.pwd orelse self.home) catch return;
    if (self.folder) |old| {
        if (std.mem.eql(u8, old, folder)) {
            self.alloc.free(folder);
            return self.showRows();
        }
        self.alloc.free(old);
    }
    self.folder = folder;
    if (self.names) |names| names.free();
    self.names = null;
    // The next names can get the same memory, so the rows must be filled again.
    for (self.row_widgets[0..self.made]) |*widgets| widgets.shown = null;
    if (self.load) |load| load.cancel();
    self.load = Load.start(self, folder) catch |err| load: {
        log.warn("unable to read folder err={}", .{err});
        break :load null;
    };
    self.showRows();
}

/// Show the rows for the typed name, or a message when there are none.
fn showRows(self: *Self) void {
    const text = std.mem.span(self.search.as(gtk.Editable).getText());
    const name = path.split(text).name;
    const children: []const path.Child = if (self.names) |names| names.children.items else &.{};
    const rows = path.rank(self.alloc, self.folder orelse "/", name, children, self.recent) catch return;
    self.alloc.free(self.rows);
    self.rows = rows;

    while (self.made < rows.len) : (self.made += 1) {
        self.row_widgets[self.made] = makeRow();
        self.list.append(self.row_widgets[self.made].row.as(gtk.Widget));
    }
    for (self.row_widgets[0..self.made]) |*widgets| {
        const index = self.rowIndex(widgets.row);
        widgets.row.as(gtk.Widget).setVisible(@intFromBool(index < rows.len));
        if (index < rows.len) self.fillRow(widgets, rows[index]);
    }
    if (rows.len > 0) {
        self.list.selectRow(self.row_widgets[if (self.side == .above) self.made - 1 else 0].row);
        self.scrollToBestLater();
    } else {
        // A hidden row stays selected, so unselect it.
        self.list.unselectAll();
    }

    const message: ?[*:0]const u8 = if (self.remote)
        i18n._("Files are on another machine. Type a path to insert it.")
    else if (rows.len > 0)
        null
    else if (self.load != null)
        i18n._("Loading…")
    else if (if (self.names) |names| names.err else null) |err| switch (err) {
        error.FileNotFound, error.NotDir => i18n._("No folder with this name"),
        error.AccessDenied, error.PermissionDenied => i18n._("Cannot open this folder"),
        else => i18n._("Cannot read this folder"),
    } else i18n._("No matches");
    self.message.setText(message orelse "");
    self.message.as(gtk.Widget).setVisible(@intFromBool(message != null));
    self.scroll.as(gtk.Widget).setVisible(@intFromBool(rows.len > 0));
}

/// The rows index of a list row; above the cursor the order is turned over.
fn rowIndex(self: *Self, row: *gtk.ListBoxRow) usize {
    const i: usize = @intCast(row.getIndex());
    return if (self.side == .above) self.made - 1 - i else i;
}

/// GTK scrolls once the row has its place, after the next layout.
fn scrollTo(self: *Self, row: *gtk.ListBoxRow) void {
    const viewport = gobject.ext.cast(gtk.Viewport, self.scroll.getChild() orelse return) orelse return;
    viewport.scrollTo(row.as(gtk.Widget), null);
}

/// While the best row is selected, keep it in view when the list changes:
/// at the top below the cursor, at the bottom above it. `scrollTo` does not
/// work for rows that GTK has just made, and the scrolled window sets the
/// value again while it lays out, so scroll after the layout.
fn scrollToBestLater(self: *Self) void {
    if (self.scroll_source == 0) self.scroll_source = glib.idleAdd(scrollToBest, self);
}

fn adjustmentChanged(_: *gtk.Adjustment, self: *Self) callconv(.c) void {
    self.scrollToBestLater();
}

fn scrollToBest(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(data.?));
    self.scroll_source = 0;
    const row = self.list.getSelectedRow() orelse return 0;
    if (self.rowIndex(row) != 0) return 0;
    const adjustment = self.scroll.getVadjustment();
    adjustment.setValue(if (self.side == .above) adjustment.getUpper() - adjustment.getPageSize() else 0);
    return 0;
}

fn makeRow() RowWidgets {
    const content = gtk.Box.new(.horizontal, 9);
    const widget = content.as(gtk.Widget);
    widget.setMarginStart(8);
    widget.setMarginEnd(8);
    widget.setMarginTop(5);
    widget.setMarginBottom(5);
    const icon = gtk.Image.new();
    content.append(icon.as(gtk.Widget));
    const label = gtk.Label.new(null);
    label.setXalign(0);
    label.setEllipsize(.middle);
    label.as(gtk.Widget).setHexpand(1);
    content.append(label.as(gtk.Widget));
    const clock = gtk.Image.newFromIconName("document-open-recent-symbolic");
    clock.as(gtk.Widget).addCssClass("dim-label");
    content.append(clock.as(gtk.Widget));
    const row = gtk.ListBoxRow.new();
    row.setChild(widget);
    return .{ .row = row, .icon = icon, .label = label, .clock = clock };
}

fn fillRow(self: *Self, widgets: *RowWidgets, row: path.Row) void {
    // While a name is typed in the same folder, labels keep their memory.
    if (widgets.shown) |shown| if (shown.label.ptr == row.label.ptr and shown.label.len == row.label.len and
        shown.match.hits == row.match.hits and shown.dir == row.dir and shown.recent == row.recent) return;
    widgets.shown = row;
    widgets.icon.setFromIconName(if (row.dir) "folder-symbolic" else "text-x-generic-symbolic");
    const icon = widgets.icon.as(gtk.Widget);
    icon.removeCssClass(if (row.dir) "file" else "folder");
    icon.addCssClass(if (row.dir) "folder" else "file");

    // Matched letters are bold. Only ASCII bytes can match a typed letter
    // alone, so the markup never splits a character.
    if (std.unicode.utf8ValidateSlice(row.label)) markup: {
        const out = &self.markup;
        out.clearRetainingCapacity();
        for (row.label, 0..) |c, i| {
            const hit = i < 64 and c < 0x80 and row.match.hits & (@as(u64, 1) << @intCast(i)) != 0;
            if (hit) out.appendSlice(self.alloc, "<b>") catch break :markup;
            const escaped: ?[]const u8 = switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                else => null,
            };
            (if (escaped) |e| out.appendSlice(self.alloc, e) else out.append(self.alloc, c)) catch break :markup;
            if (hit) out.appendSlice(self.alloc, "</b>") catch break :markup;
        }
        out.append(self.alloc, 0) catch break :markup;
        widgets.label.setMarkup(out.items[0 .. out.items.len - 1 :0]);
    } else {
        const valid = glib.utf8MakeValid(@ptrCast(row.label.ptr), @intCast(row.label.len));
        defer glib.free(valid);
        widgets.label.setText(valid);
    }

    const clock = widgets.clock.as(gtk.Widget);
    clock.setVisible(@intFromBool(row.recent != null));
    if (row.recent) |r| clock.setTooltipText(switch (self.recent[r].from) {
        .pane => i18n._("A pane was in this folder"),
        .picked => i18n._("Picked here before"),
    });
}

fn activated(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
    self.accept(self.list.getSelectedRow(), false);
}

fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
    self.accept(row, false);
}

/// Paste the chosen path, or the typed text when no row is chosen. With
/// `into_folder`, a folder row goes into the folder. Pasting closes the card,
/// which frees it, so nothing reads `self` after `paste`.
fn accept(self: *Self, list_row: ?*gtk.ListBoxRow, into_folder: bool) void {
    const alloc = self.alloc;
    const editable = self.search.as(gtk.Editable);
    const index = if (list_row) |r| self.rowIndex(r) else self.rows.len;
    const row = if (index < self.rows.len) self.rows[index] else {
        const typed = std.mem.span(editable.getText());
        if (into_folder or typed.len == 0 or !path.insertable(typed)) return;
        return self.paste(typed, .typed);
    };
    const folder = self.folder orelse return;
    const full = std.fs.path.join(alloc, &.{ folder, row.label }) catch return;
    defer alloc.free(full);
    if (!path.insertable(full)) return;

    if (into_folder and row.dir) return self.openFolder(full);
    if (Application.default().recentPaths()) |store| store.add(full, row.dir, .picked);
    const text = path.shortPath(alloc, full, self.pwd, self.home) catch return;
    defer alloc.free(text);
    self.paste(text, if (row.dir) .folder else .file);
}

/// Close the card, then paste, so that the pane has focus for the text.
/// `text` must not belong to the card.
fn paste(self: *Self, text: []const u8, kind: path.Kind) void {
    const alloc = self.alloc;
    const surface = self.surface;
    const formatted = path.format(alloc, text, kind, self.shell, if (self.remote) null else self.home, self.after_text) catch return;
    defer alloc.free(formatted);
    surface.closePathPicker();
    surface.pasteText(formatted);
}

fn keyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, mods: gdk.ModifierType, self: *Self) callconv(.c) c_int {
    if (self.toggle) |toggle| {
        const mask = gtk.acceleratorGetDefaultModMask();
        const pressed: c_uint = @as(c_uint, @bitCast(mods)) & @as(c_uint, @bitCast(mask));
        if (gdk.keyvalToLower(keyval) == toggle.keyval and pressed == @as(c_uint, @bitCast(toggle.mods))) {
            self.surface.closePathPicker();
            return 1;
        }
    }
    // Ctrl+Tab and Alt+Tab are other keys, for example the next tab.
    const tab = !mods.control_mask and !mods.alt_mask;
    switch (keyval) {
        gdk.KEY_Escape => self.surface.closePathPicker(),
        // Shift+Tab goes up one folder; Tab goes into the selected folder.
        gdk.KEY_Tab, gdk.KEY_ISO_Left_Tab => if (!tab)
            return 0
        else if (keyval == gdk.KEY_ISO_Left_Tab or mods.shift_mask)
            self.openFolder(std.fs.path.dirname(self.folder orelse return 1) orelse return 1)
        else if (self.list.getSelectedRow()) |row|
            self.accept(row, true),
        gdk.KEY_Up, gdk.KEY_Down => {
            // Up and Down follow the screen, in both orders.
            const current = self.list.getSelectedRow() orelse return 1;
            const step: c_int = if (keyval == gdk.KEY_Up) -1 else 1;
            const next = self.list.getRowAtIndex(current.getIndex() + step) orelse return 1;
            if (self.rowIndex(next) >= self.rows.len) return 1;
            self.list.selectRow(next);
            self.scrollTo(next);
        },
        else => return 0,
    }
    return 1;
}

fn focusLeft(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
    // This runs inside GTK's focus change. Removing the card now would change
    // focus again inside it, so wait until it ends.
    if (self.focus_source == 0) self.focus_source = glib.idleAdd(closeAfterFocusLeft, self);
}

fn closeAfterFocusLeft(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(data.?));
    self.focus_source = 0;
    // Focus may have come back before this ran.
    if (self.focus.containsFocus() == 0) self.surface.closePathPicker();
    return 0;
}

fn position(overlay: *gtk.Overlay, widget: *gtk.Widget, allocation: *gdk.Rectangle, self: *Self) callconv(.c) c_int {
    if (widget != self.frame.as(gtk.Widget)) return 0;
    allocation.* = List.placeCard(overlay, widget, self.search, self.anchor, &self.input_offset, 0, self.side);
    return 1;
}

/// A folder read on its own thread. The card calls `cancel` when it no longer
/// wants the result: the read stops early, and the result is freed on the
/// main thread.
const Load = struct {
    picker: ?*Self,
    cancelled: std.atomic.Value(bool) = .init(false),
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    folder: []const u8,
    /// Recent paths below the folder, to check that they still exist.
    recent: []const []const u8,
    children: std.ArrayList(path.Child) = .empty,
    missing: std.ArrayList([]const u8) = .empty,
    err: ?anyerror = null,

    fn start(picker: *Self, folder: []const u8) !*Load {
        const self = try picker.alloc.create(Load);
        errdefer picker.alloc.destroy(self);
        self.* = .{ .picker = picker, .alloc = picker.alloc, .arena = .init(picker.alloc), .folder = undefined, .recent = &.{} };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.folder = try arena.dupe(u8, folder);
        var recent: std.ArrayList([]const u8) = .empty;
        for (picker.recent) |entry| if (path.inside(entry.path, folder)) try recent.append(arena, try arena.dupe(u8, entry.path));
        self.recent = recent.items;
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.detach();
        return self;
    }

    fn cancel(self: *Load) void {
        self.picker = null;
        self.cancelled.store(true, .monotonic);
    }

    fn free(self: *Load) void {
        self.children.deinit(self.alloc);
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    fn run(self: *Load) void {
        self.read() catch |err| {
            self.err = err;
        };
        _ = glib.idleAdd(done, self);
    }

    fn read(self: *Load) !void {
        const io = global.io();
        const arena = self.arena.allocator();
        for (self.recent) |recent| {
            if (self.cancelled.load(.monotonic)) return error.Canceled;
            std.Io.Dir.accessAbsolute(io, recent, .{}) catch |err| switch (err) {
                error.FileNotFound => try self.missing.append(arena, recent),
                else => {},
            };
        }
        var dir = try std.Io.Dir.cwd().openDir(io, self.folder, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (self.children.items.len >= max_names) break;
            if (self.cancelled.load(.monotonic)) return error.Canceled;
            // A link to a folder is a folder; a broken link is a file. Some
            // file systems do not give the kind, so look it up.
            const dir_kind = switch (entry.kind) {
                .directory => true,
                .sym_link, .unknown => if (dir.statFile(io, entry.name, .{})) |stat| stat.kind == .directory else |_| false,
                else => false,
            };
            // The list is not in the arena, so that it can grow in place.
            try self.children.append(self.alloc, .{ .name = try arena.dupe(u8, entry.name), .dir = dir_kind });
        }
    }

    fn done(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Load = @ptrCast(@alignCast(data.?));
        const picker = self.picker orelse {
            self.free();
            return 0;
        };
        picker.load = null;
        picker.names = self;
        // Recent paths that are gone are left out now and removed from the list.
        for (self.missing.items) |gone| {
            for (picker.recent, 0..) |entry, i| if (std.mem.eql(u8, entry.path, gone)) {
                std.mem.copyForwards(path.Recent, picker.recent[i..], picker.recent[i + 1 ..]);
                picker.recent.len -= 1;
                break;
            };
            if (Application.default().recentPaths()) |store| store.remove(gone);
        }
        picker.showRows();
        return 0;
    }
};
