# Named sessions

Enable with `window-save-state = always`. GTK leaves this disabled for
`default` and `never`. Disabling it retains existing saved sessions.

Each session represents one window's tabs and split trees. The session name
appears at the start of the tab bar. Its menu creates a session in a new
window, renames the current session, or reopens a saved session. Selecting a
session that is already open focuses its window without creating a copy.

The manifest preserves tab order, custom window/tab/pane titles, split
orientations and ratios, working directories, active panes, selected tabs,
zoom, window size, and maximized state. Shell integration improves directory
tracking. Missing directories fall back to the normal startup directory.
Primary-screen output, styles, hyperlinks, images, and scrollback are saved
in binary snapshots. Shells start afresh; running commands and alternate-screen
programs are not resumed.

Closed sessions remain available in the menu. Startup restores the sessions
in the last active-session index. Closing the last window retains that
session for the next activation, including when a hidden quick terminal keeps
the application running. Quick terminals are not persisted.

## Compact tabs

`gtk-tabs-style = compact` adds a shared rounded tab rail, a raised selected
pill, content-width tabs, and a matching session selector. `native` (the
default) restores standard desktop styling. The choice can be reloaded live;
compact mode overrides `gtk-wide-tabs` without changing its configured value.

The style works with top or bottom tabs, inverted close buttons, and either
GTK titlebar style. Native tab selection, close buttons, dragging, overflow,
and overview remain available. For a single row of tabs and window controls,
combine it with `gtk-titlebar-style = tabs`. This uses a single new-tab button
on the right and moves overview and split actions into the main menu, giving
tabs more room. Long session names are shortened in the strip and remain fully
visible in their tooltip. Tab tooltips show the full title and working
directory, including when the title fades to fit the available width.
Chrome colors continue to follow `window-theme`. Visibility remains controlled by the existing titlebar and
tab-bar options.

## Storage

`$XDG_STATE_HOME/ghostty/sessions/<application-id>/` contains one `<id>.json`
per session plus `active.json`, which lists the sessions to restore. Display
names never form paths. Pane IDs and session IDs are independent of runtime
IPC IDs and remain stable across restoration.

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

For a local preview without a Nix profile rebuild, run from the checkout:

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
