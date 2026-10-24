const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");
const sessions = @import("../session.zig");
const Binding = @import("../../../input/Binding.zig");
const SurfaceScrolledWindow = @import("surface_scrolled_window.zig").SurfaceScrolledWindow;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;

const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const Overrides = @import("Overrides.zig");

const log = std.log.scoped(.gtk_ghostty_window);

pub const Tab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTab",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"split-tree" = struct {
            pub const name = "split-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*SplitTree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*SplitTree,
                        .{
                            .getter = getSplitTree,
                        },
                    ),
                },
            );
        };

        pub const @"surface-tree" = struct {
            pub const name = "surface-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface.Tree,
                        .{
                            .getter = getSurfaceTree,
                        },
                    ),
                },
            );
        };

        pub const tooltip = struct {
            pub const name = "tooltip";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("tooltip"),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };
        pub const @"title-override" = struct {
            pub const name = "title-override";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title_override"),
                },
            );
        };
    };

    pub const signals = struct {
        pub const @"floating-added" = struct {
            pub const name = "floating-added";
            pub const impl = gobject.ext.defineSignal(name, Self, &.{*Surface}, void);
            pub const connect = impl.connect;
        };
        pub const @"floating-removed" = struct {
            pub const name = "floating-removed";
            pub const impl = gobject.ext.defineSignal(name, Self, &.{*Surface}, void);
            pub const connect = impl.connect;
        };
        /// Emitted whenever the tab would like to be closed.
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// The title of this tab. This is usually bound to the active surface.
        title: ?[:0]const u8 = null,

        /// The manually overridden title.
        title_override: ?[:0]const u8 = null,

        /// The tooltip of this tab. This is usually bound to the active surface.
        tooltip: ?[:0]const u8 = null,

        // Template bindings
        split_tree: *SplitTree,
        content: *gtk.Overlay,
        focus_source: ?c_uint = null,
        hide_source: ?c_uint = null,
        floating: std.ArrayList(FloatEntry) = .empty,
        floating_selected: usize = 0,
        floating_visible: bool = false,
        disposing: bool = false,

        pub var offset: c_int = 0;
    };

    const FloatEntry = struct {
        surface: *Surface, // owned by the panel's scrolled window
        widget: *gtk.Box,
        button: *gtk.Button,
        close: *gtk.Button,
        name: ?[:0]const u8,
        geometry: sessions.FloatGeometry,
        dialog: ?*CloseConfirmationDialog = null,
    };

    pub fn floatingCount(self: *Self) usize {
        return self.private().floating.items.len;
    }

    pub fn floatingSurface(self: *Self, index: usize) *Surface {
        return self.private().floating.items[index].surface;
    }

    fn floatingIndex(self: *Self, surface: *Surface) ?usize {
        for (self.private().floating.items, 0..) |entry, i| if (entry.surface == surface) return i;
        return null;
    }

    pub fn floatingName(self: *Self, surface: *Surface) ?[:0]const u8 {
        const index = self.floatingIndex(surface) orelse return null;
        return self.private().floating.items[index].name;
    }

    pub fn floatingSelected(self: *Self) usize {
        return self.private().floating_selected;
    }

    pub fn floatingVisible(self: *Self) bool {
        return self.private().floating_visible;
    }

    /// Compatibility fallback for manifests from the original tabbed preview.
    pub fn floatingGeometry(self: *Self) sessions.FloatGeometry {
        return if (self.floatingCount() > 0) self.private().floating.items[self.floatingSelected()].geometry else .{};
    }

    pub fn floatingGeometryFor(self: *Self, surface: *Surface) sessions.FloatGeometry {
        return self.private().floating.items[self.floatingIndex(surface).?].geometry;
    }

    pub fn floatingStackIndex(self: *Self, surface: *Surface) usize {
        var child = self.private().content.as(gtk.Widget).getFirstChild();
        var order: usize = 0;
        while (child) |widget| : (child = widget.getNextSibling()) {
            for (self.private().floating.items) |entry| if (entry.widget.as(gtk.Widget) == widget) {
                if (entry.surface == surface) return order;
                order += 1;
                break;
            };
        }
        unreachable;
    }

    pub fn containsFloating(self: *Self, surface: *Surface) bool {
        return self.floatingIndex(surface) != null;
    }

    pub const SurfaceIterator = struct {
        tab: *Self,
        node: usize = 0,
        floating: usize = 0,

        pub fn next(it: *SurfaceIterator) ?*Surface {
            if (it.tab.getSurfaceTree()) |tree| {
                while (it.node < tree.nodes.len) {
                    const node = tree.nodes[it.node];
                    it.node += 1;
                    if (node == .leaf) return node.leaf;
                }
            }
            if (it.floating >= it.tab.floatingCount()) return null;
            defer it.floating += 1;
            return it.tab.floatingSurface(it.floating);
        }
    };

    pub fn surfaces(self: *Self) SurfaceIterator {
        return .{ .tab = self };
    }

    pub fn openFloating(self: *Self, parent: ?*Surface, overrides: Overrides, name: ?[:0]const u8) !void {
        if (name) |key| for (self.private().floating.items) |entry| {
            if (entry.name) |existing| if (std.mem.eql(u8, key, existing)) {
                self.presentFloating(entry.surface);
                return;
            };
        };
        if (self.floatingCount() >= sessions.max_tabs) return error.OpenFailed;
        const surface: *Surface = .new(overrides);
        _ = surface.refSink();
        defer surface.unref();
        if (parent) |p| if (p.core()) |core| surface.setParent(core, .split);
        try self.addFloating(surface, name);
        self.presentFloating(surface);
    }

    fn configuredFloatingGeometry() sessions.FloatGeometry {
        const config = Application.default().getConfig();
        defer config.unref();
        return sessions.FloatGeometry.anchored(
            config.get().@"gtk-floating-terminal-anchor",
            config.get().@"gtk-floating-terminal-size".width,
            config.get().@"gtk-floating-terminal-size".height,
        );
    }

    pub fn addFloating(self: *Self, surface: *Surface, name: ?[:0]const u8) !void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        const copy = if (name) |n| try alloc.dupeSentinel(u8, n, 0) else null;
        errdefer if (copy) |n| alloc.free(n);
        try priv.floating.ensureUnusedCapacity(alloc, 1);
        const width = priv.content.as(gtk.Widget).getWidth();
        const height = priv.content.as(gtk.Widget).getHeight();
        const geometry = if (self.floatingCount() > 0)
            priv.floating.items[priv.floating_selected].geometry.cascade(if (width > 0) width else 800, if (height > 0) height else 600)
        else
            configuredFloatingGeometry();
        const panel = gtk.Box.new(.vertical, 0);
        panel.as(gtk.Widget).addCssClass("floating-terminal");
        panel.as(gtk.Widget).setOverflow(.hidden);
        panel.as(gtk.Widget).setVisible(0);
        const header = gtk.Box.new(.horizontal, 0);
        header.as(gtk.Widget).addCssClass("floating-titlebar");
        const button = gtk.Button.newWithLabel(surface.getEffectiveTitle() orelse name orelse "Terminal");
        button.as(gtk.Widget).addCssClass("flat");
        button.as(gtk.Widget).setFocusOnClick(0);
        button.as(gtk.Widget).setHexpand(1);
        const label = gobject.ext.cast(gtk.Label, button.getChild().?).?;
        label.setEllipsize(.end);
        label.setXalign(0);
        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.as(gtk.Widget).addCssClass("flat");
        close.as(gtk.Widget).setFocusOnClick(0);
        close.as(gtk.Widget).setTooltipText("Close floating terminal");
        header.append(button.as(gtk.Widget));
        header.append(close.as(gtk.Widget));
        panel.append(header.as(gtk.Widget));
        const scrolled = gobject.ext.newInstance(SurfaceScrolledWindow, .{ .surface = surface });
        scrolled.as(gtk.Widget).setVexpand(1);
        panel.append(scrolled.as(gtk.Widget));
        priv.floating.appendAssumeCapacity(.{ .surface = surface, .widget = panel, .button = button, .close = close, .name = copy, .geometry = geometry });
        priv.content.addOverlay(panel.as(gtk.Widget));
        priv.content.setClipOverlay(panel.as(gtk.Widget), 1);
        _ = gtk.Button.signals.clicked.connect(button, *Self, floatingTitleClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(close, *Self, floatingCloseClicked, self, .{});
        _ = gobject.Object.signals.notify.connect(surface, *Self, floatingMapped, self, .{ .detail = "mapped" });
        _ = gobject.Object.signals.notify.connect(surface, *Self, floatingFocused, self, .{ .detail = "focused" });
        _ = Surface.signals.@"close-request".connect(surface, *Self, floatingCloseRequest, self, .{});
        _ = gobject.Object.signals.notify.connect(surface, *Self, floatingTitleChanged, self, .{ .detail = "title" });
        _ = gobject.Object.signals.notify.connect(surface, *Self, floatingTitleChanged, self, .{ .detail = "title-override" });
        signals.@"floating-added".impl.emit(self, null, .{surface}, null);
    }

    pub fn restoreFloatingState(self: *Self, saved: sessions.Tab) void {
        const priv = self.private();
        for (priv.floating.items, saved.floating, 0..) |*entry, record, i| {
            // Earlier tabbed manifests have one shared rectangle.
            entry.geometry = record.geometry orelse if (i == 0) saved.floating_geometry else priv.floating.items[i - 1].geometry.cascade(800, 600);
        }
        for (0..self.floatingCount()) |order| {
            for (saved.floating, 0..) |record, i| if (record.stacking == order) self.raiseFloating(i);
        }
        priv.floating_selected = saved.floating_selected;
        priv.floating_visible = self.floatingCount() > 0 and (saved.floating_visible or self.getSurfaceTree() == null);
        self.syncFloatingPanels();
        self.queueFloatingFocus();
        self.activeChanged();
    }

    /// Reorder an already-parented child without removing it from GtkOverlay.
    /// That preserves realization, GPU resources, and the running process.
    fn raiseFloating(self: *Self, index: usize) void {
        const content = self.private().content.as(gtk.Widget);
        const panel = self.private().floating.items[index].widget.as(gtk.Widget);
        const last = content.getLastChild();
        if (last != panel) panel.insertAfter(content, last);
    }

    fn syncFloatingPanels(self: *Self) void {
        const priv = self.private();
        for (priv.floating.items, 0..) |entry, i| {
            entry.widget.as(gtk.Widget).setVisible(@intFromBool(priv.floating_visible));
            if (i == priv.floating_selected) entry.widget.as(gtk.Widget).addCssClass("active") else entry.widget.as(gtk.Widget).removeCssClass("active");
        }
    }

    pub fn presentFloating(self: *Self, surface: *Surface) void {
        const index = self.floatingIndex(surface) orelse return;
        const priv = self.private();
        priv.floating_selected = index;
        priv.floating_visible = true;
        self.syncFloatingPanels();
        self.raiseFloating(index);
        self.activeChanged();
        surface.grabFocus();
        self.queueFloatingFocus();
    }

    pub fn hideFloating(self: *Self, restore_focus: bool) void {
        if (self.getSurfaceTree() == null) return;
        const priv = self.private();
        priv.floating_visible = false;
        self.syncFloatingPanels();
        self.activeChanged();
        if (restore_focus) if (priv.split_tree.getActiveSurface()) |surface| surface.grabFocus();
    }

    pub fn floatingAction(self: *Self, action: Binding.Action) bool {
        const priv = self.private();
        switch (action) {
            .toggle_float => {
                if (self.floatingVisible()) self.hideFloating(true) else if (self.floatingCount() > 0) {
                    self.presentFloating(self.floatingSurface(self.floatingSelected()));
                } else self.openFloating(self.getActiveSurface(), .none, null) catch return false;
            },
            .hide_float => self.hideFloating(true),
            .focus_float => |direction| {
                if (!self.floatingVisible() or self.floatingCount() == 0) return false;
                var geometries: [sessions.max_tabs]sessions.FloatGeometry = undefined;
                for (priv.floating.items, geometries[0..self.floatingCount()]) |entry, *geometry| geometry.* = entry.geometry;
                if (sessions.FloatGeometry.neighbor(geometries[0..self.floatingCount()], priv.floating_selected, direction, priv.content.as(gtk.Widget).getWidth(), priv.content.as(gtk.Widget).getHeight())) |index|
                    self.presentFloating(self.floatingSurface(index));
                // A single panel still handles the key instead of moving focus to tiles.
            },
            .move_float, .resize_float => |direction| {
                if (!self.floatingVisible() or self.floatingCount() == 0) return false;
                const dx: f64 = switch (direction) {
                    .left => -0.025,
                    .right => 0.025,
                    else => 0,
                };
                const dy: f64 = switch (direction) {
                    .up => -0.025,
                    .down => 0.025,
                    else => 0,
                };
                priv.floating.items[priv.floating_selected].geometry.adjust(dx, dy, action == .resize_float);
                priv.content.as(gtk.Widget).queueAllocate();
            },
            .reset_float => {
                if (self.floatingCount() == 0) return false;
                priv.floating.items[priv.floating_selected].geometry = configuredFloatingGeometry();
                priv.content.as(gtk.Widget).queueAllocate();
            },
            .next_float_tab, .previous_float_tab => {
                const count = self.floatingCount();
                if (count == 0) return false;
                const index = (self.floatingSelected() + if (action == .next_float_tab) @as(usize, 1) else count - 1) % count;
                self.presentFloating(self.floatingSurface(index));
            },
            else => return false,
        }
        return true;
    }

    fn activeChanged(self: *Self) void {
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn floatingPosition(_: *gtk.Overlay, child: *gtk.Widget, allocation: *gdk.Rectangle, self: *Self) callconv(.c) c_int {
        const priv = self.private();
        for (priv.floating.items) |entry| if (entry.widget.as(gtk.Widget) == child) {
            const rect = entry.geometry.pixels(priv.content.as(gtk.Widget).getWidth(), priv.content.as(gtk.Widget).getHeight());
            allocation.* = .{ .f_x = rect.x, .f_y = rect.y, .f_width = rect.width, .f_height = rect.height };
            return 1;
        };
        return 0;
    }

    fn floatingTitleClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        for (self.private().floating.items) |entry| if (entry.button == button) {
            self.presentFloating(entry.surface);
            return;
        };
    }

    fn floatingCloseClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        for (self.private().floating.items) |entry| if (entry.close == button) {
            entry.surface.close();
            return;
        };
    }

    pub fn restoreFloatingFocus(self: *Self) bool {
        if (!self.floatingVisible() or self.floatingCount() == 0) return false;
        const index = self.floatingSelected();
        const surface = self.floatingSurface(index);
        if (surface.getMapped()) {
            self.raiseFloating(index);
            surface.grabFocus();
        }
        return true;
    }

    pub fn tiledFocused(self: *Self) void {
        const priv = self.private();
        if (self.floatingVisible() and priv.hide_source == null)
            priv.hide_source = glib.idleAdd(hideFloatingIdle, self);
    }

    fn hideFloatingIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        self.private().hide_source = null;
        if (self.getSplitTree().getActiveSurface()) |surface| {
            if (surface.getFocused() and surface.getMapped()) self.hideFloating(false);
        }
        return 0;
    }

    fn floatingFocused(surface: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!surface.getFocused() or !self.floatingVisible()) return;
        const widget = surface.as(gtk.Widget);
        const root = widget.getRoot() orelse return;
        const focus = root.getFocus() orelse return;
        if (focus != widget and focus.isAncestor(widget) == 0) return;
        self.private().floating_selected = self.floatingIndex(surface) orelse return;
        self.syncFloatingPanels();
        self.activeChanged();
        // Raising waits until GTK has finished its focus traversal.
        self.queueFloatingFocus();
    }

    fn floatingMapped(surface: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (surface.getMapped()) self.queueFloatingFocus();
    }

    fn queueFloatingFocus(self: *Self) void {
        const priv = self.private();
        if (!priv.disposing and priv.focus_source == null) priv.focus_source = glib.idleAdd(focusFloatingIdle, self);
    }

    fn focusFloatingIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        self.private().focus_source = null;
        if (self.as(gtk.Widget).getMapped() != 0 and !self.restoreFloatingFocus()) {
            if (self.getActiveSurface()) |surface| surface.grabFocus();
        }
        return 0;
    }

    fn floatingTitleChanged(surface: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const index = self.floatingIndex(surface) orelse return;
        const entry = self.private().floating.items[index];
        const title = surface.getEffectiveTitle() orelse entry.name orelse "Terminal";
        entry.button.setLabel(title);
        entry.button.as(gtk.Widget).setTooltipText(title);
        const label = gobject.ext.cast(gtk.Label, entry.button.getChild().?).?;
        label.setEllipsize(.end);
        label.setXalign(0);
    }

    fn floatingCloseRequest(surface: *Surface, self: *Self) callconv(.c) void {
        const index = self.floatingIndex(surface) orelse return;
        const priv = self.private();
        if (priv.floating.items[index].dialog != null) return;
        if (surface.core()) |core| if (core.needsConfirmQuit()) {
            const dialog: *CloseConfirmationDialog = .new(.surface);
            priv.floating.items[index].dialog = dialog;
            _ = CloseConfirmationDialog.signals.@"close-request".connect(dialog, *Self, floatingConfirmClose, self, .{});
            _ = CloseConfirmationDialog.signals.cancel.connect(dialog, *Self, floatingCancelClose, self, .{});
            dialog.present(self.as(gtk.Widget));
            return;
        };
        self.finishFloatingClose(surface);
    }

    fn floatingConfirmClose(dialog: *CloseConfirmationDialog, self: *Self) callconv(.c) void {
        for (self.private().floating.items) |*entry| if (entry.dialog == dialog) {
            const surface = entry.surface;
            _ = gobject.signalHandlersDisconnectMatched(dialog.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
            entry.dialog = null;
            self.finishFloatingClose(surface);
            return;
        };
    }

    fn floatingCancelClose(dialog: *CloseConfirmationDialog, self: *Self) callconv(.c) void {
        for (self.private().floating.items) |*entry| if (entry.dialog == dialog) {
            _ = gobject.signalHandlersDisconnectMatched(dialog.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
            entry.dialog = null;
            return;
        };
    }

    fn finishFloatingClose(self: *Self, surface: *Surface) void {
        const index = self.floatingIndex(surface) orelse return;
        const priv = self.private();
        const active = self.floatingSurface(priv.floating_selected);
        const entry = priv.floating.items[index];
        signals.@"floating-removed".impl.emit(self, null, .{surface}, null);
        _ = gobject.signalHandlersDisconnectMatched(surface.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
        if (entry.name) |name| Application.default().allocator().free(name);
        _ = priv.floating.orderedRemove(index);
        priv.floating_selected = 0;
        if (active != surface) priv.floating_selected = self.floatingIndex(active) orelse 0;
        // Update selection before disposal can trigger application callbacks.
        priv.content.removeOverlay(entry.widget.as(gtk.Widget));
        if (self.floatingCount() == 0) {
            priv.floating_visible = false;
            if (priv.split_tree.getActiveSurface() == null) {
                self.activeChanged();
                signals.@"close-request".impl.emit(self, null, .{}, null);
                return;
            }
        } else if (active == surface) {
            const top = priv.content.as(gtk.Widget).getLastChild();
            for (priv.floating.items, 0..) |remaining, i| if (remaining.widget.as(gtk.Widget) == top) {
                priv.floating_selected = i;
                break;
            };
        }
        self.syncFloatingPanels();
        self.activeChanged();
        self.queueFloatingFocus();
    }

    /// Set the parent of this tab page. This only affects the first surface
    /// ever created for a tab. If a surface was already created this does
    /// nothing.
    pub fn setParent(self: *Self, parent: *CoreSurface) void {
        self.setParentWithContext(parent, .tab);
    }

    pub fn setParentWithContext(self: *Self, parent: *CoreSurface, context: apprt.surface.NewSurfaceContext) void {
        if (self.getActiveSurface()) |surface| {
            surface.setParent(parent, context);
        }
    }

    pub fn new(config: ?*Config, overrides: Overrides) *Self {
        const tab = gobject.ext.newInstance(Tab, .{});

        const priv: *Private = tab.private();

        if (config) |c| priv.config = c.ref();

        // If our configuration is null then we get the configuration
        // from the application.
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        tab.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        // A title for a new tab names the tab, not only its first pane.
        // Otherwise the tab title changes when another pane gets the focus.
        if (overrides.title) |title| tab.setTitleOverride(title);

        // Create our initial surface in the split tree.
        priv.split_tree.newSplit(.right, null, .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = null,
            .wait_after_command = overrides.wait_after_command,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                // TODO: We should make our "no surfaces" state more aesthetically
                // pleasing and show something like an "Oops, something went wrong"
                // message. For now, this is incredibly unlikely.
                @panic("oom");
            },
        };

        return tab;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        _ = gtk.Overlay.signals.get_child_position.connect(self.private().content, *Self, floatingPosition, self, .{});
        self.initActionMap();
    }

    fn initActionMap(self: *Self) void {
        const s_param_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_param_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("close", actionClose, s_param_type),
            .init("ring-bell", actionRingBell, null),
            .init("next-page", actionNextPage, null),
            .init("previous-page", actionPreviousPage, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "tab", &actions);
    }

    //---------------------------------------------------------------
    // Properties

    /// Overridden title. This will be generally be shown over the title
    /// unless this is unset (null).
    pub fn setTitleOverride(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }
    fn titleDialogSet(
        _: *TitleDialog,
        title_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const title = std.mem.span(title_ptr);
        self.setTitleOverride(if (title.len == 0) null else title);
    }
    pub fn promptTabTitle(self: *Self) void {
        const priv = self.private();
        const dialog = TitleDialog.new(.tab, priv.title_override orelse priv.title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        if (self.floatingVisible() and self.floatingCount() > 0) return self.floatingSurface(self.floatingSelected());
        return self.getSplitTree().getActiveSurface();
    }

    /// Get the surface tree of this tab.
    pub fn getSurfaceTree(self: *Self) ?*Surface.Tree {
        const priv = self.private();
        return priv.split_tree.getTree();
    }

    /// Get the split tree widget that is in this tab.
    pub fn getSplitTree(self: *Self) *SplitTree {
        const priv = self.private();
        return priv.split_tree;
    }

    pub fn getTitleOverride(self: *Self) ?[:0]const u8 {
        return self.private().title_override;
    }

    /// Returns true if this tab needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        var it = self.surfaces();
        while (it.next()) |surface| if (surface.core()) |core| {
            if (core.needsConfirmQuit()) return true;
        };
        return false;
    }

    /// Get the tab view holding this tab, if any.
    fn getTabView(self: *Self) ?*adw.TabView {
        return ext.getAncestor(
            adw.TabView,
            self.as(gtk.Widget),
        );
    }

    /// Get the tab page holding this tab, if any.
    fn getTabPage(self: *Self) ?*adw.TabPage {
        const tab_view = self.getTabView() orelse return null;
        return tab_view.getPage(self.as(gtk.Widget));
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.disposing = true;
        if (priv.hide_source) |source| {
            _ = glib.Source.remove(source);
            priv.hide_source = null;
        }
        if (priv.focus_source) |source| {
            _ = glib.Source.remove(source);
            priv.focus_source = null;
        }
        for (priv.floating.items) |entry| {
            if (entry.dialog) |dialog| {
                _ = gobject.signalHandlersDisconnectMatched(dialog.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
                dialog.close();
            }
            _ = gobject.signalHandlersDisconnectMatched(entry.surface.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
            if (entry.name) |name| Application.default().allocator().free(name);
        }
        priv.floating.deinit(Application.default().allocator());
        priv.floating = .empty;
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tooltip) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.tooltip = null;
        }
        if (priv.title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title = null;
        }
        if (priv.title_override) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title_override = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    //---------------------------------------------------------------
    // Signal handlers

    fn propSplitTree(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"surface-tree".impl.param_spec);

        // If our tree is empty we close the tab.
        const tree: *const Surface.Tree = self.getSurfaceTree() orelse &.empty;
        self.getSplitTree().as(gtk.Widget).setVisible(@intFromBool(!tree.isEmpty()));
        if (tree.isEmpty() and self.floatingCount() > 0) {
            self.presentFloating(self.floatingSurface(self.floatingSelected()));
        } else if (tree.isEmpty()) {
            signals.@"close-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
            return;
        }
    }

    fn propActiveSurface(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn actionClose(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("tab.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const tab_view = self.getTabView() orelse return;
        const page = tab_view.getPage(self.as(gtk.Widget));

        const mode = std.meta.stringToEnum(
            apprt.action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to tab.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid mode provided to tab.close-tab: {s}", .{str.?});
            return;
        };

        // Delegate to our parent to handle this, since this will emit
        // a close-page signal that the parent can intercept.
        switch (mode) {
            .this => tab_view.closePage(page),
            .other => tab_view.closeOtherPages(page),
            .right => tab_view.closePagesAfter(page),
        }
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.promptTabTitle();
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        // Future note: I actually don't like this logic living here at all.
        // I think a better approach will be for the ring bell action to
        // specify its sending surface and then do all this in the window.

        // If the page is selected already we don't mark it as needing
        // attention. We only want to mark unfocused pages. This will then
        // clear when the page is selected.
        const page = self.getTabPage() orelse return;
        if (page.getSelected() != 0) return;
        page.setNeedsAttention(@intFromBool(true));
    }

    /// Select the next tab page.
    fn actionNextPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectNextPage();
    }

    /// Select the previous tab page.
    fn actionPreviousPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectPreviousPage();
    }

    fn closureComputedTooltip(_: *Self, title: ?[*:0]const u8, cwd: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
        // AdwTabPage interprets tooltips as markup. Keep terminal titles and
        // directory names literal, including characters such as < and &.
        const text = title orelse cwd orelse return null;
        const path = cwd orelse return glib.markupEscapeText(text, -1);
        if (title == null or std.mem.eql(u8, std.mem.span(text), std.mem.span(path)))
            return glib.markupEscapeText(text, -1);
        return glib.markupPrintfEscaped("<b>%s</b>\n%s", text, path);
    }

    fn closureComputedTitle(
        _: *Self,
        config_: ?*Config,
        terminal_: ?[*:0]const u8,
        surface_override_: ?[*:0]const u8,
        tab_override_: ?[*:0]const u8,
        zoomed_: c_int,
        bell_ringing_: c_int,
        _: *gobject.ParamSpec,
    ) callconv(.c) ?[*:0]const u8 {
        const zoomed = zoomed_ != 0;
        const bell_ringing = bell_ringing_ != 0;

        // Our plain title is the manually tab overridden title if it exists,
        // otherwise the overridden title if it exists, otherwise
        // the terminal title if it exists, otherwise a default string.
        const plain = plain: {
            const default = "Ghostty";
            const config_title: ?[*:0]const u8 = title: {
                const config = config_ orelse break :title null;
                break :title config.get().title orelse null;
            };

            const plain = tab_override_ orelse
                surface_override_ orelse
                terminal_ orelse
                config_title orelse
                break :plain default;
            break :plain std.mem.span(plain);
        };

        // We don't need a config in every case, but if we don't have a config
        // let's just assume something went terribly wrong and use our
        // default title. Its easier then guarding on the config existing
        // in every case for something so unlikely.
        const config = if (config_) |v| v.get() else {
            log.warn("config unavailable for computed title, likely bug", .{});
            return glib.ext.dupeZ(u8, plain);
        };

        // Use an allocator to build up our string as we write it.
        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();

        // If our bell is ringing, then we prefix the bell icon to the title.
        if (bell_ringing and config.@"bell-features".title) {
            buf.writer.writeAll("🔔 ") catch {};
        }

        // If we're zoomed, prefix with the magnifying glass emoji.
        if (zoomed) {
            buf.writer.writeAll("🔍 ") catch {};
        }

        buf.writer.writeAll(plain) catch return glib.ext.dupeZ(u8, plain);
        return glib.ext.dupeZ(u8, buf.written());
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
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "tab",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.@"split-tree".impl,
                properties.@"surface-tree".impl,
                properties.title.impl,
                properties.@"title-override".impl,
                properties.tooltip.impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("split_tree", .{});
            class.bindTemplateChildPrivate("content", .{});

            // Template Callbacks
            class.bindTemplateCallback("computed_title", &closureComputedTitle);
            class.bindTemplateCallback("computed_tooltip", &closureComputedTooltip);
            class.bindTemplateCallback("notify_active_surface", &propActiveSurface);
            class.bindTemplateCallback("notify_tree", &propSplitTree);

            // Signals
            signals.@"close-request".impl.register(.{});
            signals.@"floating-added".impl.register(.{});
            signals.@"floating-removed".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
