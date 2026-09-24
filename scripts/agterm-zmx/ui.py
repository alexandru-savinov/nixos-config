"""Restricted native questions for the pane owning a remote attachment.

The peer supplies presentation and choices, never control commands or targets.
No answer executes an action or changes an agent's permission policy.
"""
import json
import fcntl
import hashlib
import os
from pathlib import Path
import re
import select
import socket
import threading
import time


def text(value, limit=256):
    if not isinstance(value, str) or not 1 <= len(value) <= limit:
        raise ValueError("invalid UI text length")
    if any(ord(c) < 32 or 127 <= ord(c) < 160 for c in value):
        raise ValueError("control characters are not accepted")
    return value


def question(payload, target, pane_id):
    if not isinstance(payload, dict) or set(payload) != {"ui", "title", "buttons"}:
        raise ValueError("expected question title and buttons only")
    if payload["ui"] != "ask":
        raise ValueError("unsupported UI operation")
    buttons = payload["buttons"]
    if not isinstance(buttons, list) or not 1 <= len(buttons) <= 6:
        raise ValueError("a question needs one to six choices")
    validated, ids = [], set()
    for button in buttons:
        if not isinstance(button, dict) or set(button) != {"id", "label"}:
            raise ValueError("expected button id and label only")
        identifier = text(button["id"], 48)
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", identifier) or identifier in ids:
            raise ValueError("invalid or duplicate button id")
        ids.add(identifier)
        validated.append({"id": identifier, "label": text(button["label"], 80)})
    return {"cmd": "ask.open", "target": target,
            "args": {"title": text(payload["title"]), "buttons": validated,
                     "style": "terminal", "paneID": pane_id}}


