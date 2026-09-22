#!/usr/bin/env python3
"""Remote zmx MVP. No global hooks, credentials, or existing session mutations."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile


STATES = {"idle", "active", "blocked", "completed"}


def session_name(value):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}", value):
        raise ValueError("session name must be 1-48 letters, digits, underscores or hyphens")
    return "agt-mvp-" + value


def state_dir():
    directory = Path(os.environ.get("AGT_ZMX_STATE", Path.home() / ".local/state/agt-zmx"))
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid():
        raise ValueError("state directory must be owned by this user and not a symlink")
    directory.chmod(0o700)
    return directory


def write_json(path, value):
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def status(name, value):
    """Only lifecycle state crosses the bridge; hook stdin is never read/logged."""
    if value not in STATES:
        return
    try:
        route = json.loads((state_dir() / (session_name(name) + ".route")).read_text())
        port = route["port"]
        if type(port) is not int or not 1024 <= port <= 65535:
            return
        with socket.create_connection(("127.0.0.1", port), timeout=1) as connection:
            connection.sendall((json.dumps({"status": value}) + "\n").encode())
    except (OSError, ValueError, KeyError, TypeError):
        pass  # Detached sessions must continue when there is no Mac to notify.


def hooks(name):
    result = {}
    for event, value in [("UserPromptSubmit", "active"), ("PreToolUse", "active"),
                         ("PermissionRequest", "blocked"), ("Stop", "completed"),
                         ("SessionEnd", "idle")]:
        command = shlex.join([sys.executable, str(Path(__file__).resolve()), "status", name, value])
        result[event] = [{"hooks": [{"type": "command", "command": command, "timeout": 2}]}]
    return {"hooks": result}


def launch(name):
    record = json.loads((state_dir() / (session_name(name) + ".json")).read_text())
    os.chdir(record["cwd"])
    # No inherited Mac session address may leak into this long-lived process.
    for key in list(os.environ):
        if key.startswith(("AGTERM_", "AGT_")) and key != "AGT_ZMX_STATE":
            del os.environ[key]
    agent = record["agent"]
    if agent == "shell":
        os.execvp("bash", ["bash", "--noprofile", "--norc", "-i"])
    command = [agent]
    if agent == "claude":
        command += ["--settings", json.dumps(hooks(name))]
    # A fresh conversation only. Never call sancta-session / sancta-reconnect.
    # Keep a real interactive shell with job control as the agent's parent.
    line = shlex.join(command) + "; exec bash -l"
    os.execvp("bash", ["bash", "--noprofile", "--norc", "-ic", line])


def attach(name, cwd, agent, port):
    qualified = session_name(name)
    cwd = str(Path(cwd).resolve(strict=True))
    if not Path(cwd).is_dir():
        raise ValueError("working directory is not a directory")
    if not shutil.which("zmx") or not shutil.which("bash"):
        raise ValueError("zmx and bash must be installed")
    if agent != "shell" and not shutil.which(agent):
        raise ValueError("requested agent is not on PATH")
    directory = state_dir()
    record = {"cwd": cwd, "agent": agent}
    environment = dict(os.environ)
    environment.pop("ZMX_SESSION", None)
    environment.pop("ZMX_SESSION_PREFIX", None)
    # An isolated socket namespace also prevents collisions with ordinary zmx use.
    environment["ZMX_DIR"] = str(directory / "sockets")
    environment["ZMX_DIR_MODE"] = "0700"
    environment["ZMX_LOG_MODE"] = "0600"
    with (directory / (qualified + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = directory / (qualified + ".json")
        if path.exists():
            if json.loads(path.read_text()) != record:
                raise ValueError("name already belongs to a different directory or agent; choose a new name")
            # A lost daemon is not a live conversation. Do not silently restart it.
            live = subprocess.check_output(["zmx", "list", "--short"], env=environment, text=True)
            if qualified not in live.splitlines():
                raise ValueError("session ended or host restarted; choose a new name for a fresh session")
        else:
            write_json(path, record)
        write_json(directory / (qualified + ".route"), {"port": port})
    os.execvpe("zmx", ["zmx", "attach", qualified, sys.executable,
                       str(Path(__file__).resolve()), "launch", name], environment)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    sub = commands.add_parser("attach")
    sub.add_argument("name")
    sub.add_argument("cwd")
    sub.add_argument("--agent", choices=["shell", "claude", "codex"], default="shell")
    sub.add_argument("--port", type=int, required=True)
    sub = commands.add_parser("status")
    sub.add_argument("name")
    sub.add_argument("value", choices=sorted(STATES))
    sub = commands.add_parser("launch")
    sub.add_argument("name")
    args = parser.parse_args()
    try:
        if args.action == "attach":
            if not 1024 <= args.port <= 65535:
                raise ValueError("invalid relay port")
            attach(args.name, args.cwd, args.agent, args.port)
        elif args.action == "launch":
            launch(args.name)
        else:
            status(args.name, args.value)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"agt-zmx-host: {error}\n")


if __name__ == "__main__":
    main()
