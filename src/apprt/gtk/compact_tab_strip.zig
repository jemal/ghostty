//! Content-sized presentation for AdwTabView. The view still owns all tabs,
//! selection, close confirmation and transfers; this strip only presents them.
const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const Common = @import("class.zig").Common;
const Window = @import("class/window.zig").Window;
const ext = @import("ext.zig");
const layout = @import("compact_tab_layout.zig");

pub const State = struct {
    view: ?*adw.TabView = null,
    box: *gtk.Box = undefined,
    scroll: *gtk.ScrolledWindow = undefined,
    drop: *gtk.DropTarget = undefined,
    wheel: *gtk.EventControllerScroll = undefined,
    inverted: bool = false,
    controls: *gtk.Box = undefined,
    previous: *gtk.Button = undefined,
    next: *gtk.Button = undefined,
    picker_button: *gtk.Button = undefined,
    picker: *gtk.Popover = undefined,
    search: *gtk.SearchEntry = undefined,
    results: *gtk.Box = undefined,
    overflow_idle: ?c_uint = null,

    pub fn init(self: *State, view: *adw.TabView, box: *gtk.Box, scroll: *gtk.ScrolledWindow) void {
        self.* = .{ .view = view, .box = box, .scroll = scroll };
        _ = adw.TabView.signals.page_attached.connect(view, *State, pagesChanged, self, .{ .after = true });
        _ = adw.TabView.signals.page_detached.connect(view, *State, pagesChanged, self, .{ .after = true });
        _ = adw.TabView.signals.page_reordered.connect(view, *State, pagesChanged, self, .{ .after = true });
        _ = gobject.Object.signals.notify.connect(view, *State, selectionChanged, self, .{ .detail = "selected-page", .after = true });
        _ = gtk.Widget.signals.map.connect(scroll, *State, mapped, self, .{});
        self.drop = gtk.DropTarget.new(adw.TabPage.getGObjectType(), .{ .move = true });
        _ = gtk.DropTarget.signals.drop.connect(self.drop, *State, dropped, self, .{});
        _ = gtk.DropTarget.signals.motion.connect(self.drop, *State, dragMotion, self, .{});
        _ = gtk.DropTarget.signals.leave.connect(self.drop, *State, dragLeave, self, .{});
        scroll.as(gtk.Widget).addController(self.drop.as(gtk.EventController));
        self.wheel = gtk.EventControllerScroll.new(.{ .vertical = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(self.wheel, *State, scrolled, self, .{});
        scroll.as(gtk.Widget).addController(self.wheel.as(gtk.EventController));
        self.controls = gtk.Box.new(.horizontal, 2);
        self.controls.as(gtk.Widget).addCssClass("compact-tab-tools");
        const parent = gobject.ext.cast(gtk.Box, scroll.as(gtk.Widget).getParent().?).?;
        parent.insertChildAfter(self.controls.as(gtk.Widget), scroll.as(gtk.Widget));
        self.previous = self.tool("go-previous-symbolic", "Scroll tabs left");
        self.next = self.tool("go-next-symbolic", "Scroll tabs right");
        self.picker_button = self.tool("pan-down-symbolic", "Find a tab");
        _ = gtk.Button.signals.clicked.connect(self.previous, *State, scrollPrevious, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.next, *State, scrollNext, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.picker_button, *State, openPicker, self, .{});
        self.picker = gtk.Popover.new();
        self.picker.setHasArrow(0);
        self.picker.as(gtk.Widget).setParent(self.picker_button.as(gtk.Widget));
        const content = gtk.Box.new(.vertical, 6);
        content.as(gtk.Widget).setSizeRequest(280, -1);
        self.search = gtk.SearchEntry.new();
        self.search.setPlaceholderText("Find a tab…");
        content.append(self.search.as(gtk.Widget));
        self.results = gtk.Box.new(.vertical, 2);
        const results_scroll = gtk.ScrolledWindow.new();
        results_scroll.setPolicy(.never, .automatic);
        results_scroll.setPropagateNaturalHeight(1);
        results_scroll.setMaxContentHeight(320);
        results_scroll.setChild(self.results.as(gtk.Widget));
        content.append(results_scroll.as(gtk.Widget));
        self.picker.setChild(content.as(gtk.Widget));
        _ = gtk.SearchEntry.signals.search_changed.connect(self.search, *State, filterPicker, self, .{});
        _ = gtk.SearchEntry.signals.activate.connect(self.search, *State, activateFirst, self, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(self.search, *State, closePicker, self, .{});
        const search_keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(search_keys, *State, pickerKey, self, .{});
        self.search.as(gtk.Widget).addController(search_keys.as(gtk.EventController));
        const adjustment = scroll.getHadjustment();
        _ = gtk.Adjustment.signals.changed.connect(adjustment, *State, adjustmentChanged, self, .{});
        _ = gtk.Adjustment.signals.value_changed.connect(adjustment, *State, adjustmentChanged, self, .{});
        self.sync();
    }

    fn tool(self: *State, icon: [*:0]const u8, tooltip: [*:0]const u8) *gtk.Button {
        const button = gtk.Button.newFromIconName(icon);
        button.as(gtk.Widget).setTooltipText(tooltip);
        button.as(gtk.Widget).setValign(.center);
        self.controls.append(button.as(gtk.Widget));
        return button;
    }

    fn adjustmentChanged(_: *gtk.Adjustment, self: *State) callconv(.c) void {
        // Adjustment notifications can arrive inside size allocation. Changing
        // button visibility there invalidates an ancestor's active measurement.
        if (self.overflow_idle == null) self.overflow_idle = glib.idleAdd(updateOverflow, self);
    }

    fn updateOverflow(data: ?*anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(data orelse return 0));
        self.overflow_idle = null;
        const adjustment = self.scroll.getHadjustment();
        const maximum = @max(0, adjustment.getUpper() - adjustment.getPageSize());
        self.previous.as(gtk.Widget).setVisible(@intFromBool(maximum > 1));
        self.next.as(gtk.Widget).setVisible(@intFromBool(maximum > 1));
        self.previous.as(gtk.Widget).setSensitive(@intFromBool(adjustment.getValue() > 1));
        self.next.as(gtk.Widget).setSensitive(@intFromBool(adjustment.getValue() < maximum - 1));
        return 0;
    }

    fn scrollBy(self: *State, direction: f64) void {
        const adjustment = self.scroll.getHadjustment();
        adjustment.setValue(std.math.clamp(adjustment.getValue() + direction * adjustment.getPageSize() * 0.7, 0, @max(0, adjustment.getUpper() - adjustment.getPageSize())));
    }
    fn scrollPrevious(_: *gtk.Button, self: *State) callconv(.c) void {
        self.scrollBy(-1);
    }
    fn scrollNext(_: *gtk.Button, self: *State) callconv(.c) void {
        self.scrollBy(1);
    }
    fn openPicker(_: *gtk.Button, self: *State) callconv(.c) void {
        self.search.as(gtk.Editable).setText("");
        self.populatePicker();
        self.picker.popup();
        _ = self.search.as(gtk.Widget).grabFocus();
    }
    fn populatePicker(self: *State) void {
        while (self.results.as(gtk.Widget).getFirstChild()) |child| self.results.remove(child);
        const view = self.view orelse return;
        const query = self.search.as(gtk.Editable).getText();
        const folded_query = glib.utf8Casefold(query, -1);
        defer glib.free(folded_query);
        for (0..@intCast(view.getNPages())) |index| {
            const page = view.getNthPage(@intCast(index));
            const folded_title = glib.utf8Casefold(page.getTitle(), -1);
            defer glib.free(folded_title);
            if (std.mem.indexOf(u8, std.mem.span(folded_title), std.mem.span(folded_query)) == null) continue;
            const button = gtk.Button.newWithLabel(page.getTitle());
            if (gobject.ext.cast(gtk.Label, button.getChild().?)) |label| {
                label.setEllipsize(.end);
                label.setMaxWidthChars(36);
                label.setXalign(0);
            }
            button.as(gtk.Widget).setTooltipText(page.getTitle());
            button.as(gtk.Widget).addCssClass("flat");
            if (page.getSelected() != 0) button.as(gtk.Widget).addCssClass("suggested-action");
            _ = gtk.Button.signals.clicked.connect(button, *adw.TabPage, pickerSelected, Chip.refPage(page), .{ .destroyData = Chip.unrefPage });
            self.results.append(button.as(gtk.Widget));
        }
        if (self.results.as(gtk.Widget).getFirstChild() == null) self.results.append(gtk.Label.new("No matching tabs").as(gtk.Widget));
    }
    fn filterPicker(_: *gtk.SearchEntry, self: *State) callconv(.c) void {
        self.populatePicker();
    }
    fn closePicker(_: *gtk.SearchEntry, self: *State) callconv(.c) void {
        self.picker.popdown();
    }
    fn activateFirst(_: *gtk.SearchEntry, self: *State) callconv(.c) void {
        // SearchEntry debounces search-changed; Enter must use the current text.
        self.populatePicker();
        const child = self.results.as(gtk.Widget).getFirstChild() orelse return;
        if (gobject.ext.cast(gtk.Button, child)) |button| gobject.signalEmitByName(button.as(gobject.Object), "clicked");
    }
    fn pickerKey(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, _: gdk.ModifierType, self: *State) callconv(.c) c_int {
        if (key != gdk.KEY_Down) return 0;
        self.populatePicker();
        const first = self.results.as(gtk.Widget).getFirstChild() orelse return 0;
        return first.grabFocus();
    }

    fn pickerSelected(button: *gtk.Button, page: *adw.TabPage) callconv(.c) void {
        const popover = ext.getAncestor(gtk.Popover, button.as(gtk.Widget));
        if (popover) |value| value.popdown();
        if (pageView(page)) |view| view.setSelectedPage(page);
    }

    pub fn deinit(self: *State) void {
        const view = self.view orelse return;
        self.view = null;
        if (self.overflow_idle) |source| {
            _ = glib.Source.remove(source);
            self.overflow_idle = null;
        }
        _ = gobject.signalHandlersDisconnectMatched(self.scroll.getHadjustment().as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
        self.picker.as(gtk.Widget).unparent();
        const parent = gobject.ext.cast(gtk.Box, self.controls.as(gtk.Widget).getParent().?).?;
        parent.remove(self.controls.as(gtk.Widget));
        _ = gobject.signalHandlersDisconnectMatched(view.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
        _ = gobject.signalHandlersDisconnectMatched(self.scroll.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
        self.scroll.as(gtk.Widget).removeController(self.drop.as(gtk.EventController));
        self.scroll.as(gtk.Widget).removeController(self.wheel.as(gtk.EventController));
        while (self.box.as(gtk.Widget).getFirstChild()) |child| self.box.remove(child);
    }

    fn sync(self: *State) void {
        const view = self.view orelse return;
        // Preserve widgets across title changes, selection and reorders. In
        // particular, an ongoing drag must not rebuild its source controller.
        var previous: ?*gtk.Widget = null;
        for (0..@intCast(view.getNPages())) |index| {
            const page = view.getNthPage(@intCast(index));
            const chip = self.find(page) orelse Chip.new(page);
            chip.as(gtk.Box).reorderChildAfter(chip.private().close_slot.as(gtk.Widget), if (self.inverted) null else chip.private().select.as(gtk.Widget));
            if (self.inverted) chip.as(gtk.Widget).addCssClass("inverted") else chip.as(gtk.Widget).removeCssClass("inverted");
            if (chip.as(gtk.Widget).getParent() == null) self.box.append(chip.as(gtk.Widget));
            self.box.reorderChildAfter(chip.as(gtk.Widget), previous);
            previous = chip.as(gtk.Widget);
        }
        var child = self.box.as(gtk.Widget).getFirstChild();
        while (child) |widget| {
            child = widget.getNextSibling();
            const chip = gobject.ext.cast(Chip, widget).?;
            if (pageView(chip.private().page.?) != view) self.box.remove(widget);
        }
        self.revealSelected();
        if (self.picker.as(gtk.Widget).getVisible() != 0) self.populatePicker();
    }

    pub fn setVisible(self: *State, visible: bool) void {
        self.controls.as(gtk.Widget).setVisible(@intFromBool(visible));
        if (!visible) self.picker.popdown();
    }

    pub fn configure(self: *State, inverted: bool) void {
        self.inverted = inverted;
        self.sync();
    }

    fn find(self: *State, page: *adw.TabPage) ?*Chip {
        var child = self.box.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            const chip = gobject.ext.cast(Chip, widget).?;
            if (chip.private().page == page) return chip;
        }
        return null;
    }

    fn revealSelected(self: *State) void {
        const page = (self.view orelse return).getSelectedPage() orelse return;
        const chip = self.find(page) orelse return;
        const viewport = gobject.ext.cast(gtk.Viewport, self.scroll.getChild() orelse return) orelse return;
        viewport.scrollTo(chip.as(gtk.Widget), null);
    }

    fn pagesChanged(_: *adw.TabView, _: *adw.TabPage, _: c_int, self: *State) callconv(.c) void {
        self.sync();
    }

    fn selectionChanged(view: *adw.TabView, _: *gobject.ParamSpec, self: *State) callconv(.c) void {
        if (view.getSelectedPage()) |page| page.setNeedsAttention(0);
        self.revealSelected();
    }

    fn mapped(_: *gtk.ScrolledWindow, self: *State) callconv(.c) void {
        self.revealSelected();
    }

    fn scrolled(_: *gtk.EventControllerScroll, _: f64, dy: f64, self: *State) callconv(.c) c_int {
        const adjustment = self.scroll.getHadjustment();
        const maximum = @max(0, adjustment.getUpper() - adjustment.getPageSize());
        if (maximum == 0) return 0;
        adjustment.setValue(std.math.clamp(adjustment.getValue() + dy * 40, 0, maximum));
        return 1;
    }

    fn dragMotion(_: *gtk.DropTarget, x: f64, _: f64, self: *State) callconv(.c) gdk.DragAction {
        const adjustment = self.scroll.getHadjustment();
        const width: f64 = @floatFromInt(self.scroll.as(gtk.Widget).getWidth());
        const delta: f64 = if (x < 24) -20 else if (x > width - 24) 20 else 0;
        adjustment.setValue(std.math.clamp(adjustment.getValue() + delta, 0, @max(0, adjustment.getUpper() - adjustment.getPageSize())));
        self.clearDrop();
        const slot = self.dropSlot(x);
        var child = self.box.as(gtk.Widget).getFirstChild();
        var index: usize = 0;
        while (child) |widget| : (index += 1) {
            child = widget.getNextSibling();
            if (index == slot) {
                widget.addCssClass("drop-before");
                break;
            }
            if (child == null) widget.addCssClass("drop-after");
        }
        return .{ .move = true };
    }

    fn dragLeave(_: *gtk.DropTarget, self: *State) callconv(.c) void {
        self.clearDrop();
    }

    fn clearDrop(self: *State) void {
        var child = self.box.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            widget.removeCssClass("drop-before");
            widget.removeCssClass("drop-after");
        }
    }

    fn dropSlot(self: *State, x: f64) usize {
        var child = self.box.as(gtk.Widget).getFirstChild();
        var index: usize = 0;
        while (child) |widget| : (index += 1) {
            child = widget.getNextSibling();
            var bounds: graphene.Rect = undefined;
            if (widget.computeBounds(self.scroll.as(gtk.Widget), &bounds) != 0) {
                const middle = bounds.f_origin.f_x + bounds.f_size.f_width / 2;
                if (if (self.box.as(gtk.Widget).getDirection() == .rtl) x > middle else x < middle) return index;
            }
        }
        return index;
    }

    fn dropped(_: *gtk.DropTarget, value: *gobject.Value, x: f64, _: f64, self: *State) callconv(.c) c_int {
        self.clearDrop();
        const page = gobject.ext.cast(adw.TabPage, value.getObject() orelse return 0) orelse return 0;
        const source = pageView(page) orelse return 0;
        const target = self.view orelse return 0;
        const count: usize = @intCast(target.getNPages());
        const slot = self.dropSlot(x);
        const position = layout.dropPosition(count, @intCast(target.getNPinnedPages()), page.getPinned() != 0, if (source == target) @intCast(source.getPagePosition(page)) else null, slot);
        // Moving the last page may dispose the source window. Do not access
        // source strip state after handing the page back to AdwTabView.
        _ = target.ref();
        defer target.unref();
        if (source == target) {
            _ = target.reorderPage(page, @intCast(position));
        } else {
            source.transferPage(page, target, @intCast(position));
        }
        target.setSelectedPage(page);
        return 1;
    }
};

fn pageView(page: *adw.TabPage) ?*adw.TabView {
    return ext.getAncestor(adw.TabView, page.getChild());
}

/// A chip owns its page reference and disconnects the page before disposal.
/// Drag callbacks own separate page references, surviving source-chip removal.
const Chip = extern struct {
    parent_instance: gtk.Box,
    pub const Parent = gtk.Box;
    const Self = @This();
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCompactTab",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    const Private = struct {
        pub var offset: c_int = 0;
        page: ?*adw.TabPage = null,
        label: *gtk.Label = undefined,
        select: *gtk.ToggleButton = undefined,
        close: *gtk.Button = undefined,
        close_slot: *gtk.Overlay = undefined,
        marker: *gtk.Label = undefined,
        attention: bool = false,
        pulse_timer: ?c_uint = null,
        indicator: *gtk.Image = undefined,
        popover: ?*gtk.PopoverMenu = null,
        menu_view: ?*adw.TabView = null,
    };

    fn new(page: *adw.TabPage) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.page = refPage(page);
        self.as(gtk.Widget).addCssClass("compact-tab");
        self.as(gtk.Widget).setValign(.center);
        self.as(gtk.Widget).setHasTooltip(1);
        _ = gtk.Widget.signals.query_tooltip.connect(self, *Self, queryTooltip, self, .{});
        priv.select = gtk.ToggleButton.new();
        priv.select.as(gtk.Widget).addCssClass("compact-tab-select");
        priv.select.as(gtk.Widget).setFocusOnClick(0);
        const content = gtk.Box.new(.horizontal, 6);
        priv.indicator = gtk.Image.newFromIconName("dialog-information-symbolic");
        priv.indicator.setPixelSize(12);
        content.append(priv.indicator.as(gtk.Widget));
        priv.label = gtk.Label.new(page.getTitle());
        priv.label.setEllipsize(.end);
        priv.label.setMaxWidthChars(28);
        priv.label.setXalign(0);
        content.append(priv.label.as(gtk.Widget));
        priv.select.as(gtk.Button).setChild(content.as(gtk.Widget));
        self.as(gtk.Box).append(priv.select.as(gtk.Widget));
        priv.close = gtk.Button.newFromIconName("window-close-symbolic");
        priv.close.as(gtk.Widget).addCssClass("compact-tab-close");
        priv.close.as(gtk.Widget).setFocusOnClick(0);
        priv.close.as(gtk.Widget).setFocusable(0);
        priv.close.as(gtk.Widget).setTooltipText("Close tab");
        priv.close_slot = gtk.Overlay.new();
        priv.close_slot.setChild(priv.close.as(gtk.Widget));
        priv.marker = gtk.Label.new("•");
        priv.marker.as(gtk.Widget).addCssClass("attention-marker");
        priv.marker.as(gtk.Widget).setCanTarget(0);
        priv.close_slot.addOverlay(priv.marker.as(gtk.Widget));
        self.as(gtk.Box).append(priv.close_slot.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(priv.select, *Self, selected, self, .{});
        _ = gtk.Button.signals.clicked.connect(priv.close, *Self, closed, self, .{});
        _ = gobject.Object.signals.notify.connect(page, *Self, pageChanged, self, .{});

        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(0);
        _ = gtk.GestureClick.signals.pressed.connect(click, *Self, pressed, self, .{});
        self.as(gtk.Widget).addController(click.as(gtk.EventController));
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Self, keyPressed, self, .{});
        self.as(gtk.Widget).addController(keys.as(gtk.EventController));
        const drag = gtk.DragSource.new();
        drag.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(drag, *adw.TabPage, dragPrepare, refPage(page), .{ .destroyData = unrefPage });
        _ = gtk.DragSource.signals.drag_cancel.connect(drag, *adw.TabPage, dragCancelled, refPage(page), .{ .destroyData = unrefPage });
        priv.select.as(gtk.Widget).addController(drag.as(gtk.EventController));
        self.refresh();
        return self;
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        const page = priv.page orelse return;
        priv.label.setLabel(page.getTitle());

        priv.select.setActive(page.getSelected());
        if (page.getSelected() != 0) self.as(gtk.Widget).addCssClass("selected") else self.as(gtk.Widget).removeCssClass("selected");
        const attention = page.getNeedsAttention() != 0 and page.getSelected() == 0;
        if (attention and !priv.attention and animationsEnabled()) {
            self.as(gtk.Widget).addCssClass("attention-pulse");
            priv.pulse_timer = glib.timeoutAdd(1200, pulseFinished, self);
        }
        if (!attention) self.stopPulse();
        priv.attention = attention;
        if (attention) self.as(gtk.Widget).addCssClass("needs-attention") else self.as(gtk.Widget).removeCssClass("needs-attention");
        priv.marker.as(gtk.Widget).setVisible(@intFromBool(attention));
        // Reserve the slot for pinned tabs too: attention must not resize them.
        if (page.getPinned() != 0) self.as(gtk.Widget).addCssClass("pinned") else self.as(gtk.Widget).removeCssClass("pinned");
        priv.close.as(gtk.Widget).setSensitive(@intFromBool(page.getPinned() == 0));
        if (page.getIndicatorIcon()) |icon| {
            priv.indicator.setFromGicon(icon);
            priv.indicator.as(gtk.Widget).setVisible(1);
        } else {
            priv.indicator.as(gtk.Widget).setVisible(0);
        }
    }

    fn animationsEnabled() bool {
        const settings = gtk.Settings.getDefault() orelse return false;
        var value = gobject.ext.Value.new(bool);
        defer value.unset();
        settings.as(gobject.Object).getProperty("gtk-enable-animations", &value);
        return value.getBoolean() != 0;
    }

    fn queryTooltip(_: *Self, _: c_int, _: c_int, _: c_int, tooltip: *gtk.Tooltip, self: *Self) callconv(.c) c_int {
        const page = self.private().page orelse return 0;
        const escaped = glib.markupEscapeText(page.getTitle(), -1);
        defer glib.free(escaped);
        var count: usize = 0;
        if (gobject.ext.cast(@import("class/tab.zig").Tab, page.getChild())) |tab| {
            if (tab.getSurfaceTree()) |tree| {
                if (tree.nodes.len > 0) count += tree.leafCount(.root);
            }
            count += tab.floatingCount();
        }
        // The page tooltip already contains escaped title/path markup.
        const label = gtk.Label.new(null);
        const full = std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}\n{d} {s}", .{ page.getTooltip() orelse escaped, count, if (count == 1) "pane" else "panes" }, 0) catch return 0;
        defer std.heap.page_allocator.free(full);
        label.setMarkup(full);
        label.setXalign(0);
        label.setWrap(1);
        label.setMaxWidthChars(60);
        tooltip.setCustom(label.as(gtk.Widget));
        return 1;
    }

    fn stopPulse(self: *Self) void {
        if (self.private().pulse_timer) |timer| {
            _ = glib.Source.remove(timer);
            self.private().pulse_timer = null;
        }
        self.as(gtk.Widget).removeCssClass("attention-pulse");
    }
    fn pulseFinished(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        self.private().pulse_timer = null;
        self.as(gtk.Widget).removeCssClass("attention-pulse");
        return 0;
    }

    fn pageChanged(_: *adw.TabPage, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn selected(_: *gtk.ToggleButton, self: *Self) callconv(.c) void {
        _ = self.ref();
        defer self.unref();
        const page = self.private().page orelse return;
        if (pageView(page)) |view| view.setSelectedPage(page);
        self.refresh();
    }

    fn closed(_: *gtk.Button, self: *Self) callconv(.c) void {
        const page = self.private().page orelse return;
        if (pageView(page)) |view| view.closePage(page);
    }

    fn pressed(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *Self) callconv(.c) void {
        const page = self.private().page orelse return;
        const view = pageView(page) orelse return;
        switch (gesture.as(gtk.GestureSingle).getCurrentButton()) {
            2 => {
                _ = gesture.as(gtk.Gesture).setState(.claimed);
                view.closePage(page);
            },
            3 => {
                _ = gesture.as(gtk.Gesture).setState(.claimed);
                self.popup(x, y);
            },
            else => {},
        }
    }

    fn popup(self: *Self, x: f64, y: f64) void {
        if (self.private().popover) |old| {
            old.as(gtk.Popover).popup();
            return;
        }
        const page = self.private().page orelse return;
        const view = pageView(page) orelse return;
        view.ref();
        self.private().menu_view = view;
        gobject.signalEmitByName(view.as(gobject.Object), "setup-menu", page);
        const popover = gtk.PopoverMenu.newFromModel(view.getMenuModel());
        self.private().popover = popover;
        popover.as(gtk.Widget).setParent(self.as(gtk.Widget));
        popover.as(gtk.Popover).setHasArrow(0);
        popover.as(gtk.Popover).setPointingTo(&.{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 });
        _ = gtk.Popover.signals.closed.connect(popover, *Self, menuClosed, self, .{});
        popover.as(gtk.Popover).popup();
    }

    fn menuClosed(popover: *gtk.PopoverMenu, self: *Self) callconv(.c) void {
        self.private().popover = null;
        self.clearMenuContext();
        popover.as(gtk.Widget).unparent();
    }

    fn clearMenuContext(self: *Self) void {
        if (self.private().menu_view) |view| {
            self.private().menu_view = null;
            gobject.signalEmitByName(view.as(gobject.Object), "setup-menu", @as(?*adw.TabPage, null));
            view.unref();
        }
    }

    fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, mods: gdk.ModifierType, self: *Self) callconv(.c) c_int {
        if (mods.control_mask or mods.alt_mask or mods.super_mask) return 0;
        const page = self.private().page orelse return 0;
        const view = pageView(page) orelse return 0;
        const count = view.getNPages();
        const position = view.getPagePosition(page);
        const target = switch (key) {
            gdk.KEY_Menu => {
                self.popup(0, @floatFromInt(self.as(gtk.Widget).getHeight()));
                return 1;
            },
            gdk.KEY_F10 => {
                if (!mods.shift_mask) return 0;
                self.popup(0, @floatFromInt(self.as(gtk.Widget).getHeight()));
                return 1;
            },
            gdk.KEY_Left => @mod(position - 1, count),
            gdk.KEY_Right => @mod(position + 1, count),
            gdk.KEY_Home => 0,
            gdk.KEY_End => count - 1,
            gdk.KEY_Delete => {
                view.closePage(page);
                return 1;
            },
            else => return 0,
        };
        const target_page = view.getNthPage(target);
        view.setSelectedPage(target_page);
        if (self.as(gtk.Widget).getParent()) |parent| {
            var child = parent.getFirstChild();
            while (child) |widget| : (child = widget.getNextSibling()) {
                const chip = gobject.ext.cast(Chip, widget) orelse continue;
                if (chip.private().page == target_page) {
                    _ = chip.private().select.as(gtk.Widget).grabFocus();
                    break;
                }
            }
        }
        return 1;
    }

    fn dragPrepare(_: *gtk.DragSource, _: f64, _: f64, page: *adw.TabPage) callconv(.c) ?*gdk.ContentProvider {
        var value = gobject.ext.Value.newFrom(page);
        defer value.unset();
        return gdk.ContentProvider.newForValue(&value);
    }

    fn dragCancelled(_: *gtk.DragSource, _: *gdk.Drag, reason: gdk.DragCancelReason, page: *adw.TabPage) callconv(.c) c_int {
        if (reason != .no_target) return 0;
        const window = ext.getAncestor(Window, page.getChild()) orelse return 0;
        window.detachTabPage(page);
        return 1;
    }

    fn unrefPage(page: *adw.TabPage) callconv(.c) void {
        page.unref();
    }

    fn refPage(page: *adw.TabPage) *adw.TabPage {
        page.ref();
        return page;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.stopPulse();
        if (priv.popover) |popover| {
            _ = gobject.signalHandlersDisconnectMatched(popover.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
            priv.popover = null;
            popover.as(gtk.Widget).unparent();
        }
        self.clearMenuContext();
        if (priv.page) |page| {
            _ = gobject.signalHandlersDisconnectMatched(page.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
            priv.page = null;
            page.unref();
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
