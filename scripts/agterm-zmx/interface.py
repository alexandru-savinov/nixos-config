"""Agterm presentation for remote backends; backend identity stays independent."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import uuid


def preferences():
    preferred = Path.home() / ".config/agterm/remote-hosts.json"
    fallback = Path.home() / ".config/agterm/remote-choir.json"
    path = Path(os.environ.get("AGT_REMOTE_CONFIG", preferred if preferred.exists() else fallback))
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("remote configuration must be an object")
    return data


def select_profile(client, args, config):
    """Choose a host before discovery; explicit restore arguments remain authoritative."""
    profiles = config.get("hosts")
    selected = getattr(args, "profile", None)
    if profiles is not None:
        if not isinstance(profiles, dict) or not profiles or not all(
                isinstance(name, str) and isinstance(value, dict) for name, value in profiles.items()):
            raise ValueError("hosts must be a nonempty mapping of named configurations")
        if selected is None and args.menu and args.host is None:
            selected = pick(client, "Remote host", [
                {"id": name, "label": value.get("label", name)} for name, value in profiles.items()])
            if selected is None:
                return None
        if selected is None:
            matches = [name for name, value in profiles.items() if value.get("host") == args.host]
            if args.host is not None and len(matches) != 1:
                explicit = all(getattr(args, field) is not None
                               for field in ("user", "cwd", "remote_bin", "workspace"))
                if not explicit or args.menu or args.session:
                    raise ValueError("explicit host has no unique profile; choose --profile or specify all connection fields")
                # Old restore commands remain usable after a profile is removed.
                config = {}
            else:
                selected = matches[0] if matches else config.get("default_host", "choir")
        if selected is not None:
            if selected not in profiles:
                raise ValueError("unknown remote host profile")
            config = profiles[selected]
    elif selected is not None and selected != "choir":
        raise ValueError("unknown remote host profile")
    defaults = dict(host="root@sancta-choir-1", user="sancta", cwd="/var/lib/sancta",
                    workspace=selected or "choir", remote_bin="agt-zmx-host")
    for field, default in defaults.items():
        if getattr(args, field) is None:
            setattr(args, field, config.get(field, default))
    # Raw restore commands encode scope mode by presence/absence of the flag.
    if args.user_scope is None:
        gui = args.open or args.pick or args.menu or args.session
        args.user_scope = bool(config.get("user_scope", False)) if gui else False
    return config


def ctl(client, words, **kwargs):
    result = client.agterm(words + ["--json"], **kwargs)
    result.check_returncode()
    reply = json.loads(result.stdout)
    if reply.get("ok") is not True:
        raise ValueError(reply.get("error", "agterm command failed"))
    return reply.get("result", {})


def pick(client, prompt, items, custom=False):
    words = ["pick", "--prompt", prompt]
    window = os.environ.get("AGT_WINDOW_ID") or os.environ.get("AGTERM_WINDOW_ID")
    if window:
        words += ["--window", window]
    if custom:
        words += ["--allow-custom"]
    result = client.agterm(words, json.dumps(items))
    if result.returncode == 2:
        return None
    result.check_returncode()
    selected = json.loads(result.stdout)
    if selected.get("result") == "custom" and custom:
        value = selected.get("query")
    elif selected.get("result") == "picked":
        value = selected.get("id")
    else:
        raise ValueError("unexpected picker outcome")
    if not isinstance(value, str) or not value:
        raise ValueError("picker returned an empty or invalid selection")
    return value


def inventory(client, args):
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--",
                             args.host, client.remote_command(args, ["list"])],
                            capture_output=True, text=True, timeout=20, check=True)
    records = json.loads(result.stdout)
    client.picker_items(records)  # Validate fields before showing remote text.
    return records


def identity(words):
    """Extract explicit remote identity from a restore argv, never display text."""
    try:
        argv = shlex.split(words)
        return tuple(argv[argv.index(flag) + 1] for flag in ["--host", "--user", "--name"])
    except (ValueError, IndexError):
        return None


def focus_existing(client, args):
    expected = (args.host, args.user, args.name)
    for window in ctl(client, ["window", "list"]).get("windows", []):
        if not window.get("open"):
            continue
        selector = ["--window", window["id"]]
        tree = ctl(client, ["tree", *selector])["tree"]
        for workspace in tree.get("workspaces", []):
            for session in workspace.get("sessions", []):
                for field, pane in [("restoreCommand", "left"), ("splitRestoreCommand", "right")]:
                    if identity(session.get(field) or "") != expected:
                        continue
                    ctl(client, ["window", "select", window["id"]])
                    ctl(client, ["session", "select", "--target", session["id"], *selector])
                    if session.get("hasSplit") or session.get("split"):
                        ctl(client, ["session", "focus", pane, "--target", session["id"], *selector])
                    return True
    return False


def presentation(args, config):
    for alias in config.get("aliases", {}).values():
        if alias.get("name") == args.name:
            return alias.get("title", args.name), alias.get("workspace", args.workspace)
    return args.title or args.name, args.workspace


def place(client, args, config):
    if focus_existing(client, args):
        return 0
    title, workspace = presentation(args, config)
    command = shlex.join(client.attach_argv(args))
    selector = []
    window = os.environ.get("AGT_WINDOW_ID") or os.environ.get("AGTERM_WINDOW_ID")
    if window:
        selector = ["--window", window]
    if args.split:
        target = os.environ.get("AGT_SESSION_ID") or os.environ.get("AGTERM_SESSION_ID")
        if not target:
            raise ValueError("open a session before requesting a remote split")
        tree = ctl(client, ["tree", *selector])["tree"]
        session = next((s for w in tree.get("workspaces", []) for s in w.get("sessions", [])
                        if s["id"] == target), None)
        if session is None or session.get("hasSplit") or session.get("split"):
            raise ValueError("target is unavailable or already has a split; existing panes were left intact")
        if len(("exec " + command + "\n").encode()) > 1000:
            raise ValueError("split launch command is too long; use a separate session")
        ctl(client, ["session", "split", "on", "--target", target, *selector])
        # Only type into the new shell created above, never an existing pane.
        ctl(client, ["session", "type", "exec " + command + "\n", "--target", target,
                     "--pane", "right", *selector])
        ctl(client, ["session", "focus", "right", "--target", target, *selector])
    else:
        result = ctl(client, ["session", "new", "--name", title, "--workspace-name", workspace,
                              "--create-workspace", "--command", command, "--wait", *selector])
        ctl(client, ["session", "context", f"{args.host} · {args.agent} · {args.cwd}",
                     "--target", result["id"], *selector])
    return 0


def use_record(args, record):
    if record.get("alive") is not True:
        raise ValueError("backend is no longer live; use explicit conversation recovery")
    for key in ["name", "cwd", "agent"]:
        setattr(args, key, record[key])
    args.resume = record.get("resume")
    args.user_scope = record.get("user_scope", False)


def run(client, args, config):
    args.user_scope = args.user_scope or config.get("user_scope", False)
    records = inventory(client, args) if args.session or args.menu else []
    if args.session:
        alias = config.get("aliases", {}).get(args.session)
        if not alias:
            raise ValueError("unknown configured session")
        record = next((r for r in records if r["name"] == alias["name"]), None)
        if record is None:
            raise ValueError("configured backend is missing; use explicit conversation recovery")
        use_record(args, record)
        return place(client, args, config)
    if args.menu:
        choices = client.picker_items(records)
        for item in choices:
            for alias in config.get("aliases", {}).values():
                if alias.get("name") == item["id"]:
                    item["label"] = alias.get("title", item["label"])
        choices += [{"id": "new:" + agent, "label": "New " + label, "subtitle": "Start on " + args.workspace}
                    for agent, label in [("claude", "Claude conversation"), ("codex", "Codex conversation"),
                                         ("shell", "shell")]]
        selected = pick(client, args.workspace + " · attach or start a session", choices)
        if selected is None:
            return 0
        if not selected.startswith("new:"):
            record = next((r for r in records if r["name"] == selected), None)
            if record is None:
                raise ValueError("unknown session selected")
            use_record(args, record)
            return place(client, args, config)
        args.agent = selected.removeprefix("new:")
        if args.agent not in {"claude", "codex", "shell"}:
            raise ValueError("unknown agent selected")
        projects = config.get("projects", [{"label": "Sancta home", "cwd": "/home/nixos"}])
        directory = pick(client, "Remote working directory (absolute path)",
                         [{"id": p["cwd"], "label": p["label"], "subtitle": p["cwd"]} for p in projects], True)
        if directory is None:
            return 0
        if not directory.startswith("/") or any(ord(c) < 32 for c in directory):
            raise ValueError("use an absolute remote directory without control characters")
        args.cwd = directory
        for project in projects:
            if project["cwd"] == directory:
                args.workspace = project.get("workspace", args.workspace)
        suggested = args.agent + "-" + uuid.uuid4().hex[:8]
        name = pick(client, "Session name (letters, digits, hyphens or underscores)",
                    [{"id": suggested, "label": suggested}], True)
        if name is None:
            return 0
        import re
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}", name):
            raise ValueError("use 1–48 letters, digits, hyphens or underscores")
        if any(r["name"] == name for r in records):
            raise ValueError("name already recorded; select the existing session or choose a new name")
        args.name, args.resume = name, None
    return place(client, args, config)


def report_error(client, message):
    print(message, file=__import__("sys").stderr)
    try:
        target = os.environ.get("AGT_SESSION_ID") or os.environ.get("AGTERM_SESSION_ID")
        selector = ["--target", target] if target else []
        ctl(client, ["notify", message, "--title", "Remote sessions", *selector], timeout=3)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
