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

- Review before commit on 2026-10-25 corrected immediate Enter/Down handling in
  the tab picker: results are refreshed synchronously instead of relying on
  the delayed search notification. Long picker labels are bounded, and pinned
  attention tabs keep their disabled close glyph hidden on hover/focus.
  Debug build, config validation, three focused layout tests, GTK CSS parsing,
  draft JavaScript syntax and diff whitespace checks passed. A real-widget
  regression verified search text followed immediately by Enter, overflow,
  stable tab width, finite pulse, settled marker and reduced-motion fallback.
  The installed ReleaseFast copy predates these review fixes. Stopped HTML
  experiments are retained as exploration notes, not approved GTK scope.


- The user stopped the activity/vertical-tab studies on 2026-10-25 because the
  results were not preferred. Those experiments remain HTML-only and are not
  approved for GTK. The user subsequently requested installation of the latest
  approved horizontal GTK implementation. Installed ReleaseFast with system
  Fontconfig to `~/.local` on 2026-10-25. The installed executable reports
  `1.3.2-HEAD+03a41a64d`, confirms `.fast` build mode and passed
  `+validate-config`. Running sessions were not restarted. The activity monitor
  and vertical tabs are not part of this build.


- Vertical draft simplification on 2026-10-25: the expanded inline activity
  hierarchy was rejected as too busy. The rail now contains only tab names and
  small status icons; task descriptions are available on hover or in the
  Activity panel. Inline task rows/progress and footer counts were removed.
  Browser checks and visual inspection passed; pane geometry is unchanged.
  This is HTML-only and awaiting feedback, with no compilation or installation.


- Vertical activity comparison on 2026-10-25: at the user's request, the HTML
  draft now defaults to a collapsible left tab rail with the session control
  above it and inline activity under selected or attention-needed tabs.
  A layout selector restores horizontal tabs; All activity opens the detailed
  panel. Browser interaction/layout checks passed and the screenshot was
  visually inspected. Pane gaps and rounding are preserved. Await design
  feedback before GTK implementation; installation remains cancelled.


- Activity monitor study on 2026-10-25: installation was cancelled at the
  user's request; the previous installed executable is unchanged. The local
  HTML now includes a current-window Activity panel with grouped sample tasks,
  filtering, optional idle panes, tab/pane navigation, explicit progress and
  state-transition controls connected to the approved attention treatment.
  It overlays the workspace without changing pane gaps or rounding. This is
  a draft awaiting feedback, not live process monitoring. See
  `src/apprt/gtk/ACTIVITY_MONITOR_PLAN.md` for the proposed application data path
  and validation scope. No activity GTK/backend changes or builds were made.


- Approved finishing draft port on 2026-10-25: the user approved the HTML and
  authorized GTK implementation. Compact tabs now expose overflow arrows and
  a searchable list of real pages (case-insensitive search, Enter selection,
  Down to results, Escape dismissal). Hover details use the existing escaped
  title/path with a live pane count. New attention runs a finite 1.2-second
  pulse, then retains a dot in the close-control slot; hover reveals close,
  selection clears attention, and disabled GTK animations skip the pulse.
  Page references and timer/signal cleanup follow tab/window lifetimes.
  Existing add/close/drag/session actions remain connected to their original
  models; draft undo/session demonstrations do not add restoration semantics.
  Pane gaps and rounding are unchanged. Debug build, GTK CSS parsing and all
  three focused layout tests passed. An isolated real-widget check with 19
  terminal tabs passed overflow scrolling, picker filtering/selection, finite
  pulse, settled marker, fixed tab width and disabled-animation fallback.
  Compact and native windows closed cleanly. Deferred overflow visibility
  updates avoid invalidating GTK measurement during allocation. A nonfatal
  AdwToolbarView startup allocation warning was observed in both modes; no GTK
  critical errors remained. The user approved the GTK preview and authorized
  installation on 2026-10-25, then cancelled the ReleaseFast build before it
  installed. The installed executable remains unchanged. Work moved to the
  activity-monitor HTML draft; activity process detection is not implemented.


- Attention draft iteration on 2026-10-25: the user rejected a persistent tint,
  underline and accent border. The current HTML candidate uses two soft pulses
  over 1.2 seconds, then a quiet dot in the reserved close-control space. Hover
  reveals the close control; selecting clears attention. Tab geometry stays
  fixed. Reduced motion skips the pulse. A Replay attention control supports
  comparison. Browser checks passed finite pulse, stable width, settled marker,
  selection clearing and reduced-motion fallback. The user subsequently approved
  this candidate for GTK (see above) and identified activity support as the next
  major task and wants this attention treatment to fit that future work.

- HTML finishing study on 2026-10-25: following positive desktop feedback on
  the custom tab strip, the user requested further improvements ("go wild").
  Draft 02 in `design/ui-draft/` adds overflow arrows/fades, a searchable tab
  list, delayed full-title/path details, drag insertion markers, add/close/undo
  interactions and saved/unsaved session state. Overflow and attention examples
  can be toggled. Pane margins and rounding are untouched. The draft's session
  saving and undo behavior are demonstrations, not new GTK capabilities.
  Isolated browser checks passed close/undo, add/delete, attention, overflow,
  search, synthetic drag reorder, session state, hover details and a 420 px
  layout; screenshots were visually inspected. This study was subsequently
  approved for GTK, per `AGENTS.md`. The previously
  built custom strip has positive visual feedback but is not installed.