class Bridge:
    def __init__(self, address, target, pane_id):
        self.address, self.target, self.pane_id = address, target, pane_id
        self.lock = threading.Lock()
        self.disconnected = threading.Event()
        self.hud_lock = threading.Lock()
        self.hud_lease = None
        self.hud_fingerprint = None

    def require_native_ui(self):
        version = self.call({"cmd": "version"}).get("app", {}).get("version", "")
        match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
        if not match or tuple(map(int, match.groups())) < (0, 31, 0):
            raise ValueError("native pane UI requires agterm 0.31.0 or newer")

    def session(self):
        for window in self.call({"cmd": "window.list"}).get("windows", []):
            if not window.get("open"):
                continue
            tree = self.call({"cmd": "tree", "args": {"window": window["id"]}})["tree"]
            for workspace in tree.get("workspaces", []):
                for session in workspace.get("sessions", []):
                    if session["id"] == self.target:
                        return session
        raise ValueError("attachment pane is unavailable")

    @staticmethod
    def fingerprint(hud):
        # Exclude dimensions and live pane role, which change on resize/swap.
        if not hud:
            return None
        fields = {key: hud.get(key) for key in ["message", "detail", "spinner", "position",
                                               "textColor", "backgroundColor", "hideAfter"]}
        return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()

    def release_hud(self):
        if self.hud_lease:
            self.hud_lease.close()
        self.hud_lease = self.hud_fingerprint = None

    def hud(self, payload):
        if not isinstance(payload, dict) or payload.get("ui") not in {"hud.open", "hud.update", "hud.close"}:
            raise ValueError("unsupported HUD request")
        action = payload["ui"]
        required = {"ui"} if action == "hud.close" else {"ui", "message"}
        if not required <= set(payload) or set(payload) - required - ({"detail"} if action != "hud.close" else set()):
            raise ValueError("unexpected HUD fields")
        args = {"paneID": self.pane_id}
        if action != "hud.close":
            args.update(message=text(payload["message"]), position="top-right", hideAfter=60)
            if "detail" in payload:
                args["detail"] = text(payload["detail"])
        with self.hud_lock:
            self.require_native_ui()
            if self.disconnected.is_set() and action != "hud.close":
                raise ValueError("attachment disconnected")
            if action == "hud.open" and self.hud_lease is None:
                directory = Path.home() / ".local/state/agterm-remote-ui"
                directory.mkdir(parents=True, exist_ok=True, mode=0o700)
                if directory.is_symlink() or directory.stat().st_uid != os.getuid():
                    raise ValueError("invalid HUD lease directory")
                key = hashlib.sha256((self.address + self.target).encode()).hexdigest()
                fd = os.open(directory / (key + ".lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                lease = os.fdopen(fd, "w")
                try:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BaseException:
                    lease.close()
                    raise
                self.hud_lease = lease
            if self.hud_lease is None:
                raise ValueError("this attachment does not own a HUD")
            try:
                session = self.session()
                current = self.fingerprint(session.get("hud"))
                if session.get("overlay") or current != self.hud_fingerprint:
                    raise ValueError("HUD slot is occupied or ownership changed")
                if action != "hud.open" and current is None:
                    raise ValueError("owned HUD expired or was closed")
                self.call({"cmd": "session." + action, "target": self.target, "args": args})
                if action == "hud.close":
                    self.release_hud()
                else:
                    self.hud_fingerprint = self.fingerprint(self.session().get("hud"))
                    if self.hud_fingerprint is None:
                        raise ValueError("HUD did not appear")
                return {"result": "ok"}
            except BaseException:
                self.release_hud()
                raise

    def disconnect(self):
        self.disconnected.set()
        try:
            if self.hud_lease:
                self.hud({"ui": "hud.close"})
        except (OSError, ValueError, KeyError):
            # The bounded native expiry also removes panels if the app is unreachable.
            self.release_hud()

    def call(self, request):
        with socket.socket(socket.AF_UNIX) as channel:
            channel.settimeout(3)
            channel.connect(self.address)
            channel.sendall((json.dumps(request) + "\n").encode())
            with channel.makefile("rb") as stream:
                raw = stream.readline(65537)
            if len(raw) > 65536 or not raw.endswith(b"\n"):
                raise ValueError("invalid agterm response")
        reply = json.loads(raw)
        if reply.get("ok") is not True:
            # Do not echo arbitrary server data or question contents to logs.
            raise ValueError("agterm rejected the UI request")
        return reply.get("result", {})

    def ask(self, payload, peer, timeout=300):
        request = question(payload, self.target, self.pane_id)
        if not self.lock.acquire(blocking=False):
            raise ValueError("this attachment already has a pending question")
        identifier = None
        resolved = False
        try:
            self.require_native_ui()
            if self.disconnected.is_set():
                return {"result": "cancelled", "reason": "disconnected"}
            identifier = self.call(request).get("id")
            if not isinstance(identifier, str) or not identifier:
                raise ValueError("agterm did not identify the question")
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if self.disconnected.is_set() or self.peer_closed(peer):
                    return {"result": "cancelled", "reason": "disconnected"}
                outcome = self.call({"cmd": "ask.result", "target": identifier}).get("ask", {})
                if self.disconnected.is_set() or self.peer_closed(peer):
                    return {"result": "cancelled", "reason": "disconnected"}
                state = outcome.get("result")
                if state == "answered":
                    answer = outcome.get("id")
                    if answer not in {b["id"] for b in payload["buttons"]}:
                        raise ValueError("agterm returned an unknown choice")
                    resolved = True
                    return {"result": "answered", "id": answer}
                if state in {"cancelled", "escaped"}:
                    resolved = True
                    return {"result": state}
                if state != "pending":
                    raise ValueError("unexpected question outcome")
                self.disconnected.wait(0.2)
            return {"result": "cancelled", "reason": "timeout"}
        finally:
            try:
                if identifier and not resolved:
                    self.call({"cmd": "ask.cancel", "target": identifier})
            finally:
                self.lock.release()

    @staticmethod
    def peer_closed(peer):
        readable, _, _ = select.select([peer], [], [], 0)
        if not readable:
            return False
        # Protocol is one request per connection. Extra bytes also abort it.
        return True
