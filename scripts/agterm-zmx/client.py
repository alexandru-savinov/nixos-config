#!/usr/bin/env python3
"""Attach one remote zmx session from an agterm pane, reconnecting after SSH loss."""
import argparse
import hmac
import importlib.util
import json
import os
from pathlib import Path
import random
import secrets
import re
import shlex
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid


STATES = {"idle", "active", "blocked", "completed"}


def agterm(arguments, input_text=None, timeout=None):
    executable = os.environ.get("AGTERMCTL") or shutil.which("agtermctl")
    if not executable:
        raise ValueError("agtermctl is not available; set AGTERMCTL to its absolute path")
    address = os.environ.get("AGT_SOCKET") or os.environ.get("AGTERM_SOCKET")
    if not address:
        raise ValueError("agterm socket environment is missing")
    return subprocess.run([executable, *arguments, "--socket", address],
                          input=input_text, text=True, capture_output=True, timeout=timeout)


def attach_argv(args):
    command = [sys.executable, str(Path(__file__).resolve()), "--host", args.host,
            "--user", args.user, "--name", args.name, "--cwd", args.cwd,
            "--agent", args.agent, "--remote-bin", args.remote_bin]
    if getattr(args, "resume", None):
        command += ["--resume", args.resume]
    if getattr(args, "user_scope", False):
        command += ["--user-scope"]
    return command


def remote_command(args, command):
    words = [args.remote_bin, *command]
    if args.user:
        words = ["runuser", "-u", args.user, "--", *words]
    return shlex.join(words)


def picker_items(records):
    items = []
    for record in records:
        if record.get("alive") is not True:
            continue
        name, agent, cwd = record["name"], record["agent"], record["cwd"]
        if agent not in {"shell", "claude", "codex"} or not all(isinstance(x, str) for x in [name, cwd]):
            raise ValueError("invalid remote inventory")
        if any(ord(c) < 32 for c in name + cwd):
            raise ValueError("control characters in remote inventory")
        items.append({"id": name, "label": f"{name} · {agent}", "subtitle": cwd})
    return items


def open_session(args, pick=False):
    window = os.environ.get("AGT_WINDOW_ID") or os.environ.get("AGTERM_WINDOW_ID")
    selector = ["--window", window] if window else []
    if pick:
        listing = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                  "--", args.host, remote_command(args, ["list"])],
                                 capture_output=True, text=True, timeout=20, check=True)
        records = json.loads(listing.stdout)
        choices = picker_items(records)
        if not choices:
            raise ValueError("no live zmx sessions; use --open --name NAME to start one")
        selection = agterm(["pick", "--prompt", f"zmx on {args.host}", *selector], json.dumps(choices))
        if selection.returncode == 2:
            return 0
        selection.check_returncode()
        selected = json.loads(selection.stdout)
        record = next((record for record in records if record["name"] == selected.get("id")), None)
        if record is None:
            raise ValueError("picker returned an unknown session; reopen the picker")
        args.name, args.cwd, args.agent = record["name"], record["cwd"], record["agent"]
        args.resume = record.get("resume")
        args.user_scope = record.get("user_scope", False)
    result = agterm(["session", "new", "--name", getattr(args, "title", None) or args.name,
                     "--workspace-name", getattr(args, "workspace", "choir"), "--create-workspace",
                     "--command", shlex.join(attach_argv(args)), "--wait", *selector])
    result.check_returncode()
    print(result.stdout.strip())
    return 0


def pin_restore(args, target, pane_id):
    result = agterm(["session", "restore", shlex.join(attach_argv(args)),
                     "--target", target, "--pane-id", pane_id, "--json"])
    result.check_returncode()
    response = json.loads(result.stdout)
    if response.get("ok") is not True or response.get("result", {}).get("pane") not in {"left", "right"}:
        raise ValueError("restore pin did not confirm its target pane")


def status_request(payload, target, pane_id):
    # Rebuild the request. The remote can never select another pane or command.
    if not isinstance(payload, dict) or set(payload) != {"status"}:
        raise ValueError("only a status is accepted")
    if not isinstance(payload["status"], str) or payload["status"] not in STATES:
        raise ValueError("invalid status")
    args = {"status": payload["status"], "paneID": pane_id}
    return {"cmd": "session.status", "target": target, "args": args}


