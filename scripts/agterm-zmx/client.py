#!/usr/bin/env python3
"""Attach one remote zmx session from an agterm pane, reconnecting after SSH loss."""
import argparse
import json
import os
from pathlib import Path
import random
import shlex
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid


STATES = {"idle", "active", "blocked", "completed"}


def status_request(payload, target, pane_id):
    # Rebuild the request. The remote can never select another pane or command.
    if not isinstance(payload, dict) or set(payload) != {"status"}:
        raise ValueError("only a status is accepted")
    if not isinstance(payload["status"], str) or payload["status"] not in STATES:
        raise ValueError("invalid status")
    args = {"status": payload["status"], "paneID": pane_id}
    return {"cmd": "session.status", "target": target, "args": args}


class Relay(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


class StatusHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            self.connection.settimeout(1)
            raw = self.rfile.readline(257)
            if len(raw) > 256 or not raw.endswith(b"\n"):
                return
            request = status_request(json.loads(raw), self.server.target, self.server.pane_id)
            with socket.socket(socket.AF_UNIX) as channel:
                channel.settimeout(1)
                channel.connect(self.server.agterm_socket)
                channel.sendall((json.dumps(request) + "\n").encode())
                reply = channel.recv(4096)
                if not json.loads(reply).get("ok"):
                    print("agterm rejected a remote status update", file=sys.stderr)
        except (OSError, ValueError, TypeError):
            pass


def ssh_command(args, relay_path, port):
    remote = [args.remote_bin, "attach", args.name, args.cwd,
              "--agent", args.agent, "--port", str(port)]
    if args.user:
        remote = ["runuser", "-u", args.user, "--"] + remote
    # Dedicated connection: closing it also removes its reverse forward.
    return ["ssh", "-tt", "-o", "BatchMode=yes", "-o", "ControlPath=none",
            "-o", "ForwardAgent=no", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes", "-R", f"127.0.0.1:{port}:{relay_path}",
            "--", args.host, shlex.join(remote)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="root@sancta-choir-1")
    parser.add_argument("--user", default="sancta", help="remote account; empty uses SSH account")
    parser.add_argument("--name", required=True)
    parser.add_argument("--cwd", default="/var/lib/sancta")
    parser.add_argument("--agent", choices=["shell", "claude", "codex"], default="shell")
    parser.add_argument("--remote-bin", default="agt-zmx-host", help="host executable or built Nix store path")
    args = parser.parse_args()
    target = os.environ.get("AGTERM_SESSION_ID", "")
    pane_id = os.environ.get("AGTERM_PANE_ID", "")
    agterm_socket = os.environ.get("AGTERM_SOCKET", "")
    if not target or not pane_id or not agterm_socket:
        parser.error("run inside an agterm pane with session, pane ID and socket environment")
    uuid.UUID(target)
    # Keep the Unix socket short enough for SSH forwarding on macOS.
    with tempfile.TemporaryDirectory(prefix="agt-zmx-", dir="/tmp") as directory:
        relay_path = str(Path(directory) / "relay.sock")
        with Relay(relay_path, StatusHandler) as relay:
            relay.target, relay.pane_id, relay.agterm_socket = target, pane_id, agterm_socket
            worker = threading.Thread(target=relay.serve_forever, daemon=True)
            worker.start()
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
                relay.shutdown()


if __name__ == "__main__":
    sys.exit(main())
