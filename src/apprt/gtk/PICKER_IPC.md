# Native pane picker (GTK)

`ghostty +pick` reads one UTF-8 JSON document from stdin through EOF, opens a
searchable picker inside the originating pane, and writes one JSON response
followed by a newline to stdout. Diagnostic logging uses stderr. It requires a
running Ghostty built with this API. It never starts a new application instance.
The picker is a card capped at 480 logical pixels wide, centered by default. Its height
follows the choices, with scrolling for long lists and shrinking in small panes.

To try the checkout build without replacing an installed Ghostty, run from the
repository root:

```sh
export GHOSTTY_DEV_BIN="$PWD/zig-out/bin/ghostty"
"$GHOSTTY_DEV_BIN" --class=com.mitchellh.ghostty.picker-preview --gtk-single-instance=false
```

Inside that new window, use `"$GHOSTTY_DEV_BIN" +pick` as the helper until the
updated executable is on PATH. Existing Ghostty processes do not gain the API
when a new executable is built.

For example, with the updated executable on PATH, run inside its pane:

```sh
printf '%s\n' '{"version":1,"request_id":"project","title":"Choose a project","choices":[{"id":"api","label":"Backend"},{"id":"web","label":"Website"}]}' | ghostty +pick
```

```json
{
  "version": 1,
  "request_id": "project",
  "status": "selected",
  "result": { "kind": "select", "ids": ["web"] }
}
```

Escape returns:

```json
{
  "version": 1,
  "request_id": "project",
  "status": "cancelled",
  "reason": "user"
}
```

An invalid target, busy pane, or unavailable service returns an error:

```json
{
  "version": 1,
  "request_id": "project",
  "status": "error",
  "error": { "code": "busy", "message": "busy" }
}
```

Exit codes are 0 for selection, 2 for cancellation, and 1 for errors. SIGINT and
SIGTERM request cancellation and return 130 and 143 respectively. A broken output
pipe, forced kill, or host failure can prevent response delivery. An application
must terminate its helper when abandoning a request; parent exit alone does not
imply helper exit. Stdin must reach EOF within 30 seconds.

## Request schema

Required fields are `version` (1), `request_id` (nonempty string), and `choices`
(nonempty array of objects with `id` and `label`). Each choice can also supply a
`description`. Labels may repeat; IDs must be unique. IDs are opaque strings and
are never interpreted as commands, paths, or Ghostty actions.

Optional fields:

- `kind`: `"select"` (the default and only supported kind).
- `placement`: `"center"` (default) or `"cursor"`. Cursor placement captures the
  terminal caret in the originating pane when the picker opens. Cursor pickers
  are capped at 360 logical pixels and six visible results before scrolling.
  The input text starts in line with the terminal caret, using measured widget
  geometry; pane boundaries take priority near the edges. It prefers
  below the caret, flips above near the bottom, shifts left near the right
  edge, and scrolls tall lists within the available space. It stays inside
  the pane on resize. Filtering keeps the same anchor. If the caret is off
  screen, placement falls back to center.
- `selection`: `"single"` (the default and only supported mode).
- `title`, `placeholder`: plain text for the search hint. A custom placeholder
  takes precedence; the title also remains available as the search tooltip.
- `surface_id`: a nonzero runtime pane ID, as a decimal or `0x` hexadecimal string.
- `timeout_ms`: 0 for no interaction timeout, otherwise up to 86,400,000 ms.
- `instance`: service instance identity; filled by the helper for wire requests.

Search performs Unicode case folding and substring matching over labels and
descriptions while preserving input order. Up/Down select, Enter accepts, and
Escape cancels. Tab and Shift+Tab cycle all matching choices, wrapping at the
ends and scrolling them into view while keeping search ready for typing. They
never traverse into another pane. Enter without a matching selection leaves the picker open.

The wire request is limited to 1 MiB, including target fields added by the helper.
There may be at most 1,024 choices, with 256 UTF-8 bytes per ID, 1,024 per label,
4,096 per description, 128 per request ID, and 1,024 each for title/placeholder.
Text must be valid UTF-8 without C0/DEL control characters. Unknown fields,
duplicate fields, duplicate IDs, unsupported modes, and invalid limits are
rejected. A rejected JSON document retains its request ID when it can be recovered
unambiguously; otherwise the response uses `request_id: null`.

## Targeting and lifetime

