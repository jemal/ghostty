# Named sessions

Enable with `window-save-state = always`. GTK leaves this disabled for
`default` and `never`. Disabling it retains existing saved sessions.

Each session represents one window's tabs and split trees. The session name
appears at the start of the tab bar, at a fixed width. Clicking it opens the
Sessions overlay, where you can save, create, rename, reopen, archive, or
delete sessions. Opening a session that is already open focuses its window
without creating a copy.

Opening a closed saved session from an unsaved normal window restores into
that same window, replacing all of its tabs and splits while keeping its
current position, size, and maximized/fullscreen state. The normal running-process
confirmation applies before replacement. Canceling keeps the original panes
and processes; a manifest or layout preparation failure also leaves them intact.
Archived sessions are unarchived only after confirmation and rearchived if
preparation fails.

Opening from a saved window or quick terminal still opens a separate window.
An already-open session always focuses its existing window, leaving the source
window intact. Restored terminals start fresh shells as usual.

## Program relaunch (Linux)

Register executable names in `init.lua` to relaunch selected programs when a
saved session is opened:

```lua
ghostty.session.relaunch {
  programs = { "hx", "jjui", "btop", "claude", "codex" },
  commands = {
    claude = { "claude", "--continue" },
    codex = { "codex", "resume", "--last" },
  },
}
```

There is no default registration. This function works only while `init.lua`
loads; registrations are additive, with at most 64 names. Names are executable
basenames rather than aliases or paths. The current Lua registration governs
both capture and relaunch, including sessions saved with older registrations.

The optional `commands` table replaces a program's captured argument array at
launch time. Each key must be registered and each value must be an argument
list starting with that same executable name (no shell command strings). This
replaces all captured arguments, including initial prompts, profile options and
explicit resume IDs. Without an entry, the captured arguments are replayed.
Later registrations can replace an entry; removing it from `init.lua` and
reloading restores normal replay. Saved records keep the original arguments.

The example resumes Claude Code's and Codex CLI's latest conversation in the
captured directory. It does not identify the conversation that originally ran
in a particular pane: multiple panes in the same directory can resume the same
latest conversation. Resume errors are handled by the CLI and leave the shell
available. No prompt is automatically resubmitted by these restore commands.

Saving captures the registered foreground program's argument array and working
directory. Relaunch starts a fresh shell in that directory, waits for its live
OSC 133 B/I ready-for-input marker, then submits a literally quoted command.
Exiting the program returns to the shell. Nushell, bash, zsh, fish, sh, dash and
ksh are recognized; shell integration must report prompt readiness. Typing or
pasting cancels pending relaunch, as does a 15-second readiness timeout after
the terminal initializes. Inactive tabs retain their record and wait until
initialized. Removing a registration before the prompt arrives prevents launch.

Missing directories, unknown shells, unreadable process information, redirected
input/output, unsupported commands and disabled registrations fall back to a
shell. A missing executable produces the shell's normal error and leaves it
usable. If shell startup changes directory, relaunch is skipped. Nix wrapper
names such as `.hx-wrapped` match `hx`; launch uses the current shell's PATH.

This recreates a program, not its memory, buffers, selections, stdin, pipelines,
environment, or devshell. For Helix, files opened after startup are not reflected
in its original arguments. Relative arguments can also change meaning if the
program changed its working directory. Exiting a program before the session is
saved records the current foreground process instead. Existing sessions without
relaunch records continue to restore ordinary shells.

## Saved and unsaved sessions (since 2026-10-23)

Every new window is an **unsaved** session. It gets a random haiku name (an
adjective and a noun from the session ID, for example `misty-pond`, at most 15
bytes). The header shows the name dimmed, and the tooltip says that it is
unsaved. Ghostty never writes an unsaved session to disk: no manifest, no
snapshots, no entry in the session index.

A session becomes **saved** when you press Alt+S in the Sessions overlay
(under its current name; rename it with Alt+R), when you create it with
Alt+N and a typed name, or when you
open it from the overlay. From then on it is saved like before.

Startup does **not** restore sessions. Every start opens one new unsaved
window. Open saved sessions from the overlay. Earlier versions restored the
sessions in `active.json`; that file is still written but not read.

The manifest preserves tab order, custom window/tab/pane titles, split
orientations and ratios, working directories, active panes, selected tabs,
zoom, window size, and maximized state. Shell integration improves directory
tracking. Missing directories fall back to the normal startup directory.
Primary-screen output, styles, hyperlinks, images, and scrollback are saved
in binary snapshots. Shells start afresh; running commands and alternate-screen
programs are not resumed.

