const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const TitlebarStyle = configpkg.Config.GtkTitlebarStyle;
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gtk_version = @import("../gtk_version.zig");
const gresource = @import("../build/gresource.zig");
const winprotopkg = @import("../winproto.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const Overrides = @import("Overrides.zig");
const sessions = @import("../session.zig");
const global = @import("../../../global.zig");

const ThemePicker = @import("../theme_picker.zig");
const CompactTabStrip = @import("../compact_tab_strip.zig");

const log = std.log.scoped(.gtk_ghostty_window);

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"toolbar-visible" = struct {
            pub const name = "toolbar-visible";
            const impl = gobject.ext.defineProperty(name, Self, bool, .{
                .default = true,
                .accessor = gobject.ext.typedAccessor(Self, bool, .{ .getter = getToolbarVisible }),
            });
        };

        pub const @"tabs-compact" = struct {
            pub const name = "tabs-compact";
            const impl = gobject.ext.defineProperty(name, Self, bool, .{
                .default = false,
                .accessor = gobject.ext.typedAccessor(Self, bool, .{ .getter = getTabsCompact }),
            });
        };

        pub const @"session-enabled" = struct {
            pub const name = "session-enabled";
            const impl = gobject.ext.defineProperty(name, Self, bool, .{
                .default = false,
                .accessor = gobject.ext.typedAccessor(Self, bool, .{ .getter = getSessionEnabled }),
            });
        };
        pub const @"session-name" = struct {
            pub const name = "session-name";
            const impl = gobject.ext.defineProperty(name, Self, ?[:0]const u8, .{
                .default = null,
                .accessor = C.privateStringFieldAccessor("session_name"),
            });
        };
        /// False until the user saves the session. Unsaved sessions are
        /// never written to disk.
        pub const @"session-saved" = struct {
            pub const name = "session-saved";
            const impl = gobject.ext.defineProperty(name, Self, bool, .{
                .default = false,
                .accessor = gobject.ext.typedAccessor(Self, bool, .{ .getter = isSessionSaved }),
            });
        };
        /// The active surface is the focus that should be receiving all
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

        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Self) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };

        pub const @"titlebar-style" = struct {
            pub const name = "titlebar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                TitlebarStyle,
                .{
                    .default = .native,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        TitlebarStyle,
                        .{
                            .getter = Self.getTitlebarStyle,
                        },
                    ),
                },
            );
        };

        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };

        pub const @"quick-terminal" = struct {
            pub const name = "quick-terminal";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "quick_terminal",
                    ),
                },
            );
        };

        pub const @"tabs-autohide" = struct {
            pub const name = "tabs-autohide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsAutohide,
                    }),
                },
            );
        };

        pub const @"tabs-inverted" = struct {
            pub const name = "tabs-inverted";
            const impl = gobject.ext.defineProperty(name, Self, bool, .{
                .default = false,
                .accessor = gobject.ext.typedAccessor(
                    Self,
                    bool,
                    .{
                        .getter = Self.getTabsInverted,
                    },
                ),
            });
        };

        pub const @"tabs-wide" = struct {
            pub const name = "tabs-wide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsWide,
                    }),
                },
            );
        };

        pub const @"tabs-visible" = struct {
            pub const name = "tabs-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsVisible,
                    }),
                },
            );
        };

        pub const @"toolbar-style" = struct {
            pub const name = "toolbar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                adw.ToolbarStyle,
                .{
                    .default = .raised,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        adw.ToolbarStyle,
                        .{
                            .getter = Self.getToolbarStyle,
                        },
                    ),
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

    const Private = struct {
        /// Whether this window is a quick terminal. If it is then it
        /// behaves slightly differently under certain scenarios.
        quick_terminal: bool = false,

        /// Timeout source to react to this window becoming (in)active.
        handle_active_state_source: ?c_uint = null,

        /// The window decoration override. If this is not set then we'll
        /// inherit whatever the config has. This allows overriding the
        /// config on a per-window basis.
        window_decoration: ?configpkg.WindowDecoration = null,

        /// Binding group for our active tab.
        tab_bindings: *gobject.BindingGroup,

        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// State and logic for windowing protocol for a window.
        winproto: winprotopkg.Window,

        /// Kind of hacky to have this but this lets us know if we've
        /// initialized any single surface yet. We need this because we
        /// gate default size on this so that we don't resize the window
        /// after surfaces already exist.
        ///
        /// I think long term we can probably get rid of this by implementing
        /// a property or method that gets us all the surfaces in all the
        /// tabs and checking if we have zero or one that isn't initialized.
        ///
        /// For now, this logic is more similar to our legacy GTK side.
        surface_init: bool = false,

        /// True if the running program requested a resize (see
        /// resizeSurface) that toplevelComputeSize should not override.
        resize_requested: bool = false,

        /// See tabOverviewOpen for why we have this.
        tab_overview_focus_timer: ?c_uint = null,

        /// A weak reference to a command palette.
        command_palette: WeakRef(CommandPalette) = .empty,

        /// Tab page that the context menu was opened for.
        /// setup by `setup-menu`.
        context_menu_page: ?*adw.TabPage = null,

        /// The manually overridden title.
        title_override: ?[:0]const u8 = null,

        session_id: u64 = 0,
        session_name: ?[:0]const u8 = null,
        session_hash: ?u64 = null,
        archive_on_close: bool = false,
        session_archived: bool = false,
        session_saved: bool = false,
        replacing_session: bool = false,
        session_surface_pending: bool = false,
        session_restore_pending: bool = false,
        session_opened_pending: bool = false,
        toolbar_visible_override: ?bool = null,
        pane_decorations_override: ?bool = null,

        theme: ThemePicker.State = .{},
        theme_overlay: *gtk.Overlay,

        // Template bindings
        tab_overview: *adw.TabOverview,
        tab_bar: *adw.TabBar,
        tab_strip_header: *gtk.Box,
        tab_strip_handle: *gtk.WindowHandle,
        compact_tab_scroll: *gtk.ScrolledWindow,
        compact_tab_box: *gtk.Box,
        compact_strip: CompactTabStrip.State = .{},
        side_tab_scroll: *gtk.ScrolledWindow,
        side_tab_box: *gtk.Box,
        side_strip: CompactTabStrip.State = .{},
        tab_view: *adw.TabView,
        toolbar: *adw.ToolbarView,
        toast_overlay: *adw.ToastOverlay,
        session_label: *gtk.Label,
        session_button: *gtk.Button,
        session_icon: *gtk.Image,
        session_status: *gtk.Label,
        header_status: *gtk.Label,

        pub var offset: c_int = 0;
    };

    pub fn new(
        app: *Application,
        overrides: struct {
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *Self {
        const win = gobject.ext.newInstance(Self, .{
            .application = app,
        });

        if (overrides.title) |title| {
            // If the overrides have a title set, we set that immediately
            // so that any applications inspecting the window states see an
            // immediate title set when the window appears, rather than waiting
            // possibly a few event loop ticks for it to sync from the surface.
            win.as(gtk.Window).setTitle(title);
        }

        return win;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();
        priv.compact_strip.init(priv.tab_view, priv.compact_tab_box, priv.compact_tab_scroll, false);
        priv.side_strip.init(priv.tab_view, priv.side_tab_box, priv.side_tab_scroll, true);
        priv.theme_overlay = gtk.Overlay.new();
        // The whole tab content hosts the picker, rather than a single pane.
        _ = priv.tab_view.as(gobject.Object).ref();
        priv.toast_overlay.setChild(null);
        priv.theme_overlay.setChild(priv.tab_view.as(gtk.Widget));
        priv.toast_overlay.setChild(priv.theme_overlay.as(gtk.Widget));
        priv.tab_view.as(gobject.Object).unref();

        const config = config: {
            if (priv.config) |config| break :config config.get();
            const app = Application.default();
            const config = app.getConfig();
            priv.config = config;
            break :config config.get();
        };

        // We initialize our windowing protocol to none because we can't
        // actually initialize this until we get realized.
        priv.winproto = .none;

        // Add our dev CSS class if we're in debug mode.
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        // Setup our tab binding group. This ensures certain properties
        // are only synced from the currently active tab.
        priv.tab_bindings = gobject.BindingGroup.new();
        priv.tab_bindings.bind("title", self.as(gobject.Object), "title", .{});

        // Set our window icon. We can't set this in the blueprint file
        // because its dependent on the build config.
        self.as(gtk.Window).setIconName(build_config.bundle_id);
        // Initialize our actions
        self.initActionMap();

        // Start states based on config.
        if (config.maximize) self.as(gtk.Window).maximize();
        if (config.fullscreen != .false) self.as(gtk.Window).fullscreen();

        // If we have an explicit title set, we set that immediately
        // so that any applications inspecting the window states see
        // an immediate title set when the window appears, rather than
        // waiting possibly a few event loop ticks for it to sync from
        // the surface.
        if (config.title) |title| {
            self.as(gtk.Window).setTitle(title);
        }

        // We always sync our appearance at the end because loading our
        // config and such can affect our bindings which are setup initially
        // in initTemplate.
        self.syncAppearance();

        priv.session_id = sessions.newId(global.io());
        var name_buf: [sessions.max_haiku_name_bytes]u8 = undefined;
        self.setSessionName(sessions.haikuName(&name_buf, priv.session_id));
        self.setLuaStatus(Application.default().defaultLuaStatus());

        // We need to do this so that the title initializes properly,
        // I think because its a dynamic getter.
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    /// Setup our action map.
    fn initActionMap(self: *Self) void {
        const t_variant_type = glib.ext.VariantType.newFor(u64);
        defer t_variant_type.free();
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("new-session", actionNewSession, null),
            .init("rename-session", actionRenameSession, null),
            .init("open-session", actionOpenSession, t_variant_type),
            .init("manage-sessions", actionManageSessions, null),
            .init("switch-session", actionSwitchSession, null),
            .init("about", actionAbout, null),
            .init("close", actionClose, null),
            .init("close-tab", actionCloseTab, s_variant_type),
            .init("new-tab", actionNewTab, null),
            .init("new-window", actionNewWindow, null),
            .init("prompt-surface-title", actionPromptSurfaceTitle, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-context-tab-title", actionPromptContextTabTitle, null),
            .init("prompt-window-title", actionPromptWindowTitle, null),
            .init("ring-bell", actionRingBell, null),
            .init("split-right", actionSplitRight, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("split-down", actionSplitDown, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            // TODO: accept the surface that toggled the command palette
            .init("toggle-command-palette", actionToggleCommandPalette, null),
            .init("toggle-tab-overview", actionToggleTabOverview, null),
            .init("pick-theme", actionPickTheme, null),
            .init("toggle-toolbar", actionToggleToolbar, null),
            .init("toggle-inspector", actionToggleInspector, null),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Winproto backend for this window.
    pub fn winproto(self: *Self) *winprotopkg.Window {
        return &self.private().winproto;
    }

    /// Create a new tab with the given parent. The tab will be inserted
    /// at the position dictated by the `window-new-tab-position` config.
    /// The new tab will be selected.
    pub fn newTab(self: *Self, parent_: ?*CoreSurface, overrides: Overrides) void {
        _ = self.newTabPage(parent_, .tab, .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
            .wait_after_command = overrides.wait_after_command,
        });
    }

    pub fn newTabForWindow(self: *Self, parent_: ?*CoreSurface, overrides: Overrides) void {
        _ = self.newTabPage(
            parent_,
            .window,
            .{
                .command = overrides.command,
                .shell_integration = overrides.shell_integration,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
                .wait_after_command = overrides.wait_after_command,
            },
        );
    }

    fn newTabPage(
        self: *Self,
        parent_: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
        overrides: Overrides,
    ) *adw.TabPage {
        const priv: *Private = self.private();
        const tab_view = priv.tab_view;

        // Create our new tab object
        const tab = Tab.new(
            priv.config,
            .{
                .command = overrides.command,
                .shell_integration = overrides.shell_integration,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
                .wait_after_command = overrides.wait_after_command,
            },
        );

        if (parent_) |p| {
            // For a new window's first tab, inherit the parent's initial size hints.
            if (context == .window) {
                surfaceInit(p.rt_surface.gobj(), self);
            }
            tab.setParentWithContext(p, context);
        }

        // Get the position that we should insert the new tab at.
        const config = if (priv.config) |v| v.get() else {
            // If we don't have a config we just append it at the end.
            // This should never happen.
            return tab_view.append(tab.as(gtk.Widget));
        };
        const position = switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },

            .end => tab_view.getNPages(),
        };

        // Add the page and select it
        const page = tab_view.insert(tab.as(gtk.Widget), position);
        tab_view.setSelectedPage(page);

        // Create some property bindings
        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );
        // The page keyword is also what the tab overview searches.
        _ = tab.as(gobject.Object).bindProperty(
            "program-name",
            page.as(gobject.Object),
            "keyword",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindPropertyFull(
            "icon-name",
            page.as(gobject.Object),
            "icon",
            .{ .sync_create = true },
            &iconFromName,
            null,
            null,
            null,
        );

        return page;
    }

    /// Converts the tab's icon name to the page's icon.
    fn iconFromName(_: *gobject.Binding, from: *const gobject.Value, to: *gobject.Value, _: ?*anyopaque) callconv(.c) c_int {
        const name = from.getString() orelse return 0;
        to.takeObject(gio.ThemedIcon.new(name).as(gobject.Object));
        return 1;
    }

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    /// Select the tab as requested. Returns true if the tab selection
    /// changed.
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // Get our current tab numeric position
        const selected = tab_view.getSelectedPage() orelse return false;
        const current = tab_view.getPagePosition(selected);

        // Get our total
        const total = tab_view.getNPages();

        const goto: c_int = switch (n) {
            .previous => if (current > 0)
                current - 1
            else
                total - 1,

            .next => if (current < total - 1)
                current + 1
            else
                0,

            .last => total - 1,

            .n => |v| n: {
                // 1-indexed
                if (v == 0) return false;

                const n_int = std.math.cast(
                    c_int,
                    v,
                ) orelse return false;
                break :n @min(n_int - 1, total - 1);
            },
        };
        assert(goto >= 0);
        assert(goto < total);

        // If our target is the same as our current then we do nothing.
        if (goto == current) return false;

        // Add the page and select it
        const page = tab_view.getNthPage(goto);
        tab_view.setSelectedPage(page);

        return true;
    }

    /// Move the tab containing the given surface by the given amount.
    /// Returns if this affected any tab positioning.
    pub fn moveTab(
        self: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // If we have one tab we never move.
        const total = tab_view.getNPages();
        if (total == 1) return false;

        // Get the tab that contains the given surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;

        // Get the page position that contains the tab.
        const page = tab_view.getPage(tab.as(gtk.Widget));
        const pos = tab_view.getPagePosition(page);

        // Move it
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        assert(desired_pos >= 0);
        assert(desired_pos < total);

        return tab_view.reorderPage(page, desired_pos) != 0;
    }

    pub fn moveTabToNewWindow(self: *Self, surface: *Surface) bool {
        const tab_view = self.private().tab_view;
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;
        const page = tab_view.getPage(tab.as(gtk.Widget));

        // Skip if this is the only tab in the existing window
        if (tab_view.getNPages() <= 1) return false;

        const app = Application.default();
        const window = Window.new(app, .none);

        tab_view.transferPage(
            page,
            window.private().tab_view,
            0,
        );
        window.as(gtk.Window).present();
        return true;
    }

    /// Used by the compact strip when a drag is released outside a tab strip.
    pub fn detachTabPage(self: *Self, page: *adw.TabPage) void {
        _ = self.ref();
        defer self.unref();
        const source = self.private().tab_view;
        const target = tabViewCreateWindow(source, self);
        source.transferPage(page, target, 0);
        target.setSelectedPage(page);
    }

    pub fn toggleTabOverview(self: *Self) void {
        const priv = self.private();
        const tab_overview = priv.tab_overview;
        const is_open = tab_overview.getOpen() != 0;
        tab_overview.setOpen(@intFromBool(!is_open));
    }

    pub fn toggleToolbar(self: *Self) void {
        self.private().toolbar_visible_override = !self.getToolbarVisible();
        self.as(gobject.Object).notifyByPspec(properties.@"toolbar-visible".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"tabs-autohide".impl.param_spec);
        // A toggle from a menu or the palette must leave keyboard input in
        // the terminal, including when its former toolbar widget is hidden.
        if (self.getActiveSurface()) |surface| surface.grabFocus();
    }

    pub fn getPaneDecorations(self: *Self) bool {
        const priv = self.private();
        return priv.pane_decorations_override orelse
            if (priv.config) |config| config.get().@"gtk-pane-decorations" else false;
    }

    pub fn togglePaneDecorations(self: *Self) void {
        self.private().pane_decorations_override = !self.getPaneDecorations();
        self.refreshPaneDecorations();
        if (self.getActiveSurface()) |surface| surface.grabFocus();
    }

    fn refreshPaneDecorations(self: *Self) void {
        self.syncPaneDecorationStyle();
        const Wrapper = @import("surface_scrolled_window.zig").SurfaceScrolledWindow;
        for (Application.default().core().surfaces.items) |rt_surface| {
            const widget = rt_surface.gobj().as(gtk.Widget);
            if (ext.getAncestor(Self, widget) != self) continue;
            if (ext.getAncestor(Wrapper, widget)) |wrapper| wrapper.refreshDecoration();
        }
    }

    fn syncPaneDecorationStyle(self: *Self) void {
        const widget = self.as(gtk.Widget);
        if (self.getPaneDecorations()) widget.addCssClass("pane-decorations") else widget.removeCssClass("pane-decorations");
    }

    fn getToolbarVisible(self: *Self) bool {
        const priv = self.private();
        if (priv.toolbar_visible_override) |value| return value;
        const config = priv.config orelse return true;
        if (!config.get().@"gtk-toolbar-visible") return false;
        if (self.toolbarAutohideEnabled()) {
            return priv.session_saved or priv.tab_view.getNPages() > 1;
        }
        return true;
    }

    fn toolbarAutohideEnabled(self: *Self) bool {
        const config = self.private().config orelse return false;
        return config.get().@"gtk-toolbar-autohide" and self.getSessionEnabled();
    }

    /// Toggle the visible property.
    pub fn toggleVisibility(self: *Self) void {
        const widget = self.as(gtk.Widget);
        widget.setVisible(@intFromBool(widget.isVisible() == 0));
    }

    /// Updates various appearance properties. This should always be safe
    /// to call multiple times. This should be called whenever a change
    /// happens that might affect how the window appears (config change,
    /// fullscreen, etc.).
    fn syncAppearance(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        self.syncPaneDecorationStyle();

        // Toggle style classes based on whether we're using CSDs or SSDs.
        //
        // These classes are defined in the gtk.Window documentation:
        // https://docs.gtk.org/gtk4/class.Window.html#css-nodes.
        {
            // Reset all style classes first
            inline for (&.{
                "ssd",
                "csd",
                "solid-csd",
                "no-border-radius",
            }) |class|
                widget.removeCssClass(class);

            const csd_enabled = priv.winproto.clientSideDecorationEnabled();
            self.as(gtk.Window).setDecorated(@intFromBool(csd_enabled));

            if (csd_enabled) {
                const display = widget.getDisplay();

                // We do the exact same check GTK is doing internally and toggle
                // either the `csd` or `solid-csd` style, based on whether the user's
                // window manager is deemed _non-compositing_.
                //
                // In practice this only impacts users of traditional X11 window
                // managers (e.g. i3, dwm, awesomewm, etc.) and not X11 desktop
                // environments or Wayland compositors/DEs.
                if (display.isRgba() != 0 and display.isComposited() != 0) {
                    widget.addCssClass("csd");
                } else {
                    widget.addCssClass("solid-csd");
                }
            } else {
                widget.addCssClass("ssd");
                // Fix any artifacting that may occur in window corners.
                widget.addCssClass("no-border-radius");
            }
        }

        // Trigger all our dynamic properties that depend on the config.
        inline for (&.{
            "headerbar-visible",
            "tabs-autohide",
            "tabs-compact",
            "session-enabled",
            "tabs-inverted",
            "tabs-visible",
            "tabs-wide",
            "toolbar-style",
            "toolbar-visible",
            "titlebar-style",
        }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }

        // Remainder uses the config
        const config = if (priv.config) |v| v.get() else return;

        const compact = config.@"gtk-tabs-style" == .compact;
        priv.tab_bar.as(gtk.Widget).setVisible(@intFromBool(!compact));
        priv.compact_tab_scroll.as(gtk.Widget).setVisible(@intFromBool(compact));
        priv.compact_strip.configure(config.@"gtk-tabs-inverted");
        priv.compact_strip.setVisible(compact);
        priv.side_strip.configure(config.@"gtk-tabs-inverted");
        self.toggleCssClass("tabs-left", config.@"gtk-tabs-location" == .left);
        if (compact) {
            priv.tab_strip_header.as(gtk.Widget).addCssClass("compact-tabs");
        } else {
            priv.tab_strip_header.as(gtk.Widget).removeCssClass("compact-tabs");
        }

        configureTabRail(priv.tab_bar.as(gtk.Widget), false);

        // Only add a solid background if we're opaque.
        self.toggleCssClass(
            "background",
            config.@"background-opacity" >= 1,
        );

        // Move the tab bar to the proper location.
        // With the tabs at the left, the strip is in no toolbar.
        if (ext.getAncestor(adw.ToolbarView, priv.tab_strip_handle.as(gtk.Widget)) != null)
            priv.toolbar.remove(priv.tab_strip_handle.as(gtk.Widget));
        switch (config.@"gtk-tabs-location") {
            .top => priv.toolbar.addTopBar(priv.tab_strip_handle.as(gtk.Widget)),
            .bottom => priv.toolbar.addBottomBar(priv.tab_strip_handle.as(gtk.Widget)),
            // The side panel shows the tabs instead.
            .left => {},
        }
        self.refreshPaneDecorations();

        // Do our window-protocol specific appearance sync.
        priv.winproto.syncAppearance() catch |err| {
            log.warn("failed to sync winproto appearance error={}", .{err});
        };
    }

    /// Sync the state of any actions on this window.
    fn syncActions(self: *Self) void {
        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };

        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }

    fn toggleCssClass(self: *Self, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Perform a binding action on the window's active surface.
    fn performBindingAction(
        self: *Self,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    /// Queue a simple text-based toast. All text-based toasts share the
    /// same timeout for consistency.
    ///
    // This is not `pub` because we should be using signals emitted by
    // other widgets to trigger our toasts. Other objects should not
    // trigger toasts directly.
    fn addToast(self: *Self, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }

    /// Show a message from a Lua script (`ghostty.toast`) or a Lua error.
    /// Lua scripts are not widgets, so they cannot use signals for this.
    pub fn showLuaToast(self: *Self, text: [:0]const u8) void {
        self.addToast(text.ptr);
    }

    fn connectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| self.connectSurfaceHandler(entry.view);
    }

    fn connectSurfaceHandler(self: *Self, surface: *Surface) void {
        const priv = self.private();
        surface.applyTheme(priv.theme.appearance) catch |err| log.warn("applying window theme: {}", .{err});
        // Before adding any new signal handlers, disconnect any that we may
        // have added before. Otherwise we may get multiple handlers for the
        // same signal.
        _ = gobject.signalHandlersDisconnectMatched(
            surface.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        _ = Surface.signals.init.connect(surface, *Self, themeSurfaceInitialized, self, .{});
        _ = Surface.signals.@"present-request".connect(
            surface,
            *Self,
            surfacePresentRequest,
            self,
            .{},
        );
        _ = Surface.signals.@"clipboard-write".connect(
            surface,
            *Self,
            surfaceClipboardWrite,
            self,
            .{},
        );
        _ = Surface.signals.menu.connect(
            surface,
            *Self,
            surfaceMenu,
            self,
            .{},
        );
        _ = Surface.signals.@"toggle-fullscreen".connect(
            surface,
            *Self,
            surfaceToggleFullscreen,
            self,
            .{},
        );
        _ = Surface.signals.@"toggle-maximize".connect(
            surface,
            *Self,
            surfaceToggleMaximize,
            self,
            .{},
        );

        // If we've never had a surface initialize yet, then we register
        // this signal. Its theoretically possible to launch multiple surfaces
        // before init so we could register this on multiple and that is not
        // a problem because we'll check the flag again in each handler.
        if (!priv.surface_init) {
            _ = Surface.signals.init.connect(
                surface,
                *Self,
                surfaceInit,
                self,
                .{},
            );
        }
        if (priv.session_surface_pending) {
            _ = Surface.signals.init.connect(
                surface,
                *Self,
                restoredSurfaceInitialized,
                self,
                .{},
            );
        }
    }

    fn floatingAdded(_: *Tab, surface: *Surface, self: *Self) callconv(.c) void {
        self.connectSurfaceHandler(surface);
    }

    fn floatingRemoved(_: *Tab, surface: *Surface, self: *Self) callconv(.c) void {
        _ = gobject.signalHandlersDisconnectMatched(surface.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
    }

    fn restoredSurfaceInitialized(_: *Surface, self: *Self) callconv(.c) void {
        self.private().session_surface_pending = false;
    }

    /// Restored widgets exist before GTK allocates and initializes their cores.
    /// Losing the old window's last core during that gap must not quit the app.
    pub fn hasPendingSessionSurface(self: *Self) bool {
        if (self.private().session_surface_pending) return true;
        // Closing the last tiled pane can reveal a lazily initialized float.
        // Keep the application alive until GTK gives it an allocation.
        const view = self.getTabView();
        for (0..@intCast(view.getNPages())) |index| {
            const tab = gobject.ext.cast(Tab, view.getNthPage(@intCast(index)).getChild()) orelse continue;
            if (tab.floatingCount() == 0) continue;
            if (tab.getActiveSurface()) |surface| if (surface.core() == null) return true;
        }
        return false;
    }

    /// Disconnect all the surface handlers for the given tree. This should
    /// be called whenever a tree is no longer present in the window, e.g.
    /// when a tab is detached or the tree changes.
    fn disconnectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    /// Callback to handle this window becoming active or inactive.
    /// Triggered by propIsActive with a timeout to debounce temporary
    /// changes in active state.
    fn handleActiveState(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.handle_active_state_source = null;

        // Hide quick-terminal if set to autohide
        if (self.isQuickTerminal()) {
            if (self.getConfig()) |cfg| {
                if (cfg.get().@"quick-terminal-autohide" and
                    self.as(gtk.Window).isActive() == 0 and
                    self.as(gtk.Widget).isVisible() == 1)
                {
                    self.toggleVisibility();
                }
            }
        }

        // Don't change urgency if we're not the active window.
        if (self.as(gtk.Window).isActive() == 0) return 0;

        self.winproto().setUrgent(false) catch |err| {
            log.warn(
                "winproto failed to reset urgency={}",
                .{err},
            );
        };
        return 0;
    }

    //---------------------------------------------------------------
    // Properties

    /// Whether this terminal is a quick terminal or not.
    pub fn isQuickTerminal(self: *Self) bool {
        return self.private().quick_terminal;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tab = self.getSelectedTab() orelse return null;
        return tab.getActiveSurface();
    }

    /// Returns the configuration for this window. The reference count
    /// is not increased.
    pub fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }

    /// Get the tab view for this window.
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }

    pub fn sessionId(self: *Self) u64 {
        return self.private().session_id;
    }

    fn getSessionEnabled(self: *Self) bool {
        return !self.isQuickTerminal() and if (self.getConfig()) |c| c.get().@"window-save-state" == .always else false;
    }

    fn setSessionName(self: *Self, name: []const u8) void {
        const priv = self.private();
        if (priv.session_name) |old| glib.free(@ptrCast(@constCast(old)));
        priv.session_name = glib.ext.dupeZ(u8, name);
        self.as(gobject.Object).notifyByPspec(properties.@"session-name".impl.param_spec);
    }

    /// All strings in the captured manifest belong to alloc.
    pub fn captureSession(self: *Self, alloc: std.mem.Allocator) !sessions.Session {
        const priv = self.private();
        var tabs: std.ArrayList(sessions.Tab) = .empty;
        var selected: usize = 0;
        for (0..@intCast(priv.tab_view.getNPages())) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const tree = tab.getSurfaceTree() orelse &Surface.Tree.empty;
            // Closing the final terminal can briefly leave an empty tab before
            // its close-request removes the page. It is not a restorable layout.
            if (tree.isEmpty() and tab.floatingCount() == 0) continue;
            if (page == priv.tab_view.getSelectedPage()) selected = tabs.items.len;
            const nodes = try alloc.alloc(sessions.Node, tree.nodes.len);
            for (tree.nodes, nodes, 0..) |node, *out, node_index| out.* = switch (node) {
                .leaf => |surface| .{ .leaf = .{
                    .id = surface.sessionId(),
                    .snapshot = surface.sessionSnapshotId(),
                    .relaunch = try surface.captureSessionRelaunch(alloc),
                    .working_directory = if (surface.getSessionWorkingDirectory()) |pwd|
                        if (std.fs.path.isAbsolute(pwd)) try alloc.dupeSentinel(u8, pwd, 0) else null
                    else
                        null,
                    .title = if (surface.getTitleOverride()) |t| try alloc.dupeSentinel(u8, t, 0) else null,
                } },
                .split => |split| .{ .split = .{
                    .layout = if (split.layout == .horizontal) .horizontal else .vertical,
                    .ratio = @floatCast(split.ratio),
                    .left = @intCast(split.left.idx()),
                    .right = @intCast(split.right.idx()),
                    .stacked = split.stacked,
                    .stack_selected = if (split.stacked) tree.nodes[tree.selected(@fromBackingInt(@intCast(node_index))).idx()].leaf.sessionId() else null,
                } },
            };
            const active = if (tab.getSplitTree().getActiveSurface()) |surface| tree.locate(surface) else null;
            const floating = try alloc.alloc(sessions.Floating, tab.floatingCount());
            for (floating, 0..) |*out, index| {
                const surface = tab.floatingSurface(index);
                out.* = .{
                    .name = if (tab.floatingName(surface)) |name| try alloc.dupeSentinel(u8, name, 0) else null,
                    .geometry = tab.floatingGeometryFor(surface),
                    .stacking = tab.floatingStackIndex(surface),
                    .pane = .{ .leaf = .{
                        .id = surface.sessionId(),
                        .snapshot = surface.sessionSnapshotId(),
                        .relaunch = try surface.captureSessionRelaunch(alloc),
                        .working_directory = if (surface.getSessionWorkingDirectory()) |pwd|
                            if (std.fs.path.isAbsolute(pwd)) try alloc.dupeSentinel(u8, pwd, 0) else null
                        else
                            null,
                        .title = if (surface.getTitleOverride()) |title| try alloc.dupeSentinel(u8, title, 0) else null,
                    } },
                };
            }
            try tabs.append(alloc, .{
                .floating = floating,
                .floating_selected = tab.floatingSelected(),
                .floating_visible = tab.floatingVisible(),
                .floating_geometry = tab.floatingGeometry(),
                .title = if (tab.getTitleOverride()) |t| try alloc.dupeSentinel(u8, t, 0) else null,
                .nodes = nodes,
                .active = if (active) |h| @intCast(h.idx()) else firstLeaf(tree),
                .zoomed = if (tree.zoomed) |h| @intCast(h.idx()) else null,
            });
        }
        var width: c_int = 800;
        var height: c_int = 600;
        self.as(gtk.Window).getDefaultSize(&width, &height);
        return .{
            .id = priv.session_id,
            .name = try alloc.dupeSentinel(u8, priv.session_name orelse "Session", 0),
            .width = std.math.clamp(width, 1, 32767),
            .height = std.math.clamp(height, 1, 32767),
            .maximized = self.as(gtk.Window).isMaximized() != 0,
            .title = if (priv.title_override) |t| try alloc.dupeSentinel(u8, t, 0) else null,
            .selected_tab = selected,
            .tabs = try tabs.toOwnedSlice(alloc),
        };
    }

    fn firstLeaf(tree: *const Surface.Tree) u32 {
        var it = tree.iterator();
        return if (it.next()) |entry| @intCast(entry.handle.idx()) else 0;
    }

    pub fn sessionHash(self: *Self) ?u64 {
        return self.private().session_hash;
    }

    pub fn setSessionHash(self: *Self, hash: ?u64) void {
        self.private().session_hash = hash;
    }

    pub fn restoreSession(manifest: sessions.Session) !*Self {
        try manifest.validate();
        const app = Application.default();
        const window = Self.new(app, .none);
        errdefer window.as(gtk.Window).destroy();
        const priv = window.private();
        priv.session_id = manifest.id;
        // Saved window geometry wins over the first shell's initial size.
        priv.surface_init = true;
        window.setSessionName(manifest.name);
        window.markSessionSaved();
        window.setTitleOverride(manifest.title);
        window.as(gtk.Window).setDefaultSize(manifest.width, manifest.height);
        if (manifest.maximized) window.as(gtk.Window).maximize() else window.as(gtk.Window).unmaximize();
        for (manifest.tabs) |saved| {
            const page = window.newTabPage(null, .tab, .none);
            const tab = gobject.ext.cast(Tab, page.getChild()).?;
            const widget = tab.getSplitTree();
            for (saved.floating) |floating| {
                const surface = try restoreSessionSurface(manifest.id, floating.pane.leaf);
                defer surface.unref();
                try tab.addFloating(surface, floating.name);
            }
            var tree = if (saved.nodes.len > 0) try restoreSessionNode(widget, manifest.id, saved.nodes, 0) else Surface.Tree.empty;
            defer tree.deinit();
            var active: ?*Surface = null;
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view.sessionId() == saved.nodes[saved.active].leaf.id) {
                    active = entry.view;
                    tree.select(entry.handle);
                }
                if (saved.zoomed) |z| {
                    if (entry.view.sessionId() == saved.nodes[z].leaf.id) tree.zoom(entry.handle);
                }
            }
            if (active) |s| widget.setActiveSurface(s);
            widget.setTree(&tree);
            tab.setTitleOverride(saved.title);
            tab.restoreFloatingState(saved);
        }
        priv.tab_view.setSelectedPage(priv.tab_view.getNthPage(@intCast(manifest.selected_tab)));
        return window;
    }

    /// Opening from a disposable window reuses its toplevel. Saved windows and
    /// quick terminals retain the normal open-or-focus behavior.
    pub fn openSession(self: *Self, id: u64, archived: bool) !void {
        const app = Application.default();
        if (!app.sessionsEnabled()) return;
        if (self.isQuickTerminal() or self.isSessionSaved() or app.sessionWindow(id) != null) {
            try openSessionWindow(id, archived);
            return;
        }
        if (self.private().session_restore_pending) return error.SessionRestorePending;
        if (!self.getNeedsConfirmQuit()) return self.replaceSession(id, archived);

        const request = try app.allocator().create(SessionRestoreRequest);
        request.* = .{ .window = self.ref(), .id = id, .archived = archived };
        self.private().session_restore_pending = true;
        const dialog = adw.AlertDialog.new(
            i18n._("Restore Session Here?"),
            i18n._("All terminal sessions in this unsaved window will be terminated and replaced by the saved session."),
        );
        dialog.addResponse("cancel", i18n._("Cancel"));
        dialog.addResponse("restore", i18n._("Restore"));
        dialog.setResponseAppearance("restore", .destructive);
        dialog.setDefaultResponse("cancel");
        dialog.setCloseResponse("cancel");
        dialog.choose(self.as(gtk.Widget), null, sessionRestoreConfirmed, request);
    }

    const SessionRestoreRequest = struct { window: *Self, id: u64, archived: bool };

    fn openSessionWindow(id: u64, archived: bool) !void {
        const app = Application.default();
        const unarchive = archived and app.sessionWindow(id) == null;
        if (unarchive) try app.archiveSession(id, false);
        errdefer if (unarchive) app.archiveSession(id, true) catch |err| {
            log.warn("unable to roll back session unarchive err={}", .{err});
        };
        try app.openSession(id);
    }

    fn sessionRestoreConfirmed(source: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const request: *SessionRestoreRequest = @ptrCast(@alignCast(ud orelse return));
        const self = request.window;
        defer self.unref();
        defer Application.default().allocator().destroy(request);
        self.private().session_restore_pending = false;
        const dialog = gobject.ext.cast(adw.AlertDialog, source orelse return) orelse return;
        const response = dialog.chooseFinish(result);
        if (self.as(gtk.Widget).getMapped() == 0) return;
        if (std.mem.orderZ(u8, response, "restore") != .eq) {
            if (self.getActiveSurface()) |surface| surface.grabFocus();
            return;
        }
        self.replaceSession(request.id, request.archived) catch |err| {
            log.warn("unable to restore session in place err={}", .{err});
            self.addToast(i18n._("Unable to restore this session."));
        };
    }

    fn replaceSession(self: *Self, id: u64, archived: bool) !void {
        const app = Application.default();
        // The window may have been saved, or the destination opened elsewhere,
        // while its confirmation dialog was waiting.
        if (self.isSessionSaved() or app.sessionWindow(id) != null) {
            try openSessionWindow(id, archived);
            return;
        }
        if (!app.sessionsEnabled()) return;
        // Defer unarchiving until confirmation, and undo it on load failure.
        if (archived) try app.archiveSession(id, false);
        errdefer if (archived) app.archiveSession(id, true) catch |err| {
            log.warn("unable to roll back session unarchive err={}", .{err});
        };
        const dir = try app.sessionDir();
        defer dir.close(global.io());
        const manifest = try sessions.load(dir, global.io(), app.allocator(), id);
        defer manifest.deinit();

        // Build everything offscreen before touching the current layout. Page
        // transfers are the same native operation used for moving live tabs.
        const staged = try Self.restoreSession(manifest.value);
        defer staged.as(gtk.Window).destroy();
        staged.private().session_saved = false;
        staged.private().replacing_session = true;
        const priv = self.private();
        priv.replacing_session = true;
        priv.session_surface_pending = true;
        defer priv.replacing_session = false;
        self.cancelThemePicker();
        if (app.picker()) |service| service.cancelWindow(self);
        const old_count = priv.tab_view.getNPages();
        const staged_view = staged.private().tab_view;
        const selected = staged_view.getSelectedPage();
        while (staged_view.getNPages() > 0) {
            staged_view.transferPage(staged_view.getNthPage(0), priv.tab_view, priv.tab_view.getNPages());
        }
        var remaining = old_count;
        while (remaining > 0) : (remaining -= 1) {
            const page = priv.tab_view.getNthPage(0);
            // Move the old layout into the hidden staging window for disposal.
            // This also handles tabs already waiting on a close confirmation.
            const position = if (page.getPinned() != 0)
                staged_view.getNPinnedPages()
            else
                staged_view.getNPages();
            priv.tab_view.transferPage(page, staged_view, position);
        }
        priv.session_id = manifest.value.id;
        priv.session_hash = null;
        priv.session_archived = false;
        priv.archive_on_close = false;
        // Do not apply saved window geometry: this is the same desktop window.
        priv.surface_init = true;
        self.setSessionName(manifest.value.name);
        self.setTitleOverride(manifest.value.title);
        self.markSessionSaved();
        if (selected) |page| priv.tab_view.setSelectedPage(page);
        if (self.getActiveSurface()) |surface| {
            if (surface.core() != null) priv.session_surface_pending = false;
            surface.grabFocus();
        }
        app.saveSessions();
        self.emitSessionOpened();
    }

    fn restoreSessionSurface(session_id: u64, leaf: @FieldType(sessions.Node, "leaf")) std.mem.Allocator.Error!*Surface {
        var relaunch = leaf.relaunch;
        if (relaunch) |record| {
            if (!record.valid() or !Application.default().sessionRelaunchAllowed(record.program)) relaunch = null;
        }
        const cwd = cwd: {
            if (relaunch) |record| {
                if (std.Io.Dir.cwd().openDir(global.io(), record.cwd, .{})) |dir| {
                    dir.close(global.io());
                    break :cwd record.cwd;
                } else |_| relaunch = null;
            }
            const path = leaf.working_directory orelse break :cwd null;
            const dir = std.Io.Dir.cwd().openDir(global.io(), path, .{}) catch {
                log.warn("session directory no longer available: {s}", .{path});
                break :cwd null;
            };
            dir.close(global.io());
            break :cwd path;
        };
        const surface: *Surface = .new(.{
            .command = null,
            .shell_integration = null,
            .working_directory = cwd,
            .title = leaf.title,
        });
        _ = surface.refSink();
        errdefer surface.unref();
        surface.restoreSessionId(leaf.id);
        surface.restoreSessionSnapshot(session_id, leaf.snapshot);
        if (relaunch) |record| try surface.restoreSessionRelaunch(record);
        return surface;
    }

    fn restoreSessionNode(widget: *SplitTree, session_id: u64, nodes: []const sessions.Node, index: u32) std.mem.Allocator.Error!Surface.Tree {
        const alloc = Application.default().allocator();
        switch (nodes[index]) {
            .leaf => |leaf| {
                const surface = try restoreSessionSurface(session_id, leaf);
                defer surface.unref();
                surface.bindIsSplit(widget);
                return Surface.Tree.init(alloc, surface);
            },
            .split => |split| {
                var left = try restoreSessionNode(widget, session_id, nodes, split.left);
                defer left.deinit();
                var right = try restoreSessionNode(widget, session_id, nodes, split.right);
                defer right.deinit();
                var result = try left.split(alloc, .root, if (split.layout == .horizontal) .right else .down, @floatCast(split.ratio), &right);
                if (split.stacked) {
                    var selected = result.nodes[result.deepest(.left, .root).idx()].leaf;
                    var it = result.iterator();
                    while (it.next()) |entry| if (split.stack_selected == entry.view.sessionId()) {
                        selected = entry.view;
                        break;
                    };
                    result.setStack(.root, selected);
                }
                return result;
            },
        }
    }

    pub fn emitSessionOpened(self: *Self) void {
        self.setLuaStatus(Application.default().defaultLuaStatus());
        self.private().session_opened_pending = true;
        self.flushSessionOpened();
    }

    pub fn flushSessionOpened(self: *Self) void {
        if (!self.private().session_opened_pending) return;
        const active = self.getActiveSurface() orelse return;
        const surface = active.core() orelse return;
        self.private().session_opened_pending = false;
        Application.default().emitLuaEvent(.{
            .kind = .session_opened,
            .surface = surface.id,
            .session_id = self.sessionId(),
            .name = self.private().session_name,
        });
    }

    pub fn setLuaStatus(self: *Self, text: [:0]const u8) void {
        const priv = self.private();
        // Lua accepts up to two lines. Present them as one quiet status line
        // in the chrome; retain the original text in the tooltip.
        var buffer: [512]u8 = undefined;
        var stream: std.Io.Writer = .fixed(&buffer);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (!first) stream.writeAll(" · ") catch break;
            stream.writeAll(line) catch break;
            first = false;
        }
        stream.writeByte(0) catch return;
        const display: [:0]const u8 = buffer[0 .. stream.end - 1 :0];
        for ([_]*gtk.Label{ priv.session_status, priv.header_status }) |label| {
            label.setLabel(display);
            label.as(gtk.Widget).setTooltipText(if (text.len > 0) text else null);
            label.as(gtk.Widget).setVisible(@intFromBool(display.len > 0));
        }
    }

    fn actionSwitchSession(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = self.switchSession();
    }

    pub fn switchSession(self: *Self) bool {
        if (!Application.default().sessionsEnabled()) return false;
        @import("session_manager.zig").SessionManager.present(self);
        return true;
    }

    fn actionManageSessions(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = self.switchSession();
    }

    pub fn renameSession(self: *Self, name: []const u8) void {
        self.setSessionName(name);
        Application.default().saveSessions();
    }

    pub fn isSessionArchived(self: *Self) bool {
        return self.private().session_archived;
    }

    pub fn isSessionSaved(self: *Self) bool {
        return self.private().session_saved;
    }

    fn markSessionSaved(self: *Self) void {
        const priv = self.private();
        priv.session_saved = true;
        priv.session_label.as(gtk.Widget).removeCssClass("dim-label");
        priv.session_icon.as(gtk.Widget).removeCssClass("dim-label");
        self.as(gobject.Object).notifyByPspec(properties.@"session-saved".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"toolbar-visible".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"tabs-autohide".impl.param_spec);
    }

    /// Save this window's session from now on, renamed to `name` if it is
    /// not null. Later changes are saved like in any saved session.
    pub fn saveSession(self: *Self, name: ?[]const u8) void {
        if (name) |v| self.setSessionName(v);
        self.markSessionSaved();
        Application.default().saveSessions();
    }

    pub fn markSessionArchived(self: *Self) void {
        self.private().session_archived = true;
    }

    pub fn archiveAndClose(self: *Self) void {
        if (self.private().archive_on_close) return;
        self.private().archive_on_close = true;
        self.as(gtk.Window).present();
        self.as(gtk.Window).close();
    }

    fn actionNewSession(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        createSession(null);
    }

    /// Open a new session window. With a name, the session is saved.
    /// Without one, it is unsaved and keeps the haiku name that every new
    /// window gets, like any other new window.
    pub fn createSession(name: ?[]const u8) void {
        if (!Application.default().sessionsEnabled()) return;
        const window = Self.new(Application.default(), .none);
        window.newTab(null, .none);
        Application.default().presentSessionWindow(window);
        if (name) |v| window.saveSession(v);
    }

    fn actionRenameSession(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        if (!Application.default().sessionsEnabled()) return;
        self.promptSessionName();
    }

    fn promptSessionName(self: *Self) void {
        const dialog = TitleDialog.new(.session, self.private().session_name);
        dialog.as(adw.AlertDialog).setBody(i18n._("Name this session to find its tabs and splits later."));
        _ = TitleDialog.signals.set.connect(dialog, *Self, sessionNameSet, self, .{});
        _ = adw.Dialog.signals.closed.connect(dialog.as(adw.Dialog), *Self, sessionNameClosed, self, .{ .after = true });
        dialog.present(self.as(gtk.Widget));
    }

    fn sessionNameClosed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        if (self.as(gtk.Widget).getMapped() == 0) return;
        if (self.getActiveSurface()) |surface| surface.grabFocus();
    }

    fn sessionNameSet(_: *TitleDialog, value: [*:0]const u8, self: *Self) callconv(.c) void {
        const name = std.mem.trim(u8, std.mem.span(value), &std.ascii.whitespace);
        if (!sessions.validName(name)) {
            self.addToast(i18n._("Enter a short session name without line breaks."));
            return;
        }
        self.setSessionName(name);
        Application.default().saveSessions();
    }

    fn actionOpenSession(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        const value = param orelse return;
        self.openSession(value.getUint64(), false) catch |err| {
            log.warn("unable to open session err={}", .{err});
            self.addToast(i18n._("Unable to restore this session."));
        };
    }

    /// Get the current window decoration value for this window.
    pub fn getWindowDecoration(self: *Self) configpkg.WindowDecoration {
        const priv = self.private();
        if (priv.window_decoration) |v| return v;
        if (priv.config) |v| return v.get().@"window-decoration";
        return .auto;
    }

    /// Resize the window so that the given surface is the given size, as
    /// requested by the running program. See `apprt.action.ResizeWindow`.
    /// This is only done if the surface is the only terminal in the window
    /// and the compositor doesn't own the window size.
    pub fn resizeSurface(
        self: *Self,
        surface: *Surface,
        size: apprt.action.ResizeWindow,
    ) bool {
        if (self.isQuickTerminal() or
            self.isMaximized() or
            self.isFullscreen() or
            self.isTiled()) return false;
        if (self.getTabView().getNPages() != 1) return false;
        const tree = ext.getAncestor(
            SplitTree,
            surface.as(gtk.Widget),
        ) orelse return false;
        if (tree.getIsSplit()) return false;

        // The requested size is in the surface's content scale, which also
        // includes the font DPI, so we compute the change in device pixels
        // and then convert it to the window's logical pixels. Resizing the
        // window by the change accounts for the headerbar and tab bar.
        const scale = surface.getContentScale();
        const current = surface.getSize();
        const factor: f32 = @floatFromInt(self.as(gtk.Widget).getScaleFactor());
        const dw = resizeDelta(size.width, scale.x, current.width, factor);
        const dh = resizeDelta(size.height, scale.y, current.height, factor);

        const widget = self.as(gtk.Widget);
        self.private().resize_requested = true;
        self.as(gtk.Window).setDefaultSize(
            widget.getWidth() + dw,
            widget.getHeight() + dh,
        );
        return true;
    }

    /// Returns the change in logical pixels from the current device pixel
    /// size to the requested size, or zero if the requested size is zero.
    fn resizeDelta(requested: u32, scale: f32, current: u32, factor: f32) c_int {
        if (requested == 0) return 0;
        const px = @as(f32, @floatFromInt(requested)) * scale;
        return @intFromFloat(@round((px - @as(f32, @floatFromInt(current))) / factor));
    }

    /// Toggle the window decorations for this window.
    pub fn toggleWindowDecorations(self: *Self) void {
        const priv = self.private();

        if (priv.window_decoration) |_| {
            // Unset any previously set window decoration settings
            self.setWindowDecoration(null);
            return;
        }

        const config = if (priv.config) |v| v.get() else return;
        self.setWindowDecoration(switch (config.@"window-decoration") {
            // Use auto when the decoration is initially none
            .none => .auto,

            // Anything non-none to none
            .auto, .client, .server => .none,
        });
    }

    /// Set the window decoration override for this window. If this is null,
    /// then we'll revert back to the configuration's default.
    fn setWindowDecoration(
        self: *Self,
        new_: ?configpkg.WindowDecoration,
    ) void {
        const priv = self.private();
        priv.window_decoration = new_;
        self.syncAppearance();
    }

    /// Get the currently selected tab as a Tab object.
    fn getSelectedTab(self: *Self) ?*Tab {
        const priv = self.private();
        const page = priv.tab_view.getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        return gobject.ext.cast(Tab, child);
    }

    /// Returns true if this window needs confirmation before quitting.
    fn getNeedsConfirmQuit(self: *Self) bool {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        assert(n >= 0);

        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child) orelse {
                log.warn("unexpected non-Tab child in tab view", .{});
                continue;
            };
            if (tab.getNeedsConfirmQuit()) return true;
        }

        return false;
    }

    fn isFullscreen(self: *Window) bool {
        return self.as(gtk.Window).isFullscreen() != 0;
    }

    fn isMaximized(self: *Window) bool {
        return self.as(gtk.Window).isMaximized() != 0;
    }

    fn isTiled(self: *Window) bool {
        const surface = self.as(gtk.Native).getSurface() orelse return false;
        const toplevel = gobject.ext.cast(gdk.Toplevel, surface) orelse return false;
        return toplevel.getState().tiled;
    }

    fn getHeaderbarVisible(self: *Self) bool {
        const priv = self.private();

        // Never display the header bar when CSDs are disabled.
        const csd_enabled = priv.winproto.clientSideDecorationEnabled();
        if (!csd_enabled) return false;

        // Never display the header bar as a quick terminal.
        if (priv.quick_terminal) return false;

        // If we're fullscreen we never show the header bar.
        if (self.isFullscreen()) return false;

        // The remainder needs a config
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();

        // *Conditionally* disable the header bar when maximized, and
        // gtk-titlebar-hide-when-maximized is set
        if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") {
            return false;
        }

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs never show the titlebar.
            .tabs => false,

            // If the titlebar style is native show the titlebar if configured
            // to do so.
            .native => config.@"gtk-titlebar",
        };
    }

    fn getTabsAutohide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        // Explicitly showing toolbars or using the session-aware visibility
        // policy must also reveal a single tab in the native titlebar style.
        if (priv.toolbar_visible_override == true or self.toolbarAutohideEnabled()) return false;

        // Quick terminals have no session selector or separate titlebar to
        // preserve. Use the normal tab-count policy even with combined chrome.
        if (self.isQuickTerminal()) return config.@"window-show-tab-bar" != .always;

        // Keep the session selector reachable even with a single tab when
        // automatic toolbar hiding is disabled.
        if (!self.isQuickTerminal() and config.@"window-save-state" == .always) return false;

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs we cannot autohide.
            .tabs => false,

            .native => switch (config.@"window-show-tab-bar") {
                // Auto we always autohide... obviously.
                .auto => true,

                // Always we never autohide because we always show the tab bar.
                .always => false,

                // Never we autohide because it doesn't actually matter,
                // since getTabsVisible will return false.
                .never => true,
            },
        };
    }

    fn getTabsVisible(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        if (self.isQuickTerminal()) return config.@"window-show-tab-bar" != .never;

        switch (config.@"gtk-titlebar-style") {
            .tabs => {
                // *Conditionally* disable the tab bar when maximized, the titlebar
                // style is tabs, and gtk-titlebar-hide-when-maximized is set.
                if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") return false;

                // If the titlebar style is tabs the tab bar must always be visible.
                return true;
            },
            .native => {
                return switch (config.@"window-show-tab-bar") {
                    .always, .auto => true,
                    .never => false,
                };
            },
        }
    }

    fn getTabsInverted(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return false;
        return config.@"gtk-tabs-inverted";
    }

    /// Keep native expansion and overflow, with a smaller minimum rail width
    /// in compact mode. Pinned tabs retain their natural width.
    fn configureTabRail(widget: *gtk.Widget, compact: bool) void {
        if (gobject.ext.cast(gtk.ScrolledWindow, widget)) |scroll| {
            if (scroll.getChild()) |child| {
                if (std.mem.eql(u8, std.mem.span(child.getCssName()), "tabbox")) {
                    const pinned = widget.hasCssClass("pinned") != 0;
                    if (pinned) {
                        scroll.setPropagateNaturalWidth(1);
                        widget.setHalign(if (compact) .start else .fill);
                        return;
                    }
                    scroll.setPropagateNaturalWidth(0);
                    scroll.setMinContentWidth(if (compact) 0 else 100);
                    widget.setHalign(.fill);
                    return;
                }
            }
        }
        var child = widget.getFirstChild();
        while (child) |current| : (child = current.getNextSibling()) configureTabRail(current, compact);
    }

    fn getTabsWide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        // Expansion only applies to the native bar; the compact strip always
        // measures its labels independently.
        return config.@"gtk-tabs-style" != .compact and config.@"gtk-wide-tabs";
    }

    fn getTabsCompact(self: *Self) bool {
        const config = self.private().config orelse return false;
        return config.get().@"gtk-tabs-style" == .compact;
    }

    fn getToolbarStyle(self: *Self) adw.ToolbarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .raised;
        return switch (config.@"gtk-toolbar-style") {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
    }

    fn getTitlebarStyle(self: *Self) TitlebarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .native;
        return config.@"gtk-titlebar-style";
    }

    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.toolbar_visible_override = null;
        priv.pane_decorations_override = null;
        self.refreshPaneDecorations();
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.@"app-notifications".@"config-reload") {
                self.addToast(i18n._("Reloaded the configuration"));
            }
        }

        self.syncAppearance();
    }

    fn propIsActive(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Use a timeout callback to wait for focus state to settle,
        // because depending on the windowing backend the window might
        // become inactive and immediately active again. This happens
        // e.g. on Wayland when opening a context menu or a submenu
        // inside a context menu.
        if (priv.handle_active_state_source == null) {
            priv.handle_active_state_source = glib.timeoutAddFull(
                // Use priority of an idle callback instead of the higher
                // default timeout priority. This allows us to use a shorter
                // timeout duration.
                glib.PRIORITY_DEFAULT_IDLE,
                // 50ms was chosen to be conservative. From testing we know
                // that, depending on the backend and system performance, a
                // shorter timeout or just an idle callback can be enough for
                // the focus to settle. On the other hand a delay of e.g. 10ms
                // does not work reliably on some slow systems. The downside
                // of a high value is that some operations in handleActiveState,
                // e.g. hiding the quick-terminal, will be visibly delayed.
                // However, 50ms should barely be noticeable. We can change
                // this in the future if necessary.
                50,
                handleActiveState,
                self,
                null,
            );
        }
    }

    fn propGdkSurfaceDims(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn toplevelComputeSize(
        _: *gdk.Toplevel,
        size: *gdk.ToplevelSize,
        self: *Self,
    ) callconv(.c) void {
        // The compositor/quick terminal own the size in these states.
        if (self.isMaximized() or
            self.isFullscreen() or
            self.isQuickTerminal()) return;

        // Let GTK apply the default size set by a requested resize.
        const priv = self.private();
        if (priv.resize_requested) {
            priv.resize_requested = false;
            return;
        }

        // If there's no GdkSurface yet these dimensions will be zero size which
        // will make the window start out as small as possible. These checks ensure
        // we don't start with a 0, 0 window size.
        const gdk_surface = self.as(gtk.Native).getSurface() orelse return;
        const w = gdk_surface.getWidth();
        const h = gdk_surface.getHeight();
        if (w <= 0 or h <= 0) return;

        // GTK clamps the requested size to the compositor-reported bounds, which
        // go stale when the window moves to a larger monitor. Only re-assert the
        // current size when it exceeds those bounds; otherwise let GTK's default
        // sizing win so a freshly-mapped window isn't forced to a tiny size.
        var bounds_w: c_int = undefined;
        var bounds_h: c_int = undefined;
        size.getBounds(&bounds_w, &bounds_h);

        if (bounds_w <= 0 or bounds_h <= 0) return;
        if (w <= bounds_w and h <= bounds_h) return;

        size.setSize(w, h);
    }

    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We only care if we're activating. If we're activating then
        // we need to check the validity of our menu items.
        const active = button.getActive() != 0;
        if (!active) return;

        self.syncActions();
    }

    fn propQuickTerminal(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) {
            log.warn("quick terminal property can't be changed after surfaces have been initialized", .{});
            return;
        }

        if (priv.quick_terminal) {
            // Initialize the quick terminal at the app-layer
            Application.default().winproto().initQuickTerminal(self) catch |err| {
                log.warn("failed to initialize quick terminal error={}", .{err});
                return;
            };
        }
    }

    fn propScaleFactor(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // On some platforms (namely X11) we need to refresh our appearance when
        // the scale factor changes. In theory this could be more fine-grained as
        // a full refresh could be expensive, but a) this *should* be rare, and
        // b) quite noticeable visual bugs would occur if this is not present.
        self.private().winproto.syncAppearance() catch |err| {
            log.warn(
                "failed to sync appearance after scale factor has been updated={}",
                .{err},
            );
            return;
        };
    }

    fn closureTitlebarStyleIsTab(
        _: *Self,
        value: TitlebarStyle,
    ) callconv(.c) c_int {
        return @intFromBool(switch (value) {
            .native => false,
            .tabs => true,
        });
    }

    fn closureNativeTabControls(_: *Self, style: TitlebarStyle, compact: c_int) callconv(.c) c_int {
        return @intFromBool(style == .tabs and compact == 0);
    }

    fn closureSidePanelVisible(_: *Self, config_: ?*Config, toolbar_visible: c_int) callconv(.c) c_int {
        const config = if (config_) |v| v.get() else return 0;
        return @intFromBool(config.@"gtk-tabs-location" == .left and toolbar_visible != 0);
    }

    /// True when the side tab list is hidden, so that the first pane's header
    /// shows the button that brings it back.
    pub fn sideTabsHidden(self: *Self) bool {
        const config = self.private().config orelse return false;
        return config.get().@"gtk-tabs-location" == .left and !self.getToolbarVisible();
    }

    fn notifyToolbarVisible(_: *adw.ApplicationWindow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.refreshPaneDecorations();
    }

    fn closureTabStripVisible(_: *Self, visible: c_int, autohide: c_int, count: c_int) callconv(.c) c_int {
        return @intFromBool(visible != 0 and (autohide == 0 or count > 1));
    }

    /// The width of the session name in the header, in characters. Every
    /// haiku name (`sessions.max_haiku_name_bytes`) fits without ellipsis.
    fn closureSessionNameWidth(_: *Self, compact: c_int) callconv(.c) c_int {
        return if (compact != 0) 24 else 20;
    }

    pub fn setTitleOverride(self: *Self, title: ?[]const u8) void {
        const priv: *Private = self.private();

        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;

        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);

        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }

    fn titleDialogSet(_: *TitleDialog, title_: [*:0]const u8, self: *Self) callconv(.c) void {
        const title = std.mem.span(title_);
        self.setTitleOverride(if (title.len == 0) null else title);
    }

    pub fn promptWindowTitle(self: *Self) void {
        const priv: *Private = self.private();

        var value = std.mem.zeroes(gobject.Value);
        _ = value.init(gobject.ext.types.string);
        defer value.unset();

        self.as(gobject.Object).getProperty("title", &value);

        const title_: ?[*:0]const u8 = value.getString();
        const title: ?[:0]const u8 = if (title_) |v| std.mem.span(v) else null;

        const dialog = TitleDialog.new(.window, priv.title_override orelse title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }

    fn closureTitle(
        _: *Self,
        _: ?*Config,
        title_: ?[*:0]const u8,
        title_override_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        if (title_override_) |v| return glib.ext.dupeZ(u8, std.mem.span(v));
        if (title_) |v| return glib.ext.dupeZ(u8, std.mem.span(v));
        return glib.ext.dupeZ(u8, "Ghostty");
    }

    fn closureSubtitle(
        _: *Self,
        config_: ?*Config,
        pwd_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const config = if (config_) |v| v.get() else return null;
        return switch (config.@"window-subtitle") {
            .false => null,
            .@"working-directory" => pwd: {
                const pwd = pwd_ orelse return null;
                break :pwd glib.ext.dupeZ(u8, std.mem.span(pwd));
            },
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.compact_strip.deinit();
        priv.side_strip.deinit();
        priv.theme.deinit(self);
        if (priv.handle_active_state_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove handle active state source", .{});
            }
            priv.handle_active_state_source = null;
        }

        priv.command_palette.deinit();

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        priv.tab_bindings.setSource(null);

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
        priv.tab_bindings.unref();
        priv.winproto.deinit();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        if (priv.session_name) |v| glib.free(@ptrCast(@constCast(v)));

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn windowRealize(_: *gtk.Widget, self: *Window) callconv(.c) void {
        const app = Application.default();

        // Initialize our window protocol logic
        if (winprotopkg.Window.init(
            app.allocator(),
            app.winproto(),
            self,
        )) |wp| {
            self.private().winproto = wp;
        } else |err| {
            log.warn("failed to initialize window protocol error={}", .{err});
            return;
        }

        // We need to setup resize notifications on our surface,
        // which is only available after the window had been realized.
        if (self.as(gtk.Native).getSurface()) |gdk_surface| {
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "width" },
            );
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "height" },
            );
            // Connect after GTK's compute-size handler so our size wins.
            if (gobject.ext.cast(gdk.Toplevel, gdk_surface)) |toplevel| {
                _ = gdk.Toplevel.signals.compute_size.connect(
                    toplevel,
                    *Self,
                    toplevelComputeSize,
                    self,
                    .{ .after = true },
                );
            }
        }

        // Notify every displayed surface when the compositor changes the
        // Wayland xdg_toplevel suspended state.
        _ = gobject.Object.signals.notify.connect(
            self.as(gtk.Window),
            *Self,
            propSuspended,
            self,
            .{ .detail = "suspended" },
        );

        // When we are realized we always setup our appearance since this
        // calls some winproto functions.
        self.syncAppearance();
    }

    fn propSuspended(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const tab = self.getSelectedTab() orelse return;
        var it = tab.surfaces();
        while (it.next()) |surface| surface.updateOcclusion();
    }

    fn btnNewTab(_: *adw.SplitButton, self: *Self) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn tabOverviewCreateTab(
        _: *adw.TabOverview,
        self: *Self,
    ) callconv(.c) *adw.TabPage {
        return self.newTabPage(if (self.getActiveSurface()) |v| v.core() else null, .tab, .none);
    }

    fn tabOverviewOpen(
        tab_overview: *adw.TabOverview,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We only care about when the tab overview is closed.
        if (tab_overview.getOpen() != 0) return;

        // On tab overview close, focus is sometimes lost. This is an
        // upstream issue in libadwaita[1]. When this is resolved we
        // can put a runtime version check here to avoid this workaround.
        //
        // Our workaround is to start a timer after 500ms to refocus
        // the currently selected tab. We choose 500ms because the adw
        // animation is 400ms.
        //
        // [1]: https://gitlab.gnome.org/GNOME/libadwaita/-/issues/670

        // If we have an old timer remove it
        const priv = self.private();
        if (priv.tab_overview_focus_timer) |timer| {
            _ = glib.Source.remove(timer);
        }

        // Restart our timer
        priv.tab_overview_focus_timer = glib.timeoutAdd(
            500,
            tabOverviewFocusTimer,
            self,
        );
    }

    fn tabOverviewFocusTimer(
        ud: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always note our timer is removed
        self.private().tab_overview_focus_timer = null;

        // Get our currently active surface which should respect the newly
        // selected tab. Grab focus.
        const surface = self.getActiveSurface() orelse return 0;
        surface.grabFocus();

        // Remove the timer
        return 0;
    }

    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        if (self.getNeedsConfirmQuit()) {
            // Show a confirmation dialog
            const dialog: *CloseConfirmationDialog = .new(.window);
            _ = CloseConfirmationDialog.signals.@"close-request".connect(
                dialog,
                *Self,
                closeConfirmationClose,
                self,
                .{},
            );

            _ = CloseConfirmationDialog.signals.cancel.connect(dialog, *Self, closeConfirmationCancel, self, .{});

            // Show it
            dialog.present(self.as(gtk.Widget));
            return @intFromBool(true);
        }

        self.finishClose();
        return @intFromBool(true);
    }

    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.finishClose();
    }

    fn closeConfirmationCancel(_: *CloseConfirmationDialog, self: *Self) callconv(.c) void {
        self.private().archive_on_close = false;
    }

    fn finishClose(self: *Self) void {
        const app = Application.default();
        if (self.private().archive_on_close) {
            self.private().archive_on_close = false;
            app.archiveClosingSession(self) catch |err| {
                log.warn("unable to archive closing session err={}", .{err});
                self.addToast(i18n._("Unable to archive this session. The window was kept open."));
                return;
            };
        } else app.saveSessions();
        self.as(gtk.Window).destroy();
    }

    fn closeConfirmationCloseTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    fn closeConfirmationCancelTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(false));
    }

    fn tabViewClosePage(
        _: *adw.TabView,
        page: *adw.TabPage,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse
            return @intFromBool(false);

        if (priv.tab_view.getNPages() == 1) Application.default().saveSessions();

        // If the tab says it doesn't need confirmation then we go ahead
        // and close immediately.
        if (!tab.getNeedsConfirmQuit()) {
            priv.tab_view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.tab);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCloseTab,
            page,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCancelTab,
            page,
            .{},
        );

        // Show it
        dialog.present(child);
        return @intFromBool(true);
    }

    fn tabViewSelectedPage(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Always reset our binding source in case we have no pages.
        priv.tab_bindings.setSource(null);

        // Get our current page which MUST be a Tab object.
        const page = priv.tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));

        // Setup our binding group. This ensures things like the title
        // are synced from the active tab.
        priv.tab_bindings.setSource(child.as(gobject.Object));

        // If the tab was previously marked as needing attention
        // (e.g. due to a bell character), we now unmark that
        page.setNeedsAttention(@intFromBool(false));
    }

    fn tabViewPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // Get the attached page which must be a Tab object.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;

        // Attach listeners for the tab.
        _ = Tab.signals.@"close-request".connect(
            tab,
            *Self,
            tabCloseRequest,
            self,
            .{},
        );

        // Attach listeners for the surface.
        //
        // Interesting behavior here that was previously undocumented but
        // I'm going to make it explicit here: we accept all the signals here
        // (like toggle-fullscreen) regardless of whether the surface or tab
        // is focused. At the time of writing this we have no API that could
        // really trigger these that way but its theoretically possible.
        //
        // What is DEFINITELY possible is something like OSC52 triggering
        // a clipboard-write signal on an unfocused tab/surface. We definitely
        // want to show the user a notification about that but our notification
        // right now is a toast that doesn't make it clear WHO used the
        // clipboard. We probably want to change that in the future.
        //
        // I'm not sure how desirable all the above is, and we probably
        // should be thoughtful about future signals here. But all of this
        // behavior is consistent with macOS and the previous GTK apprt,
        // but that behavior was all implicit and not documented, so here
        // I am.
        if (tab.getSurfaceTree()) |tree| {
            self.connectSurfaceHandlers(tree);
        }

        for (0..tab.floatingCount()) |index| self.connectSurfaceHandler(tab.floatingSurface(index));
        _ = Tab.signals.@"floating-added".connect(tab, *Self, floatingAdded, self, .{});
        _ = Tab.signals.@"floating-removed".connect(tab, *Self, floatingRemoved, self, .{});

        // Keep our surface handlers in sync as the tree changes. This is
        // connected here rather than when the tab is created so that tabs
        // moved between windows notify the window that they are in.
        _ = SplitTree.signals.changed.connect(
            tab.getSplitTree(),
            *Self,
            tabSplitTreeChanged,
            self,
            .{},
        );
    }

    fn tabViewPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // We need to get the tab to disconnect the signals.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        self.cancelThemePicker();

        _ = gobject.signalHandlersDisconnectMatched(
            tab.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        _ = gobject.signalHandlersDisconnectMatched(
            tab.getSplitTree().as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        for (0..tab.floatingCount()) |index| floatingRemoved(tab, tab.floatingSurface(index), self);

        // Remove the tree handlers
        if (tab.getSurfaceTree()) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }
    }

    fn tabViewCreateWindow(
        _: *adw.TabView,
        _: *Self,
    ) callconv(.c) *adw.TabView {
        // Create a new window without creating a new tab.
        const win = gobject.ext.newInstance(
            Self,
            .{
                .application = Application.default(),
            },
        );

        // We have to show it otherwise it'll just be hidden.
        gtk.Window.present(win.as(gtk.Window));

        // Get our tab view
        return win.private().tab_view;
    }

    fn tabCloseRequest(
        tab: *Tab,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.tab_view.getPage(tab.as(gtk.Widget));
        // TODO: connect close page handler to tab to check for confirmation
        priv.tab_view.closePage(page);
    }

    fn tabViewNPages(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        self.as(gobject.Object).notifyByPspec(properties.@"toolbar-visible".impl.param_spec);
        if (priv.replacing_session) return;
        if (priv.tab_view.getNPages() == 0) {
            // If we have no pages left then we want to close window.

            // If the tab overview is open, then we don't close the window
            // because its a rather abrupt experience. This also fixes an
            // issue where dragging out the last tab in the tab overview
            // won't cause Ghostty to exit.
            if (priv.tab_overview.getOpen() != 0) return;

            self.as(gtk.Window).close();
        }
    }
    fn setupTabMenu(
        _: *adw.TabView,
        page: ?*adw.TabPage,
        self: *Self,
    ) callconv(.c) void {
        self.private().context_menu_page = page;
    }

    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        // We only toast for the standard clipboard.
        if (clipboard_type != .standard) return;

        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }

        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }

    fn surfaceMenu(
        _: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.syncActions();
    }

    fn surfacePresentRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        // Verify that this surface is actually in this window.
        {
            const surface_window = ext.getAncestor(
                Self,
                surface.as(gtk.Widget),
            ) orelse {
                log.warn(
                    "present request called for non-existent surface",
                    .{},
                );
                return;
            };
            if (surface_window != self) {
                log.warn(
                    "present request called for surface in different window",
                    .{},
                );
                return;
            }
        }

        // Get the tab for this surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse {
            log.warn("present request surface not found", .{});
            return;
        };

        // Get the page that contains this tab
        const priv = self.private();
        const tab_view = priv.tab_view;
        const page = tab_view.getPage(tab.as(gtk.Widget));
        tab_view.setSelectedPage(page);

        // Reveal the owning floating tab for notifications and IPC targeting.
        if (tab.containsFloating(surface)) tab.presentFloating(surface);
        // Grab focus
        surface.grabFocus();

        // Bring the window to the front.
        self.as(gtk.Window).present();
    }

    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }

        // We react to the changes in the propFullscreen callback
    }

    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }

        // We react to the changes in the propMaximized callback
    }

    fn themeSurfaceInitialized(surface: *Surface, self: *Self) callconv(.c) void {
        if (self.themeAppearance()) |appearance|
            surface.applyTheme(appearance) catch |err| log.warn("initializing pane theme: {}", .{err});
    }

    fn surfaceInit(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Make sure we init only once
        if (priv.surface_init) return;
        priv.surface_init = true;

        // Setup our default and minimum size.
        if (surface.getDefaultSize()) |size| {
            self.as(gtk.Window).setDefaultSize(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
        if (surface.getMinSize()) |size| {
            self.as(gtk.Widget).setSizeRequest(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
    }

    fn tabSplitTreeChanged(
        _: *SplitTree,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        if (old_tree) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        if (new_tree) |tree| {
            self.connectSurfaceHandlers(tree);
        }
    }

    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = "Ghostty";
        const icon = "com.mitchellh.ghostty";
        const website = "https://ghostty.org";

        adw.showAboutDialog(
            self.as(gtk.Widget),
            "application-name",
            name,
            "developer-name",
            i18n._("Ghostty Developers"),
            "application-icon",
            icon,
            "version",
            build_config.version_string.ptr,
            "issue-url",
            "https://github.com/ghostty-org/ghostty/issues",
            "website",
            website,
            @as(?*anyopaque, null),
        );
    }

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionCloseTab(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("win.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const mode = std.meta.stringToEnum(
            input.Binding.Action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to win.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            log.warn("invalid mode provided to win.close-tab: {s}", .{str.?});
            return;
        };

        self.performBindingAction(.{ .close_tab = mode });
    }

    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }

    pub fn themeConfig(self: *Self) *const configpkg.Config {
        return self.private().config.?.get();
    }

    pub fn applyThemeToConfig(self: *Self, config: *configpkg.Config) void {
        if (self.private().theme.appearance) |appearance| appearance.apply(config);
    }

    pub fn themeAppearance(self: *Self) ?configpkg.Config.ThemeAppearance {
        return self.private().theme.appearance;
    }

    pub fn cancelThemePicker(self: *Self) void {
        self.private().theme.cancel();
    }
    pub fn clearTheme(self: *Self) void {
        self.private().theme.clear(self);
    }

    pub fn pickTheme(self: *Self) void {
        self.private().theme.open(self, self.private().theme_overlay) catch |err| {
            log.warn("opening theme picker: {}", .{err});
            self.addToast(i18n._("Unable to open theme picker"));
        };
    }

    fn actionPickTheme(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.pickTheme();
    }

    fn actionNewTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn actionPromptContextTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.context_menu_page orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        tab.promptTabTitle();
    }

    fn actionPromptSurfaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_surface_title);
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_tab_title);
    }

    fn actionPromptWindowTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_window_title);
    }

    fn actionSplitRight(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }

    fn actionSplitLeft(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }

    fn actionSplitUp(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }

    fn actionSplitDown(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .down });
    }

    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }

    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;

        if (config.@"bell-features".system) system: {
            const native = self.as(gtk.Native).getSurface() orelse {
                log.warn("unable to get native surface from window", .{});
                break :system;
            };
            native.beep();
        }

        if (config.@"bell-features".attention) attention: {
            // Dont set urgency if the window is already active.
            if (self.as(gtk.Window).isActive() != 0) break :attention;

            // Request user attention
            self.winproto().setUrgent(true) catch |err| {
                log.warn("winproto failed to set urgency={}", .{err});
            };
        }
    }

    /// Toggle the command palette.
    ///
    /// TODO: accept the surface that toggled the command palette as a parameter
    fn toggleCommandPalette(self: *Window) void {
        const priv = self.private();

        // Get a reference to a command palette. First check the weak reference
        // that we save to see if we already have one stored. If we don't then
        // create a new one.
        const command_palette = priv.command_palette.get() orelse command_palette: {
            // Create a fresh command palette.
            const command_palette = CommandPalette.new();

            // Synchronize our config to the command palette's config.
            _ = gobject.Object.bindProperty(
                self.as(gobject.Object),
                "config",
                command_palette.as(gobject.Object),
                "config",
                .{ .sync_create = true },
            );

            // Listen to the activate signal to know if the user selected an option in
            // the command palette.
            _ = CommandPalette.signals.trigger.connect(
                command_palette,
                *Window,
                signalCommandPaletteTrigger,
                self,
                .{},
            );

            // Save a weak reference to the command palette. We use a weak reference to avoid
            // reference counting cycles that might cause problems later.
            priv.command_palette.set(command_palette);

            break :command_palette command_palette;
        };
        defer command_palette.unref();

        // Tell the command palette to toggle itself. If the dialog gets
        // presented (instead of hidden) it will be modal over our window.
        command_palette.toggle(self);
    }

    // React to a signal from a command palette asking an action to be performed.
    fn signalCommandPaletteTrigger(_: *CommandPalette, action: *const input.Binding.Action, self: *Self) callconv(.c) void {
        // If the activation actually has an action, perform it.
        self.performBindingAction(action.*);
    }

    /// React to a GTK action requesting that the command palette be toggled.
    fn actionToggleCommandPalette(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleCommandPalette();
    }

    fn actionToggleTabOverview(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.toggleTabOverview();
    }

    fn actionToggleToolbar(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.toggleToolbar();
    }

    /// Toggle the Ghostty inspector for the active surface.
    fn toggleInspector(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        _ = surface.controlInspector(.toggle);
    }

    /// React to a GTK action requesting that the Ghostty inspector be toggled.
    fn actionToggleInspector(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleInspector();
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
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(Tab);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 4,
                    .name = "window",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"session-name".impl,
                properties.@"session-saved".impl,
                properties.@"session-enabled".impl,
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"quick-terminal".impl,
                properties.@"tabs-autohide".impl,
                properties.@"tabs-compact".impl,
                properties.@"tabs-inverted".impl,
                properties.@"tabs-visible".impl,
                properties.@"tabs-wide".impl,
                properties.@"toolbar-style".impl,
                properties.@"toolbar-visible".impl,
                properties.@"titlebar-style".impl,
                properties.@"title-override".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tab_overview", .{});
            class.bindTemplateChildPrivate("tab_bar", .{});
            class.bindTemplateChildPrivate("tab_strip_header", .{});
            class.bindTemplateChildPrivate("tab_strip_handle", .{});
            class.bindTemplateChildPrivate("compact_tab_scroll", .{});
            class.bindTemplateChildPrivate("compact_tab_box", .{});
            class.bindTemplateChildPrivate("side_tab_scroll", .{});
            class.bindTemplateChildPrivate("side_tab_box", .{});
            class.bindTemplateChildPrivate("tab_view", .{});
            class.bindTemplateChildPrivate("toolbar", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateChildPrivate("session_label", .{});
            class.bindTemplateChildPrivate("session_button", .{});
            class.bindTemplateChildPrivate("session_icon", .{});
            class.bindTemplateChildPrivate("session_status", .{});
            class.bindTemplateChildPrivate("header_status", .{});

            // Template Callbacks
            class.bindTemplateCallback("realize", &windowRealize);
            class.bindTemplateCallback("new_tab", &btnNewTab);
            class.bindTemplateCallback("overview_create_tab", &tabOverviewCreateTab);
            class.bindTemplateCallback("overview_notify_open", &tabOverviewOpen);
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("close_page", &tabViewClosePage);
            class.bindTemplateCallback("page_attached", &tabViewPageAttached);
            class.bindTemplateCallback("page_detached", &tabViewPageDetached);
            class.bindTemplateCallback("setup_tab_menu", &setupTabMenu);
            class.bindTemplateCallback("tab_create_window", &tabViewCreateWindow);
            class.bindTemplateCallback("notify_n_pages", &tabViewNPages);
            class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_is_active", &propIsActive);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_quick_terminal", &propQuickTerminal);
            class.bindTemplateCallback("notify_scale_factor", &propScaleFactor);
            class.bindTemplateCallback("titlebar_style_is_tabs", &closureTitlebarStyleIsTab);
            class.bindTemplateCallback("native_tab_controls", &closureNativeTabControls);
            class.bindTemplateCallback("tab_strip_visible", &closureTabStripVisible);
            class.bindTemplateCallback("side_panel_visible", &closureSidePanelVisible);
            class.bindTemplateCallback("notify_toolbar_visible", &notifyToolbarVisible);
            class.bindTemplateCallback("session_name_width", &closureSessionNameWidth);
            class.bindTemplateCallback("computed_title", &closureTitle);
            class.bindTemplateCallback("computed_subtitle", &closureSubtitle);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
