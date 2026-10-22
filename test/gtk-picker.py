#!/usr/bin/env python3
"""Real GTK picker checks on a private display and session bus.

Build Ghostty, then run with Xvfb, xdotool, gdbus and dbus-run-session on PATH:
    python3 test/gtk-picker.py
GHOSTTY_TEST_BIN, XVFB and XDOTOOL may override executable locations.
"""
import json
import os
from pathlib import Path
import shutil
import shlex
import signal
import subprocess
import sys
import tempfile
import time

BIN = os.environ.get("GHOSTTY_TEST_BIN", str(Path(__file__).resolve().parents[1] / "zig-out/bin/ghostty"))
XDOTOOL = os.environ.get("XDOTOOL", "xdotool")
XVFB = os.environ.get("XVFB", "Xvfb")
CLASS = "com.mitchellh.ghostty.picker.test"


def wait_for(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise RuntimeError("Timed out waiting for test state")


def isolated_run():
    for executable in (BIN, XVFB, XDOTOOL, "gdbus", "dbus-run-session"):
        if not shutil.which(executable):
            raise SystemExit(f"Missing executable: {executable}")
    with tempfile.TemporaryDirectory(prefix="ghostty-picker-") as directory:
        with open(Path(directory) / "xvfb.log", "w") as log:
            read_fd, write_fd = os.pipe()
            server = subprocess.Popen(
                [XVFB, "-displayfd", str(write_fd), "-screen", "0", "1200x800x24", "-nolisten", "tcp"],
                pass_fds=(write_fd,), stdout=log, stderr=log,
            )
            os.close(write_fd)
            try:
                display = os.read(read_fd, 100).decode().strip()
                env = os.environ.copy()
                env.update(
                    DISPLAY=":" + display, GDK_BACKEND="x11", GSK_RENDERER="cairo",
                    PICKER_TEST_DIR=directory, XDG_STATE_HOME=directory + "/state",
                    GTK_A11Y="none", GSETTINGS_BACKEND="memory",
                )
                for key in ("WAYLAND_DISPLAY", "GHOSTTY_SURFACE_ID", "GHOSTTY_IPC_BUS_NAME", "GHOSTTY_IPC_INSTANCE"):
                    env.pop(key, None)
                return subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "inner"], env=env)
            finally:
                os.close(read_fd)
                server.terminate()
                server.wait(timeout=10)