Closed saved sessions remain available in the Sessions overlay. Closing an
unsaved window discards it. Quick terminals are not persisted.

Click the session name in the tab bar or choose **Sessions…** in the command
palette to open the searchable floating overlay inside the current window.
The GTK-only `switch_session` action opens the same overlay:

```ini
keybind = alt+space=switch_session
```

This shortcut is configured in the user's Home Manager source, including the
Vim key table; no default shortcut is imposed by the fork.

Type to filter session names (Unicode case-insensitive substring search).
Up/Down or Tab/Shift+Tab select a result while keeping search focused. Selection
survives refreshes and follows a neighboring row after removal. Rows show
Current, Open, Saved, or Archived status; unsaved sessions are not listed.
**Show archived sessions** includes the archive. The **New Session** button was
removed; use Alt+N.

| Shortcut | Action |
|---|---|
| Alt+S | Save the current window's session under its current name. The search text is not used; rename with Alt+R. |
| Alt+N | Open a new window. With search text, it is a saved session with that name; without, an unsaved window. The hint line shows which one as you type. |
| Enter | Focus an open session, or restore a saved session. Archived sessions are unarchived before opening. |
| Alt+A | Archive; for an open session, save and close with the normal running-process confirmation. Unarchive an archived session. |
| Alt+R | Rename. |
| Alt+K | Ask to permanently delete a closed saved session and its snapshots. Open sessions must be closed first. |
| Escape | Dismiss the overlay. |

Archiving retains the saved layout and terminal snapshots. Canceling a close
confirmation or encountering an archive failure keeps the session open and
unarchived. Pending saves finish before storage changes.

The overlay belongs to its host window, so closing or archiving that window
also closes the overlay. Creating or opening a session dismisses it and shows
the destination window. Normal quit-after-last-window behavior still applies.
There is one overlay per window; the former separate picker and manager paths
both lead to it. The external [native picker API](PICKER_IPC.md) remains separate
and does not expose session-management shortcuts.

## Live theme picker

Use **Pick Theme…** in the main menu or command palette. A user-selected
shortcut can invoke the GTK-only action:

```ini
keybind = ctrl+shift+p=pick_theme
```

The centered picker lists bundled and user themes (user themes take precedence
for duplicate names). Search and navigate with Up/Down or Tab/Shift+Tab to
preview colors across all panes in the current window. Enter or clicking a
result keeps it; Escape or moving focus outside the picker restores the
previous appearance. Opening does not change colors, and no matches cannot be
accepted. Invalid theme files leave the last valid preview visible and show
an error in the picker.

The choice is runtime-only and window-scoped. New tabs and splits follow it;
other windows keep their own colors. **Configured theme** returns to the
configured theme, including automatic light/dark selection. Explicit user
color overrides still win, and theme files cannot change fonts, commands, or
bindings through this picker. With `window-theme = ghostty`, the chrome follows
the preview too; other window theme modes retain desktop colors.

A hard config reload clears runtime choices. Closing the app does not save
them to config or session files. The public `+pick` protocol remains unchanged.
Validation uses builds, focused theme logic tests, and user review of the live
preview; isolated X11 screenshot testing is currently paused at the user's
request.

## CLI tab creation

Create a tab in an existing GTK instance with a directory and command:

```sh
ghostty +new-tab --working-directory=/tmp -e nu
```

Put options before `-e`; all following arguments belong to the command.
An explicit directory takes precedence over parent-pane directory inheritance.
Without `--working-directory`, the CLI forwards its own current directory and
that likewise takes precedence. Relative directory arguments resolve against
the CLI caller's directory. Normal keyboard-created tabs continue to follow
`tab-inherit-working-directory`.

The new process starts from the running Ghostty application's environment,
with configured environment overrides and any shell startup changes. The CLI
does not forward the invoking shell's environment (for example, temporary
exports or a development shell's PATH).

## Compact tabs

`gtk-tabs-style = compact` adds a shared rounded tab rail, a raised selected
pill, and a matching session selector. Tabs fill the available bar by default;
set `gtk-wide-tabs = false` for narrower tabs. Native shrinking and overflow
remain available. The strip uses tighter tab/button padding. Dividers separate inactive
neighbors and fade beside selected or hovered tabs, following native tab order
during dragging and reordering. `native` (the
default) restores standard desktop styling. The choice can be reloaded live;
compact mode respects `gtk-wide-tabs`.

