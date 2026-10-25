//! Shared Quiet rail CSS; selectors isolate temporary window overrides.
const std = @import("std");
const Config = @import("../../config/Config.zig");

pub fn write(writer: *std.Io.Writer, config: *const Config, selector: []const u8) !void {
    const headerbar_background = config.@"window-titlebar-background" orelse config.background;
    const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;
    try writer.print(
        \\{s} {{
        \\  --ghostty-fg: rgb({d},{d},{d});
        \\  --ghostty-bg: rgb({d},{d},{d});
        \\  --ghostty-chrome-bg: {s};
        \\  --ghostty-rail-bg: color-mix(in srgb, var(--ghostty-fg) 5%, var(--ghostty-bg));
        \\  --ghostty-raised-bg: color-mix(in srgb, var(--ghostty-fg) 8%, var(--ghostty-bg));
        \\  --ghostty-accent: rgb({d},{d},{d});
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
        \\  background: var(--ghostty-bg);
        \\}}
        \\{s} :is(.native-picker, .floating-terminal) {{
        \\  background: var(--ghostty-raised-bg);
        \\  color: var(--ghostty-fg);
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
        selector,
        selector,
        selector,
        selector,
        selector,
        selector,
    });
}
