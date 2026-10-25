const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gtk_version = @import("../gtk_version.zig");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;
const program_icon = @import("../program_icon.zig");
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_surface_scrolled_window);

/// A wrapper widget that embeds a Surface inside a GtkScrolledWindow.
/// This provides scrollbar functionality for the terminal surface.
/// The surface property can be set during initialization or changed
/// dynamically via the surface property.
pub const SurfaceScrolledWindow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhostttySurfaceScrolledWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
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

        pub const surface = struct {
            pub const name = "surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = .{
                        .getter = getSurfaceValue,
                        .setter = setSurfaceValue,
                    },
                },
            );
        };
    };

    const Private = struct {
        config: ?*Config = null,
        config_binding: ?*gobject.Binding = null,
        surface: ?*Surface = null,
        scrolled_window: *gtk.ScrolledWindow,
        pane_frame: *gtk.Box,
        pane_header: *gtk.Box,
        pane_title: *gtk.Label,
        pane_icon: *gtk.Image,
        pane_title_button: *gtk.Button,
        pane_lead: *gtk.Button,
        stacked: bool = false,
        collapsed: bool = false,
        surface_handlers: [5]c_ulong = .{ 0, 0, 0, 0, 0 },
        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Dragging the header moves the pane, like the surface's drag handle.
        const drag = gtk.DragSource.new();
        drag.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(drag, *Self, headerDragPrepare, self, .{});
        _ = gtk.DragSource.signals.drag_begin.connect(drag, *Self, headerDragBegin, self, .{});
        self.private().pane_title_button.as(gtk.Widget).addController(drag.as(gtk.EventController));
        if (gtk_version.runtimeUntil(4, 20, 1)) self.disableKineticScroll();
    }

    fn disableKineticScroll(self: *Self) void {
        // Until gtk 4.20.1 trackpads have kinetic scrolling behavior regardless
        // of `Gtk.ScrolledWindow.kinetic_scrolling`. As a workaround, disable
        // EventControllerScroll.kinetic
        const controllers = self.private().scrolled_window.as(gtk.Widget).observeControllers();
        defer controllers.unref();
        var i: c_uint = 0;
        while (controllers.getObject(i)) |obj| : (i += 1) {
            defer obj.unref();
            const controller = gobject.ext.cast(gtk.EventControllerScroll, obj) orelse continue;
            var flags = controller.getFlags();
            flags.kinetic = false;
            controller.setFlags(flags);
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.disconnectSurface();
        priv.surface = null;

        if (priv.config_binding) |binding| {
            binding.unbind();
            binding.unref();
            priv.config_binding = null;
        }

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
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn getSurfaceValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().surface,
        );
    }

    fn setSurfaceValue(self: *Self, value: *const gobject.Value) void {
        self.setSurface(gobject.ext.Value.get(
            value,
            ?*Surface,
        ));
    }

    pub fn getSurface(self: *Self) ?*Surface {
        return self.private().surface;
    }

    pub fn setStacked(self: *Self, stacked: bool, collapsed: bool) void {
        const priv = self.private();
        priv.stacked = stacked;
        priv.collapsed = stacked and collapsed;
        priv.scrolled_window.as(gtk.Widget).setVisible(@intFromBool(!priv.collapsed));
        self.as(gtk.Widget).setVexpand(@intFromBool(stacked and !collapsed));
        self.as(gtk.Widget).setSizeRequest(-1, if (stacked and !collapsed) 120 else -1);
        self.refreshDecoration();
    }

    pub fn setSurface(self: *Self, surface_: ?*Surface) void {
        const priv = self.private();

        if (surface_ == priv.surface) return;

        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);

        self.disconnectSurface();
        priv.surface = surface_;
    }

    fn disconnectSurface(self: *Self) void {
        const priv = self.private();
        if (priv.surface) |surface| {
            for (&priv.surface_handlers) |*handler| {
                if (handler.* != 0) gobject.signalHandlerDisconnect(surface.as(gobject.Object), handler.*);
                handler.* = 0;
            }
        }
    }

    /// Update presentation in place; the terminal stays in its scrolled window.
    pub fn refreshDecoration(self: *Self) void {
        const priv = self.private();
        const ext = @import("../ext.zig");
        const split_tree = ext.getAncestor(@import("split_tree.zig").SplitTree, self.as(gtk.Widget));
        const window = ext.getAncestor(@import("window.zig").Window, self.as(gtk.Widget));
        const enabled = if (window) |w| split_tree != null and w.getPaneDecorations() else false;
        const frame = priv.pane_frame.as(gtk.Widget);
        if (enabled and !priv.stacked) frame.addCssClass("decorated-pane") else frame.removeCssClass("decorated-pane");
        if (priv.stacked) frame.addCssClass("stack-member") else frame.removeCssClass("stack-member");
        priv.pane_header.as(gtk.Widget).setVisible(@intFromBool(enabled or priv.stacked));
        // While the side tab list is hidden, the first pane (top left, or the
        // zoomed pane) shows the button that brings it back.
        const lead = lead: {
            const w = window orelse break :lead false;
            const tree = (split_tree orelse break :lead false).getTree() orelse break :lead false;
            const surface = priv.surface orelse break :lead false;
            if (!(enabled or priv.stacked) or !w.sideTabsHidden() or tree.nodes.len == 0) break :lead false;
            const first = tree.deepest(.left, tree.zoomed orelse .root);
            break :lead switch (tree.nodes[first.idx()]) {
                .leaf => |view| view == surface,
                .split => false,
            };
        };
        priv.pane_lead.as(gtk.Widget).setVisible(@intFromBool(lead));
        if (priv.surface) |surface| {
            surface.setDragHandleEnabled(!(enabled or priv.stacked));
            const title = surface.getEffectiveTitle() orelse "Terminal";
            {
                const alloc = @import("application.zig").Application.default().allocator();
                const markup = program_icon.labelMarkup(alloc, surface.getProgramName() orelse "", title) catch null;
                defer if (markup) |v| alloc.free(v);
                if (markup) |v| priv.pane_title.setMarkup(v) else priv.pane_title.setLabel(title);
            }
            priv.pane_title.as(gtk.Widget).setTooltipText(title);
            priv.pane_icon.setFromIconName(surface.getProgram().glyph());
            if (surface.getFocused()) frame.addCssClass("active") else frame.removeCssClass("active");
        }
    }

    fn refreshDecorationCallback(self: *Self) callconv(.c) void {
        self.refreshDecoration();
    }

    fn surfaceChanged(_: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.refreshDecoration();
    }

    fn headerDragPrepare(src: *gtk.DragSource, x: f64, y: f64, self: *Self) callconv(.c) ?*gdk.ContentProvider {
        const surface = self.private().surface orelse return null;
        if (surface.core() == null) return null;
        return Surface.dragPrepare(src, x, y, surface);
    }

    fn headerDragBegin(src: *gtk.DragSource, drag: *gdk.Drag, self: *Self) callconv(.c) void {
        if (self.private().surface) |surface| Surface.dragBegin(src, drag, surface);
    }

    fn focusPane(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.selectPane();
    }

    fn selectPane(self: *Self) void {
        if (self.private().surface) |surface| {
            const ext = @import("../ext.zig");
            if (ext.getAncestor(@import("split_tree.zig").SplitTree, self.as(gtk.Widget))) |tree|
                tree.setActiveSurface(surface)
            else
                surface.grabFocus();
        }
    }

    /// Header buttons act on their own pane, so they select it first.
    fn splitTreeAction(self: *Self, name: [:0]const u8, target: ?*glib.Variant) void {
        self.selectPane();
        _ = self.as(gtk.Widget).activateActionVariant(name, target);
    }

    fn splitRight(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.splitTreeAction("split-tree.new-split", glib.Variant.newString("right"));
    }

    fn splitDown(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.splitTreeAction("split-tree.new-split", glib.Variant.newString("down"));
    }

    fn zoomPane(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.splitTreeAction("split-tree.zoom", null);
    }

    fn closePane(_: *gtk.Button, self: *Self) callconv(.c) void {
        if (self.private().surface) |surface| surface.close();
    }

    fn closureScrollbarPolicy(
        _: *Self,
        config_: ?*Config,
    ) callconv(.c) gtk.PolicyType {
        const config = if (config_) |c| c.get() else return .automatic;
        return switch (config.scrollbar) {
            .never => .never,
            .system => .automatic,
        };
    }

    fn propSurface(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const scrolled_window = self.private().scrolled_window.as(gtk.ScrolledWindow);
        scrolled_window.setChild(if (priv.surface) |s| s.as(gtk.Widget) else null);

        // Unbind old config binding if it exists
        if (priv.config_binding) |binding| {
            binding.unbind();
            binding.unref();
            priv.config_binding = null;
        }

        // Bind config from surface to our config property
        if (priv.surface) |surface| {
            inline for (.{ "title", "title-override", "focused", "program", "program-name" }, 0..) |detail, i| {
                priv.surface_handlers[i] = gobject.Object.signals.notify.connect(surface, *Self, surfaceChanged, self, .{ .detail = detail });
            }
            const binding = surface.as(gobject.Object).bindProperty(
                properties.config.name,
                self.as(gobject.Object),
                properties.config.name,
                .{ .sync_create = true },
            );
            // Keep another ref, otherwise the binding would be freed and
            // our pointer become stale if the surface gets finalized.
            binding.ref();
            priv.config_binding = binding;
        }
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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "surface-scrolled-window",
                }),
            );

            // Bindings
            class.bindTemplateCallback("scrollbar_policy", &closureScrollbarPolicy);
            class.bindTemplateCallback("notify_surface", &propSurface);
            class.bindTemplateChildPrivate("scrolled_window", .{});
            class.bindTemplateChildPrivate("pane_frame", .{});
            class.bindTemplateChildPrivate("pane_header", .{});
            class.bindTemplateChildPrivate("pane_title", .{});
            class.bindTemplateChildPrivate("pane_icon", .{});
            class.bindTemplateChildPrivate("pane_title_button", .{});
            class.bindTemplateChildPrivate("pane_lead", .{});
            class.bindTemplateCallback("refresh_decoration", &refreshDecorationCallback);
            class.bindTemplateCallback("focus_pane", &focusPane);
            class.bindTemplateCallback("close_pane", &closePane);
            class.bindTemplateCallback("split_right", &splitRight);
            class.bindTemplateCallback("split_down", &splitDown);
            class.bindTemplateCallback("zoom_pane", &zoomPane);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.surface.impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
