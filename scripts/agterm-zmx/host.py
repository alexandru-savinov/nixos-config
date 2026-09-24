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
                        "user_scope": record.get("user_scope", False),
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
            connection.sendall((json.dumps(envelope(route, {"status": value})) + "\n").encode())
    except (OSError, ValueError, KeyError, TypeError):
        pass  # Detached sessions must continue when there is no Mac to notify.


def envelope(route, payload):
    token = route.get("token")
    if not isinstance(token, str) or not re.fullmatch(r"[0-9a-f]{64}", token):
        raise ValueError("authenticated route unavailable")
    return {"token": token, "payload": payload}


def prepare_route(name, port):
    if not 1024 <= port <= 65535:
        raise ValueError("invalid relay port")
    raw = sys.stdin.readline(257)
    if len(raw) > 256 or not raw.endswith("\n"):
        raise ValueError("invalid route preparation")
    data = json.loads(raw)
    if not isinstance(data, dict) or set(data) != {"token"}:
        raise ValueError("invalid route preparation")
    envelope(data, {})
    write_json(state_dir() / (session_name(name) + f".pending-{port}"), {"port": port, "token": data["token"]})


def hooks(name):
    # Claude documents PermissionRequest as the tool-permission request signal:
    # https://code.claude.com/docs/en/hooks#permissionrequest
    # This is a lifecycle observation, not proof a human dialog stays visible
    # (another hook can decide it). Codex has different review semantics below.
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
    if agent not in {"claude", "codex"} or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", identifier):
        raise ValueError("resume requires an agent and an explicit lowercase conversation UUID")
    if agent == "codex":
        directory = Path(config_dir or os.environ.get("CODEX_HOME", Path.home() / ".codex"))
        if not any((directory / "sessions").glob("**/*" + identifier + ".jsonl")):
            raise ValueError("conversation transcript not found; refusing to start a fresh conversation")
        # Probe only: never create, truncate, unlink, or keep Codex's own lock.
        # Codex re-acquires its native writer lock at startup, closing this race.
        try:
            with (directory / "thread-writer-locks" / (identifier + ".lock")).open("rb") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise ValueError("conversation still has an active Codex writer; exit it before resuming") from None
        except FileNotFoundError:
            pass
        return
    directory = Path(config_dir or os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))
    if not any((directory / "projects").glob("*/" + identifier + ".jsonl")):
        raise ValueError("conversation transcript not found; refusing to start a fresh conversation")
    # Inspect metadata only. Never read transcript contents or stop an old agent.
    for path in (directory / "sessions").glob("*.json"):
        record = json.loads(path.read_text())
        if record.get("sessionId") != identifier:
            continue
        try:
            pid = int(record.get("pid"))
        except (ValueError, TypeError):
            raise ValueError("invalid conversation process metadata") from None
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
    if record.get("resume"):
        conversation_lock = resume_lock(record["resume"])
        validate_resume(agent, record["resume"])
    if agent == "claude":
        command += ["--settings", json.dumps(hooks(name))]
        if record.get("resume"):
            command += ["--resume", record["resume"]]
    elif agent == "codex":
        command += ["--profile", codex_profile(name)]
        print("zmx status hooks require review in Codex /hooks before they can run.", flush=True)
        if record.get("resume"):
            command += ["resume", record["resume"]]
    # Never call sancta-session / sancta-reconnect or reconcile an old process.
    # Keep a real interactive shell with job control as the agent's parent.
    unlock = f"; exec {conversation_lock.fileno()}>&-" if conversation_lock else ""
    line = shlex.join(command) + unlock + "; exec bash -l"
    os.execvp("bash", ["bash", "--noprofile", "--norc", "-ic", line])


def attach(name, cwd, agent, port, resume=None, user_scope=False):
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
    if user_scope:
        record["user_scope"] = True
    # An isolated socket namespace also prevents collisions with ordinary zmx use.
    environment = zmx_environment(directory)
    with (directory / (qualified + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = directory / (qualified + ".json")
        creating = not path.exists()
        if path.exists():
            if json.loads(path.read_text()) != record:
                raise ValueError("name already belongs to a different directory or agent; choose a new name")
            # A lost daemon is not a live conversation. Do not silently restart it.
            live = subprocess.check_output(["zmx", "list", "--short"], env=environment, text=True)
            if qualified not in live.splitlines():
                raise ValueError("session ended or host restarted; preserve this record and use a new name; resume a saved agent conversation explicitly")
        else:
            if resume is not None:
                validate_resume(agent, resume)
        route_path = directory / (qualified + f".pending-{port}")
        route = json.loads(route_path.read_text())
        envelope(route, {})
        if route.get("port") != port:
            raise ValueError("attachment route changed; retry from the owning client")
        if creating:
            write_json(path, record)
        write_json(directory / (qualified + ".route"), route)
        route_path.unlink()
    # runuser preserves the SSH caller's cwd (often /root). zmx initializes its
    # daemon there before our launch callback runs; an unprivileged daemon cannot
    # enter /root. Establish the requested directory for the backend itself.
    os.chdir(cwd)
    environment["PWD"] = cwd
    command = ["zmx", "attach", qualified, sys.executable,
               str(Path(__file__).resolve()), "launch", name]
    if creating and user_scope:
        # Scope the backend's birth, not each attachment. Its daemon remains in
        # the user-manager scope when the SSH client disconnects.
        environment["XDG_RUNTIME_DIR"] = f"/run/user/{os.getuid()}"
        environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + environment["XDG_RUNTIME_DIR"] + "/bus"
        command = ["systemd-run", "--user", "--scope", "--collect", "--quiet",
                   "--unit=" + qualified + ".scope", "--", *command]
    os.execvpe(command[0], command, environment)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("list")
    sub = commands.add_parser("prepare-route")
    sub.add_argument("name")
    sub.add_argument("port", type=int)
    sub = commands.add_parser("attach")
    sub.add_argument("name")
    sub.add_argument("cwd")
    sub.add_argument("--agent", choices=["shell", "claude", "codex"], default="shell")
    sub.add_argument("--port", type=int, required=True)
    sub.add_argument("--resume", help="explicit Claude or Codex conversation UUID; source must be stopped")
    sub.add_argument("--user-scope", action="store_true", help="start backend in an existing systemd user manager")
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
            attach(args.name, args.cwd, args.agent, args.port, args.resume, args.user_scope)
        elif args.action == "prepare-route":
            prepare_route(args.name, args.port)
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
