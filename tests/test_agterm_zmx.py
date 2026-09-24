"""Protocol and reconnect regressions; optional real-zmx PTY acceptance test."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import unittest
from unittest.mock import patch

SCRIPTS = Path(os.environ.get("AGT_ZMX_SCRIPTS", Path(__file__).resolve().parents[1] / "scripts/agterm-zmx"))


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


client, host, interface = load("client"), load("host"), load("interface")
ui = load("ui")


def fixture_route():
    address = host.prepare_route()
    with socket.socket(socket.AF_UNIX) as channel:
        channel.bind(address)
    os.chmod(address, 0o600)
    return address


class ProtocolTests(unittest.TestCase):
    def test_forwarded_socket_grant_checks_type_owner_and_parent(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            account = SimpleNamespace(pw_dir=directory, pw_uid=os.getuid(), pw_gid=os.getgid())
            with patch.dict(os.environ, {"AGT_ZMX_STATE": str(Path(directory) / ".local/state/agt-zmx")}), \
                    patch.object(host.pwd, "getpwnam", return_value=account):
                address = fixture_route()
                host.grant_route("backend", address)
                self.assertEqual(Path(address).stat().st_uid, os.getuid())
                Path(address).parent.chmod(0o755)
                with self.assertRaises(ValueError):
                    host.grant_route("backend", address)
                Path(address).parent.chmod(0o700)
                Path(address).unlink()
                Path(address).write_text("not a socket")
                with self.assertRaises(ValueError):
                    host.grant_route("backend", address)

    def test_private_route_refuses_other_paths_permissions_and_symlinks(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory, patch.dict(os.environ, {"AGT_ZMX_STATE": directory}):
            address = fixture_route()
            self.assertEqual(host.validate_route(address), address)
            parent = Path(address).parent
            parent.chmod(0o755)
            with self.assertRaises(ValueError):
                host.validate_route(address)
            parent.chmod(0o700)
            os.chmod(address, 0o666)
            with self.assertRaises(ValueError):
                host.validate_route(address)
            os.chmod(address, 0o600)
            outside = Path(directory) / "ordinary-file"
            outside.write_text("owner data")
            Path(address).unlink()
            Path(address).symlink_to(outside)
            with self.assertRaises(ValueError):
                host.validate_route(address)
            with self.assertRaises(ValueError):
                host.remove_route(address)
            self.assertEqual(outside.read_text(), "owner data")

    def test_forward_uses_private_socket_and_grants_before_dropping_user(self):
        args = self.gui_args()
        command = client.ssh_command(args, "/tmp/local", "/private/relay-test/socket")
        self.assertEqual(command[command.index("-R") + 1], "/private/relay-test/socket:/tmp/local")
        self.assertNotIn("127.0.0.1", " ".join(command))
        remote = shlex.split(command[-1])
        self.assertEqual(remote[:4], ["/helper", "grant-route", "sancta", "/private/relay-test/socket"])
        self.assertLess(remote.index("grant-route"), remote.index("runuser"))

    def test_hud_ownership_update_disconnect_and_foreign_slot(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory, patch.object(ui.Path, "home", return_value=Path(directory)):
            first = ui.Bridge("socket", "session", "pane-a")
            second = ui.Bridge("socket", "session", "pane-b")
            state = {}
            requests = []
            def call(request):
                requests.append(request)
                if request["cmd"] == "session.hud.close":
                    state.pop("hud", None)
                else:
                    state["hud"] = dict(request["args"])
                return {}
            with patch.object(first, "require_native_ui"), patch.object(second, "require_native_ui"), \
                    patch.object(first, "session", return_value=state), \
                    patch.object(second, "session", return_value=state), \
                    patch.object(first, "call", side_effect=call):
                first.hud(dict(ui="hud.open", message="Counting files"))
                self.assertEqual(requests[-1]["args"]["paneID"], "pane-a")
                with self.assertRaises(BlockingIOError):
                    second.hud(dict(ui="hud.open", message="Other task"))
                first.hud(dict(ui="hud.update", message="Count complete"))
                first.disconnect()
                self.assertNotIn("hud", state)
                self.assertIsNone(first.hud_lease)
                state["hud"] = {"message": "Owner panel"}
                with self.assertRaises(ValueError):
                    second.hud(dict(ui="hud.open", message="Other task"))
                self.assertEqual(state["hud"]["message"], "Owner panel")

    def test_hud_does_not_close_replaced_panel_or_accept_target(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory, patch.object(ui.Path, "home", return_value=Path(directory)):
            bridge = ui.Bridge("socket", "session", "pane")
            state = {}
            def call(request):
                state["hud"] = dict(request["args"])
                return {}
            with patch.object(bridge, "require_native_ui"), patch.object(bridge, "session", return_value=state), \
                    patch.object(bridge, "call", side_effect=call) as send:
                with self.assertRaises(ValueError):
                    bridge.hud(dict(ui="hud.open", message="Text", target="other"))
                bridge.hud(dict(ui="hud.open", message="Mine"))
                state["hud"] = {"message": "Replacement"}
                bridge.disconnect()
                self.assertEqual(send.call_count, 1)
                self.assertEqual(state["hud"]["message"], "Replacement")

    def test_custom_picker_returns_query_and_rejects_unexpected_custom(self):
        reply = subprocess.CompletedProcess([], 0, '{"result":"custom","query":"/work/new"}')
        with patch.object(client, "agterm", return_value=reply):
            self.assertEqual(interface.pick(client, "Directory", [], True), "/work/new")
            with self.assertRaises(ValueError):
                interface.pick(client, "Session", [])

    def test_question_rejects_target_injection_and_invalid_choices(self):
        payload = dict(ui="ask", title="Choose", buttons=[dict(id="yes", label="Yes")])
        request = ui.question(payload, "local-session", "local-pane")
        self.assertEqual(request["target"], "local-session")
        self.assertEqual(request["args"]["paneID"], "local-pane")
        for bad in [dict(payload, target="other"), dict(payload, title="escape\x1b"),
                    dict(payload, buttons=payload["buttons"] * 2),
                    dict(payload, buttons=[dict(id="yes", label="Yes", command="exec")])]:
            with self.assertRaises(ValueError):
                ui.question(bad, "local-session", "local-pane")

    def test_question_answer_cancel_disconnect_and_timeout(self):
        payload = dict(ui="ask", title="Choose", buttons=[dict(id="yes", label="Yes")])
        for state in ["answered", "escaped", "cancelled", "disconnect", "timeout", "invalid"]:
            with self.subTest(state=state):
                bridge = ui.Bridge("unused", "session", "pane")
                calls = []
                def call(request):
                    calls.append(request)
                    if request["cmd"] == "version":
                        return {"app": {"version": "0.31.0"}}
                    if request["cmd"] == "ask.open":
                        return {"id": "owned-question"}
                    return {"ask": {"result": state if state != "invalid" else "answered",
                                    "id": "yes" if state != "invalid" else "unknown"}}
                with patch.object(bridge, "call", side_effect=call), \
                        patch.object(bridge, "peer_closed", return_value=state == "disconnect"):
                    if state == "invalid":
                        with self.assertRaises(ValueError):
                            bridge.ask(payload, None)
                    else:
                        result = bridge.ask(payload, None, timeout=0 if state == "timeout" else 1)
                        self.assertEqual(result["result"], state if state in {"answered", "escaped"}
                                         else "cancelled")
                    self.assertEqual(any(c["cmd"] == "ask.cancel" for c in calls),
                                     state in {"disconnect", "timeout", "invalid"})
                    self.assertFalse(bridge.lock.locked())

    def test_question_refuses_old_app_before_opening(self):
        bridge = ui.Bridge("unused", "session", "pane")
        with patch.object(bridge, "call", return_value={"app": {"version": "0.26.1"}}) as call:
            with self.assertRaisesRegex(ValueError, "0.31.0"):
                bridge.ask(dict(ui="ask", title="Choose", buttons=[dict(id="a", label="A")]), None)
            self.assertEqual(call.call_count, 1)

    def test_ssh_connection_notice_requires_local_ready_marker(self):
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            path = Path(directory) / "ready"
            callback = Mock()
            process = Mock()
            def wait(timeout):
                if not path.exists():
                    path.touch()
                    raise subprocess.TimeoutExpired("ssh", timeout)
                return 0
            process.wait.side_effect = wait
            with patch.object(client.subprocess, "Popen", return_value=process):
                self.assertEqual(client.wait_for_ssh(["ssh"], path, callback), 0)
            callback.assert_called_once()
            callback.reset_mock()
            process.wait.side_effect = None
            process.wait.return_value = 255
            with patch.object(client.subprocess, "Popen", return_value=process):
                self.assertEqual(client.wait_for_ssh(["ssh"], path, callback), 255)
            callback.assert_not_called()

    def gui_args(self, **changes):
        from argparse import Namespace
        values = dict(host="root@choir", user="sancta", remote_bin="/helper", name="test",
                      cwd="/work", agent="shell", resume=None, user_scope=False,
                      workspace="choir", title=None, split=False, session=None, menu=False)
        values.update(changes)
        return Namespace(**values)

    def test_gui_alias_uses_record_identity_and_rejects_missing_backend(self):
        args = self.gui_args(session="sancta")
        record = dict(name="main", cwd="/original", agent="claude", resume="saved-id",
                      user_scope=True, alive=True)
        config = {"aliases": {"sancta": {"name": "main", "title": "sancta"}}}
        with patch.object(interface, "inventory", return_value=[record]), \
                patch.object(interface, "place", return_value=0) as place:
            self.assertEqual(interface.run(client, args, config), 0)
            self.assertEqual((args.name, args.cwd, args.resume, args.user_scope),
                             ("main", "/original", "saved-id", True))
            place.assert_called_once()
        with patch.object(interface, "inventory", return_value=[]), \
                patch.object(interface, "place") as place:
            with self.assertRaisesRegex(ValueError, "missing"):
                interface.run(client, args, config)
            place.assert_not_called()

    def test_gui_menu_cancellation_at_each_stage_creates_nothing(self):
        for replies in [[None], ["new:shell", None], ["new:shell", "/work", None]]:
            with patch.object(interface, "inventory", return_value=[]), \
                    patch.object(interface, "pick", side_effect=replies), \
                    patch.object(interface, "place") as place:
                self.assertEqual(interface.run(client, self.gui_args(menu=True), {}), 0)
                place.assert_not_called()

    def test_gui_new_conversation_cannot_reuse_old_record(self):
        record = dict(name="existing", cwd="/work", agent="shell", alive=False)
        with patch.object(interface, "inventory", return_value=[record]), \
                patch.object(interface, "pick", side_effect=["new:claude", "/work", "existing"]), \
                patch.object(interface, "place") as place:
            with self.assertRaisesRegex(ValueError, "already recorded"):
                interface.run(client, self.gui_args(menu=True), {})
            place.assert_not_called()

    def test_gui_focus_matches_host_user_backend_not_title(self):
        args = self.gui_args()
        command = __import__('shlex').join(client.attach_argv(args))
        tree = {"tree": {"workspaces": [{"sessions": [
            {"id": "wrong", "name": "test", "restoreCommand": command.replace("root@choir", "root@other")},
            {"id": "right", "name": "renamed by owner", "restoreCommand": command},
        ]}]}}
        with patch.object(interface, "ctl", side_effect=[{"windows": [{"id": "window", "open": True}]}, tree, {}, {}]) as ctl:
            self.assertTrue(interface.focus_existing(client, args))
            self.assertEqual(ctl.call_args.args[1], ["session", "select", "--target", "right", "--window", "window"])

    def test_gui_split_refuses_hidden_existing_pane_before_typing(self):
        tree = {"tree": {"workspaces": [{"sessions": [{"id": "target", "hasSplit": True, "split": False}]}]}}
        with patch.dict(os.environ, {"AGTERM_SESSION_ID": "target", "AGT_SESSION_ID": "target"}), \
                patch.object(interface, "focus_existing", return_value=False), \
                patch.object(interface, "ctl", return_value=tree) as ctl:
            with self.assertRaisesRegex(ValueError, "already has a split"):
                interface.place(client, self.gui_args(split=True), {})
            self.assertEqual(ctl.call_count, 1)

    def test_gui_display_name_is_separate_from_restore_identity(self):
        args = self.gui_args(name="technical-backend")
        config = {"aliases": {"sancta": {"name": args.name, "title": "sancta", "workspace": "choir"}}}
        with patch.object(interface, "focus_existing", return_value=False), \
                patch.object(interface, "ctl", return_value={"id": "created"}) as ctl:
            interface.place(client, args, config)
            command = ctl.call_args_list[0].args[1]
            self.assertEqual(command[command.index("--name") + 1], "sancta")
            self.assertEqual(command[command.index("--workspace-name") + 1], "choir")
            self.assertIn("technical-backend", command[command.index("--command") + 1])

    def test_picker_transport_failures_are_clean_nonzero_diagnostics(self):
        import io
        for error in [subprocess.CalledProcessError(255, ["ssh"]),
                      subprocess.TimeoutExpired(["ssh"], 20), OSError("socket unavailable")]:
            output = io.StringIO()
            with patch.object(sys, "argv", ["client.py", "--pick"]), \
                    patch.object(client.subprocess, "run", side_effect=error), \
                    patch.object(sys, "stderr", output):
                self.assertEqual(client.main(), 1)
            self.assertIn("Could not open zmx pane:", output.getvalue())
            self.assertNotIn("Traceback", output.getvalue())

    def test_codex_resume_respects_native_writer_lock_without_mutating_it(self):
        identifier = '11111111-2222-3333-4444-555555555555'
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'transcript not found'):
                host.validate_resume('codex', identifier, root)
            (root / 'sessions').mkdir()
            transcript = root / 'sessions' / ('rollout-test-' + identifier + '.jsonl')
            transcript.write_text('private test sentinel')
            (root / 'thread-writer-locks').mkdir()
            path = root / 'thread-writer-locks' / (identifier + '.lock')
            path.write_text('native lock sentinel')
            with path.open('rb') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaisesRegex(ValueError, 'active Codex writer'):
                    host.validate_resume('codex', identifier, root)
            host.validate_resume('codex', identifier, root)
            self.assertEqual(path.read_text(), 'native lock sentinel')
            self.assertEqual(transcript.read_text(), 'private test sentinel')

    approval_screen = """Would you like to run the following command?
