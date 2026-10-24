# GTK stacked panes

Status: first implementation on 2026-10-24. GTK ReleaseFast build with system
Fontconfig, focused stack/Lua and action-parser tests, standalone session tests
(19 passed, one existing Fish skip), Zig formatting and CLI configuration checks
passed. Model tests cover copied references/allocation failures, close selection,
grouping, extraction, clone/transfer, swap, flattening and stack geometry.
Desktop-approved on 2026-10-24, including the Shift-only mode fix. Extended
lifecycle/restore testing is not claimed. Installed to `~/.local` with
ReleaseFast and system Fontconfig; installed CLI configuration validation
passed. Running sessions were not restarted. Committed in jj change `rnvumyqp`
with the desktop-approved pane-focus follow-up.

## Implementation checkpoint

- Initial desktop trial found that Shift alone canceled pane mode through
  its catch-all binding. The native one-shot lookup now ignores modifier-only
  catch-all matches. Explicit modifier bindings and ordinary table lookup are
  unchanged. Keybinding-set tests and the rebuilt ReleaseFast preview passed;
  the user approved the corrected mode on the desktop on 2026-10-24.
  Whole-stack move/swap remains intentional.
- Stacks mark binary ownership branches with `stacked` and a borrowed
  `stack_selected` terminal pointer. No terminal is owned outside the tree.
  Clone, removal and branch transfer preserve membership; single-member
  stacks naturally become ordinary leaves. Removing the selected member
  chooses the next member or the preceding member at the end.
- A scrollable GTK accordion reuses terminal wrappers. Headers remain visible
  with decorations disabled; only expanded content is mapped. Existing hidden
  PTYs retain their grid and processes; hidden restored members initialize
  lazily when first expanded, following inactive-tab behavior.
- Each stack is limited to 32 members. The expanded wrapper requests at least
  120 logical pixels of height; the group scrolls when its minimum content
  does not fit, including in small windows.
- Directional combination is restricted to compatible sibling leaves/stacks.
  No wrapping or unrelated layout rearrangement is used for combination.
  Move/swap and resize operate on whole stacks. Ordinary splits go beside the
  stack; explicit extraction moves only the selected member. Unstack All
  creates equal-height vertical tiles in member order.
- Up/Down steps through members before external navigation. Horizontal entry
  restores the expanded selection; vertical entry selects the near end.
  Pane zoom shows the selected terminal alone and returns to the stack.
- Native actions: `new_stacked_terminal`, `stack_pane:direction`,
  `unstack_pane:direction`, `unstack_all`; all have command-palette entries.
  `ghostty.stack{ surface?, command?, cwd?, title?, wait? }` creates a member.
- Optional `pane_mode.lua` supplies a one-shot Alt+P key table in normal and
  Vim modes: HJKL combines, Shift+HJKL extracts, N adds, U unstacks all,
  Escape cancels. Unknown non-modifier keys cancel and are consumed; bare
  modifiers keep the mode active. A toast shows the
  available keys. The same guarded block is added to the user's Home Manager
  source, with LuaLS metadata updated and configuration symlinks preserved.
  Builds without `ghostty.stack` skip the block.
- Session version 1 retains ordinary binary nodes, adding optional split
  fields `stacked` and `stack_selected` (saved pane ID). Old sessions default
  to ordinary splits. Older fork readers ignore the added fields and see the
  underlying binary layout; stack grouping/selection is lost on a subsequent
  save from those older readers. Snapshots and relaunch records are unchanged.

The design notes below record the exploration that led to this implementation.
The checkpoint above takes precedence where an earlier proposal differs.

## Confirmed preferences

- Support both new terminals in a stack and combining existing panes.
- Existing directional Up/Down pane-focus actions switch the expanded member,
  then leave the stack at its ends.
- Ordinary split commands split beside the whole stack; adding a member is
  a separate explicit action.
- Directional stack-with-neighbor actions are sufficient for the first
  version; a general pane picker is unnecessary for this delivery.
- The reference is Zellij's accordion-style tiled stacks: every member has a
  visible title row, with one terminal expanded between the rows. This is
  distinct from the already implemented overlapping floating panels.

## Proposed first version

A stack occupies one rectangular tile in a main tab. Its members are terminal
panes, with one expanded and receiving input. Other members retain their
processes, output, titles and close confirmation. Clicking a title expands and
focuses that member. Other stacks and tiles keep their current selections.

Use the existing pane-header visual language, with a single restrained outer
frame and compact title rows. Stack headers remain visible even when optional
tiled-pane decorations are disabled: they are functional navigation controls.
Avoid duplicate headers on the expanded terminal.

Proposed operations (names are provisional):

- **New Stacked Terminal**: turn the current tile into a two-member stack, or
  add after the expanded member of an existing stack; select the new terminal.
- **Stack with Pane Left/Right/Up/Down**: combine existing live terminals
  without restarting them. Use adjacent geometry, not focus-edge wrapping.
- **Unstack Pane Left/Right/Up/Down**: extract the current terminal into a
  neighboring split, preserving its process and focus.
