# Lua scripting plan (GTK)

Status: phase 1 is implemented and passed the user's desktop test
(2026-10-22). Phase 2 is implemented and passed the user's desktop test.
Phase 3 is implemented and passed the user's desktop test (2026-10-23). Phase 4
is not started.

## Phase 3: what exists now

Program relaunch is implemented and desktop-approved (2026-10-23): load-time
`ghostty.session.relaunch{ programs = { "hx", "jjui", "btop" } }` registers
executable basenames (additive, maximum 64). The current runtime controls capture
and relaunch; nothing is allowed by default. Linux sessions store eligible argv
and cwd; a fresh shell relaunches after OSC 133 readiness, with literal quoting.
See `SESSION_RESTORE.md` for cancellation and supported shells. This does not
add phase 4 events, devshell reconstruction or editor-internal state restoration.

An optional `commands` table maps registered executable
names to replacement argv for restoration, for example
`commands = { claude = { "claude", "--continue" }, codex = { "codex", "resume", "--last" } }`.
Overrides use the current runtime at launch time and do not alter saved argv.
Each command must start with its registered name. This supports latest-per-cwd
conversation resume, not per-pane conversation identity.

- Each action, bound function and timer function runs in its own Lua
  coroutine (a "task"). A task can wait for the host. While it waits, GTK
  keeps running, and other actions can run.
- `ghostty.exec(argv, { cwd?, timeout?, stdin? })` runs a process with
  GSubprocess, without a shell, and waits for it. It returns
  `{ status, signal, stdout, stderr }`, or `nil, err` if the process cannot
  start. `timeout` is in seconds. After it, the process gets SIGTERM, and
  SIGKILL two seconds later. The process gets Ghostty's environment.
- `ghostty.pick{ surface?, title?, placeholder?, placement?, choices }`
  opens the native picker on a pane and waits. A choice is a string (both
  ID and label) or `{ id?, label, description? }`. It returns the chosen
  ID, or `nil` if the picker is cancelled. The request goes through the
  same JSON checks and limits as `ghostty +pick`.
- `ghostty.sleep(seconds)` waits.
- `ghostty.after(seconds, fn)` and `ghostty.every(seconds, fn)` run `fn` as
  a new task later. They return a timer ID. `ghostty.cancel(id)` stops a
  timer. They also work while `init.lua` loads; then `ctx.surface` is 0.
  `every` needs at least 0.01 seconds.
- Waiting works only in the task's own coroutine. In a coroutine that the
  script makes, the functions return `nil, err`. A bare `coroutine.yield()`
  in a task ends it with an error, because nothing would resume it.
- The time limit (250 ms) applies to each run between two waits.
- A bound function that returns `false` after it waited does not give the
  key back to the terminal. The key counts as handled when the task first
  waits.
- A config reload or app exit stops all waiting operations: processes are
  killed, pickers close and timers stop.
- `ghostty.exec.start` (a process handle) is not implemented yet.

Example: pick a Cargo target and run it in a split.

```lua
ghostty.bind("alt+;>r", function(ctx)
  local root = cargo_root(pane_cwd(ctx.surface))
  if not root then return false end

  local r, err = ghostty.exec(
    { "nix", "develop", "-c", "cargo", "metadata", "--no-deps", "--format-version=1" },
    { cwd = root, timeout = 60 })
  if not r then error(err, 0) end
  if r.status ~= 0 then error(r.stderr, 0) end

  -- Simple parsing: in `cargo metadata`, a target object starts with
  -- "kind", then "crate_types", then "name".
  local choices = {}
  for name in r.stdout:gmatch('"kind":%["bin"%],"crate_types":%[[^%]]*%],"name":"([^"]+)"') do
    table.insert(choices, name)
  end
  if #choices == 0 then return ghostty.toast("no bin targets") end

  local target = ghostty.pick{ title = "Run Cargo target", choices = choices }
  if not target then return end

  ghostty.split{
    command = { "nix", "develop", "-c", "cargo", "run", "--bin", target },
    cwd = root,
    wait = true,
  }
end)
```

## Phase 2: what exists now

- `ghostty.surface.info([id])` returns `{ id, title, pwd, foreground }`.
  `foreground` is `{ pid, cwd, name }`. `cwd` and `name` come from
  `/proc/<pid>/cwd` and `/proc/<pid>/comm` (Linux only). `id` defaults to
  `ctx.surface`.
- `ghostty.split{ surface?, direction?, command?, cwd?, title?, wait? }` splits
  beside `surface` (default `ctx.surface`). `direction` defaults to
  `right`. The new split always gets the focus.