The style works with top or bottom tabs, inverted close buttons, and either
GTK titlebar style. Native tab selection, close buttons, dragging, overflow,
and overview remain available. For a single row of tabs and window controls,
combine it with `gtk-titlebar-style = tabs`. This uses a single new-tab button
on the right and moves overview and split actions into the main menu, giving
tabs more room. Long session names are shortened in the strip and remain fully
visible in their tooltip. Tab tooltips show the full title and working
directory, including when the title fades to fit the available width.

With `window-theme = ghostty`, the title/tab bar mixes 5% of the configured
foreground into the background. The compact rail uses the same mix, while
selected tabs use 12% and popovers, dialogs, and the native picker use an 8%
raised surface. Accents come from ANSI bright blue (palette entry 12), with
soft selection fills and the configured foreground for selection text. These
colors follow configuration reload, not pane focus or application-driven
terminal palette changes. An explicit `window-titlebar-background` keeps its
exact color for the title/tab bar. Other window theme modes retain desktop
colors.

Compact tabs use regular inactive titles and medium-weight selected titles
and session names. The interface font and size follow the desktop by default;
`window-title-font-family` overrides the font family for both the headerbar and
tab bar, independently of the terminal font. Native libadwaita title alignment
and fading remain in use.

Chrome colors continue to follow `window-theme`. Visibility remains controlled
by the existing titlebar and tab-bar options.

## Hiding toolbars

With sessions enabled, toolbars automatically hide for unsaved single-tab
windows. Saving the session or opening a second tab reveals them; closing back
to one tab hides them again if the session is still unsaved. Splits do not
affect this rule. Quick terminals have no saved session: with
`window-show-tab-bar = auto` (default), their tab bar hides with one tab and
appears with multiple tabs, including with `gtk-titlebar-style = tabs`.
Explicit `always` and `never` tab-bar settings still apply.

Set `gtk-toolbar-autohide = false` to disable this policy. A manual toolbar
toggle overrides the policy for that window until configuration is reloaded,
so explicitly showing the bar keeps it visible even with one unsaved tab.
The session shortcut and command palette remain available while bars are hidden.

Use the binding action to toggle the headerbar and tab bar in the current
window:

```ini
keybind = ctrl+shift+b=toggle_toolbar
```

The binding is configurable and has no default shortcut. The command palette's
“Toggle Toolbar” command and the terminal context menu's “Show/Hide Toolbar”
item remain available when toolbars are hidden. The main menu also has the
same toggle. Terminal keyboard focus is retained after toggling.

To keep toolbars hidden regardless of session or tab count, add
`gtk-toolbar-visible = false`. Visibility
toggles are temporary per-window overrides; reloading config and creating new
windows use the configured value. Showing a toolbar respects the existing
headerbar and tab visibility options. Both top and bottom toolbars are covered;
window-manager decorations are controlled separately. This feature is GTK only.

## Moving panes with the keyboard

GTK supports `move_split:left|right|up|down` and
`swap_split:left|right|up|down` within the current tab. For example:

```ini
keybind = ctrl+alt+shift+left=move_split:left
keybind = ctrl+alt+shift+right=move_split:right
keybind = ctrl+alt+shift+up=move_split:up
keybind = ctrl+alt+shift+down=move_split:down
keybind = super+alt+left=swap_split:left
keybind = super+alt+right=swap_split:right
keybind = super+alt+up=swap_split:up
keybind = super+alt+down=swap_split:down
```

These are examples, with no default shortcuts assigned. Your desktop may
reserve some combinations; choose bindings that are free in your environment.
The command palette also offers all eight actions.

Movement uses the same placement as dragging a pane onto its neighbor's edge:
the source's old branch collapses and the target is split equally, placing
the source on the requested side. Swapping exchanges the two panes while
keeping every divider and ratio intact. Both use the nearest pane in the
requested direction, do nothing at an outer edge, retain keyboard focus on
the same running terminal, and reveal the full layout if it was zoomed.
Rearranged layouts are included in normal session saves.

The old personal fork's `move_split` exchanged panes; use `swap_split` for
that behavior here.

## Storage

`$XDG_STATE_HOME/ghostty/sessions/<application-id>/` contains one `<id>.json`
per session plus `active.json`, which lists the sessions to restore. Display
names never form paths. Pane IDs and session IDs are independent of runtime
IPC IDs and remain stable across restoration.
Archived manifests live in the `archived/` subdirectory; their snapshots stay
in the main directory so archiving and unarchiving only rename the manifest.

