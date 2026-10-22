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
Shells start afresh; running commands and terminal contents are not restored.

Closed sessions remain available in the menu. Startup restores the sessions
in the last active-session index. Closing the last window retains that
session for the next activation, including when a hidden quick terminal keeps
the application running. Quick terminals are not persisted.

## Storage

`$XDG_STATE_HOME/ghostty/sessions/<application-id>/` contains one `<id>.json`
per session plus `active.json`, which lists the sessions to restore. Display
names never form paths. Pane IDs and session IDs are independent of runtime
IPC IDs and remain stable across restoration.

The application captures layout every two seconds, on session-menu opening,
and before closing a window or quitting. Content hashes suppress unchanged
writes. Files are written with user-only permissions to a unique temporary
file, synced, then renamed. The active index is committed after the session
files. This provides atomic individual files, not a transaction spanning all
windows. Multiple application instances with the same application ID share
the store; use distinct `class` values to keep independent stores.

Loading validates manifest versions, names, dimensions, tree reachability,
cycles, depth, ratios, and focus/zoom references. One invalid session does not
prevent the other sessions from restoring. Unknown fields are tolerated.

## Binary snapshots

This first layer restores layout and directories. Future content persistence
can reference binary terminal snapshots by stable pane ID and generation.
Commit the snapshots before publishing a manifest that references them.

Attaching a new shell needs an explicit policy for resetting old parser
continuations, alternate-screen state, keyboard/mouse modes, and prompt
state. Full terminal decoding alone does not restore the process that used
to produce its output. Keep layout restore independent so an incompatible
snapshot can fall back to a fresh pane without losing the session layout.

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