- Resumed and validated on 2026-10-25: custom compact tabs and the persistent
  session name are ready for desktop comparison, NOT installed or approved yet.
  Final Debug build with system Fontconfig passed. Direct rectangle fields
  removed the accidental Graphene getter dependency; the preview starts without
  a Nix-shell library override. Expanded an unsupported `:is()` CSS selector;
  GTK CSS parsing now passes. Isolated normal-desktop startup checks in both
  compact and native modes passed tab creation, selection, reorder actions,
  transfer-to-new-window actions and cleanup, with no GTK criticals or parser
  errors. Three standalone drop-layout tests, formatting, configuration and
  whitespace checks pass. Mouse DnD, close confirmation, overflow behavior,
  context menus and live native/compact switching still need desktop testing.
  Temporary check scripts/logs are in `/tmp/ghostty-tab-strip-smoke` and
  `/tmp/ghostty-css-check.py`. Preview: `./zig-out/bin/ghostty` (Debug).
  Installed daily-use binary remains the earlier approved styling pass.
  No running user sessions were restarted. Prefer HTML-first design, Debug
  iteration and ReleaseFast only for final validation/install.

- Custom compact-tab strip and persistent session name on 2026-10-25: the user
  requested both in one implementation pass using the approved HTML reference.
  Compact mode now presents content-sized, capped/ellipsized tabs with 4 px gaps,
  horizontal scrolling and a persistent session name. Native mode keeps AdwTabBar.
  Both share AdwTabView for selection, process ownership, confirmation, page order
  and transfers. The new strip implements close/middle-click, tab context menus,
  keyboard navigation, drag reordering, transfers between compact strips and
  drag-out windows; mixed native/compact drag protocols are not integrated.
  Selection/attention/title updates preserve chip widgets. Page signal cleanup,
  drag-owned references and menu-context cleanup are explicit. Existing toolbar
  visibility rules, tab-bar location, pane gaps and rounding remain.
  The idle-collapse timer, revealer and related hover/dialog hooks are removed.
  Semantic checking and three standalone drop-layout tests passed. Final Debug
  build and startup checks passed as recorded above. Desktop approval remains
  pending; not installed.

- Desktop-approved and installed on 2026-10-25: the user approved the final
  compact-tab/pane-header readability pass. Installed to `~/.local` with
  ReleaseFast and system Fontconfig; installed configuration validation passed.
  Final sizes are 15 px tabs/session, 14 px pane titles and 13 px status, with
  native tab spacing and no added side margins. Fixed pane-title weight,
  reserved focus dots and faint inactive-tab backgrounds are included. Pane
  gaps and rounding are unchanged. Running sessions were not restarted.
  Native uniform tab widths remain a documented difference from the HTML draft.

- Running-app readability correction on 2026-10-25: the user found the previous
  sizes still too small. HTML and GTK now use 15 px tabs/session, 14 px pane
  titles and 13 px status. Removed the extra 3 px margins on each side of every
  GTK tab to avoid adding them to libadwaita's native spacing. Pane geometry
  and fixed title weight are unchanged. GTK ReleaseFast build with system
  Fontconfig, configuration validation, whitespace and draft JavaScript checks
  passed. Desktop approval pending; not installed.

- Readability follow-up on 2026-10-25: pane titles increase to 12 px and tabs
  to 13 px in HTML and GTK. The user confirmed focus no longer moves pane titles.
  Bar height, pane gaps and rounding stay unchanged. Investigation of libadwaita
  1.8.1 `adw-tab.c` and `adw-tab-box.c` found native uniform tab sizing even when
  expansion is disabled. Earlier content-width claims describe the HTML target,
  not exact GTK behavior; true per-title sizing remains unimplemented and needs
  a separate tab-strip solution. GTK ReleaseFast build with system Fontconfig,
  configuration validation, Zig formatting, draft JavaScript syntax and
  whitespace checks passed. Desktop approval pending; not installed.

- Draft parity follow-up on 2026-10-25: inactive compact tabs gain the draft's
  faint 4% foreground background; tab titles retain a fixed normal weight.
  Tiled/stacked/floating pane titles retain a fixed medium weight on focus,
  with reserved 5 px focus dots and subdued inactive titles. UI text sizes
  follow the draft (12 px tabs/session, 11 px pane headers/status), along
  with header insets and reserved close-icon geometry. The user rebuilt their
  Nix configuration; the active Ghostty config now uses IBM Plex Sans, matching
  the draft. Final GTK ReleaseFast build with system Fontconfig, configuration
  validation, Zig formatting and whitespace checks passed. GTK desktop
  validation of this follow-up is pending; not installed.

- HTML-approved UI revision on 2026-10-25: the earlier tinted pill/underline
  experiment was rejected. The accepted reference is `design/ui-draft/index.html`:
  compact content-width rounded tabs, subtle selected outline, session control
  at top left and Lua status at top right. The bottom-bar experiment was removed.
  Pane headers blend into the terminal with a 3% focused accent tint and clearer
  active titles. Pane margins (3 px), corners (8 px), neutral frame borders and
  split allocation stay unchanged. Compact tabs now always use content widths;
  native tabs retain `gtk-wide-tabs`. Theme colors remain configurable; the HTML
  palette is not imposed on GTK. The final GTK ReleaseFast build with system
  Fontconfig, configuration validation, Zig formatting and whitespace checks
  passed. GTK desktop approval is pending; not installed. Use an HTML draft
  before future GTK UI changes.
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
