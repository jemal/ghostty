# Activity monitor: draft and implementation plan

Status: stopped at the user's request on 2026-10-25. The activity and vertical
studies were not preferred and are retained only as exploration notes.
No activity/vertical GTK implementation is approved or installed.
Draft: `design/ui-draft/index.html`, `activity.css`, `activity.js`,
`vertical.css`, `vertical.js`.

The user requested a vertical-tab comparison, then rejected the expanded task
hierarchy as too busy. The current draft keeps only tab names and a small
aggregate status icon in the left rail (228 px expanded, 48 px collapsed).
Native hover text contains task messages/progress. A small Activity control
in the top bar opens the detailed panel. Inline descriptions, progress bars
and footer counts have been removed. Horizontal tabs remain selectable.
The user stopped this candidate; vertical tabs are not implemented in
GTK. Browser checks passed the simplified structure, hover descriptions,
selection, status changes, activity-panel navigation, add/close, collapse,
horizontal restoration and narrow-window bounds. Pane margins/radii were
checked and a screenshot visually inspected.

## First version

A compact Activity control opens a dismissible panel over the workspace.
It covers the current window's tabs and tiled/floating panes; cross-session
navigation is outside this first version. Pane geometry stays unchanged.

Group explicit reports into Needs attention (blocked/error), Running (working),
Finished (done), and optional Idle. Show the reporting program, message,
location, age of its last state change, and determinate progress when supplied.
Filter by program/message/location. Selecting a row focuses its tab and pane.

Attention and task state are separate. Selecting a tab acknowledges its marker;
a blocked task remains blocked until its program sends a different status.
A new blocked/error/completed transition can produce the approved brief pulse
and settled marker on an inactive tab. Repeated unchanged reports must not
restart the pulse. Working updates should not demand attention. Respect GTK's
animation preference. The HTML study uses sample reports, not OS monitoring.

## Existing support and proposed data path

- The OSC 7501 parser already accepts idle, working, done, blocked and error,
  plus clear reports, record IDs, program identity, messages and progress.
- `src/termio/stream_handler.zig` currently ignores `.program_status`.
- Forward validated reports through the existing thread-safe surface message
  path. Copy report data before the parser callback returns; borrowed text
  cannot survive that callback.
- Maintain bounded records per surface, keyed by report ID within that surface.
  Define replacement/clear/reset behavior and overflow handling before coding.
  Remove records when a surface closes; do not restore stale running statuses
  from session snapshots. Moving a live pane retains its records.
- Derive the window list and tab aggregates from those records. Focus targets
  must remain safe if the original pane closes or moves while the panel is open.
- Advertise protocol support only once reports have a real consumer. Programs
  without reporting support do not magically acquire waiting/completion states.
  Shell-integration command tracking can be a separate fallback afterward.

## Validation before installation

Target parser-to-surface ownership, replacing IDs, clear/reset, process/surface
closure, bounded retention, tab aggregation and acknowledgment separately from
state. Exercise live progress, blocked-to-working, done/error, repeated reports,
focus after tab/pane moves, keyboard navigation, empty/filter states and reduced
motion. Use a small reporting shell script to verify the complete application
path. Batch GTK changes before a Debug build; install only after desktop review.
