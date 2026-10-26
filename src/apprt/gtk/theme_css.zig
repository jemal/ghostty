//! Shared Quiet rail CSS; selectors isolate temporary window overrides.
const std = @import("std");
const Config = @import("../../config/Config.zig");

pub fn write(writer: *std.Io.Writer, config: *const Config, selector: []const u8) !void {
    const headerbar_background = config.@"window-titlebar-background" orelse config.background;
    const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;
    // Decorated panes are cards on a darker window background. As in Rex,
    // dark themes mark the card edge with a light 1 px border; light themes
    // with the darker gap, a faint border and a faint line under the card.
    const dark = dark: {
        const bg = config.background;
        const luma = (@as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114) / 1000;
        break :dark luma < 128;
    };
    const shell_shade: u8 = if (dark) 28 else 11;
    const pane_border: u8 = if (dark) 10 else 8;
    const pane_shadow = if (dark) "none" else "0 1px 0 rgba(0, 0, 0, 0.05)";
    try writer.print(
        \\{s} {{
        \\  --ghostty-fg: rgb({d},{d},{d});
        \\  --ghostty-bg: rgb({d},{d},{d});
        \\  --ghostty-chrome-bg: {s};
        \\  --ghostty-rail-bg: color-mix(in srgb, var(--ghostty-fg) 5%, var(--ghostty-bg));
        \\  --ghostty-raised-bg: color-mix(in srgb, var(--ghostty-fg) 8%, var(--ghostty-bg));
        \\  --ghostty-accent: rgb({d},{d},{d});
        \\  --ghostty-shell-bg: color-mix(in srgb, black {d}%, var(--ghostty-bg));
        \\  --ghostty-pane-border: color-mix(in srgb, var(--ghostty-fg) {d}%, transparent);
        \\  --ghostty-pane-shadow: {s};
        \\  --headerbar-fg-color: var(--ghostty-fg);
        \\  --headerbar-bg-color: var(--ghostty-chrome-bg);
        \\  --headerbar-backdrop-color: oklab(from var(--headerbar-bg-color) calc(l * 0.9) a b / alpha);
        \\  --overview-fg-color: var(--ghostty-fg);
        \\  --overview-bg-color: var(--ghostty-bg);
        \\  --popover-fg-color: var(--ghostty-fg);
        \\  --popover-bg-color: var(--ghostty-raised-bg);
        \\  --window-fg-color: var(--ghostty-fg);
        \\  --window-bg-color: var(--ghostty-bg);
        \\  --view-fg-color: var(--ghostty-fg);
        \\  --view-bg-color: var(--ghostty-bg);
        \\  --dialog-fg-color: var(--ghostty-fg);
        \\  --dialog-bg-color: var(--ghostty-raised-bg);
        \\  --card-fg-color: var(--ghostty-fg);
        \\  --card-bg-color: var(--ghostty-raised-bg);
        \\  --active-toggle-bg-color: color-mix(in srgb, var(--ghostty-fg) 12%, var(--ghostty-bg));
        \\  --active-toggle-fg-color: var(--ghostty-fg);
        \\  --accent-color: var(--ghostty-accent);
        \\  --accent-bg-color: color-mix(in srgb, var(--ghostty-accent) 18%, var(--ghostty-raised-bg));
        \\  --accent-fg-color: var(--ghostty-fg);
        \\}}
        \\{s} tabbar {{
        \\  background: var(--ghostty-chrome-bg);
        \\  color: var(--ghostty-fg);
        \\}}
        \\{s} .tab-strip-header.compact-tabs {{
        \\  background: var(--ghostty-bar-bg, var(--ghostty-bg));
        \\}}
        \\{s} listview.command-palette-view {{
        \\  --view-fg-color: var(--ghostty-fg);
        \\  --view-bg-color: var(--ghostty-bg);
        \\}}
        \\{s} windowhandle {{
        \\  background-color: var(--headerbar-bg-color);
        \\  color: var(--headerbar-fg-color);
        \\}}
        \\{s} windowhandle:backdrop {{
        \\ background-color: var(--headerbar-backdrop-color);
        \\}}
        \\{s} .tab-side windowhandle {{
        \\  background-color: transparent;
        \\}}
    , .{
        selector,
        headerbar_foreground.r,
        headerbar_foreground.g,
        headerbar_foreground.b,
        headerbar_background.r,
        headerbar_background.g,
        headerbar_background.b,
        // An explicit titlebar background remains an exact override.
        if (config.@"window-titlebar-background" != null)
            "var(--ghostty-bg)"
        else
            "color-mix(in srgb, var(--ghostty-fg) 5%, var(--ghostty-bg))",
        config.palette.value[12].r,
        config.palette.value[12].g,
        config.palette.value[12].b,
        shell_shade,
        pane_border,
        pane_shadow,
        selector,
        selector,
        selector,
        selector,
        selector,
        selector,
    });
}