- `ghostty.tab{ surface?, command?, cwd?, title? }` adds a tab to the window
  of `surface`.
- `ghostty.window{ surface?, command?, cwd?, title? }` opens a window.
  Without `surface`, it inherits nothing.
- `command` is a list (run directly) or a string (run through the shell).
- `wait = true` keeps the pane open after the command exits, until a key
  is pressed. `wait = false` closes it. Without `wait`, the
  `wait-after-command` config value applies. The value is stored on the
  core surface (`wait_after_command_override`), so a config reload does
  not reset it.
- A list command runs with Ghostty's own environment. Tools that come only
  from a project dev shell, such as `cargo`, need a wrapper, for example
  `{ "direnv", "exec", root, "cargo", "run" }`.
- The functions return `true`, or `nil, err`. They do not return the ID of
  the new surface, because GTK creates the terminal later, when the widget
  is shown. Phase 3 can wait for it.
- `split_tree.newSplit` now splits beside the given parent when it is in
  the tree. Before, it always split beside the active surface. Existing
  callers pass the active surface, so they do not change.

The Cargo example below works with phase 2. Its `focus` field is ignored.

## Phase 1: what exists now

- Lua 5.4.8 is built from source as `pkg/lua` and linked only into the GTK
  app.
- `src/apprt/gtk/lua/Runtime.zig` holds the Lua state and the API.
  `src/apprt/gtk/lua.zig` connects it to the application.
- Ghostty loads `$XDG_CONFIG_HOME/ghostty/init.lua` at startup and on a hard
  config reload. The new runtime replaces the old one. A runtime that is
  still running an action is freed when GTK is idle.
- The API is `ghostty.action`, `ghostty.bind`, `ghostty.invoke`,
  `ghostty.toast` and `ghostty.log`.
- `ctx` has only `surface`. `args` is always an empty table.
- `ghostty.action` accepts `keywords`, but the command palette does not use
  them yet.
- `ghostty.invoke("lua:<name>")` runs a Lua action.
- The time limit is 1 second for `init.lua` and 250 ms for one action,
  nested actions included.
- `Config.loadWithExtra` adds the Lua keybinds and palette entries as config
  entries after all config files, before any `-e` command. They are replay
  steps, so a light/dark theme change keeps them.

Example for phase 1:

```lua
ghostty.action{
  name = "split_right",
  title = "Split Right",
  description = "Open a split on the right.",
  run = function(ctx)
    ghostty.invoke("new_split:right")
  end,
}

ghostty.bind("super+r", "split_right")

-- A function bind. Returning false sends the key to the terminal.
ghostty.bind("ctrl+alt+t", function(ctx)
  ghostty.toast("surface " .. ctx.surface)
end)
```

The rest of this document is the full plan.

## Goal

Let a Lua file add actions and keybinds to Ghostty. The INI config stays the
main config. Lua does not replace it.