- **Unstack All**: replace the stack with ordinary vertical splits in member
  order. Exact pre-stack layout restoration is not assumed.
- Closing one member uses the normal confirmation path. Closing the expanded
  member selects the next member, or the previous member at the end. One
  remaining member becomes an ordinary tile; zero follows normal tile closure.

Expose actions in the command palette and binding parser without imposing
personal shortcuts. A Lua creation API should follow the established
`split`/`float` command, directory, title and wait semantics; its exact name
and whether it belongs in the first delivery remain design choices.

## Focus and geometry

Up/Down selects the preceding/following member while one exists. At a stack
end, navigate to an adjacent external tile; wrap only at the tab's outer
edge, following the approved tiled-focus behavior. Left/Right navigates out
of the stack. Horizontal entry selects its remembered expanded member.
Proposed vertical entry selects the nearest end member, matching spatial
order. Re-entering a stack must not restart or recreate a terminal.

External navigation, movement and resize must use the stack's rectangle,
rather than the obsolete rectangles of collapsed members. Resizing adjusts
the outer tile. Normal zoom should expand the selected terminal to tab
content and return to the same stack and member afterward.

GTK can hide terminal content independently from title rows. Prefer keeping
collapsed terminals at their last usable grid size, marking them occluded,
and resizing when expanded. Verify this against the surface map/unmap and
lazy initialization paths; do not assume a hidden restored terminal already
has a PTY. Starting fresh hidden terminals and restoring hidden terminals
need an explicit initialization policy.

Header count must not consume the entire usable height. Define a minimum
expanded-terminal area and a strategy for excess rows, such as scrolling
headers, before accepting arbitrarily large stacks. Do not create terminals
and then silently abandon them if layout preparation fails.

## Layout and ownership findings

`Surface.Tree` currently instantiates `datastruct.SplitTree(Surface)`. Its
nodes are terminal leaves or binary splits; `buildTree` creates wrappers and
`GtkPaned` widgets. The macOS application uses a separate Swift split tree.

A stack needs an explicit group model with ordered membership and selection.
Preferred direction to investigate: a stack node referencing terminal leaf
handles, preserving one authoritative owner/iterator for every terminal.
This requires auditing clone, reference counting, removal, split insertion,
iteration, lookup, geometry, equalization, resize, navigation and zoom.

An alternative is GTK group metadata over binary subtrees. This can retain a
fallback ordinary layout, but metadata must survive node-handle changes and
every structural edit must maintain subtree/group consistency. It should not
be selected merely to avoid changing the node type; stale group membership
and different visual/model geometries would be serious correctness risks.

Do not move collapsed members outside normal terminal ownership. They must
participate in close/quit confirmation, snapshots, theme updates, config
reload, Lua surface lookup/events and main-tab transfers.

## Session persistence

Save member order and expanded selection alongside each terminal's existing
identity, directory, title, snapshots and registered-program relaunch record.
Restore retains the fresh-shell policy; stacks do not preserve live processes
across application exit.

Current session manifests encode only leaves and binary splits. Decide on
explicit stack nodes versus optional stack metadata and document version
compatibility. New readers must load existing sessions. Test rollback to
older binaries separately; unknown union tags are not automatically safe.
Validate membership, unique ownership, selection, nesting and limits before
constructing widgets or modifying a live layout.

## Deferred scope

- Merging arbitrary unequal neighboring regions needs clear layout rules;
  proposed first scope is compatible sibling tiles/groups whose combined
  area is rectangular, with unavailable actions returning false rather than
  unexpectedly rearranging unrelated panes.
- Vertical entry, zoom, header overflow, Lua creation and lazy initialization
  use the implementation choices recorded above; desktop feedback is pending.
- Nested stack members, floating stacks, automatic stacking on resize, mouse
  rearrangement and stack animations are proposed deferrals.

## Validation and references

Use focused model tests for membership, ordering, focus, structural operations,
close/cancel, zoom and manifest compatibility. Build GTK ReleaseFast with
system Fontconfig and check formatting. Desktop trials should cover running
TUIs, multiple stacks, decoration toggles, themes, tiny windows, restored
inactive members, tab transfer and canceled close/quit. Do not run isolated
X11 screenshot workflows or restart the user's existing sessions. Install
only after desktop approval.

Local Zellij references:

- `zellij-server/src/panes/tiled_panes/stacked_panes.rs`: expansion, geometry,
  grouping and extraction.
- `zellij-server/src/panes/tiled_panes/tiled_pane_grid.rs`: focus entry,
  within-stack navigation and directional grouping.
- `zellij-server/src/panes/tiled_panes/mod.rs`: terminal creation, focus,
  rendering and PTY resize integration.

Ghostty references: `class/split_tree.zig`, `class/surface_scrolled_window.zig`,
`class/tab.zig`, `class/window.zig`, `session.zig`, `session_save.zig`,
`pane_focus.zig`, `LUA_PLAN.md` and `SESSION_RESTORE.md` under this directory.
