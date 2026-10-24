# Ghostty fork: status and roadmap

Updated: 2026-10-23

This document records the work completed across the development chats, the current feature boundaries, and the ideas discussed for future work. It describes this fork's GTK/Linux implementation. It does not imply equivalent support in the macOS application.

## Current checkpoint

- Installed and desktop-approved on 2026-10-23: per-tab floating terminals
  are recorded in jj change `lptzpuoy`. The user tried the tabbed container and requested
  independent floating panels instead, approving directional focus with wrapping.
  Each main tab now owns a group of panels, each with its own geometry, title/
  close row and process. New panels cascade 24 logical pixels from the previous
  active panel, constrained to content. Focus raises a panel without reparenting
  or restarting it. Named Lua launches reveal/raise an existing panel; unnamed
  launches create another. The group hides/shows together, and clicking/focusing
  tiles hides it. Main-tab changes retain each group's visibility and selection.
  The user's guarded Home Manager `init.lua` supplies Alt+HJKL directional focus
  (tiled navigation fallback), Alt+Shift+HJKL movement (tiled swapping fallback),
  Ctrl+Alt+HJKL resizing (tiled resizing fallback), Alt+grave toggle, Alt+; then F
  for a fresh shell, and Alt+; then G for named LazyGit, in normal and Vim tables.
  Adjustment mode and the floating tab strip are removed. Move/resize steps are
  2.5%; plain arrows/Enter/Escape reach applications. The command palette exposes
  controls; no repository default bindings were imposed.
  Saved sessions retain individual geometry and stacking, names, output, group
  visibility/selection and existing registered-program relaunch records. Earlier
  tabbed-preview records migrate to cascading panels. Hidden processes participate
  in confirmation, snapshots, themes and main-tab transfers. Scratch-only tabs
  remain alive. Defaults use `gtk-floating-terminal-anchor = center` and
  `gtk-floating-terminal-size = 70%,60%`; reset applies them to the selected panel.
  Saved/manual geometry wins over defaults. Mouse adjustment, docking and floating
  split groups remain deferred. Home Manager edits preserve configuration links.
  The original tabbed/placement implementation passed GTK ReleaseFast builds,
  formatting, 123 focused Lua/session tests (one Fish skip) and 85 placement tests.
  Independent-panel geometry, directional focus/wrapping, cascade and persistence
  tests pass in the standalone session suite (17 passed, one existing Fish skip).
  Final panel validation: GTK ReleaseFast build with system Fontconfig passed;
  the focused floating/session run passed 112 tests with one existing Fish skip.
  Zig formatting, Lua syntax, contextual shortcut/fallback checks and preserved
  Home Manager link targets were verified.
  The user approved the panel redesign on the normal desktop and requested
  review, installation and a commit. Review found no blocking issues. The final
  floating/session/Lua run passed 115 tests with one existing Fish skip; Zig
  formatting, Lua syntax and shortcut fallback checks passed. Installed
  ReleaseFast with system Fontconfig to `~/.local`; running terminals were not
  restarted. Extended lifecycle/restore UI testing is not claimed. See
  `src/apprt/gtk/SESSION_RESTORE.md` and `src/apprt/gtk/LUA_PLAN.md` for behavior.
- Installed on 2026-10-23: Lua phase 4 events and titlebar status. The user
  approved the final titlebar layout on the desktop before installation.
  `ghostty.on` supports surface creation/closure, directory/title changes,
  session opening and command completion. Owned snapshots are delivered as
  coroutine tasks, one handler per GTK tick; reload retires old delivery.
  `ghostty.status(text, { surface? })` updates one window or, with surface 0,
  every window and the default for future windows. The combined titlebar has
  a clickable session name without an arrow, a short divider, optional status
  of up to two lines,
  then a divider before the tabs. Separate headerbars show status beside their
  controls. Compact mode hides the new-tab/menu/window buttons; native tab
  styling retains its controls. The name fits its content up to 24 characters,
  with status capped at 28 characters of width. Empty status collapses.
  A guarded clock example and LuaLS types were added directly to the user's
  Home Manager sources, preserving the configuration links. GTK build with
  system Fontconfig, all 97 final Lua tests and Zig formatting passed. Timer
  operations retain the Lua runtime allocator so timers registered during
  init.lua loading work before the GTK application exists; the production
  timer regression also passed. Review found no blocking issues. Installed
  ReleaseFast with system Fontconfig to `~/.local`; running sessions were not
  restarted. Recorded in jj change `upyuptwx`.
- Installed and desktop-approved on 2026-10-23: per-program Lua restore commands. `commands` in
  `ghostty.session.relaunch` maps registered names to replacement argv; other
  programs replay captured arguments. Claude uses `claude --continue`, Codex
  uses `codex resume --last`, both in the captured directory. These select the
  latest conversation there, not an exact per-pane ID. GTK build with system
  Fontconfig, focused relaunch tests, formatting and diff checks passed. The
  user's init.lua and LuaLS types were updated. The user confirmed desktop
  behavior on 2026-10-23. Installed to `~/.local` with ReleaseFast and system
  Fontconfig. Review found no blocking issues; final focused checks passed
  (86 tests passed, one Fish test skipped) and Zig formatting passed.
  Recorded in jj change `kypvvzst`.