The model is the Lua API of Rex
(https://www.superlogical.com/rex/docs/reference/lua): named actions, keybinds
that call Lua functions, calls into the terminal, and work that waits without
blocking the UI.

The target use case is a script like this one: press a key, find the Cargo
project of the focused pane, and open a target picker in a new split in the
project root.

## Example: the target script

```lua
-- The working directory of a pane: the foreground process first, then the
-- directory that the shell reports (OSC 7).
local function pane_cwd(id)
  local info = ghostty.surface.info(id)
  if not info then return nil end
  return (info.foreground and info.foreground.cwd) or info.pwd
end

-- The nearest directory at or above dir that has a Cargo.toml, or nil.
local function cargo_root(dir)
  while dir and dir ~= "" do
    local f = io.open(dir .. "/Cargo.toml")
    if f then
      f:close()
      return dir
    end
    if dir == "/" then return nil end
    dir = dir:match("^(.*)/[^/]*$")
    if dir == "" then dir = "/" end
  end
end

-- Open the target picker beside a pane. Returns false outside a Cargo project.
local function open_cargo_targets(id, dir)
  local root = cargo_root(dir)
  if not root then return false end
  local _, err = ghostty.split{
    surface = id,
    direction = "right",
    focus = true,
    command = { "cargo-targets" },
    cwd = root,
  }
  if err then error(err, 0) end
  return true
end

ghostty.action{
  name = "cargo_targets",
  title = "Run Cargo Target…",
  description = "Pick a bin or bench target in the current Cargo project and run it in a new pane.",
  keywords = "rust cargo bench run build",
  run = function(ctx, args)
    local dir = args.dir or pane_cwd(ctx.surface)
    if not open_cargo_targets(ctx.surface, dir) then
      error("not in a Cargo project: " .. tostring(dir), 0)
    end
  end,
}

ghostty.bind("super+r", function(ctx)
  return open_cargo_targets(ctx.surface, pane_cwd(ctx.surface))
end)
```

Differences from the Rex version:

- One `ghostty.surface.info` call gives both the foreground process directory
  and the OSC 7 directory. Ghostty already stores the OSC 7 directory as a
  decoded path, so the script does not need to decode `file://` URLs.
- `ghostty.split` takes the command and directory directly. Ghostty has no
  block types, so there is no `flavor`.
- A later phase adds `ghostty.pick`, which opens the native picker. Then the
  Cargo target list can be built in Lua, with no external `cargo-targets`
  program.

## API

All API is in one global table, `ghostty`. Calls that can fail return
`nil, err`. They do not raise errors. An error raised inside an action or a
bound function shows as a toast and goes to the log.

### Load time only

| Function | Result |
|---|---|
| `ghostty.action{ name, title, description?, keywords?, run }` | Adds a named action. It shows in the command palette when it has a `title`. `run(ctx, args)` is called when it runs. |
| `ghostty.bind(key, name \| fn [, opts])` | Binds a key. `key` uses the INI trigger syntax, for example `super+r` or `ctrl+a>n`. `opts.table` names a key table. A function that returns `false` lets the key go to the terminal. |

### Run time only (inside actions, bound functions and callbacks)

| Function | Result |
|---|---|
| `ghostty.invoke(action)` | Runs any built-in binding action, for example `"new_split:right"` or `"goto_tab:3"`. It uses the INI action parser, so all actions work. `"lua:<name>"` runs a Lua action. |
| `ghostty.surface.info(id?)` | `{ id, title, pwd, foreground = { pid, cwd, name } }`. `foreground` is nil when it is unknown. |
| `ghostty.split{ surface?, direction?, command?, cwd?, title?, wait? }` | New split beside `surface`. `direction` is `left`, `right`, `up` or `down`. `command` is a list (run directly) or a string (run through the shell). `wait = true` keeps the pane open after the command exits. Returns `true`. |
| `ghostty.tab{ surface?, command?, cwd?, title?, wait? }` | New tab in the window of `surface`. Returns `true`. |
| `ghostty.window{ surface?, command?, cwd?, title?, wait? }` | New window. `surface` is the parent to inherit from. Returns `true`. |
| `ghostty.toast(text)` | Shows a toast in the window of the current surface. |
| `ghostty.log(text)` | Writes to the Ghostty log. |

### Later phases

| Function | Result |
|---|---|
| `ghostty.exec(argv, { cwd?, timeout?, stdin? })` | Done in phase 3. Runs a process and waits for it. Returns `{ status, signal, stdout, stderr }`. The action pauses while it waits; the UI does not. |
| `ghostty.exec.start(argv, opts)` | Not done. Starts a process and returns a handle with `wait`, `write`, `kill`, `running`. |
| `ghostty.pick{ surface?, title?, placeholder?, placement?, choices }` | Done in phase 3. Opens the native picker and waits for the choice. Returns the choice ID, or nil when the picker is cancelled. |
| `ghostty.sleep(seconds)`, `ghostty.after(seconds, fn)`, `ghostty.every(seconds, fn)`, `ghostty.cancel(id)` | Done in phase 3. Timers. |
| `ghostty.on(event, fn)` | Phase 4. Events: `surface_created`, `surface_closed`, `pwd_changed`, `title_changed`, `session_opened`, `command_finished`. |

### ctx

`ctx.surface` is the runtime ID of the pane that started the action. The IDs
are the same runtime surface IDs that picker IPC already uses. They are not
saved in sessions. `ctx.window` is the ID of its window.

## Where Lua runs

- Only on the GTK main thread. One Lua state for the whole app.
- Each action call runs in a new coroutine. `exec`, `pick` and timers pause
  the coroutine, and a GLib callback resumes it later. This keeps the UI
  responsive while a script waits.
- An instruction-count hook stops an action that runs for more than 250 ms
  without a pause. The action fails with a toast.
- The standard library is available, including `io.open` and `require`.
  `io.popen`, `os.execute` and `os.exit` raise errors, because they block or
  stop the app. Use `ghostty.exec`.

## Loading and reload

- The file is `$XDG_CONFIG_HOME/ghostty/init.lua`. Ghostty loads it after the
  INI config. When the file does not exist, nothing changes.
- `require` searches `$XDG_CONFIG_HOME/ghostty/lua/`.
- A config reload closes the Lua state, cancels coroutines and timers, stops
  processes that actions started, and loads `init.lua` again. WezTerm does the
  same. This is simple and predictable.
- A load error does not stop Ghostty. The INI config still applies, and the
  error shows as a config diagnostic.

## How it connects to existing code

### New binding action: `lua`

`src/input/Binding.zig` gets a new action `lua: []const u8` that holds an
action name. INI can use it too:

```ini
keybind = super+r=lua:cargo_targets
```

`Surface.performBindingAction` sends it to the apprt in the same way as
`switch_session` and `pick_theme`:

```zig
.lua => |name| {
    if (comptime @hasDecl(apprt.Surface, "runLua"))
        return self.rt_surface.runLua(name);
    return false;
},
```

The result is `true` when the action ran, so `performable:` keybinds work.
This needs no change to the C API.

### Keybinds from Lua

`ghostty.bind` records the binding. After `init.lua` loads, the GTK app adds
each binding to its config copy with the normal keybind parser:

- A bind to an action name becomes `key=lua:<name>`.
- A bind to a function gets a hidden name `__bind_<n>` and becomes
  `performable:key=lua:__bind_<n>`.

So the binds follow the same rules as INI binds, including key tables and
sequences. CLI tools such as `+list-keybinds` do not run Lua, so they do not
show these binds.

### Command palette

Lua actions that have a `title` are added to the GTK command palette, with
the action `lua:<name>`.

### Splits, tabs and windows

`split_tree.newSplit` already takes `command`, `working_directory` and
`title` overrides. It always splits beside the active surface. It needs a
small change to split beside a given surface handle. Tabs and windows use the
same override types as the `+new-tab` IPC.

### Foreground process directory

`Surface.getProcessInfo(.foreground_pid)` exists. On Linux, the directory is
the target of `/proc/<pid>/cwd`. Add `foreground_cwd` and `foreground_name`
(from `/proc/<pid>/comm`) next to it.

### Lua library

- Lua 5.4, built from source as `pkg/lua`, in the same way as the other C
  dependencies in `pkg/`. Optional `-fsys=lua` for the system library.
- Why 5.4 and not 5.1 (Rex) or LuaJIT (Neovim):
  - Actions wait with coroutines. PUC Lua 5.1 cannot yield across `pcall`
    or a C function call, so a script that calls `ghostty.exec` inside
    `pcall` would fail. Lua 5.2 and later can do this.
  - Lua 5.4 is plain C with no build steps that run on the host. LuaJIT
    needs host tools (`minilua`, `buildvm`) during its build, which is harder
    with `zig build` and Nix.
  - PUC Lua 5.1 gets no more updates. Lua 5.4 does.
  - Scripts are small, so LuaJIT's speed does not matter.
  - Lua 5.5 is very new. Tools such as LuaLS support it less well.
  - Rex and Neovim scripts need only small changes, for example
    `table.unpack` in place of `unpack`. The APIs are different anyway.
- A small binding written by hand on top of `lua.h` through `pkg/translate-c`.
  No third-party Zig binding, because Zig 0.17 support is not certain.
- The new dependency must be added to the Nix dependency hashes.
- Code goes in `src/apprt/gtk/lua/`, like the other GTK-only fork features.

## Phases

1. **Runtime.** `pkg/lua`, load `init.lua`, `ghostty.action`, `ghostty.bind`,
   `ghostty.invoke`, `ghostty.toast`, `ghostty.log`, the `lua:` binding
   action, palette entries, reload, errors as toasts.
2. **Panes.** `ghostty.surface.info`, `ghostty.split`, `ghostty.tab`,
   `ghostty.window`, foreground process directory. After this phase the
   example script works.
3. **Waiting.** Coroutines, `ghostty.exec`, `ghostty.pick`, timers, the
   instruction limit.
4. **Events.** `ghostty.on`. Later: titlebar status text from Lua.

## Validation

- Zig tests for the parts that do not need GTK: argument conversion,
  `nil, err` results, bind translation to keybind strings, the instruction
  limit.
- GTK ReleaseFast build and `zig fmt`.
- The user runs the example script on the normal desktop. No X11 screenshot
  tests.

## Open questions

- Whether `init.lua` should also be able to set INI keys, for example
  `ghostty.set("font-size", 14)`. Not needed for the goal above.
- Whether Lua binds should show in `+list-keybinds`. That would need the CLI
  to run Lua.
