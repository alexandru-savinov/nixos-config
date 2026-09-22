#!/usr/bin/env python3
"""Attach one remote zmx session from an agterm pane, reconnecting after SSH loss."""
import argparse
import json
import os
from pathlib import Path
import random
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
        record = next(record for record in records if record["name"] == selected["id"])
        args.name, args.cwd, args.agent = record["name"], record["cwd"], record["agent"]
        args.resume = record.get("resume")
        args.user_scope = record.get("user_scope", False)
    result = agterm(["session", "new", "--name", f"zmx / {args.name}",
                     "--workspace-name", "Remote zmx", "--create-workspace",
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

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.tracker = StatusTracker(self.forward)

    def forward(self, value):
        request = status_request({"status": value}, self.target, self.pane_id)
        with socket.socket(socket.AF_UNIX) as channel:
            channel.settimeout(1)
            channel.connect(self.agterm_socket)
            channel.sendall((json.dumps(request) + "\n").encode())
            if not json.loads(channel.recv(4096)).get("ok"):
                print("agterm rejected a status update", file=sys.stderr)


def watch_codex_dialog(relay, stop):
    while not stop.wait(0.75):
        generation = relay.tracker.snapshot()
        try:
            result = agterm(["session", "text", "--target", relay.target,
                             "--pane-id", relay.pane_id, "--lines", "24"], timeout=3)
            if result.returncode == 0 and not stop.is_set():
                relay.tracker.observe(result.stdout, generation)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass


class StatusHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            self.connection.settimeout(1)
            raw = self.rfile.readline(257)
            if len(raw) > 256 or not raw.endswith(b"\n"):
                return
            payload = json.loads(raw)
            status_request(payload, self.server.target, self.server.pane_id)
            self.server.tracker.receive(payload["status"])
        except (OSError, ValueError, TypeError):
            pass


def ssh_command(args, relay_path, port):
    # Dedicated connection: closing it also removes its reverse forward.
    return ["ssh", "-tt", "-o", "BatchMode=yes", "-o", "ControlPath=none",
            "-o", "ForwardAgent=no", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes", "-R", f"127.0.0.1:{port}:{relay_path}",
            "--", args.host, remote_command(args, ["attach", args.name, args.cwd,
                                                    "--agent", args.agent, "--port", str(port)]
                                                    + (["--resume", args.resume] if getattr(args, "resume", None) else [])
                                                    + (["--user-scope"] if getattr(args, "user_scope", False) else []))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="root@sancta-choir-1")
    parser.add_argument("--user", default="sancta", help="remote account; empty uses SSH account")
    parser.add_argument("--name")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--open", action="store_true", help="open a new agterm pane for the named session")
    mode.add_argument("--pick", action="store_true", help="pick a live remote session and open a pane")
    parser.add_argument("--cwd", default="/var/lib/sancta")
    parser.add_argument("--agent", choices=["shell", "claude", "codex"], default="shell")
    parser.add_argument("--resume", help="explicit Claude conversation UUID; requires a stopped source")
    parser.add_argument("--user-scope", action="store_true", help="create backend outside the SSH service cgroup")
    parser.add_argument("--remote-bin", default="agt-zmx-host", help="host executable or built Nix store path")
    args = parser.parse_args()
    if not args.pick and not args.name:
        parser.error("--name is required unless --pick is used")
    if args.open or args.pick:
        return open_session(args, args.pick)
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
            if args.agent == "codex":
                monitor = threading.Thread(target=watch_codex_dialog, args=(relay, monitor_stop), daemon=True)
                monitor.start()
            try:
                while True:
                    port = random.SystemRandom().randrange(20000, 60000)
                    result = subprocess.run(ssh_command(args, relay_path, port))
                    if result.returncode != 255:
                        return result.returncode
                    print("SSH disconnected or forwarding failed; retrying in 5s. Ctrl-C stops retries.", flush=True)
                    time.sleep(5)
            except KeyboardInterrupt:
                return 130
            finally:
                monitor_stop.set()
                if monitor:
                    monitor.join(timeout=4)
                relay.shutdown()


if __name__ == "__main__":
    sys.exit(main())
