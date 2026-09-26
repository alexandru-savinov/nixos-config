#!/usr/bin/env python3
"""Synthetic hook protocol fixture, NOT Sancta's guard or a secret scanner."""
import json
import sys

payload = json.load(sys.stdin)
command = payload.get("tool_input", {}).get("command", "")
if command == "git commit --no-verify --allow-empty -m fixture":
    print("fixture: blocked", file=sys.stderr)
    sys.exit(2)