- Desktop-approved on 2026-10-23: Lua-managed program relaunch on session restore. Register names
  with `ghostty.session.relaunch{ programs = { "hx", "jjui", "btop" } }`;
  the default is empty. Linux capture records eligible foreground argv/cwd. A
  fresh shell relaunches after OSC 133 readiness, with literal quoting and
  cancellation on typing/paste or timeout. Devshell and editor-internal state
  are outside scope. The GTK build with system Fontconfig, formatting and focused
  tests passed. Fish's runtime test is skipped because Fish is not installed.
  The user's init.lua registers hx, jjui and btop with an older-binary guard;
  LuaLS types were updated. The user confirmed program relaunch works on the
  desktop on 2026-10-23. Capture streams procfs cmdline files, which report zero
  size; a regression test and a check against live Helix cover this behavior.
  Review found no blocking issues. The final focused tests and formatting passed;
  installed to `~/.local` with ReleaseFast and system Fontconfig after review.
  Recorded in jj change `rypyunky`.
- Desktop-approved on 2026-10-23: opening a closed saved session from an unsaved normal window
  restores in place, preserving the host window's geometry. Saved source windows
  and quick terminals still open separately; already-open sessions are focused.
  Process confirmation precedes replacement. Cancellation and preparation errors
  preserve current panes; archived-session changes wait for confirmation.
  The GTK build with system Fontconfig, Zig formatting and all five focused
  session manifest/storage tests passed. A pending-surface guard prevents the
  last old terminal's disposal from triggering application quit before restored
  terminals initialize. The ReleaseFast build with system Fontconfig is installed
  to `~/.local`, and the user's desktop test passed. Recorded in jj change
  `kqzsmzko`. Active processes were not restarted by the agent.
- Installed on 2026-10-23 at the user's request: quick terminals now follow `window-show-tab-bar` even with
  `gtk-titlebar-style = tabs`: auto hides a single tab and reveals multiple
  tabs. Explicit always/never and manual toolbar overrides remain available.
  The GTK build with system Fontconfig, Zig formatting and diff checks passed.
  The ReleaseFast build with system Fontconfig is installed to `~/.local`.
  The user confirmed the fix works on the desktop. Active processes were not
  restarted by the agent.
- Desktop-approved on 2026-10-23: session-enabled windows automatically hide toolbars when unsaved
  with one tab, and show them when saved or containing multiple tabs.
  `gtk-toolbar-autohide = false` disables the rule; manual toggles override it
  until config reload. Quick terminals are unaffected. The GTK build with system
  Fontconfig, Zig formatting and diff checks passed. Installed to `~/.local`
  with ReleaseFast and system Fontconfig after desktop approval.
- Desktop-approved on 2026-10-23: compact tabs now respect `gtk-wide-tabs` (default true), filling
  the available bar. The custom rail width layout was removed. The GTK build
  with system Fontconfig, Zig formatting and diff checks passed. Installed to
  `~/.local` with ReleaseFast after desktop approval. These tab and toolbar changes,
  including the quick-terminal fix, are recorded in jj change `zxrltonz`.
- Repository: `/home/jemal/dev/projects/ghostty`
- `folie` contains the fork history, including themed chrome, the live theme
  picker, the CLI working-directory fix, the local Fontconfig build guidance,
  Lua scripting (phases 1 to 3), the tab-title and font-reset fixes, and
  unsaved-by-default sessions (haiku names, no startup restore, Alt+S / Alt+N
  in the session manager, fixed-width session name). All passed the user's
  desktop test on 2026-10-23 and are installed in `~/.local`.
- Remotes: `origin` is upstream; `fork` is https://github.com/jemal/ghostty.
  `folie` tracks `folie@fork`. Never push `folie` to `origin`. The newest
  commits are not pushed yet.
- Commit messages have no `Co-Authored-By` line (user rule).
- Next session: read this file, `src/apprt/gtk/SESSION_RESTORE.md` and
  `src/apprt/gtk/LUA_PLAN.md`, then `jj status`. Independent floating panels
  and Lua phase 4 events/titlebar status are installed and desktop-approved.
  Explored ideas are listed under
  "New ideas from 2026-10-23".
- The old feature bookmarks were removed; their commits remain in `folie`.
- Daily use is through `~/.local/bin/ghostty`, built with system Fontconfig.
  The user reports that the font-zoom and theme-picker fixes seem good for now.
- Session switching and management are merged into one searchable overlay.
- The merged overlay passed the GTK ReleaseFast build, formatting, and shortcut
  configuration validation and is installed locally (22:23 CEST). The user
  responded positively to the merged overlay; extended lifecycle testing is
  not claimed.

The fork is usable for daily local workflows. The next useful step is to build real integrations on the existing features, while keeping further UI changes focused.

## Current install and iteration workflow

To test a change, build with `nix develop -c zig build` and let the user run
it with `zig build run`. Install to `~/.local` (below) only after the user says
the change is good enough (user rule, 2026-10-23).

The user now uses a local ReleaseFast installation instead of rebuilding the
Nix-profile/Home Manager package for each change. This is the preferred
temporary workflow because full Nix package builds take too long.

From the repository checkout:

```sh
nix develop -c zig build -p ~/.local -Doptimize=ReleaseFast -fsys=fontconfig
```

When already inside `nix develop`, run:

```sh
zig build -p ~/.local -Doptimize=ReleaseFast -fsys=fontconfig
```

