# Live theme picker: implementation plan

Status: initial implementation on 2026-10-22; uncommitted. The user approved
the look and basic behavior after a desktop trial on 2026-10-22. A subsequent
ReleaseFast trial exposed a GTK focus-change assertion. Focus-loss dismissal
now runs on an idle callback, and focus is restored only if still owned by the
picker. The ReleaseFast rebuild passed and was installed under `~/.local`;
desktop confirmation after a full application restart is pending. The GTK build and focused theme
tests previously passed.
Isolated X11 screenshot testing is paused at the user's request; use build and
logic checks, then iterate with the user on the normal desktop.

Implementation uses a color-only renderer/terminal update, window-scoped CSS,
and an internal selection callback on the reusable picker. The config helper
tracks the loaded-theme replay prefix so candidates can retain explicit user
overrides without inheriting colors from the previous theme. Candidate colors
are cached for each open picker. Keyboard navigation previews after a short
debounce; Enter flushes pending preview work. Opening another picker cancels
the active theme transaction.

The checks below remain a reference for future validation, not a requirement
to resume isolated UI testing. Desktop feedback is ongoing; the design approval
does not imply all lifecycle cases below are verified.

## First-version behavior

- GTK/Linux only. Add a `pick_theme` binding action and a **Pick Theme…** command-palette entry. Do not impose a default shortcut.
- Open a centered picker inside the current window, using the existing searchable list widget. Cover the window rather than anchoring this window-wide operation to a terminal caret.
- List installed bundled and user themes, sorted by name. User themes take precedence over bundled themes with the same name, matching the existing loader. Show the source in the description.
- Include **Configured theme**, which represents the original configured theme, including a light/dark pair and explicit color overrides.
- Opening the picker does not change colors. Keyboard or pointer selection previews a theme; filtering previews the selected matching result. No matches leaves the last valid preview visible and disables acceptance.
- Enter or row activation keeps the selected theme for this window. Escape or dismissal restores its previous appearance. Closing the owning window disposes the transaction without accessing destroyed surfaces.
- Apply to all tabs and panes in the window, including inactive tabs and newly initialized panes. Other windows keep their own appearance.
- Theme changes affect terminal colors. Chrome follows the same choice when `window-theme = ghostty`; desktop theme modes and explicit titlebar overrides retain their existing meaning.
- Preview and accepted choices do not write config or session files. A hard config reload clears the runtime choice and returns to the latest configuration. New windows start from the configured theme.
- Selecting a named theme temporarily pins that single theme for the window. Selecting **Configured theme** restores automatic light/dark selection. Desktop appearance changes must not overwrite a pinned choice.

Saving a default theme, changing one branch of a light/dark pair, favorites, fuzzy ranking, theme installation, scripting, and a CLI/IPC theme API are later work.

## Findings that shape the design

- `picker/list.zig` already implements search, selection, acceptance, cancellation, and keyboard navigation. It currently exposes only the final result, not selection changes.
- `config/theme.zig` provides ordered user/resource lookup. Theme enumeration also exists in `cli/list_themes.zig`; reuse or extract its non-TUI discovery logic rather than spawning the CLI.
- `Config.loadTheme` loads a theme before replaying user configuration. This precedence must survive previewing. Applying a candidate over an already finalized config can retain colors from the previous theme.
- GTK runtime chrome CSS currently lives in the application's display-wide provider, with color declarations on `:root`. `AdwStyleManager` also controls light/dark appearance at application/display scope. Calling the ordinary app-wide reload path would change other windows.
- Ordinary config propagation has unrelated effects: window config notifications clear toolbar visibility overrides and can show reload toasts. A preview must not invoke these effects on every selection.
- The installed theme set currently has 771 files. Discover names first and load candidates on demand; do not parse every theme on each keystroke. Internal browsing must not acquire the external picker protocol's 1,024-choice limit.

## Implementation sequence

### 1. Build a reversible appearance model

Introduce a small owned appearance value and a config helper that resolves a selected theme against the original config inputs. Keep the replay/provenance handling inside the config module.

- Reconstruct candidate appearance from clean theme inputs plus explicit user/CLI overrides, excluding contributions from the previously loaded theme. Do not recursively accumulate preview state.
- Define an explicit list of appearance fields: palette, background/foreground, cursor colors, selection colors, and the colors needed by existing GTK chrome and split styling. Include theme-provided titlebar colors while retaining explicit user precedence.
- Transfer only those fields into each surface's effective config. Theme files must not change commands, environment, fonts, keybindings, geometry, or process ownership through this feature.
- Preserve special values such as `cursor-color = cell-foreground`, as well as each pane's non-theme settings.
- Snapshot appearance and any previous accepted window override before the first preview. Escape restores that snapshot without rereading config files.
- Resolve and validate a candidate before applying it. Missing or invalid themes leave the last valid preview intact and show a concise picker-local error; acceptance is disabled for the failed candidate.

