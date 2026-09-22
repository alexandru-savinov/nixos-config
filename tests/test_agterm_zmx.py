"""Protocol and reconnect regressions; optional real-zmx PTY acceptance test."""
import importlib.util
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
import unittest
from unittest.mock import patch

SCRIPTS = Path(os.environ.get("AGT_ZMX_SCRIPTS", Path(__file__).resolve().parents[1] / "scripts/agterm-zmx"))


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


client, host = load("client"), load("host")


class ProtocolTests(unittest.TestCase):
    def test_backend_starts_in_requested_directory_not_ssh_callers_directory(self):
        original = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            requested = root / "project"
            requested.mkdir()
            try:
                with patch.dict(os.environ, {"AGT_ZMX_STATE": str(root / "state"), "PWD": "/root"}), \
                        patch.object(host.shutil, "which", return_value="/bin/tool"), \
                        patch.object(host.os, "execvpe") as execute:
                    host.attach("cwd-test", str(requested), "shell", 22222)
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
        with tempfile.TemporaryDirectory() as directory:
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
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"AGT_ZMX_STATE": directory}):
            listeners = []
            try:
                for _ in range(2):
                    listener = socket.socket()
                    listener.bind(("127.0.0.1", 0))
                    listener.listen()
                    listener.settimeout(1)
                    listeners.append(listener)
                    host.write_json(Path(directory) / "agt-mvp-test.route", {"port": listener.getsockname()[1]})
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
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"AGT_ZMX_STATE": directory}):
            host.status("detached", "completed")

    def test_remote_arguments_survive_ssh_shell_quoting(self):
        from argparse import Namespace
        args = Namespace(name="trial", cwd="/tmp/project with ' quotes", agent="shell",
                         user="sancta", host="root@sancta-choir-1", remote_bin="agt-zmx-host")
        command = client.ssh_command(args, "/tmp/relay.sock", 22222)
        remote = shlex.split(command[-1])
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
            argv = [sys.executable, str(SCRIPTS / "host.py"), "attach", "acceptance", directory,
                    "--agent", "shell", "--port", "22222"]
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