def run_tests():
    directory = Path(os.environ["PICKER_TEST_DIR"])
    pane = directory / "pane.py"
    pane.write_text(
        'import json,os,time,pathlib\n'
        'data={k:v for k,v in os.environ.items() if k.startswith("GHOSTTY_")}\n'
        'data["PANE_PID"]=str(os.getpid())\n'
        'pathlib.Path(os.environ["PICKER_TEST_DIR"],"endpoint.json").write_text(json.dumps(data))\n'
        'while True: time.sleep(1)\n'
    )
    helpers = []
    log_path = directory / "ghostty.log"
    with log_path.open("w") as log:
        app = subprocess.Popen([
            BIN, "--config-default-files=false", "--gtk-single-instance=false",
            "--class=" + CLASS, "--window-save-state=always", "--window-save-state-snapshot-limit=0",
            "--confirm-close-surface=false", "--shell-integration=none", "--wait-after-command=true",
            "--keybind=ctrl+alt+x=close_surface",
            "--title=Picker IPC Test", "--command=" + shlex.join([sys.executable, str(pane)]),
        ], stdout=log, stderr=log)

        def xd(*arguments):
            return subprocess.check_output([XDOTOOL, *arguments], text=True).strip()

        def request(**changes):
            value = dict(version=1, request_id="r", timeout_ms=1500, choices=[
                dict(id="one", label="Backend"), dict(id="two", label="Website"),
            ])
            value.update(changes)
            return value

        def start(value, env=None, flags=()):
            helper = subprocess.Popen([BIN, "+pick", *flags], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env or endpoint)
            helpers.append(helper)
            helper.stdin.write(json.dumps(value))
            helper.stdin.close()
            helper.stdin = None
            return helper

        def result(helper):
            stdout, stderr = helper.communicate(timeout=8)
            try:
                return helper.returncode, json.loads(stdout)
            except ValueError:
                raise AssertionError((helper.returncode, stdout, stderr))

        def check(name, condition):
            assert condition, name
            print("PASS", name, flush=True)

        def action(name):
            return subprocess.run([
                "gdbus", "call", "--session", "--dest", endpoint["GHOSTTY_IPC_BUS_NAME"],
                "--object-path", "/com/mitchellh/ghostty/picker/test/window/1",
                "--method", "org.gtk.Actions.Activate", name, "[]", "{}",
            ], check=True, capture_output=True, text=True)

        try:
            wait_for(lambda: (directory / "endpoint.json").exists() or app.poll() is not None)
            if app.poll() is not None:
                raise RuntimeError(log_path.read_text())
            endpoint = os.environ.copy()
            endpoint.update(json.loads((directory / "endpoint.json").read_text()))
            check("endpoint published for non-unique instance", bool(endpoint.get("GHOSTTY_IPC_BUS_NAME")))
            window = wait_for(lambda: xd("search", "--name", "^Picker IPC Test$"))
            xd("windowfocus", "--sync", window)
            time.sleep(0.3)

            helper = start(request(placement="cursor"))
            time.sleep(0.2)
            xd("type", "Website")
            xd("key", "Return")
            code, reply = result(helper)
            check("cursor-anchored picker filters and selects", code == 0 and reply["result"]["ids"] == ["two"])
            code, reply = result(start(request(placement="mouse")))
            check("unsupported placement is rejected", code == 1 and reply["status"] == "error")

            code, reply = result(start(request(timeout_ms=200)))
            check("timeout", code == 2 and reply.get("reason") == "timeout")
            helper = start(request())
            time.sleep(0.2)
            xd("type", "--clearmodifiers", "Website")
            xd("key", "Return")
            code, reply = result(helper)
            check("immediate filtered selection preserves ID", code == 0 and reply["result"]["ids"] == ["two"])

            for backwards in (False, True):
                helper = start(request())
                time.sleep(0.2)
                xd("key", *(["shift+Tab" if backwards else "Tab"] * 6))
                xd("type", "Website")
                xd("key", "Return")
                code, reply = result(helper)
                check("Tab cycling stays inside picker" + (" backwards" if backwards else " forwards"), code == 0 and reply["result"]["ids"] == ["two"])
            many = [dict(id=str(i), label=f"Choice {i}") for i in range(12)]
            helper = start(request(choices=many))
            time.sleep(0.2)
            xd("key", *(["Tab"] * 11), "Return")
            code, reply = result(helper)
            check("Tab reaches every choice beyond viewport", code == 0 and reply["result"]["ids"] == ["11"])
            helper = start(request(choices=many))
            time.sleep(0.2)
            xd("key", "shift+Tab", "Return")
            code, reply = result(helper)
            check("reverse Tab wraps to final choice", code == 0 and reply["result"]["ids"] == ["11"])
            helper = start(request(choices=[dict(id="a", label="match A"), dict(id="b", label="skip"), dict(id="c", label="match C")]))
            time.sleep(0.2)
            xd("type", "match")
            xd("key", "Tab", "Return")
            code, reply = result(helper)
            check("Tab skips filtered choices", code == 0 and reply["result"]["ids"] == ["c"])
            helper = start(request())
            time.sleep(0.2)
            xd("key", "Tab", "Down", "Return")
            code, reply = result(helper)
            check("keyboard selection after tabbing into results", code == 0 and reply["result"]["ids"] == ["two"])
            helper = start(request())
            time.sleep(0.2)
            xd("key", "Down", "Return")
            code, reply = result(helper)
            check("arrow selection preserves search focus", code == 0 and reply["result"]["ids"] == ["two"])
            helper = start(request())
            time.sleep(0.2)
            xd("type", "no-matching-choice")
            time.sleep(0.3)
            xd("key", "Return")
            time.sleep(0.1)
            check("Enter with no matches keeps picker open", helper.poll() is None)
            xd("key", "Escape")
            code, reply = result(helper)
            check("Escape cancellation", code == 2 and reply["reason"] == "user")

            first = start(request(timeout_ms=800))
            time.sleep(0.2)
            code, reply = result(start(request(request_id="second")))
            check("same pane busy", code == 1 and reply["error"]["code"] == "busy")
            code, reply = result(first)
            check("busy rejection leaves original request intact", code == 2 and reply["reason"] == "timeout")
            helper = start(request())
            time.sleep(0.2)
            helper.send_signal(signal.SIGTERM)
            code, reply = result(helper)
            check("SIGTERM cancels", code == 143 and reply["status"] == "cancelled")
            helper = start(request())
            time.sleep(0.2)
            helper.kill()
            helper.wait()
            time.sleep(0.2)
            code, reply = result(start(request(timeout_ms=200)))
            check("caller disappearance releases pane", code == 2 and reply["reason"] == "timeout")

            wrong = endpoint.copy()
            wrong["GHOSTTY_IPC_INSTANCE"] = "stale"
            code, reply = result(start(request(), wrong))
            check("stale instance rejected", code == 1 and reply["error"]["code"] == "stale_instance")
            code, reply = result(start(request(surface_id="0x1")))
            check("missing pane rejected", code == 1 and reply["error"]["code"] == "surface_not_found")
            invalid = request()
            invalid["choices"][1]["id"] = "one"
            code, reply = result(start(invalid))
            check("invalid choices retain request correlation", code == 1 and reply["request_id"] == "r")
            helper = start(request(timeout_ms=700))
            time.sleep(0.2)
            subprocess.run([
                "gdbus", "call", "--session", "--dest", endpoint["GHOSTTY_IPC_BUS_NAME"],
                "--object-path", "/com/mitchellh/ghostty/Picker1",
                "--method", "com.mitchellh.ghostty.Picker1.Cancel", "r",
            ], check=True, capture_output=True)
            code, reply = result(helper)
            check("foreign sender cannot cancel", code == 2 and reply["reason"] == "timeout")
            code, reply = result(start(request(timeout_ms=200), flags=("--bus-name=" + endpoint["GHOSTTY_IPC_BUS_NAME"],)))
            check("explicit unique target works", code == 2 and reply["reason"] == "timeout")

            action("split-right")
            time.sleep(0.5)
            xd("mousemove", "--window", window, "100", "450")
            xd("click", "1")
            time.sleep(0.2)
            helper = start(request())
            time.sleep(0.2)
            xd("key", *(["Tab"] * 12))
            xd("type", "Website")
            xd("key", "Return")
            code, reply = result(helper)
            check("Tab cannot focus neighboring split", code == 0 and reply["result"]["ids"] == ["two"])
            xd("mousemove", "--window", window, "650", "450")
            xd("click", "1")
            time.sleep(0.1)
            xd("key", "ctrl+alt+x")
            time.sleep(0.3)
            action("switch-session")
            time.sleep(0.2)
            xd("key", "Escape")
            session_dir = directory / "state/ghostty/sessions" / CLASS
            sessions = lambda: [json.loads(f.read_text()) for f in session_dir.glob("*.json") if f.name != "active.json"]
            initial = sessions()
            check("native session picker enumerates saved sessions", len(initial) == 1)
            action("new-session")
            time.sleep(0.7)
            xd("key", "Escape")
            time.sleep(0.2)
            xd("windowfocus", "--sync", window)
            time.sleep(0.2)
            action("switch-session")
            time.sleep(0.2)
            target = next(s for s in sessions() if s["id"] != initial[0]["id"])
            xd("type", "--clearmodifiers", target["name"])
            time.sleep(0.3)
            xd("key", "Return")
            time.sleep(0.3)
            other_window = xd("getwindowfocus")
            check("session selection focuses existing other window", other_window != window)
            second_endpoint = os.environ.copy()
            second_endpoint.update(json.loads((directory / "endpoint.json").read_text()))
            code, reply = result(start(request()))
            check("inactive origin is rejected", code == 1 and reply["error"]["code"] == "not_active")

            xd("windowfocus", "--sync", window)
            time.sleep(0.2)
            first = start(request(timeout_ms=800))
            time.sleep(0.2)
            xd("windowfocus", "--sync", other_window)
            time.sleep(0.2)
            second = start(request(timeout_ms=300), second_endpoint)
            second_code, second_reply = result(second)
            code, reply = result(first)
            check("independent panes accept concurrent requests", code == second_code == 2 and reply["reason"] == second_reply["reason"] == "timeout")
            check("timeout does not raise origin window", xd("getwindowfocus") == other_window)
            xd("windowfocus", "--sync", window)
            time.sleep(0.2)
            helper = start(request())
            time.sleep(0.2)
            xd("windowfocus", "--sync", other_window)
            time.sleep(0.2)
            xd("windowfocus", "--sync", window)
            time.sleep(0.2)
            xd("key", "Return")
            code, reply = result(helper)
            check("picker survives focus changes", code == 0 and reply["result"]["ids"] == ["one"])
            # Closing an owning window must complete even if its weak refs
            # have already been cleared by GObject disposal.
            helper = start(request(), second_endpoint)
            # The other window is inactive; explicitly focus it and retry.
            code, reply = result(helper)
            check("inactive second pane is rejected", code == 1)
            xd("windowfocus", "--sync", other_window)
            time.sleep(0.2)
            helper = start(request(), second_endpoint)
            time.sleep(0.2)
            subprocess.run([
                "gdbus", "call", "--session", "--dest", endpoint["GHOSTTY_IPC_BUS_NAME"],
                "--object-path", "/com/mitchellh/ghostty/picker/test/window/2",
                "--method", "org.gtk.Actions.Activate", "close", "[]", "{}",
            ], check=True, capture_output=True)
            code, reply = result(helper)
            check("owning window closure cancels request", code == 2 and reply["reason"] == "pane_closed")
            xd("windowfocus", "--sync", window)
            time.sleep(0.2)
            helper = start(request())
            time.sleep(0.2)
            os.kill(int(endpoint["PANE_PID"]), signal.SIGTERM)
            code, reply = result(helper)
            check("owning child exit cancels request", code == 2 and reply["reason"] == "child_exited")
            action("new-session")
            time.sleep(0.7)
            xd("key", "Escape")
            time.sleep(0.2)
            third_endpoint = os.environ.copy()
            third_endpoint.update(json.loads((directory / "endpoint.json").read_text()))
            helper = start(request(), third_endpoint)
            time.sleep(0.2)
            app.terminate()
            code, reply = result(helper)
            check("Ghostty termination unblocks helper", code == 1 and reply["error"]["code"] == "transport_error")
            app.wait(timeout=10)
            # Explicit classes resolve a well-known name once, even when the
            # helper inherited a different instance identity.
            single_class = CLASS + ".single"
            single = subprocess.Popen([
                BIN, "--config-default-files=false", "--gtk-single-instance=true",
                "--class=" + single_class, "--window-save-state=always", "--window-save-state-snapshot-limit=0",
                "--confirm-close-surface=false", "--shell-integration=none",
                "--title=Picker IPC Test", "--command=" + shlex.join([sys.executable, str(pane)]),
            ], stdout=log, stderr=log)
            try:
                def new_endpoint():
                    value = json.loads((directory / "endpoint.json").read_text())
                    return value if value["GHOSTTY_IPC_BUS_NAME"] != third_endpoint["GHOSTTY_IPC_BUS_NAME"] else None
                explicit_endpoint = wait_for(new_endpoint)
                new_window = wait_for(lambda: xd("search", "--name", "^Picker IPC Test$"))
                xd("windowfocus", "--sync", new_window)
                time.sleep(0.2)
                # The inherited endpoint is stale; explicit class and surface win.
                code, reply = result(start(request(timeout_ms=200), flags=(
                    "--class=" + single_class, "--surface-id=" + explicit_endpoint["GHOSTTY_SURFACE_ID"],
                )))
                check("explicit class targets correct instance", code == 2 and reply["reason"] == "timeout")
                code, reply = result(start(request(), flags=("--class=" + single_class + ".missing",)))
                check("missing class does not auto-start an instance", code == 1 and reply["error"]["code"] == "unavailable")
                time.sleep(2.1)
                subprocess.run([
                    "gdbus", "call", "--session", "--dest", explicit_endpoint["GHOSTTY_IPC_BUS_NAME"],
                    "--object-path", "/com/mitchellh/ghostty/picker/test/single",
                    "--method", "org.gtk.Actions.Activate", "quit", "[]", "{}",
                ], check=True, capture_output=True)
                check("graceful shutdown after autosave completes", single.wait(timeout=10) == 0)
                log.flush()
                check("session-save jobs are released at shutdown", "error(SafeAllocator)" not in log_path.read_text())
            finally:
                if single.poll() is None:
                    single.terminate()
                single.wait(timeout=10)

        except BaseException:
            log.flush()
            print(log_path.read_text(), file=sys.stderr)
            raise
        finally:
            for helper in helpers:
                if helper.poll() is None:
                    helper.kill()
                helper.wait(timeout=10)
            if app.poll() is None:
                app.terminate()
            app.wait(timeout=10)


if __name__ == "__main__":
    if len(sys.argv) == 1:
        sys.exit(isolated_run())
    run_tests()