The application captures layout every two seconds and saves terminal contents
and files on a background worker. Opening the session menu, closing a window,
and quitting flush pending work and capture the latest state synchronously.
Content hashes suppress unchanged writes. Files are written with user-only permissions to a unique temporary
file, synced, then renamed. The active index is committed after the session
files, after each pane snapshot. This provides atomic individual files, not a
transaction spanning all
windows. Multiple application instances with the same application ID share
the store; use distinct `class` values to keep independent stores.

Loading validates manifest versions, names, dimensions, tree reachability,
cycles, depth, ratios, and focus/zoom references. One invalid session does not
prevent the other sessions from restoring. Unknown fields are tolerated.

## Binary snapshots

Each pane references an immutable generation in a
`<session-id>-<pane-id>-<generation>.snapshot` file. Snapshots are committed
before their manifest. Obsolete generations are removed only after the new
manifest is committed. Closed sessions keep their snapshots. Inactive tabs
load their contents when their surfaces initialize; autosaving an uninitialized
pane retains its previous generation.

`window-save-state-snapshot-limit` limits each binary file to 64 MiB by default,
including images. Zero disables content saving and restoration while preserving
layout restoration. A snapshot exceeding the limit keeps its previous saved
generation rather than publishing truncated data. The file-size limit does not
bound all temporary encoder/decoder memory.

Restore takes the primary screen from a complete, validated binary snapshot
and attaches it to a freshly initialized terminal. It discards parser
continuations, alternate screens, keyboard/mouse modes, and cursor pen state.
Current configuration supplies terminal defaults and scrollback/image limits;
contents reflow to the current grid. Shell integration allows removal of an
unfinished visible prompt and input before starting the new shell. Without
integration, the old prompt remains as saved output. Saved input is never sent
to the new process.

Missing, corrupt, or incompatible snapshots fall back independently to fresh
panes. Binary compatibility follows the upstream snapshot format; old content
may become unreadable after an incompatible upstream update. Layout manifests
remain usable without their snapshots. Snapshots contain terminal output and
use the same user-only permissions as manifests.

## Validation

Run the focused tests with `zig build test -Dtest-filter=session`, then build
the GTK application. The storage module can also be tested directly:

```sh
zig test src/apprt/gtk/session.zig
```

For interactive testing, use a separate `class` and `XDG_STATE_HOME`. Check
nested and unequal splits; active/zoomed panes in an inactive tab; renaming
with Unicode; close and reopen; selecting an already open session; a missing
directory; a corrupt session among valid ones; config reload to `never`; and
reactivation while a hidden quick terminal keeps the process running.

For snapshots, run `zig build test-lib-vt -Dtest-filter="session snapshot"`.
Check styled output and scrollback across restart, fresh shell PIDs and input,
primary-screen recovery while a fullscreen program was active, inactive-tab
restoration, missing/corrupt snapshots, size-limit fallback, obsolete-generation
cleanup, and config reload to zero or `never`.

For daily iteration without a Nix-profile rebuild, install from the checkout:

```sh
nix develop -c zig build -p ~/.local -Doptimize=ReleaseFast -fsys=fontconfig
```

Inside an existing development shell, use
`zig build -p ~/.local -Doptimize=ReleaseFast -fsys=fontconfig`. The executable is
`~/.local/bin/ghostty`; ensure it takes precedence in PATH. Fully restart the
application after installing to load the rebuilt binary. Coordinate restarts
with the user so their running sessions are not interrupted unexpectedly.

On Linux, retain `-fsys=fontconfig` so Ghostty and GTK/Pango use the same
Fontconfig library. A local build with bundled Fontconfig aborted during font
zoom on 2026-10-22 while destroying a stale font pattern. Mixing bundled and
system Fontconfig is a known source of font-cache corruption; see the
[upstream discussion](https://github.com/ghostty-org/ghostty/discussions/13479).

Do not use isolated X11/Xvfb screenshot capture or screenshot-viewing workflows
for routine iteration. The user prefers builds, focused logic checks, and
feedback from the normal desktop. Historical screenshot checks above do not
override this preference; resume that workflow only on an explicit request.

For a separate development preview, run from the checkout:

```sh
nix develop -c zig build run -- \
  --class=com.mitchellh.ghostty.preview \
  --gtk-single-instance=false \
  --gtk-tabs-style=compact \
  --gtk-titlebar-style=tabs
```

The preview application ID keeps its named sessions separate from the installed
application. The normal configuration still supplies themes and keybindings.
Alternatively, `nix develop -c zig build` installs the development executable at
`zig-out/bin/ghostty`, which accepts the same flags.
