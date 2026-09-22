#!/usr/bin/env python3
"""Remote zmx MVP. No global hooks, credentials, or existing session mutations."""
import argparse
import fcntl
import hashlib
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


def zmx_environment(directory):
    environment = dict(os.environ)
    environment.pop("ZMX_SESSION", None)
    environment.pop("ZMX_SESSION_PREFIX", None)
    environment["ZMX_DIR"] = str(directory / "sockets")
    environment["ZMX_DIR_MODE"] = "0700"
    environment["ZMX_LOG_MODE"] = "0600"
    return environment


def inventory():
    # Read only. An empty inventory must not create state or start a daemon.
    directory = Path(os.environ.get("AGT_ZMX_STATE", Path.home() / ".local/state/agt-zmx"))
    if not directory.exists():
        return []
    live = subprocess.check_output(["zmx", "list", "--short"],
                                   env=zmx_environment(directory), text=True, timeout=5).splitlines()
    records = []
    for path in sorted(directory.glob("agt-mvp-*.json")):
        name = path.stem.removeprefix("agt-mvp-")
        session_name(name)
        record = json.loads(path.read_text())
        records.append({"name": name, "cwd": record["cwd"], "agent": record["agent"],
                        "resume": record.get("resume"),
                        "alive": path.stem in live})
    return records


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


def codex_profile_text(name):
    # A separate active profile adds hooks without rewriting user config/auth.
    # PermissionRequest is deliberately absent: it precedes automatic review,
    # and does not prove that a human approval dialog is actually visible.
    lines = ["# Generated launch-specific zmx lifecycle hooks. Review with /hooks.", "[hooks]"]
    for event, value in [("SessionStart", "idle"), ("UserPromptSubmit", "active"),
                         ("PreToolUse", "active"), ("PostToolUse", "active"),
                         ("Stop", "completed"), ("Interrupt", "idle"), ("SessionEnd", "idle")]:
        command = shlex.join([sys.executable, str(Path(__file__).resolve()), "status", name, value])
        lines.append(event + ' = [{ hooks = [{ type = "command", command = '
                     + json.dumps(command) + ', timeout = 2 }] }]')
    return "\n".join(lines) + "\n"


def codex_profile(name, directory=None):
    content = codex_profile_text(name)
    identifier = "agt-zmx-" + hashlib.sha256(content.encode()).hexdigest()[:16]
    directory = Path(directory) if directory is not None else Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = directory / (identifier + ".config.toml")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        if path.is_symlink() or path.read_text() != content:
            raise ValueError("Codex profile name already exists with different content")
    else:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
    return identifier


def validate_resume(agent, identifier, config_dir=None):
    if agent != "claude" or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", identifier):
        raise ValueError("resume requires Claude and an explicit lowercase conversation UUID")
    directory = Path(config_dir or os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))
    if not any((directory / "projects").glob("*/" + identifier + ".jsonl")):
        raise ValueError("conversation transcript not found; refusing to start a fresh conversation")
    # Inspect metadata only. Never read transcript contents or stop an old agent.
    for path in (directory / "sessions").glob("*.json"):
        record = json.loads(path.read_text())
        if record.get("sessionId") != identifier:
            continue
        pid = int(record["pid"])
        if pid <= 0:
            raise ValueError("invalid conversation process metadata")
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise ValueError("conversation still has a live process; exit it cleanly before resuming")


def resume_lock(identifier):
    # Keep this descriptor in the agent's parent shell across exec. Serializes
    # cooperating resume launches, including the gap before Claude writes metadata.
    lock = (state_dir() / ("resume-" + identifier + ".lock")).open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise ValueError("another zmx launch owns this conversation") from None
    os.set_inheritable(lock.fileno(), True)
    return lock


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
    conversation_lock = None
    if agent == "claude":
        command += ["--settings", json.dumps(hooks(name))]
        if record.get("resume"):
            conversation_lock = resume_lock(record["resume"])
            validate_resume(agent, record["resume"])
            command += ["--resume", record["resume"]]
    elif agent == "codex":
        command += ["--profile", codex_profile(name)]
        print("zmx status hooks require review in Codex /hooks before they can run.", flush=True)
    # Never call sancta-session / sancta-reconnect or reconcile an old process.
    # Keep a real interactive shell with job control as the agent's parent.
    unlock = f"; exec {conversation_lock.fileno()}>&-" if conversation_lock else ""
    line = shlex.join(command) + unlock + "; exec bash -l"
    os.execvp("bash", ["bash", "--noprofile", "--norc", "-ic", line])


def attach(name, cwd, agent, port, resume=None):
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
    if resume is not None:
        record["resume"] = resume
    # An isolated socket namespace also prevents collisions with ordinary zmx use.
    environment = zmx_environment(directory)
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
            if resume is not None:
                validate_resume(agent, resume)
            write_json(path, record)
        write_json(directory / (qualified + ".route"), {"port": port})
    # runuser preserves the SSH caller's cwd (often /root). zmx initializes its
    # daemon there before our launch callback runs; an unprivileged daemon cannot
    # enter /root. Establish the requested directory for the backend itself.
    os.chdir(cwd)
    environment["PWD"] = cwd
    os.execvpe("zmx", ["zmx", "attach", qualified, sys.executable,
                       str(Path(__file__).resolve()), "launch", name], environment)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("list")
    sub = commands.add_parser("attach")
    sub.add_argument("name")
    sub.add_argument("cwd")
    sub.add_argument("--agent", choices=["shell", "claude", "codex"], default="shell")
    sub.add_argument("--port", type=int, required=True)
    sub.add_argument("--resume", help="explicit Claude conversation UUID; source must be stopped")
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
            attach(args.name, args.cwd, args.agent, args.port, args.resume)
        elif args.action == "launch":
            launch(args.name)
        elif args.action == "status":
            status(args.name, args.value)
        else:
            print(json.dumps(inventory()))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"agt-zmx-host: {error}\n")


if __name__ == "__main__":
    main()
