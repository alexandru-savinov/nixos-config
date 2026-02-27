---
name: coding-agent-local
description: "Local overrides and fixes for the coding-agent skill. Read AFTER the main coding-agent SKILL.md for sancta-claw-specific patterns."
read_when:
  - Spawning Claude Code via exec
  - Troubleshooting missing output from -p mode
  - Using Agent Teams through OpenClaw
  - Running PR reviews via OpenClaw
metadata: {"openclaw": {"emoji": "🔧"}}
---

# Coding Agent — Local Fixes (sancta-claw)

These overrides apply on top of the main `coding-agent` skill.

## ⚠️ Critical Fix: --output-format text

Claude Code's default output goes to its TUI renderer, NOT stdout.
When spawned via `exec` (background or not), OpenClaw's process manager
captures stdout/stderr — but the TUI output is invisible.

**Always add `--output-format text`** when running `claude -p`:

```bash
# ✅ Correct — output captured by OpenClaw
claude --dangerously-skip-permissions --output-format text -p "Your task"

# ❌ Wrong — no output visible in process logs
claude --dangerously-skip-permissions -p "Your task"
```

### With background mode (recommended pattern):

```text
exec(
  command: "cd /path/to/repo && claude --dangerously-skip-permissions --output-format text -p 'Your task here'",
  pty: true,
  background: true,
  timeout: 300,
  yieldMs: 30000
)
```

### PTY: optional but safe

- `pty: true` — works fine WITH `--output-format text`
- `pty: false` — also works fine WITH `--output-format text`
- Without `--output-format text` — PTY captures garbage TUI escape codes or nothing

## Agent Teams (experimental)

Enabled in `~/.claude/settings.json` via `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`.

When using Agent Teams through exec, the lead process runs for a long time
and may hit OpenClaw's process timeout. Increase timeout accordingly:

```text
exec(
  command: "cd /path/to/repo && CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --dangerously-skip-permissions --output-format text -p 'Create a team: ...'",
  pty: true,
  background: true,
  timeout: 600  # 10 min for team coordination
)
```

**Known issue:** Agent Teams spawns child processes that may outlive the lead
if the lead gets SIGTERM. Always check `ps aux | grep claude` after a killed session.

## Custom Subagents (--agents flag)

For specialized reviews without full Agent Teams overhead:

```bash
claude --dangerously-skip-permissions --output-format text --agents '{
  "nix-reviewer": {
    "description": "Reviews NixOS configuration changes",
    "prompt": "You are a NixOS expert. Check derivations, tmpfiles, module structure.",
    "tools": ["Read", "Grep", "Glob", "Bash"],
    "model": "sonnet"
  }
}' -p "Review the diff: git diff main...fix/my-branch"
```

## PR Review Pattern (sancta-claw)

```bash
REVIEW_DIR=$(mktemp -d)
git clone https://github.com/alexandru-savinov/nixos-config.git $REVIEW_DIR
cd $REVIEW_DIR && git fetch origin 'refs/pull/NUMBER/head:pr-NUMBER'

claude --dangerously-skip-permissions --output-format text -p '
Review PR #NUMBER (branch pr-NUMBER vs main).
Run: git diff main...pr-NUMBER
Check: Nix syntax, Python correctness, pattern consistency.
Fix issues and push. Post gh pr review comment.
'
```

## Auto-Notify on Completion

Append to prompt so OpenClaw wakes immediately:

```
When completely finished, run:
openclaw system event --text "Done: [summary]" --mode now
```
