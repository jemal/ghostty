# GTK pane and session UI refinements

Status: approved on 2026-10-23; first implementation completed on 2026-10-24.
GTK ReleaseFast build with system Fontconfig, focused action-parser tests,
Zig formatting and diff checks passed. CLI checks confirmed the new default
setting and action; a temporary config enabling decorations and binding the
toggle passed `+validate-config`. The user approved pane decorations and the
refined session/status bar on the normal desktop on 2026-10-24. Extended
lifecycle testing is not claimed. Final review corrected the session control's
high-contrast selector and restored the main-menu tooltip; no blocking issues
remain. The reviewed GTK ReleaseFast build with system Fontconfig, all 88
focused action-parser tests, Zig formatting and whitespace checks passed.
Committed in jj change `ovytvymr` and installed ReleaseFast with system
Fontconfig to `~/.local` at the user's request on 2026-10-24. The installed
executable reports `1.3.2-HEAD+9e1c31062` and passed the pane-decoration
action/config checks. Installation notes were folded into the same change
afterward. Running sessions were not restarted.

## Implementation checkpoint

- Font consistency follow-up on 2026-10-24: `window-title-font-family` now
  applies across the GTK interface, including tiled/floating pane headers,
  tabs, status, menus, pickers and dialogs. Terminal text retains `font-family`.
  Font sizes and weights retain their existing UI styling. GTK ReleaseFast
  with system Fontconfig, Zig formatting and diff checks passed; the user's
  desktop check of this follow-up is pending.
- `gtk-pane-decorations = true` enables tiled-pane frames and title/close
  headers. Default false; **Toggle Pane Decorations** in the command palette
  or `toggle_pane_decorations` overrides it for the current window until reload.
- The existing `SurfaceScrolledWindow` owns the frame/header. Toggling changes
  presentation without reparenting the terminal or rebuilding the split tree.
  Single and zoomed panes receive the same treatment; floats retain their
  existing headers. Frames use 8 px corners and 3 px outer margins per pane
  (6 px between adjoining frames, plus the split handle). Existing terminal
  `window-padding-*` values supply the inner padding without another layer.
  Decorated mode hides the old split separator visuals while preserving their
  allocation and mouse-resize hit areas, including during live theme previews.
- The frame has `overflow: hidden`: GTK clips its children to the rounded CSS
  padding box, including terminal textures, rather than only painting a rounded
  background. See GTK's `gtk_widget_create_render_node` in
  https://github.com/GNOME/gtk/blob/4.20.1/gtk/gtkwidget.c.
- Header titles follow pane title overrides and live terminal titles. Clicking
  a title focuses that pane; closing uses its existing close-request and
  confirmation path. Signal handlers disconnect before wrapper disposal.
- The session control uses the build's Ghostty icon, dimmed for unsaved
  sessions, and a 160 ms horizontal name reveal. It expands on hover, keyboard
  focus, session changes/rename/save, toolbar remapping and session-overlay
  opening. Modal dialogs hold it expanded; closing a dialog restarts the
  three-second idle delay. Lua status is independent. Disposal cancels timers
  and disconnects dialog-model callbacks.
- Tiled focus borders/header text and floating focus shadows use 160 ms CSS
  transitions. Floating-panel entrance/exit fades and animated split geometry
  are not included in this first version.
- Contrast configuration remains unchanged; no new contrast algorithm was added.
- Desktop feedback on 2026-10-24: pane decorations look good; the user rejected
  the cramped session/status area and approved moving status to the far right.
  The follow-up uses a flat session control with a 20 px Ghostty icon, 9 px
  icon/name spacing, a 9 px hover radius and explicit padding that overrides
  the compact bar's generic button rule. Both vertical dividers are removed.
  Status uses one readable, muted line at the right, joining nonempty Lua
  input lines with ` · ` and keeping the original text in a tooltip. The API
  still accepts two lines. Name collapse leaves status visible. This bar
  refinement passed the final GTK ReleaseFast build with system Fontconfig,
  Zig formatting and diff checks. The user approved the resulting bar on the
  normal desktop on 2026-10-24.

## Inspiration and scope

Superlogical's Rex is an inspiration for this fork's UI as well as its Lua
API. Den is a useful implementation reference for the Rex-inspired interface:

- Rex: https://www.superlogical.com/rex/
- Rex Lua API: https://www.superlogical.com/rex/docs/reference/lua
- Den: https://github.com/DeepanshuMishraa/den
- Local Den checkout: `/home/jemal/dev/thirdparty/den` (not
  `~/dev/projects/thirdparty`). Inspected revision: `1a20526`.

The user chose UI work before the other features explored in this chat.
The approved first scope is toggleable tiled-pane framing, a Ghostty icon
beside an automatically collapsing session name, and subtle animations.
Evaluate existing terminal contrast correction before considering a new
algorithm. The design below records the proposed starting behavior accepted
for implementation; exact dimensions and timings remain desktop-tuning values.

This work is GTK/Linux only. Keep the existing floating-panel visual language
and window-scoped theme behavior consistent with the new tiled-pane UI.

## Toggleable tiled-pane UI

The user requested rounded corners, padding and a header like the current
floating terminals, with a way to toggle the treatment.

- Add a configuration option and a command-palette/binding action. No personal
  keyboard shortcut is imposed. The selected names/default are in the checkpoint
  above.
- Use rounded containers, subtle neutral borders, space between panes, and a
  compact title/close header. Give the focused pane a clear but restrained
  appearance consistent with floating panels.
- Begin with approximately 8 px corners and 6–8 px gaps, then tune with the
  user on the normal desktop. These are proposals, not fixed requirements.