This installs the executable at `~/.local/bin/ghostty` and resources under
`~/.local/share`. The Nix development environment supplies the toolchain and
runtime library paths. Ensure `~/.local/bin` takes precedence over the old
Nix-profile executable; use `which ghostty` to check. Re-run the same build
command after changes. Fully quit and restart Ghostty to load the new binary;
installing it does not update already running processes. Coordinate restarts
with the user rather than terminating their active sessions automatically.
Building/installing does not create a commit or update the Nix-profile package.

Retain `-fsys=fontconfig` on Linux. The 2026-10-22 zoom crash (PID 80461)
aborted with `free(): invalid size` in bundled `FcPatternDestroy`, called from
font-set destruction. Its stale pattern pointed into a GPU mapping, and both
bundled and system Fontconfig were present in the process. This matches the
[known Fontconfig interposition problem](https://github.com/ghostty-org/ghostty/discussions/13479).
Linking system Fontconfig removes the duplicate implementation. The rebuilt
binary imports system Fontconfig and passes font discovery. The user reports
that the fixes seem good in normal desktop use for now; longer-term stability
remains subject to continued use.

## Desktop integration and continuation notes

- Preserve Nix/Home Manager symlinks when editing configuration. Resolve the
  target first and edit `~/.config/hamlet/modules/ghostty/init.lua` directly;
  `~/.config/ghostty/init.lua` points there through Home Manager's store links.
  Do not use `sed -i` on the symlink path: it replaces the link. The types
  directory is also linked to `~/.config/hamlet/modules/ghostty/types`.
- Home Manager source: `~/.config/hamlet/modules/ghostty.mod.nix`.
  On Linux, `programs.ghostty.package = null` and `systemd.enable = false`.
  A declarative drop-in at
  `systemd/user/app-com.mitchellh.ghostty.service.d/local-binary.conf`
  clears `ExecStart` and runs the absolute local binary with
  `--gtk-single-instance=true --initial-window=false`. Do not replace it with
  bare `ghostty`: the systemd executable search path did not find the local
  build, causing `203/EXEC`.
- The local build installs D-Bus activation files. `+new-tab` and
  `+toggle-quick-terminal` can start Ghostty on demand; enabling startup at
  login is not needed. D-Bus sends actions directly when Ghostty is running.
- Niri config: `~/.config/hamlet/modules/niri.config.kdl`. Super+grave runs
  `/home/jemal/.local/bin/ghostty +toggle-quick-terminal`. Niri handles the
  keypress, so this route does not require the global-shortcut portal.
  The Niri config is linked directly and does not need a Nix switch.
- Alt+Space is declared as `switch_session` in both the normal and Vim key
  tables in Hamlet. The generated Ghostty config takes a Home Manager/Nix
  activation to update. Restart Ghostty after binary installation; never kill
  the user's sessions automatically.
- Example CLI launch:
  `ghostty +new-tab --working-directory=~/Documents/vault --title=Vault -e hx`.
  Nushell aliases are not external executables; use `hx` directly rather than
  `nu -c e` when `e` is an interactive alias.
- On 2026-10-23 the user changed the earlier choice: startup no longer
  restores sessions. New windows are unsaved; the session manager saves and
  opens sessions. `+new-split` is still deferred. Native tab bindings with a
  directory and command are now possible with Lua (`ghostty.tab`).
- Next session: read this file and `src/apprt/gtk/SESSION_RESTORE.md`, inspect
  `jj status`, and continue from `folie`. Keep UI iteration based on user
  feedback. Do not restart isolated X11 screenshot tests.

## UI validation preference: no X11 screenshot workflow

**Do not set up isolated X11/Xvfb desktop tests, capture screenshots, or run
screenshot-viewing/visual QA loops for routine iteration.** The user explicitly
stopped this workflow because it adds too much work and takes too long.

Use builds, formatting checks, and focused logic checks where relevant, then
iterate on the normal desktop with the user's feedback about appearance and
behavior. Do not resume the screenshot workflow unless the user explicitly
requests it. Earlier X11/screenshot results in this document are historical
validation, not instructions to repeat those checks.

## Completed features

### Named sessions

One session represents one terminal window. Sessions can be named, renamed, saved and reopened when enabled with the setting below. Since 2026-10-23, new windows are unsaved sessions with haiku names, only saved sessions are written to disk, and startup does not restore sessions. See `src/apprt/gtk/SESSION_RESTORE.md`.

```ini
window-save-state = always
```

Restoration preserves:

- Tab order and split orientations/ratios.
- Working directories and custom window, tab, and pane titles.
- Selected tabs, active panes, and zoom state.
- Window size and maximized state.

Opening an already-open session focuses its existing window. Saved sessions remain available after their windows close. Missing directories fall back to the normal startup directory. Quick terminals are not persisted.

### Terminal contents and scrollback

Binary snapshots restore primary-screen output, scrollback, styles, hyperlinks, and supported image contents. Layouts are captured periodically, with terminal contents and files saved by a background worker. Inactive tabs restore their contents when initialized.

Missing, corrupt, incompatible, or oversized snapshots fall back independently. Content saving has a configurable per-snapshot limit, defaulting to 64 MiB; setting the limit to zero retains layout restoration without terminal contents.

**Restoration starts fresh shells. It does not resume running processes or fullscreen applications.** Shell integration improves directory tracking and cleanup of the old visible prompt. Snapshots contain saved output, and storage uses user-only permissions.

### Session management

Clicking the session name in the header opens one searchable floating Sessions
overlay. The command palette and GTK-only `switch_session` action open the same
UI. Alt+Space is declared in the user's Home Manager source, including Vim
mode. Alt+S saves the current session and Alt+N opens a new one (2026-10-23,
committed); the New Session button was removed.

Type to filter names; Up/Down and Tab/Shift+Tab select a session. Rows show
Current, Open, Saved, or Archived status; unsaved sessions are not listed.
**Show archived sessions** includes the archive. A compact footer shows the
shortcuts. Since 2026-10-23 they use Alt, not Ctrl (user request):

- Enter: open or focus the selected session.
- Alt+S: save the current window's session under its current name.
- Alt+N: new window; saved with the typed name, or unsaved when the search is
  empty. The footer shows which one as you type.
- Alt+A: archive; unarchive when an archived session is selected.
- Alt+R: rename the selected session.
- Alt+K: delete a closed session after confirmation.
- Escape: dismiss the overlay.

Archiving an open session saves and closes it, with the normal running-process
confirmation. Canceling keeps the session open and unarchived. Deletion remains
unavailable for open sessions and removes the layout and snapshots only after
confirmation. Pending saves finish before storage changes.

The overlay is owned by its host window and closes with it, including when
that window is archived. Creating or opening a session dismisses the overlay.
Selection is retained across refreshes, or moves to a neighboring result after
removal. The old pane-local session picker provider was removed; the external
picker IPC and its request/response schema are unchanged.

### Keyboard pane movement and swapping

Directional actions support `left`, `right`, `up`, and `down`:

- `move_split`: removes the pane from its old position and splits its neighbor to place it on the requested side. This reshapes the layout.
- `swap_split`: exchanges two terminals while keeping existing dividers and ratios.

Both retain focus on the same terminal and preserve its running process. Rearranged layouts are included in session saves. Actions are available in the command palette; no default keyboard shortcuts are imposed.

The old personal fork's `move_split` behavior corresponds to `swap_split` here.

### Compact tabs and toolbar controls

Enable the optional compact appearance with:

```ini
gtk-tabs-style = compact
gtk-titlebar-style = tabs
```

The tab strip has a shared rounded rail, a raised selected tab, quieter inactive titles, fewer competing controls, and consistent session-selector styling. Compact tabs respect `gtk-wide-tabs`: by default tabs fill the available bar; `false` retains narrower tabs. The user approved this on the desktop on 2026-10-23. Dividers separate inactive neighbors and disappear beside selected or hovered tabs.

Native selection, close buttons, dragging, reordering, and overflow remain available. Top/bottom tabs and live style reload are supported. Tooltips retain full titles and directory information. UI typography follows desktop settings, with `window-title-font-family` covering the tab bar as well as the headerbar.

Toolbars can be toggled per window:

```ini
keybind = ctrl+shift+b=toggle_toolbar
```

They can also start hidden with `gtk-toolbar-visible = false`. The command palette and terminal context menu provide a way to reveal them. Config reload restores configured visibility.

With sessions enabled, `gtk-toolbar-autohide = true` (default) hides the bars
for unsaved single-tab windows and shows them for saved sessions or multiple
tabs. Splits do not affect the rule, and quick terminals keep their existing
behavior. Set it to `false` to disable automatic hiding. Manual toolbar toggles
override the rule until config reload. The GTK build with system Fontconfig,
formatting and diff checks passed; the user approved the desktop behavior on
2026-10-23.

### Theme-derived GTK chrome

`window-theme = ghostty` now extends the existing terminal background/foreground mapping with the Quiet rail design:

- Title/tab bar and compact rail: 5% foreground mixed into background.
- Selected tabs: 12% foreground mixed into background.
- Popovers, dialogs, cards, and native picker: an 8% raised surface.
- Accents: ANSI bright blue (palette entry 12), with soft selection fills and theme foreground text.

Explicit `window-titlebar-background` values retain their exact title/tab bar color. Other window theme modes retain desktop colors. The palette follows configured theme reloads, not pane focus or terminal applications changing colors through escape sequences. No new configuration setting or Lua dependency was introduced.

The GTK build and Zig formatting checks passed. Isolated X11 checks verified bar and selected-tab pixel colors for Pierre Dark, Kanagawa Wave, Gruvbox Dark Hard, Pierre Light, and an explicit titlebar background. Live reload checks also covered desktop colors, bottom tabs, native tabs, the session picker, and the session manager, without GTK CSS parsing warnings. The user subsequently exercised the chrome and live theme picker on their normal desktop and approved the result on 2026-10-22.

### Live theme picker

**Pick Theme…** is available in the main menu and command palette, with the
GTK-only `pick_theme` binding action and no imposed default shortcut. It lists
bundled and user themes, previews on selection across the current window,
keeps the choice with Enter or a click, and rolls back with Escape or dismissal.
**Configured theme** restores the configured appearance, including a light/dark
pair. Other windows remain independent; new tabs and panes follow the window's
runtime choice. Chrome follows the choice with `window-theme = ghostty`.

Choices are not written to config or sessions; hard reload clears them.
Explicit color overrides retain precedence. Previews update renderer/terminal
colors without full config reload side effects such as resetting key tables,
rebuilding font grids, or showing reload toasts. Theme files cannot change
non-color settings through the picker. The external picker protocol is unchanged.

The GTK build and focused theme logic tests passed. Isolated X11 tests and
screenshots are paused at the user's request; validation proceeds through
builds, logic checks, and live desktop feedback. The user approved the look and
basic behavior. After the subsequent focus-lifecycle crash fixes and the
system-Fontconfig rebuild, the user reports that the fixes seem good for now.
Treat this as provisional desktop confirmation rather than an extended
stability result.

Earlier Escape crashes came from GTK retaining input widgets and emitting
selection/focus callbacks after picker state was freed. Cleanup disconnects
those callbacks before releasing state. The later core dump (PID 49534,
2026-10-22 20:45 CEST) instead showed GTK aborting in
`check_crossing_invariants`: focus-loss cancellation destroyed widgets and
called `grabFocus` during GTK's own focus-change traversal. The new fix defers
focus-loss dismissal to an idle callback, cancels that callback on disposal,
and restores terminal focus only when the picker still owns focus. The
ReleaseFast build passed and the fix is installed at `~/.local/bin/ghostty`.
The user subsequently reported that the fixes seem good for now. Existing
processes were not stopped or restarted by the agent.

The microfetch color issue was traced to an agent preview-launch environment:
`NO_COLOR=1` suppressed ANSI colors, making the logo and color swatches use the
theme foreground. Agent previews now unset that flag; the user confirmed that
resolved the colors. Normal user-specified `NO_COLOR` behavior remains intact.

### CLI tab working-directory precedence

A live check against the user's ReleaseFast build confirmed that
`ghostty +new-tab --working-directory=<requested> -e <command>` ran the command
in the existing pane's directory instead. A second check confirmed the same
failure when relying on the CLI caller's directory without an explicit flag.
The earlier interrupted diagnostic was inconclusive; these later checks
produced actual directory results and reproduced the bug.

The GTK surface now skips parent-directory inheritance when the request
supplies a directory, and applies the explicit override after any inherited
or restored `pwd`. Normal keyboard-created tabs still inherit as configured.
The ReleaseFast build passed and is installed in `~/.local`. Formatting and
diff checks also passed. The user confirmed on 2026-10-22 that `+new-tab`
works on the normal desktop after a restart.

A caller-only environment marker was absent in the new tab, confirming the
existing IPC semantics: new tabs inherit the running Ghostty process's
environment, with config overrides and any shell startup changes, rather than
copying the invoking shell's environment. This behavior was not changed.


See `src/apprt/gtk/SESSION_RESTORE.md` for usage
and `src/apprt/gtk/THEME_PICKER_PLAN.md` for design and future validation cases.

### Lua scripting (phases 1 to 3)

`$XDG_CONFIG_HOME/ghostty/init.lua` can define actions and keybinds. It adds
to the INI config and does not replace it. The model is the Rex Lua API.
Phase 1 has `ghostty.action`, `ghostty.bind`, `ghostty.invoke`,
`ghostty.toast` and `ghostty.log`, and a new `lua:<name>` binding action that
INI keybinds can also use. Lua runs only on the GTK main thread, with time
limits. Errors show as toasts or config diagnostics.

Lua 5.4.8 is built from source (`pkg/lua`). The Nix dependency files were
updated; `nix/zigCacheHash.nix` was not.

Tests for the runtime and the config entries passed. The ReleaseFast build
passed and is installed in `~/.local`. The user's desktop test passed on
2026-10-22.
Phase 2 adds `ghostty.surface.info` (title, OSC 7 directory, foreground
process ID, directory and name) and `ghostty.split`, `ghostty.tab` and
`ghostty.window` with `command`, `cwd`, `title` and `wait`. Its tests and the
ReleaseFast build passed and it is installed. The user's desktop test
passed on 2026-10-22, with the Cargo split script.
Phase 3 runs each action as a coroutine that can wait, and adds
`ghostty.exec` (GSubprocess, with a timeout), `ghostty.pick` (the native
picker, through a new native entry point in the picker service),
`ghostty.sleep`, `ghostty.after`, `ghostty.every` and `ghostty.cancel`.
A reload or exit stops waiting processes, pickers and timers. Its tests and
the ReleaseFast build passed and it is installed. The user's desktop test
passed on 2026-10-23. Phase 4 adds queued `ghostty.on` lifecycle events and
`ghostty.status` for transient window status with up to two lines. The compact
titlebar groups the clickable session name, status and tabs with short
dividers; the user approved the final layout on 2026-10-23. See
`src/apprt/gtk/LUA_PLAN.md`.

### Program relaunch on restore

On Linux, `ghostty.session.relaunch{ programs = { "hx", "jjui", "btop" } }`
in `init.lua` registers executable names for saved-session relaunch. There is no
default allowlist. Session panes store captured argv and the foreground process
directory; both capture and launch consult the current Lua registration.

Restoration starts a fresh shell, waits for live OSC 133 prompt readiness, and
submits a literally quoted command. Exiting the program returns to the shell.
Typing/pasting or a 15-second readiness timeout cancels pending launch. Inactive
tabs retain their record until initialized. Unsupported processes, redirection,
missing directories and disabled registrations restore ordinary shells.

Program memory, editor buffers, pipelines and devshell environments are not
reconstructed. The user will handle Helix's development environment through its
plugin system. GTK builds and focused tests passed, including real Bash/Nushell
argument round trips and zero-size procfs reads. Fish runtime testing is skipped
because it is unavailable. The user confirmed desktop behavior on 2026-10-23.

### Native picker and IPC

Applications and scripts can invoke `ghostty +pick`, supplying one JSON document on stdin and receiving one structured JSON response on stdout.

The service runs inside the existing Ghostty process through D-Bus. It does not require a separate persistent picker process. The helper CLI waits for the response.

Implemented behavior:

- Versioned requests, correlation IDs, and opaque choice IDs.
- Single selection with labels and optional descriptions.
- Unicode case-insensitive substring filtering, preserving input order.
- Up/Down selection, Enter to accept, Escape to cancel.
- Tab/Shift+Tab cycling across all matching results, wrapping and scrolling without traversing into other panes.
- Explicit live instance and pane targeting through inherited endpoint information or CLI overrides.
- Structured selection, cancellation, and error responses.
- Cleanup on timeout, caller disconnection, child exit, pane closure, and application shutdown.
- One picker per pane, with concurrent requests in different panes and an instance limit of 32 active requests.

Choice IDs are data. Ghostty does not interpret them as commands or paths; the caller decides what a selected ID means.

Picker placements:

| Placement | Behavior |
|---|---|
| `center` | Default; centered card capped at 480 logical pixels wide, with scrolling for long lists. |
| `cursor` | Card capped at 360 logical pixels wide and six visible results; aligns the input text start with the terminal caret. |

Cursor placement measures the actual GTK input insertion point, including icon, border, and padding. It captures the terminal caret when opening, prefers below it, flips above when needed, and shifts horizontally to remain inside the pane. Pane boundaries take priority over exact alignment. Filtering retains the horizontal anchor. An off-screen terminal caret falls back to centered placement.

Session switching and management now use a dedicated window-owned overlay.
External picker IPC retains its reusable pane-local widget. Nushell examples
and a Ctrl+X test binding were provided; the user's binding mode is `helix_insert`.

### Reliability and packaging

- Fixed shutdown cleanup of session-save jobs: overdue autosave timers are stopped and pending jobs joined before final GTK event draining.
- Fixed propagated GStreamer package paths in Nix packaging.
- Stabilized the Zig dependency-source cache name so unrelated source revisions can reuse it. Application compilation is still required for changed builds.
- Established an isolated GTK testing workflow using Xvfb, a private session bus, temporary state, xdotool, and actual window screenshots.

## Validation and remaining boundaries

Completed validation includes GTK builds, focused session/storage tests during session development, six picker protocol tests, two picker placement tests, and 38 live picker integration checks. Cursor placement was visually checked at 1× and 2× scaling. Tab checks covered opening, closing, dragging, overflow, and configuration reload. The user also exercised the preview on the normal desktop.

Current boundaries:

- Picker IPC is local GTK/D-Bus functionality. SSH transport and tmux/screen pane discovery are not implemented.
- The desktop session bus is a same-user trust boundary; it does not authenticate which foreground process owns a pane.
- Picker requests contain static choices and support single selection only.
- Search is substring matching, not fuzzy ranking.
- Requests are limited to 1 MiB of JSON and 1,024 choices.
- Saved session/pane IDs and live runtime IPC surface IDs are distinct. Restored processes receive new runtime identities.
- Session restoration preserves state and output, not live processes.
- Binary snapshot compatibility follows the upstream format; layout restoration remains usable if old snapshots become incompatible.
- Broad Wayland, accessibility, and packaging validation is still worthwhile before wider distribution. Xvfb testing primarily covers X11.

## Roadmap: discussed, not yet implemented

There is no unfinished implementation from the approved picker plan. The following items are proposals; their order is a recommendation rather than an approved commitment.

| Priority | Feature | Intended result |
|---|---|---|
| Near term | Nushell picker module | Reusable request construction, result parsing, cancellation handling, and convenient commands without embedding JSON in every binding. |
| Near term | Real project/worktree picker | Populate choices from actual directories or worktrees and change the current shell directory after selection. Replace the test binding with a useful workflow. |
| Near term | Previous-session switching | Return directly to the previously active session; keyboard access to the picker is implemented. |
| Next | Read-only discovery IPC | Structured queries for sessions, windows, tabs, and panes, with explicit distinctions between saved and live identities. |
| Next | Session CLI | List, open, and focus sessions from shells and launchers, with useful structured responses. |
| Next | Optional fuzzy filtering | Match highlighting and ranking for path-heavy lists, while preserving existing request behavior by default. |
| Later | Session templates/duplication | Reuse a layout and directories with fresh shells for another project. |
| Later | Detach a pane | Move a running pane into its own tab or window without restarting its process. |

Possible small UI improvements include tooltips for truncated choice text and an optional result count on long lists. Further permanent chrome should be justified by an actual workflow problem.

### Floating terminals: original exploratory proposal

The original proposal below was refined in discussion on 2026-10-23. The user
approved per-tab floating terminals, direct Lua command launches, optional named reuse,
and keyboard controls. After trying the tabbed prototype, the user approved
independent cascading panels and directional focus with wrapping. That version
is installed and desktop-approved; see the
current checkpoint and `src/apprt/gtk/SESSION_RESTORE.md` for actual behavior.

The initial proposal was one tab-owned scratch terminal above the tiled layout:

- A shortcut shows or hides it; hiding preserves its running process.
- Sensible default geometry, restrained border/shadow, and clear focus indication.
- An explicit way to return focus to the tiled layout.
- Move/resize controls and geometry constrained to the tab's available area.
- Session restoration for its geometry, visibility, contents, and focus.

This is a real terminal-layout feature, not an extension of the picker widget. It needs ownership outside the existing tiled split tree, correct command/input routing, lifecycle handling, and persistence. It does not itself require a daemon.

A later stage could float an existing pane and dock it again while preserving its process. Independent panels and focus-based stacking are implemented; explicit stacking controls, snapping, and floating split groups remain deferred.

### Deliberately deferred ideas

- Vertical tabs: an earlier idea, not implemented in this work.
- Pane headers and additional pane spacing: deferred because of visual clutter and maintenance cost.
- Multiple-selection pickers, confirmation dialogs, text-input request types, and live choice updates: possible API extensions, not supported today.
- SSH-aware picker transport and multiplexer attachment discovery: separate transport/design work.
- Processes surviving application exit: requires separating PTY/process ownership from the GUI and should be treated as its own architectural project.

### Additional ideas collected on 2026-10-22

These record the user's ideas for discussion, not a priority order. The Quiet rail chrome and live theme picker were subsequently approved for implementation and are described above; the remaining items are not an approved implementation plan.

- **`+new-split` CLI action:** Deferred at the user's request.
- **`+new-tab` with a working directory and command:** Directory precedence is fixed and confirmed by the user on the desktop. The environment behavior is documented above.
- **Session startup and keyboard access:** The user prefers keeping automatic startup restoration. Keyboard access uses `switch_session`, with Alt+Space in the user's configuration.
- **Floating session manager:** Merged with session switching into one searchable, window-owned floating libadwaita dialog with Enter, Alt+A, Alt+R, and Alt+K shortcuts; the user approved the merged UI. Extended lifecycle validation is not claimed.
- **Random haiku session names:** Give new sessions generated, readable names, with manual renaming still available.
- **Wider compact tabs or a title/tab bar redesign:** Explore wider tabs in compact mode, or redesign the combined title/tab bar to improve its appearance.
- **Lua VM:** Phase 1 is implemented; see "Lua scripting (phase 1)" above and `src/apprt/gtk/LUA_PLAN.md`. The user decided not to replace the INI config. The original idea: explore embedded Lua for scripting, potentially including replacement of the current INI-style configuration system. No scripting API or configuration migration approach has been selected. Revisit native keybindings that create tabs with a working directory, title, and command during this exploration; the user prefers deferring this capability rather than extending the current `new_tab` binding syntax now. The existing CLI can be invoked through Nushell or compositor shortcuts in the meantime.
- **Optional titlebar time/status:** Add an option to display the time in the titlebar. Consider richer configurable status content, potentially driven by Lua.
- **UI chrome themed from the active terminal palette:** Allow the titlebar, tab rail, session selector, menus, and other chrome to derive colors from the current ANSI/terminal theme instead of fixed colors. Explore background/foreground and palette-based accents, readable contrast for text and controls, and live updates when the theme changes. How to choose the chrome palette when panes use different themes remains a design question.
- **Live theme picker (initial implementation):** Implemented and committed. Browse installed themes with live previews across the current window's terminals and chrome. Enter retains the choice for that window; Escape restores its previous appearance. The first version does not save config. See `src/apprt/gtk/THEME_PICKER_PLAN.md` for appearance isolation, runtime scope, and precedence rules. The user approved the desktop trial on 2026-10-22.

### Approved on 2026-10-23

The user approved these ideas for implementation. No order is set yet.

- Floating scratch terminal (see "Floating terminals" above).
- Random haiku session names: done 2026-10-23, together
  with Alt+N/Alt+S, unsaved sessions and a fixed-width session name.
- Wider compact tabs: done 2026-10-23 by respecting `gtk-wide-tabs`, with
  desktop approval. Session-aware toolbar hiding was also implemented and
  approved. A broader title/tab bar redesign remains optional future work.
- Titlebar time/status: implemented with Lua phase 4 events; the horizontal
  session/status area passed the user's desktop trial on 2026-10-23.

### New ideas from 2026-10-23 (explored, not approved)

Findings from the code are in the conversation of 2026-10-23. Short form:

- **Some sessions not saved:** done 2026-10-23 as the
  user's design: new windows are unsaved, Alt+S in the manager saves the
  current window under its current name, and
  startup does not restore.
- **Placement for new tabs and splits:** `window-new-tab-position` has only
  `current` and `end`. `+new-tab` and Lua could take a position (relative or
  absolute). Splits already take a direction.
- **`+new-tab --title` names only the pane:** fixed (2026-10-23, desktop test
  passed). `Tab.new` now sets the tab's `title-override` and gives the
  first pane no title. This covers `+new-tab`, `+new-window`, `ghostty.tab`
  and `ghostty.window`.
- **Alt+N in the session manager:** done 2026-10-23.
  With typed text, it opens a saved session with that name; without, an
  unsaved window. The New Session button was removed.
- **Picker for links in view:** `renderer/link.zig` already matches the
  `link` regexes in the viewport for hover. OSC 8 hyperlinks are in the page
  cells. A Lua API that returns them (or the viewport text) would let a
  script build the picker.
- **Vim-style cursor mode in scrollback:** not in upstream. Upstream has
  search and `adjust_selection` only. Large feature.
- **Restore Helix panes:** implemented and desktop-approved on 2026-10-23 as
  Lua-managed program relaunch. Captures argv/cwd for registered executables
  and relaunches through a fresh shell; editor-internal state is outside scope.
- **Font size reset:** fixed (2026-10-23, desktop test passed). A surface
  that inherits a zoomed size now keeps `font-size` from the config as its
  original size, so reset goes back to the configured size. The inherited
  zoom counts as an adjustment, so a config reload keeps it.
- **Tasks from `.vscode/tasks.json` / `.zed/tasks.json`:** possible as a Lua
  script with `exec` + `pick` + `split`. Lua has no JSON parser; add
  `ghostty.json.decode` (Rex has `rex.json`).

## Commit checkpoints

Use jj change IDs below: they survive the timestamp rewrites that changed Git
commit hashes. Only `main` and `folie` remain as local bookmarks. The fork's
16 original author dates were randomized in order from 19:30 to 21:42 CEST on
2026-10-22. Committer dates record subsequent rewrites; `jj log` displays those
by default. Do not interpret its relative times as the randomized author dates.
On 2026-10-23, `folie` was pushed to the `fork` remote
(https://github.com/jemal/ghostty) and tracks `folie@fork`. `origin` is
upstream; `main` tracks `main@origin`. Never push `folie` to `origin`.

| jj change | Change |
|---|---|
| `xsnurzul` | nix: fix propagated GStreamer package paths |
| `lrmxuzkt` | gtk: add named session restoration |
| `tynpprsv` | nix: reuse the Zig dependency cache across revisions |
| `spzxqnnx` | gtk: restore session contents from binary snapshots |
| `xsvumyqv` | gtk: add a compact pill tab style |
| `qrukzomu` | gtk: simplify compact tab controls |
| `yuxuoutk` | gtk: refine compact tab typography |
| `woolputm` | gtk: add toolbar visibility controls |
| `owrurkzp` | gtk: add keyboard pane movement and swapping |
| `zsmykktp` | gtk: add session archiving and deletion |
| `ryqquyks` | gtk: add a session manager window |
| `npkvkqtw` | gtk: add pane-scoped picker IPC and cursor-anchored selection |
| `mnnxprwv` | gtk: honor CLI working directories for new tabs |
| `sqlxrquw` | gtk: derive UI chrome colors from the terminal theme |
| `ptqyknxn` | gtk: add a window-scoped live theme picker |
| `yksnvuzw` | docs: record fork roadmap and local development workflow |
| `ukknpltx` | docs: use system fontconfig for local Linux builds |
| `xvyxyotw` | Unified searchable session overlay, keyboard actions, and handoff docs. |
| `zpwtzozm` | gtk: add Lua scripting for actions and keybinds (phase 1) |
| `onykxtxm` | gtk: let Lua inspect panes and open splits, tabs and windows (phase 2) |
| `qpmzpspo` | gtk: let Lua actions wait for processes, the picker and timers (phase 3) |
| `ttzpzmnp` | gtk: let a title for a new tab name the tab |
| `yusoxzrx` | gtk: reset an inherited font size to the configured size |
| `xslmnnxk` | gtk: make sessions unsaved until the user saves them |
| `mnzxlrvt` | docs: record the 2026-10-23 fork work in FORK_STATUS.md |
| `zxrltonz` | gtk: refine tab sizing and automatic toolbar visibility |
| `kqzsmzko` | gtk: restore saved sessions in unsaved windows |
| `rypyunky` | gtk: relaunch registered programs when restoring sessions |
| `kypvvzst` | gtk: configure session relaunch commands in Lua |
| `upyuptwx` | gtk: add Lua events and titlebar status |
| `lptzpuoy` | gtk: add per-tab floating terminal panels |

## Related implementation documentation

- `src/apprt/gtk/SESSION_RESTORE.md`: configuration, session semantics, storage, snapshots, pane actions, and validation.
- `src/apprt/gtk/PICKER_IPC.md`: request/response schema, endpoint targeting, lifecycle, limits, D-Bus methods, and Nushell usage.
- `src/apprt/gtk/THEME_PICKER_PLAN.md`: implemented live theme picker and reference plan, appearance isolation, runtime scope, and validation criteria.
- `src/apprt/gtk/LUA_PLAN.md`: Lua scripting API and implemented phases 1 to 4.
- User tooling outside the repository: `~/.config/ghostty/types/ghostty.lua` (LuaLS `---@meta` types for the API), `.luarc.json` and `stylua.toml` (2 spaces, double quotes, 100 columns, `call_parentheses = "NoSingleTable"`, one-line conditionals allowed). Keep the types file in step with the API.
- `~/dev/rust-terminal-idea.md`: notes for a possible Rust terminal on libghostty-vt (idea only; this fork has priority).
- `test/gtk-picker.py`: portable isolated GTK picker integration checks.

Keep this document updated at feature checkpoints. Move roadmap entries into completed features only after implementation and validation; distinguish newly approved work from speculative ideas.