def codex_approval_visible(text):
    # Match the observed command-approval dialog, not prose mentioning approval.
    lines = [line.strip().lower() for line in text.splitlines() if line.strip()]
    return bool(lines and lines[-1] == "press enter to confirm or esc to cancel"
                and "would you like to run the following command?" in lines
                and any(re.match(r"^[›>]?[ ]*1\. yes, proceed \(y\)$", line) for line in lines)
                and any("no, and tell codex what to do differently (esc)" in line for line in lines))


def claude_empty_prompt_visible(text):
    """Recognize the observed empty composer, not merely a missing dialog.

    Claude does not emit Stop for Esc at a permission prompt. Read the visible
    screen only; an unknown layout or ongoing activity must not clear blocked.
    """
    lines = [line.strip().lower() for line in text.splitlines() if line.strip()]
    if any("esc to interrupt" in line or (
            re.match(r"^[✢✳✶✻✽]", line) and not re.search(r"\bfor \d.* · done \d", line))
           for line in lines):
        return False
    for index, line in enumerate(lines):
        if line != "❯" or not 0 < index < len(lines) - 1:
            continue
        borders = (lines[index - 1], lines[index + 1])
        if not all(len(border) >= 8 and set(border) == {"─"} for border in borders):
            continue
        footer = lines[index + 2:]
        if 1 <= len(footer) <= 3 and any(
                marker in footer[-1] for marker in ("manual mode on", "auto mode on",
                                                     "accept edits on", "plan mode on")):
            return True
    return False


class StatusTracker:
    def __init__(self, send):
        self.send = send
        self.lock = threading.Lock()
        self.generation = 0
        self.latest = "idle"
        self.dialog = False

    def receive(self, value):
        with self.lock:
            self.generation += 1
            self.latest, self.dialog = value, False
            self.send(value)

    def snapshot(self):
        with self.lock:
            return self.generation

    def observe_claude(self, text, generation):
        ready = claude_empty_prompt_visible(text)
        with self.lock:
            if generation != self.generation or self.latest != "blocked" or not ready:
                return
            self.send("idle")
            self.latest, self.dialog = "idle", False

    def observe(self, text, generation):
        visible = codex_approval_visible(text)
        with self.lock:
            # A Stop/PreToolUse arriving during the screen read supersedes it.
            if generation != self.generation or visible == self.dialog:
                return
            self.send("blocked" if visible else self.latest)
            self.dialog = visible