Ghostty publishes `GHOSTTY_IPC_BUS_NAME`, `GHOSTTY_IPC_INSTANCE`, and the existing
`GHOSTTY_SURFACE_ID` to pane processes. The bus name identifies the exact live
connection, including for `gtk-single-instance=false` and custom classes. The
instance value detects stale environments after a bus restart. These are routing
identities, not secret credentials.

`--surface-id=<id>` overrides the JSON/environment surface. A JSON surface overrides
the environment. `--bus-name=<name>` or `--class=<application-id>` overrides inherited
instance targeting; these two flags are mutually exclusive. A class is resolved
to its unique owner once, and all operations stay pinned to that owner. There is
no fallback to the focused pane or to a replacement process.

Each pane accepts one picker. A second request receives `busy`; different panes
can host requests concurrently, with at most 32 active requests per instance.
External requests must originate from an active, visible pane. After admission,
changing focus leaves the picker open. Completion restores pane input focus only
when the picker still owns focus and never raises another window. Ordinary pane
move/swap preserves the interaction with its live surface.

Cancellation reasons include `user`, `caller`, `caller_gone`, `timeout`,
`child_exited`, `pane_closed`, and `shutdown`. Child exit cancels requests even
when `wait-after-command` keeps the pane open. New requests to an exited pane are
rejected. Process or bus loss can instead produce a helper-side `transport_error`.
Selection/cancellation/teardown compete for one terminal outcome.

A saved pane ID is not a runtime surface ID. Session restoration starts new
processes with new endpoint identities; requests are never persisted or resumed.

## Direct D-Bus API

The existing Ghostty process exports `com.mitchellh.ghostty.Picker1` at
`/com/mitchellh/ghostty/Picker1` on its session-bus connection:

```text
GetCapabilities() -> (capabilities_json: string)
Select(request_json: string) -> (response_json: string)
Cancel(request_id: string) -> ()
```

Capabilities include version, instance identity, supported kinds, and aggregate
payload/choice limits. `Select` holds the method invocation asynchronously until
completion; the GTK main loop continues running. Set an appropriate human-scale
or unlimited client timeout: GIO's `-1` is a default timeout, not unlimited.
`G_MAXINT` requests no timeout. Disable service auto-start.

Keep the same connection for Select and Cancel. Cancellation matches both the
sender's unique name and request ID; another connection cannot cancel a request.
Duplicate in-flight IDs on one sender are rejected. Caller disconnection frees
its requests. There are no result broadcasts, callback paths, request objects,
or post-disconnection result recovery. Cancelling a local GIO operation does not
cancel the remote picker: send Cancel or disconnect the owning connection.

The desktop session bus is a same-user trust boundary. It does not prove that a
sender is the foreground process in a pane. Sandbox/Flatpak access may be filtered;
missing access is an error. This initial implementation does not bridge SSH or
map tmux/screen panes: long-lived multiplexer environments may identify an old or
ambiguous attachment. Specify a verified endpoint explicitly when needed.

## Session switching

With named sessions enabled (`window-save-state=always`), the session menu has
**Switch Session…**. It uses the same widget and lifetime controller with stable
session IDs, without D-Bus or JSON. Choosing an open session focuses its window;
choosing a saved session restores it through the existing session loader. The
list excludes archived sessions. Rename/archive/delete remain in Manage Sessions.

## Validation

```sh
nix develop -c zig build test -Dtest-filter=picker
nix develop -c zig build
```

The live GTK suite uses a private Xvfb display, session bus, state directory, and
application class. It needs `Xvfb`, `xdotool`, `gdbus`, and `dbus-run-session` on PATH:

```sh
nix develop -c python3 test/gtk-picker.py
```

`XVFB`, `XDOTOOL`, and `GHOSTTY_TEST_BIN` can override executable locations. The
suite covers filtered and keyboard selection, empty results, cancellation,
connection ownership, busy/concurrent requests, focus changes, session switching,
child exit, window disposal, application termination, and a graceful shutdown
after autosave without allocator leak warnings. It does not install
Ghostty or interact with normal user windows.

## Cursor-anchored example (Nushell)

```nu
{
  version: 1
  request_id: "project-at-cursor"
  placement: "cursor"
  title: "Choose a project"
  choices: [
    {id: "api", label: "Backend", description: "API services"}
    {id: "web", label: "Website", description: "Frontend"}
  ]
} | to json --raw | ^$env.GHOSTTY_DEV_BIN +pick
```
