const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;

/// A single row in the `TabSidebar` list, representing one `Adw.TabPage`.
/// `Gtk.ListView` recycles these rows as items scroll in and out, so
/// `page` may be reassigned repeatedly over the row's lifetime.
pub const TabSidebarRow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabSidebarRow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const page = struct {
            pub const name = "page";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*adw.TabPage,
                .{
                    .accessor = .{
                        .getter = getPageValue,
                        .setter = setPageValue,
                    },
                },
            );
        };
    };

    const Private = struct {
        /// The tab page this row currently represents.
        page: ?*adw.TabPage = null,

        /// Handler id for `page`'s "notify::needs-attention", so we can
        /// disconnect it whenever `page` is reassigned or this row is
        /// disposed.
        needs_attention_handler: c_ulong = 0,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn getPageValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.private().page);
    }

    fn setPageValue(self: *Self, value: *const gobject.Value) void {
        self.setPage(gobject.ext.Value.get(value, ?*adw.TabPage));
    }

    fn setPage(self: *Self, page: ?*adw.TabPage) void {
        const priv = self.private();

        if (priv.page) |old| {
            if (priv.needs_attention_handler != 0) {
                gobject.signalHandlerDisconnect(
                    old.as(gobject.Object),
                    priv.needs_attention_handler,
                );
                priv.needs_attention_handler = 0;
            }
            old.unref();
            priv.page = null;
        }

        if (page) |p| {
            p.ref();
            priv.page = p;
            priv.needs_attention_handler = gobject.Object.signals.notify.connect(
                p,
                *Self,
                propNeedsAttention,
                self,
                .{ .detail = "needs-attention" },
            );
        }

        self.updateNeedsAttentionClass();
    }

    fn propNeedsAttention(
        _: *adw.TabPage,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.updateNeedsAttentionClass();
    }

    fn updateNeedsAttentionClass(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const needs_attention = if (priv.page) |p| p.getNeedsAttention() != 0 else false;
        if (needs_attention) {
            widget.addCssClass("needs-attention");
        } else {
            widget.removeCssClass("needs-attention");
        }
    }

    fn closeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const page = priv.page orelse return;
        const child = page.getChild();
        const tab_view = ext.getAncestor(adw.TabView, child) orelse return;
        tab_view.closePage(page);
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.setPage(null);

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
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
                    .minor = 5,
                    .name = "tab-sidebar-row",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.page.impl,
            });

            // Template Callbacks
            class.bindTemplateCallback("close_clicked", &closeClicked);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