class Relay(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    request_queue_size = 16
    max_connections = 16

    def __init__(self, *args, **kwargs):
        self.connection_slots = threading.BoundedSemaphore(self.max_connections)
        super().__init__(*args, **kwargs)
        self.tracker = StatusTracker(self.forward)

    def process_request(self, request, client_address):
        # Acquire before ThreadingMixIn creates a thread. Peers sharing the
        # remote host can connect before authentication, so never queue an
        # unbounded number of workers or wait here behind a pending question.
        if not self.connection_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.connection_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connection_slots.release()

    def forward(self, value):
        request = status_request({"status": value}, self.target, self.pane_id)
        with socket.socket(socket.AF_UNIX) as channel:
            channel.settimeout(1)
            channel.connect(self.agterm_socket)
            channel.sendall((json.dumps(request) + "\n").encode())
            if not json.loads(channel.recv(4096)).get("ok"):
                print("agterm rejected a status update", file=sys.stderr)


def watch_agent_prompt(relay, stop, agent):
    while not stop.wait(0.75):
        if agent == "claude":
            with relay.tracker.lock:
                if relay.tracker.latest != "blocked":
                    continue
        generation = relay.tracker.snapshot()
        try:
            # Claude's activity indicator can be above the composer. Inspect the
            # visible screen rather than a tail that could omit it. Never persist
            # or forward the text. Codex's dialog has a bounded footer layout.
            tail = ["--lines", "24"] if agent == "codex" else []
            result = agterm(["session", "text", "--target", relay.target,
                             "--pane-id", relay.pane_id, *tail], timeout=3)
            if result.returncode == 0 and not stop.is_set():
                observe = relay.tracker.observe if agent == "codex" else relay.tracker.observe_claude
                observe(result.stdout, generation)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass


class StatusHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            self.connection.settimeout(1)
            raw = self.rfile.readline(6145)
            if len(raw) > 6144 or not raw.endswith(b"\n"):
                return
            envelope = json.loads(raw)
            expected = getattr(self.server, "token", None)
            if (not isinstance(envelope, dict) or set(envelope) != {"token", "payload"}
                    or not isinstance(expected, str) or not isinstance(envelope["token"], str)
                    or not hmac.compare_digest(envelope["token"], expected)):
                return
            payload = envelope["payload"]
            if isinstance(payload, dict) and "ui" in payload:
                bridge = getattr(self.server, "ui", None)
                if bridge is None:
                    raise ValueError("UI bridge unavailable")
                try:
                    outcome = (bridge.ask(payload, self.connection) if payload["ui"] == "ask"
                               else bridge.hud(payload))
                except (OSError, ValueError, TypeError):
                    outcome = {"result": "error", "reason": "native question unavailable or invalid request"}
                self.wfile.write((json.dumps(outcome) + "\n").encode())
                return
            status_request(payload, self.server.target, self.server.pane_id)
            self.server.tracker.receive(payload["status"])
        except (OSError, ValueError, TypeError):
            pass


def ssh_command(args, relay_path, port, connected_path=None):
    # Dedicated connection: closing it also removes its reverse forward.
    ready = (["-o", "PermitLocalCommand=yes", "-o",
              "LocalCommand=" + shlex.join(["/usr/bin/touch", str(connected_path)])]
             if connected_path else [])
    return ["ssh", "-tt", "-o", "BatchMode=yes", "-o", "ControlPath=none",
            "-o", "ForwardAgent=no", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes", "-R", f"127.0.0.1:{port}:{relay_path}",
            *ready, "--", args.host, remote_command(args, ["attach", args.name, args.cwd,
                                                    "--agent", args.agent, "--port", str(port)]
                                                    + (["--resume", args.resume] if getattr(args, "resume", None) else [])
                                                    + (["--user-scope"] if getattr(args, "user_scope", False) else []))]


def prepare_route(args, port, token):
    # Token travels through encrypted SSH stdin, never argv, environment or logs.
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--",
                             args.host, remote_command(args, ["prepare-route", args.name, str(port)])],
                            input=json.dumps({"token": token}) + "\n", capture_output=True,
                            text=True, timeout=20)
    if result.returncode:
        if result.returncode == 255:
            raise ConnectionError("SSH unavailable during route preparation")
        # Do not expose a CalledProcessError containing its captured data.
        raise ValueError("private route preparation failed; check helper version and SSH connectivity")


def wait_for_ssh(command, connected_path, on_connected):
    """Observe SSH's local post-connect callback separately from agent status."""
    connected_path.unlink(missing_ok=True)
    process = subprocess.Popen(command)
    announced = False
    try:
        while True:
            if connected_path.exists() and not announced:
                announced = True
                on_connected()
            try:
                return process.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                pass
    except BaseException:
        process.terminate()  # Only the local attachment, never the remote scope.
        process.wait(timeout=5)
        raise


def connection_notice(name, message, target):
    print(f"{name}: {message}", flush=True)
    if sys.stdout.isatty():
        # A terminal notification belongs to this exact surface, including a
        # split after promotion/swap. Agterm applies the owner's banner settings.
        clean = "".join(c for c in f"{name}: {message}" if c.isprintable())
        sys.stdout.write("\x1b]9;" + clean + "\x07")
        sys.stdout.flush()
        return
    try:
        agterm(["notify", f"{name}: {message}", "--title", "Remote connection",
                "--target", target], timeout=3)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass


def load_interface(name="interface"):
    spec = importlib.util.spec_from_file_location("agt_zmx_" + name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    interface = load_interface()
    try:
        config = interface.preferences()
    except (OSError, ValueError) as error:
        print(f"Invalid remote configuration: {error}", file=sys.stderr)
        return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=config.get("host", "root@sancta-choir-1"))
    parser.add_argument("--user", default=config.get("user", "sancta"), help="remote account; empty uses SSH account")
    parser.add_argument("--name")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--open", action="store_true", help="open a new agterm pane for the named session")
    mode.add_argument("--pick", action="store_true", help="pick a live remote session and open a pane")
    parser.add_argument("--cwd", default=config.get("cwd", "/var/lib/sancta"))
    parser.add_argument("--agent", choices=["shell", "claude", "codex"], default="shell")
    parser.add_argument("--resume", help="explicit Claude or Codex conversation UUID; requires a stopped source")
    parser.add_argument("--user-scope", action="store_true", help="create backend outside the SSH service cgroup")
    parser.add_argument("--remote-bin", default=config.get("remote_bin", "agt-zmx-host"), help="host executable or built Nix store path")
    mode.add_argument("--menu", action="store_true", help="native picker for existing or new remote sessions")
    mode.add_argument("--session", help="attach a configured named session, such as sancta")
    parser.add_argument("--workspace", default=config.get("workspace", "choir"))
    parser.add_argument("--title", help="display name, independent of the backend identity")
    parser.add_argument("--split", action="store_true", help="open into a new split; never replace an existing split")
    args = parser.parse_args()
    if args.split and not (args.menu or args.session or args.open):
        parser.error("--split requires --menu, --session or --open")
    if not (args.pick or args.menu or args.session) and not args.name:
        parser.error("--name is required unless --pick is used")
    if args.open or args.pick or args.menu or args.session:
        try:
            if args.pick:
                return open_session(args, True)
            # Pass this module's operations without importing a second client.
            from types import SimpleNamespace
            client = SimpleNamespace(agterm=agterm, remote_command=remote_command,
                                     picker_items=picker_items, attach_argv=attach_argv)
            return interface.run(client, args, config)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            if isinstance(error, subprocess.TimeoutExpired):
                detail = "request timed out; check SSH connectivity and agterm"
            elif isinstance(error, subprocess.CalledProcessError):
                detail = f"SSH or agterm command failed (exit {error.returncode}); check connectivity and retry"
            else:
                detail = str(error)
            from types import SimpleNamespace
            interface.report_error(SimpleNamespace(agterm=agterm), f"Could not open zmx pane: {detail}")
            return 1
    target = os.environ.get("AGTERM_SESSION_ID", "")
    pane_id = os.environ.get("AGTERM_PANE_ID", "")
    agterm_socket = os.environ.get("AGTERM_SOCKET", "")
    if not target or not pane_id or not agterm_socket:
        parser.error("run inside an agterm pane with session, pane ID and socket environment")
    uuid.UUID(target)
    # Pin only the pane running this client; never rely on the selected UI pane.
    # Preserve remote identity while refreshing local target IDs after app restart.
    try:
        pin_restore(args, target, pane_id)
    except (OSError, ValueError, subprocess.CalledProcessError):
        print("Could not pin app-restart restoration; re-run this client manually after restart.", file=sys.stderr)
    # Keep the Unix socket short enough for SSH forwarding on macOS.
    with tempfile.TemporaryDirectory(prefix="agt-zmx-", dir="/tmp") as directory:
        relay_path = str(Path(directory) / "relay.sock")
        with Relay(relay_path, StatusHandler) as relay:
            relay.target, relay.pane_id, relay.agterm_socket = target, pane_id, agterm_socket
            worker = threading.Thread(target=relay.serve_forever, daemon=True)
            worker.start()
            monitor_stop = threading.Event()
            monitor = None
            if args.agent in {"codex", "claude"}:
                monitor = threading.Thread(target=watch_agent_prompt,
                                           args=(relay, monitor_stop, args.agent), daemon=True)
                monitor.start()
            disconnected = False
            try:
                while True:
                    relay.ui = load_interface("ui").Bridge(agterm_socket, target, pane_id)
                    port = random.SystemRandom().randrange(20000, 60000)
                    relay.token = secrets.token_hex(32)
                    connected_path = Path(directory) / "ssh-connected"
                    def connected():
                        nonlocal disconnected
                        if disconnected:
                            connection_notice(args.name, "SSH reconnected", target)
                        disconnected = False
                    try:
                        prepare_route(args, port, relay.token)
                        result = wait_for_ssh(ssh_command(args, relay_path, port, connected_path),
                                              connected_path, connected)
                    except (ConnectionError, subprocess.TimeoutExpired):
                        result = 255
                    finally:
                        relay.token = None
                        relay.ui.disconnect()
                    if result != 255:
                        if result:
                            connection_notice(args.name, "remote command ended; see this pane for details", target)
                        return result
                    if not disconnected:
                        connection_notice(args.name, "SSH disconnected or forwarding failed; reconnecting", target)
                    disconnected = True
                    print("SSH disconnected or forwarding failed; retrying in 5s. Ctrl-C stops retries.", flush=True)
                    time.sleep(5)
            except KeyboardInterrupt:
                return 130
            except (OSError, ValueError, subprocess.SubprocessError):
                print("Could not establish the authenticated relay; check SSH connectivity and helper version.", file=sys.stderr)
                return 1
            finally:
                monitor_stop.set()
                if monitor:
                    monitor.join(timeout=4)
                relay.shutdown()


if __name__ == "__main__":
    sys.exit(main())