### 2. Isolate window appearance

Refactor the current runtime CSS into application defaults and window-scoped palette overrides. Use selectors scoped to a stable window identity, including its descendant popovers and native picker.

- Generate both the Quiet rail colors and terminal-related split colors from the effective window appearance.
- Keep the application style manager unchanged during preview. Supply the needed light/dark surface and foreground tokens locally instead of changing a display-wide color scheme.
- Reuse one provider/override per window; replace its contents on change and remove it during disposal. Verify actual GTK popover ancestry rather than assuming every popup inherits the window selector.
- Propagate appearance to realized terminals through the core's existing update mechanism while preserving unrelated config fields. Retain the effective appearance for lazy surfaces and future tabs/splits.
- Avoid ordinary reload toasts, resetting toolbar visibility, accelerator registration, and other non-appearance side effects.

This is the largest prerequisite. Verify two differently themed windows before connecting live picker selection.

### 3. Add internal selection notifications

Extend the reusable list with an optional internal selection-change callback, separate from its existing completion callback.

- Notify on keyboard navigation, filtering, and pointer selection, deduplicated by selected ID. Report an empty selection explicitly.
- Let callers choose the initial row without triggering a preview on opening.
- Coalesce rapid changes with a short debounce (initially around 75 ms). Enter flushes the latest selection before acceptance.
- Keep the external `+pick` request/response schema and session-picker behavior unchanged. Internal theme rows are not constrained by IPC serialization limits.
- Decide and enforce mutual exclusion with other pickers in the same window. Opening another picker first cancels the theme transaction and restores its baseline; pickers in other windows continue normally.

### 4. Own the transaction in the window

Add a theme-picker controller owned by `Window`, holding the catalog, baseline, last valid candidate, prior accepted override, and pending preview source.

- Model opening, previewing, accepting, cancelling, and disposal explicitly. Completion and cleanup are idempotent.
- Use generation checks and weak/lifetime-safe references so stale callbacks cannot repaint a closed window or a newer preview.
- Cache resolved candidates for the transaction and discard the cache on close. Avoid unbounded config clones and CSS providers while scrolling.
- Newly created tabs/panes use the effective preview; cancellation restores their appearance from the pre-preview window baseline while preserving their own non-theme settings.
- Cancel an active transaction before a hard reload or tab transfer between windows. Accepted overrides belong to the destination window when a tab moves; running processes stay intact.
- On successful hard reload, clear the accepted override and use the newly loaded config. Do not restore an old snapshot over it. Soft conditional updates retain pinned runtime choices.
- Restore terminal focus after accept/cancel and leave the running terminal's contents, selection, scroll position, and processes intact, subject to existing color-reload semantics for application-driven palette overrides.

### 5. Wire access and document behavior

Add the binding action, GTK action routing, command-palette entry, and menu access using existing project conventions. Define unsupported-platform behavior consistently with other GTK-only actions.

Document runtime-only scope, cancellation, hard reload, explicit color precedence, light/dark pairs, and an example user-selected shortcut. Update `FORK_STATUS.md` only after implementation and validation.

## Verification and completion criteria

Use focused tests for the config appearance helper and controller state transitions, plus isolated GTK integration checks. Extend reusable picker tests only for changed selection-notification behavior.

- Preview A → B → Escape restores the exact original appearance; reopen → accept B → preview C → Escape restores B. Cover **Configured theme** from an originally configured light/dark pair.
- Theme B omits fields present in A: no values leak from A. Explicit user color overrides and `cell-foreground`/`cell-background` cursor settings still win. Non-theme settings remain equal across previews.
- Two windows with different palettes remain independent, including chrome, split dividers, popovers, picker focus, and concurrent browsing. Changing the OS light/dark appearance does not overwrite pinned themes.
- Existing inactive tabs, newly opened tabs/splits, and tab transfers receive the correct window appearance without restarting processes. Toolbar visibility overrides remain unchanged and no reload toasts appear.
- Cover search with zero matches, rapid navigation followed immediately by Enter/Escape, missing/invalid themes, duplicate names, empty/missing theme directories, and a catalog larger than 1,024 entries.
- Cover reload while browsing, close while preview work is pending, reopening another picker, and repeated open/close cycles. No stale callbacks, growing provider counts, or accumulating configuration allocations.
- Visually check Pierre Dark/Light, Kanagawa Wave, and Gruvbox Dark Hard with top/bottom and compact/native tabs. Check keyboard interaction, readable selections, GTK warnings, X11, and the user's normal Wayland desktop.
- Build with `zig build`, run relevant targeted tests, check Zig formatting, and record the validation performed. Ship no config-writing behavior in this first version.

The result is complete when browsing is visibly live, Escape reliably reverses it, Enter keeps it in exactly one window, and other windows and running processes are unaffected.