Environment: local
Reason: Do you approve running exactly sleep 2 outside the sandbox?
$ sleep 2
› 1. Yes, proceed (y)
2. Yes, and don't ask again for commands that start with `sleep 2` (p)
3. No, and tell Codex what to do differently (esc)
Press enter to confirm or esc to cancel
"""

    def test_codex_dialog_detection_requires_live_dialog_layout(self):
        self.assertTrue(client.codex_approval_visible(self.approval_screen))
        self.assertFalse(client.codex_approval_visible('Would you approve this?'))
        self.assertFalse(client.codex_approval_visible('Press enter to confirm or esc to cancel'))
        self.assertFalse(client.codex_approval_visible(self.approval_screen + '\n› Ask Codex to do anything\n'))
        self.assertFalse(client.codex_approval_visible('Hooks need review\nPress enter to confirm or esc to go back'))

    def test_dialog_status_clears_and_stale_reads_cannot_overwrite_stop(self):
        sent = []
        tracker = client.StatusTracker(sent.append)
        tracker.receive('active')
        tracker.observe(self.approval_screen, tracker.snapshot())
        tracker.observe(self.approval_screen, tracker.snapshot())
        tracker.observe('Working...', tracker.snapshot())
        self.assertEqual(sent, ['active', 'blocked', 'active'])
        stale = tracker.snapshot()
        tracker.receive('completed')
        tracker.observe(self.approval_screen, stale)
        self.assertEqual(sent[-1], 'completed')
        self.assertEqual(sent.count('blocked'), 1)

    def test_failed_dialog_delivery_is_retried(self):
        from unittest.mock import Mock
        send = Mock(side_effect=[OSError('temporarily disconnected'), None])
        tracker = client.StatusTracker(send)
        with self.assertRaises(OSError):
            tracker.observe(self.approval_screen, tracker.snapshot())
        tracker.observe(self.approval_screen, tracker.snapshot())
        self.assertEqual(send.call_count, 2)

    def test_lost_daemon_never_relaunches_or_overwrites_recovery_evidence(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            record = root / "agt-mvp-ended.json"
            route = root / "agt-mvp-ended.route"
            record.write_text(json.dumps({"cwd": str(root.resolve()), "agent": "claude"}))
            route.write_text('{"port": 22222}')
            original = record.read_bytes(), route.read_bytes()
            with patch.dict(os.environ, {"AGT_ZMX_STATE": directory}), \
                    patch.object(host.shutil, "which", return_value="/bin/tool"), \
                    patch.object(host.subprocess, "check_output", return_value=""), \
                    patch.object(host.os, "execvpe") as execute:
                with self.assertRaisesRegex(ValueError, "preserve this record"):
                    host.attach("ended", directory, "claude", fixture_route())
                execute.assert_not_called()
            self.assertEqual((record.read_bytes(), route.read_bytes()), original)

    def test_scope_wraps_backend_creation_but_not_reattachment(self):
        original = Path.cwd()
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            try:
                with patch.dict(os.environ, {"AGT_ZMX_STATE": str(root / "state")}), \
                        patch.object(host.shutil, "which", return_value="/bin/tool"), \
                        patch.object(host.os, "execvpe") as execute:
                    host.attach("scoped", directory, "shell", fixture_route(), user_scope=True)
                    binary, argv, env = execute.call_args[0]
                    self.assertEqual(binary, "systemd-run")
                    self.assertIn("--unit=agt-mvp-scoped.scope", argv)
                    self.assertEqual(env["XDG_RUNTIME_DIR"], f"/run/user/{os.getuid()}")
                    with patch.object(host.subprocess, "check_output", return_value="agt-mvp-scoped\n"):
                        host.attach("scoped", directory, "shell", fixture_route(), user_scope=True)
                    self.assertEqual(execute.call_args[0][0], "zmx")
            finally:
                os.chdir(original)

    def test_resume_requires_existing_transcript_and_stopped_process(self):
        identifier = "11111111-2222-3333-4444-555555555555"
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "transcript not found"):
                host.validate_resume("claude", identifier, root)
            project = root / "projects" / "test"
            project.mkdir(parents=True)
            transcript = project / (identifier + ".jsonl")
            transcript.write_text('private test sentinel, never parsed')
            host.validate_resume("claude", identifier, root)
            (root / "sessions").mkdir()
            metadata = root / "sessions" / "test.json"
            metadata.write_text(json.dumps({"sessionId": identifier, "pid": os.getpid()}))
            with self.assertRaisesRegex(ValueError, "live process"):
                host.validate_resume("claude", identifier, root)
            with patch.object(host.os, "kill", side_effect=ProcessLookupError):
                host.validate_resume("claude", identifier, root)
            for invalid in [None, "invalid", 0, -1]:
                metadata.write_text(json.dumps({"sessionId": identifier, "pid": invalid}))
                with self.assertRaisesRegex(ValueError, "invalid conversation process metadata"):
                    host.validate_resume("claude", identifier, root)
            metadata.write_text(json.dumps({"sessionId": identifier}))
            with self.assertRaisesRegex(ValueError, "invalid conversation process metadata"):
                host.validate_resume("claude", identifier, root)
            self.assertEqual(transcript.read_text(), 'private test sentinel, never parsed')
            for agent, value in [("shell", identifier), ("codex", identifier), ("claude", "../../other")]:
                with self.assertRaises(ValueError):
                    host.validate_resume(agent, value, root)

    def test_resume_lock_survives_parent_handoff_and_releases_after_exit(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory, patch.dict(os.environ, {"AGT_ZMX_STATE": directory}):
            lock = host.resume_lock("test")
            child = subprocess.Popen(["bash", "-c", "read -r value"], stdin=subprocess.PIPE,
                                     pass_fds=(lock.fileno(),))
            lock.close()
            try:
                with self.assertRaisesRegex(ValueError, "owns this conversation"):
                    host.resume_lock("test")
            finally:
                child.communicate(b"exit\n", timeout=5)
            host.resume_lock("test").close()

    def test_resume_identity_survives_restore_and_ssh_transport(self):
        from argparse import Namespace
        args = Namespace(host="host", user="sancta", name="resume", agent="claude", cwd="/tmp",
                         remote_bin="agt-zmx-host", resume="11111111-2222-3333-4444-555555555555")
        self.assertEqual(client.attach_argv(args)[-2:], ["--resume", args.resume])
        command = shlex.split(client.ssh_command(args, "/tmp/socket", "/private/relay-test/socket")[-1])
        self.assertEqual(command[-2:], ["--resume", args.resume])

    def test_codex_profile_preserves_owner_files_and_requires_normal_hook_trust(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            (root / "config.toml").write_text('# owner configuration\n')
            (root / "auth.json").write_text('test credential sentinel')
            identifier = host.codex_profile("codex-test", root)
            path = root / (identifier + ".config.toml")
            parsed = tomllib.loads(path.read_text())
            self.assertIn("Stop", parsed["hooks"])
            self.assertNotIn("PermissionRequest", parsed["hooks"])
            self.assertNotIn("dangerously", path.read_text())
            self.assertEqual(host.codex_profile("codex-test", root), identifier)
            self.assertEqual((root / "config.toml").read_text(), '# owner configuration\n')
            self.assertEqual((root / "auth.json").read_text(), 'test credential sentinel')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.write_text('# owner edit\n')
            with self.assertRaises(ValueError):
                host.codex_profile("codex-test", root)
            self.assertEqual(path.read_text(), '# owner edit\n')

    def test_backend_starts_in_requested_directory_not_ssh_callers_directory(self):
        original = Path.cwd()
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory)
            requested = root / "project"
            requested.mkdir()
            try:
                with patch.dict(os.environ, {"AGT_ZMX_STATE": str(root / "state"), "PWD": "/root"}), \
                        patch.object(host.shutil, "which", return_value="/bin/tool"), \
                        patch.object(host.os, "execvpe") as execute:
                    host.attach("cwd-test", str(requested), "shell", fixture_route())
                    self.assertEqual(Path.cwd(), requested.resolve())
                    self.assertEqual(execute.call_args[0][2]["PWD"], str(requested.resolve()))
            finally:
                os.chdir(original)

    def test_picker_lists_live_sessions_only(self):
        self.assertEqual(client.picker_items([
            {"name": "gone", "cwd": "/tmp", "agent": "shell", "alive": False},
            {"name": "work", "cwd": "/tmp/project", "agent": "codex", "alive": True},
        ]), [{"id": "work", "label": "work · codex", "subtitle": "/tmp/project"}])
        with self.assertRaises(ValueError):
            client.picker_items([{"name": "bad\nrow", "cwd": "/tmp", "agent": "shell", "alive": True}])

    def test_picker_cancellation_creates_no_pane(self):
        from argparse import Namespace
        args = Namespace(host="host", user="", remote_bin="agt-zmx-host")
        records = [{"name": "work", "cwd": "/tmp", "agent": "shell", "alive": True}]
        with patch.object(client.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(records))), \
                patch.object(client, "agterm", return_value=subprocess.CompletedProcess([], 2, '{"result":"cancelled"}')) as ctl:
            self.assertEqual(client.open_session(args, pick=True), 0)
            self.assertEqual(ctl.call_count, 1)
            self.assertEqual(ctl.call_args[0][0][0], "pick")

    def test_restore_pin_preserves_remote_identity_and_uses_current_pane(self):
        from argparse import Namespace
        args = Namespace(host="root@host", user="sancta", remote_bin="/nix/store/pkg/bin/agt-zmx-host",
                         name="work", cwd="/tmp/with ' quote", agent="claude")
        reply = subprocess.CompletedProcess([], 0, '{"ok":true,"result":{"pane":"right"}}')
        with patch.object(client, "agterm", return_value=reply) as ctl:
            client.pin_restore(args, "new-session", "new-pane")
            command = ctl.call_args[0][0]
            self.assertEqual(command[:2], ["session", "restore"])
            self.assertEqual(shlex.split(command[2]), client.attach_argv(args))
            self.assertEqual(command[command.index("--target") + 1], "new-session")
            self.assertEqual(command[command.index("--pane-id") + 1], "new-pane")
            self.assertNotIn("--open", shlex.split(command[2]))
        with patch.object(client, "agterm", return_value=subprocess.CompletedProcess([], 0, '{"ok":true}')):
            with self.assertRaises(ValueError):
                client.pin_restore(args, "new-session", "new-pane")

    def test_missing_inventory_is_read_only(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            missing = Path(directory) / "not-created"
            with patch.dict(os.environ, {"AGT_ZMX_STATE": str(missing)}):
                self.assertEqual(host.inventory(), [])
                self.assertFalse(missing.exists())

    def test_foreign_commands_targets_and_bad_states_rejected(self):
        for bad in [None, [], {"status": "completed", "target": "other"},
                    {"cmd": "session.type", "status": "idle"}, {"status": []},
                    {"status": "healthy"}]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                client.status_request(bad, "fixed-session", "fixed-pane")
        self.assertEqual(client.status_request({"status": "blocked"}, "s", "p"),
                         {"cmd": "session.status", "target": "s",
                          "args": {"status": "blocked", "paneID": "p"}})

    def test_shell_metacharacters_cannot_be_session_names(self):
        for name in ["../old", "x;touch pwned", "", "-old", "a\nb"]:
            with self.assertRaises(ValueError):
                host.session_name(name)

    def test_claude_hooks_are_session_scoped_and_do_not_request_approval_bypass(self):
        hooks = host.hooks("trial")["hooks"]
        self.assertIn("PermissionRequest", hooks)
        self.assertIn("Stop", hooks)
        for entries in hooks.values():
            command = shlex.split(entries[0]["hooks"][0]["command"])
            self.assertEqual(command[2:4], ["status", "trial"])
            self.assertNotIn("--dangerously-skip-permissions", command)

    def test_routing_changes_on_reattach(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory, patch.dict(os.environ, {"AGT_ZMX_STATE": directory}):
            listeners = []
            try:
                for _ in range(2):
                    address = host.prepare_route()
                    listener = socket.socket(socket.AF_UNIX)
                    listener.bind(address)
                    os.chmod(address, 0o600)
                    listener.listen()
                    listener.settimeout(1)
                    listeners.append(listener)
                    host.write_json(Path(directory) / "agt-mvp-test.route", {"socket": address})
                    host.status("test", "active")
                    connection, _ = listener.accept()
                    with connection:
                        self.assertEqual(json.loads(connection.recv(256)), {"status": "active"})
                listeners[0].settimeout(0.05)
                with self.assertRaises(socket.timeout):
                    listeners[0].accept()
            finally:
                for listener in listeners:
                    listener.close()

    def test_detached_status_is_nonfatal(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory, patch.dict(os.environ, {"AGT_ZMX_STATE": directory}):
            host.status("detached", "completed")

    def test_remote_arguments_survive_ssh_shell_quoting(self):
        from argparse import Namespace
        args = Namespace(name="trial", cwd="/tmp/project with ' quotes", agent="shell",
                         user="sancta", host="root@sancta-choir-1", remote_bin="agt-zmx-host")
        command = client.ssh_command(args, "/tmp/relay.sock", "/private/relay-test/socket")
        remote = shlex.split(command[-1])
        remote = remote[remote.index("&&") + 1:]
        self.assertEqual(remote[:4], ["runuser", "-u", "sancta", "--"])
        self.assertEqual(remote[7], args.cwd)
        self.assertIn("ControlPath=none", command)
        self.assertIn("ForwardAgent=no", command)

    def test_relay_forwards_only_fixed_target_over_real_sockets(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            agterm = socket.socket(socket.AF_UNIX)
            agterm.bind(directory + "/app")
            agterm.listen()
            agterm.settimeout(2)
            received = []
            def receive():
                connection, _ = agterm.accept()
                with connection:
                    received.append(json.loads(connection.recv(4096)))
                    connection.sendall(b'{"ok":true}\n')
            receiver = threading.Thread(target=receive)
            receiver.start()
            with client.Relay(directory + "/relay", client.StatusHandler) as relay:
                relay.target, relay.pane_id, relay.agterm_socket = "session-a", "pane-b", directory + "/app"
                runner = threading.Thread(target=relay.serve_forever)
                runner.start()
                try:
                    with socket.socket(socket.AF_UNIX) as sender:
                        sender.connect(directory + "/relay")
                        sender.sendall(b'{"status":"blocked"}\n')
                    receiver.join(3)
                    self.assertEqual(received[0]["target"], "session-a")
                    self.assertEqual(received[0]["args"]["paneID"], "pane-b")
                finally:
                    relay.shutdown()
                    runner.join()
                    agterm.close()

    def test_question_roundtrip_over_real_relay(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            with client.Relay(directory + "/relay", client.StatusHandler) as relay:
                relay.target, relay.pane_id = "session-a", "pane-b"
                relay.ui = ui.Bridge("unused", relay.target, relay.pane_id)
                requests = []
                def call(request):
                    requests.append(request)
                    if request["cmd"] == "version":
                        return {"app": {"version": "0.31.0"}}
                    if request["cmd"] == "ask.open":
                        return {"id": "owned"}
                    return {"ask": {"result": "answered", "id": "continue"}}
                runner = threading.Thread(target=relay.serve_forever)
                runner.start()
                try:
                    with patch.object(relay.ui, "call", side_effect=call):
                        with socket.socket(socket.AF_UNIX) as sender:
                            sender.settimeout(3)
                            sender.connect(directory + "/relay")
                            sender.sendall(json.dumps(dict(ui="ask", title="Continue?", buttons=[
                                dict(id="continue", label="Continue")])).encode() + b"\n")
                            self.assertEqual(json.loads(sender.recv(4096)),
                                             dict(result="answered", id="continue"))
                    opened = next(r for r in requests if r["cmd"] == "ask.open")
                    self.assertEqual((opened["target"], opened["args"]["paneID"]),
                                     ("session-a", "pane-b"))
                finally:
                    relay.shutdown()
                    runner.join()


@unittest.skipUnless(os.environ.get("AGT_ZMX_TEST_BINARY"), "set AGT_ZMX_TEST_BINARY for real PTY acceptance")
class LiveZmxTests(unittest.TestCase):
    def test_shell_pid_survives_client_loss_and_reattach(self):
        binary = os.environ["AGT_ZMX_TEST_BINARY"]
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="zmx-test-") as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "bin/zmx").symlink_to(binary)
            environment = dict(os.environ, AGT_ZMX_STATE=str(root / "state"),
                               PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                               ZMX_DIR=str(root / "state/sockets"), TERM="xterm-256color")
            environment.pop("ZMX_SESSION", None)
            environment.pop("ZMX_SESSION_PREFIX", None)
            with patch.dict(os.environ, environment):
                address = fixture_route()
            argv = [sys.executable, str(SCRIPTS / "host.py"), "attach", "acceptance", directory,
                    "--agent", "shell", "--socket", address]
            processes, masters = [], []
            def start():
                master, slave = pty.openpty()
                process = subprocess.Popen(argv, env=environment, stdin=slave, stdout=slave, stderr=slave,
                                           start_new_session=True)
                os.close(slave)
                processes.append(process)
                masters.append(master)
                return master
            def wait_file(path, master):
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if path.exists():
                        return path.read_text().strip()
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            os.read(master, 65536)
                        except OSError:
                            break
                self.fail("test shell did not write its PID")
            try:
                first = start()
                time.sleep(0.5)
                os.write(first, b'echo $$ > before.pid\r')
                before = wait_file(root / "before.pid", first)
                processes[0].terminate()
                processes[0].wait(timeout=5)
                second = start()
                time.sleep(0.5)
                os.write(second, b'echo $$ > after.pid\r')
                after = wait_file(root / "after.pid", second)
                self.assertEqual(before, after)
                # Different cwd with the same name must not hijack the live session.
                wrong = argv.copy()
                wrong[4] = "/tmp"
                rejected = subprocess.run(wrong, env=environment, capture_output=True, text=True, timeout=5)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("different directory or agent", rejected.stderr)
            finally:
                # This dedicated socket directory contains only this test's daemon.
                subprocess.run([binary, "kill", "agt-mvp-acceptance"], env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
                for master in masters:
                    os.close(master)


if __name__ == "__main__":
    unittest.main()