- Account for existing `window-padding-*` values when adding inner padding;
  avoid unintentionally doubling terminal padding.
- Clip terminal contents at the rounded container boundary. A CSS border radius
  alone does not establish that the rendered terminal is clipped correctly.
- Toggling changes presentation while preserving surfaces and running
  processes. Preserve split ratios, selection, input routing, focus, zoom,
  close confirmation, and saved-session behavior.
- Support newly created and restored panes, nested splits, theme previews and
  config reload. Manual toggles are window-scoped and reset on reload, following
  the existing toolbar convention.
- Include single and zoomed panes; the request does not limit the treatment to
  tabs containing multiple splits.

Relevant implementation: `class/split_tree.zig`, `class/surface.zig`,
`ui/1.0/surface.blp`, `css/style.css`. Existing floating framing/header creation
is in `class/tab.zig`; share styling or structure where it helps maintain
consistent behavior without changing floating-terminal ownership.

## Session icon and automatic name collapse

Keep the Ghostty icon visible whenever the session control's toolbar is
visible. Initially show the name beside it, then collapse the name after
approximately three idle seconds to give tabs more room.

Proposed behavior:

- Expand on pointer hover, keyboard focus, session change or rename.
- Clicking the control opens the existing Sessions overlay and expands the name.
- Keep it expanded while hovered, keyboard-focused, or while the overlay is open.
- Restart the idle delay when interaction ends; animate the name folding away.
- Keep the full session name in the icon/control tooltip and accessible label.
- Preserve saved/unsaved indication and existing session operations.
- Keep the Lua status block independently visible; collapsing the session name
  should not discard or conceal status text.
- Respect existing automatic/manual toolbar hiding. This feature does not
  force an icon into a window whose toolbar is hidden.
- Cancel pending timers on disposal and avoid stale callbacks after config
  reload or session replacement.

Den's `Sources/DenApp/Views/TitleBar.swift`, `SessionButton`, provides the
reference: a persistent stack icon, a three-second idle delay, expansion on
click/session change, and collapse suppressed by hover or an open session menu.
Expansion on hover/keyboard focus is our proposed refinement of that behavior.
Our current control is in `ui/1.4/window.blp` and `class/window.zig`.

## Animation approach

GTK and libadwaita support this work natively:

- `Gtk.Revealer` for the session-name reveal/collapse:
  https://docs.gtk.org/gtk4/class.Revealer.html
- CSS transitions for supported color, opacity and shadow changes.
- `Adw.TimedAnimation` if explicit interpolation is needed:
  https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.TimedAnimation.html

Start with short transitions around 120–180 ms for session-name collapse,
pane focus/header styling, and, where practical, floating-panel appearance.
Honor the desktop animation setting. Input/focus must become usable promptly;
visual completion must not gate input. Hidden panels must stop intercepting
input, and show/hide interruption must leave widgets in a consistent state.

Animating split creation or terminal geometry is deferred: repeated size
changes can cause terminal reflow and application redraws. Do not revive the
previously deferred partial-redraw investigation merely to add animations;
the small initial-reveal title artifacts remain a separate known issue.

## Contrast correction

Terminal-text correction already exists through `minimum-contrast` in
`src/config/Config.zig`, passed to the renderer in `src/renderer/generic.zig`.
The default is 1. Try 3 and optionally 4.5 on the normal desktop before
deciding whether another implementation is worthwhile. Do not change the
user's configuration without making the selected value explicit.

Den's `Sources/DenApp/Theme/OKLab.swift` instead adjusts low-contrast colors
in OKLab toward the theme foreground, targeting 4.5:1. Ghostty's documented
behavior can push colors toward black or white. An OKLab renderer change is
not part of the approved first implementation.

Contrast for theme-derived GTK chrome is a separate possible follow-up:
ensure pane headers, inactive labels and controls remain readable while
preserving explicit user color overrides. No new chrome contrast algorithm
or global theme alteration has been selected.

## Sequence and validation

1. Implement toggleable tiled-pane framing and headers.
2. Add the persistent Ghostty session icon and animated name collapse.
3. Add restrained focus/appearance transitions where appropriate.
4. Let the user evaluate the existing terminal contrast setting separately.

Read `FORK_STATUS.md`, `SESSION_RESTORE.md` and `LUA_PLAN.md`, then inspect
`jj status` before continuing. Use the existing Nix development toolchain and
system Fontconfig. Build and format changed files; use focused logic tests
for new state/timer behavior where useful. Verify lifecycle and focus behavior,
including toggling with running panes, split/close/zoom, session replacement,
and floating panels. Check appearance through normal desktop user feedback.

Do not run isolated X11/Xvfb screenshot workflows. Do not restart or terminate
the user's sessions. Install to `~/.local` only after the user approves the
desktop result. Keep this plan and `FORK_STATUS.md` accurate about what is
implemented, tested, desktop-approved and installed.

## Other ideas explored, not approved for this task

Program icons and rich tab hover cards, OSC 7501 activity indicators, an
activity overlay/sidebar, vertical tabs, tab peek, cross-pane search, path
insertion, and mouse pane rearrangement remain candidates for later work.
Persistent PTY ownership and SSH reconnection are separate architecture projects.

Useful findings for a later task: the current terminal parser and libghostty-vt
support OSC 7501, but `src/termio/stream_handler.zig` ignores `.program_status`
in the application. GTK already has `toggle_tab_overview`; a Den-style broader
overview would extend existing functionality. Our sessions represent separate
windows, unlike Den's client navigation, so a cross-session sidebar needs an
explicit window-focus model.
