const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gtk_version = @import("../gtk_version.zig");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;
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
        surface_handlers: [3]c_ulong = .{ 0, 0, 0 },
        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
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
        const tiled = ext.getAncestor(@import("split_tree.zig").SplitTree, self.as(gtk.Widget)) != null;
        const enabled = if (ext.getAncestor(@import("window.zig").Window, self.as(gtk.Widget))) |window|
            tiled and window.getPaneDecorations()
        else
            false;
        const frame = priv.pane_frame.as(gtk.Widget);
        if (enabled) frame.addCssClass("decorated-pane") else frame.removeCssClass("decorated-pane");
        priv.pane_header.as(gtk.Widget).setVisible(@intFromBool(enabled));
        if (priv.surface) |surface| {
            const title = surface.getEffectiveTitle() orelse "Terminal";
            priv.pane_title.setLabel(title);
            priv.pane_title.as(gtk.Widget).setTooltipText(title);
            if (surface.getFocused()) frame.addCssClass("active") else frame.removeCssClass("active");
        }
    }

    fn refreshDecorationCallback(self: *Self) callconv(.c) void {
        self.refreshDecoration();
    }

    fn surfaceChanged(_: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.refreshDecoration();
    }

    fn focusPane(_: *gtk.Button, self: *Self) callconv(.c) void {
        if (self.private().surface) |surface| surface.grabFocus();
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
            inline for (.{ "title", "title-override", "focused" }, 0..) |detail, i| {
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
            class.bindTemplateCallback("refresh_decoration", &refreshDecorationCallback);
            class.bindTemplateCallback("focus_pane", &focusPane);
            class.bindTemplateCallback("close_pane", &closePane);

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
