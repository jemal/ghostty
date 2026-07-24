const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const TabSidebarRow = @import("tab_sidebar_row.zig").TabSidebarRow;

/// A vertical list of tabs, shown as a sidebar alternative to the
/// horizontal `Adw.TabBar` when `gtk-tabs-location` is `left`/`right`.
pub const TabSidebar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabSidebar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"tab-view" = struct {
            pub const name = "tab-view";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*adw.TabView,
                .{
                    .accessor = .{
                        .getter = getTabViewValue,
                        .setter = setTabViewValue,
                    },
                },
            );
        };
    };

    const Private = struct {
        /// The tab view we're presenting a sidebar for. Not owned; this
        /// widget is always a descendant of the same window that owns
        /// the tab view.
        tab_view: ?*adw.TabView = null,

        // Template bindings
        view: *gtk.ListView,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn getTabViewValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.private().tab_view);
    }

    fn setTabViewValue(self: *Self, value: *const gobject.Value) void {
        self.setTabView(gobject.ext.Value.get(value, ?*adw.TabView));
    }

    /// Set the tab view this sidebar reflects. `Adw.TabView.getPages()`
    /// returns a `Gtk.SelectionModel` whose selection state IS the tab
    /// view's selection, so we can feed it directly to our list view
    /// without an intermediate `Gtk.SingleSelection`.
    fn setTabView(self: *Self, tab_view: ?*adw.TabView) void {
        const priv = self.private();
        priv.tab_view = tab_view;
        priv.view.setModel(if (tab_view) |tv| tv.getPages() else null);
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        const priv = self.private();
        const tab_view = priv.tab_view orelse return;
        const model = priv.view.getModel() orelse return;

        const object_ = model.as(gio.ListModel).getObject(pos);
        defer if (object_) |v| v.unref();
        const page = gobject.ext.cast(adw.TabPage, object_ orelse return) orelse return;

        tab_view.setSelectedPage(page);
    }

    fn dispose(self: *Self) callconv(.c) void {
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
            gobject.ext.ensureType(TabSidebarRow);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "tab-sidebar",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"tab-view".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("view", .{});

            // Template Callbacks
            class.bindTemplateCallback("row_activated", &rowActivated);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
