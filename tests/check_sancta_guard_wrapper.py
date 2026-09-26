"""Exercise a rendered managed guard with disposable inputs, never real secrets.

Usage: python check_sancta_guard_wrapper.py SETTINGS_JSON GUARD_SOURCE
Optional --timeout-binary substitutes the platform dependency for a Mac run.
Without it, the exact rendered Linux timeout executable is used.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("settings")
    parser.add_argument("guard_source")
    parser.add_argument("--timeout-binary")
    args = parser.parse_args()
    settings = json.loads(Path(args.settings).read_text())
    entries = [entry for entry in settings["hooks"]["PreToolUse"]
               if any("garda-secret-hook.mjs" in h["command"] for h in entry["hooks"])]
    assert len(entries) == 1 and entries[0]["matcher"] == "Bash"
    hook = entries[0]["hooks"][0]
    template = hook["command"]
    source_path = "/var/lib/sancta/.claude/hooks/garda-secret-hook.mjs"
    assert template.count(source_path) == 1
    assert hook["timeout"] > 12
    if args.timeout_binary:
        template, count = re.subn(r"/nix/store/[^ /]+/bin/timeout", shlex.quote(args.timeout_binary), template)
        assert count == 1
    with tempfile.TemporaryDirectory(prefix="sancta-guard-wrapper-") as directory:
        root = Path(directory)
        binary = root / "bin"
        binary.mkdir()
        identity = binary / "id"
        identity.write_text("#!/bin/sh\nprintf '%s\\n' sancta\n")
        identity.chmod(0o700)
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"])
        guard = root / "guard"
        command = template.replace(source_path, shlex.quote(str(guard)))
        def check(label, expected, payload=None):
            result = subprocess.run(["sh", "-c", command], input=json.dumps(payload or {}),
                                    text=True, capture_output=True, env=env, timeout=18)
            assert result.returncode == expected, (label, result.returncode)
            print("PASS", label)
        for status in (0, 2, 1, 126, 127, 137):
            guard.write_text(f"#!/bin/sh\nexit {status}\n")
            guard.chmod(0o700)
            check(f"guard status {status}", 0 if status == 0 else 2)
        guard.unlink()
        check("missing guard blocks", 2)
        guard.write_text("#!/bin/sh\nexit 0\n")
        guard.chmod(0o600)
        check("non-executable guard blocks", 2)
        guard.write_text("#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 1; done\n")
        guard.chmod(0o700)
        check("hung guard blocks after escalation", 2)
        guard.unlink()
        identity.write_text("#!/bin/sh\nprintf '%s\\n' unrelated-fixture-user\n")
        check("unrelated user does not access soul guard", 0)
        identity.write_text("#!/bin/sh\nprintf '%s\\n' sancta\n")
        actual = root / "garda-secret-hook.mjs"
        shutil.copyfile(args.guard_source, actual)
        actual.chmod(0o700)
        command = template.replace(source_path, shlex.quote(str(actual)))
        repo = root / "repo"
        subprocess.run(["git", "init", "-q", str(repo)], check=True, capture_output=True)
        (repo / "shell.nix").write_text("# nixos-config secret-hook v2\n")
        payload = {"tool_name": "Bash", "cwd": str(repo),
                   "tool_input": {"command": "git commit --no-verify --allow-empty -m fixture"}}
        check("supplied guard blocks unscanned commit input", 2, payload)
        # A user-settings schema rewrite cannot remove this separate managed
        # entry. Re-run the same rendered command after replacing a fixture.
        user_settings = root / "settings.json"
        user_settings.write_text(json.dumps({"hooks": {"PreToolUse": []}, "unrelated": True}))
        user_settings.write_text(json.dumps({"modelSettings": {}, "unrelated": True}))
        check("managed guard survives user-settings replacement", 2, payload)
        check("supplied guard allows harmless input", 0,
              {"tool_name": "Bash", "cwd": str(repo), "tool_input": {"command": "git status"}})
        assert subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "HEAD"],
                              capture_output=True).returncode != 0
        print("No commit command was executed; this tests the hook protocol, not Claude loading it.")


if __name__ == "__main__":
    main()
