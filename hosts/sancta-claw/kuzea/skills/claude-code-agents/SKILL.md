---
name: Claude Code Agents
description: Reference for Claude Code subagents (Task tool, custom agents) and experimental agent teams (parallel independent instances). Use when planning multi-agent workflows, creating custom subagents, or coordinating parallel work.
read_when:
  - Using the Task tool to delegate work
  - Creating custom subagents
  - Coordinating parallel agent work
  - Understanding agent teams vs subagents
---

# Claude Code: Agent Teams & Subagents Reference

## Overview

Claude Code has two mechanisms for parallel work:

1. **Subagents** — lightweight helpers within a single session
2. **Agent Teams** — multiple independent Claude Code instances coordinating via shared task list

## Subagents

Subagents are specialized AI assistants that handle specific tasks within a session. Each runs in its own context window with a custom system prompt, specific tool access, and independent permissions.

### Built-in Subagents

| Agent | Model | Purpose |
|---|---|---|
| Explore | Haiku | Fast read-only codebase exploration |
| Plan | Inherit | Research for planning mode |
| general-purpose | Inherit | Complex multi-step tasks |

### Creating Custom Subagents

**Via CLI flag (session-only):**
```bash
claude --agents '{
  "code-reviewer": {
    "description": "Expert code reviewer. Use proactively after code changes.",
    "prompt": "You are a senior code reviewer. Focus on code quality, security, and best practices.",
    "tools": ["Read", "Grep", "Glob", "Bash"],
    "model": "sonnet"
  }
}'
```

**Via Markdown files:**
```markdown
---
name: code-reviewer
description: Reviews code for quality and best practices
tools: Read, Glob, Grep
model: sonnet
---

You are a code reviewer. Analyze code and provide specific, actionable feedback.
```

### Subagent File Locations (priority order)

| Location | Scope | Priority |
|---|---|---|
| `--agents` CLI flag | Current session | 1 (highest) |
| `.claude/agents/` | Current project | 2 |
| `~/.claude/agents/` | All projects | 3 |
| Plugin `agents/` | Where plugin enabled | 4 (lowest) |

### Subagent Frontmatter Fields

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Unique identifier (lowercase, hyphens) |
| `description` | Yes | When Claude should delegate to this subagent |
| `tools` | No | Tools the subagent can use (inherits all if omitted) |
| `disallowedTools` | No | Tools to deny |
| `model` | No | `sonnet`, `opus`, `haiku`, or `inherit` (default: `inherit`) |
| `permissionMode` | No | `default`, `acceptEdits`, `dontAsk`, `bypassPermissions`, `plan` |
| `maxTurns` | No | Maximum agentic turns |
| `skills` | No | Skills to load into subagent context |
| `memory` | No | Additional context |
| `hooks` | No | Hooks configuration |
| `mcpServers` | No | MCP servers |

## Agent Teams (Experimental)

⚠️ **Experimental** — disabled by default. Enable with:
```jsonc
// settings.json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### Subagents vs Agent Teams

| | Subagents | Agent Teams |
|---|---|---|
| **Context** | Own context; results return to caller | Own context; fully independent |
| **Communication** | Report results back to main only | Teammates message each other directly |
| **Coordination** | Main agent manages all work | Shared task list with self-coordination |
| **Best for** | Focused tasks where only result matters | Complex work requiring discussion |
| **Token cost** | Lower | Higher (each teammate = separate instance) |

### When to Use Agent Teams

Best for:
- **Research and review** — multiple teammates investigate different aspects simultaneously
- **New modules/features** — teammates each own a separate piece
- **Debugging with competing hypotheses** — test different theories in parallel
- **Cross-layer coordination** — frontend, backend, tests each owned by different teammate

NOT for:
- Sequential tasks
- Same-file edits
- Work with many dependencies

### Starting a Team

```text
Create an agent team to review PR #142. Spawn three reviewers:
- One focused on security implications
- One checking performance impact
- One validating test coverage
Have them each review and report findings.
```

### Display Modes

| Mode | How | Requirement |
|---|---|---|
| `in-process` | All in main terminal, Shift+Down to cycle | Any terminal |
| `split panes` | Each teammate in own pane | tmux or iTerm2 |

```bash
# Force in-process
claude --teammate-mode in-process
```

### Team Architecture

| Component | Role |
|---|---|
| **Team lead** | Creates team, spawns teammates, coordinates |
| **Teammates** | Separate Claude Code instances, work on tasks |
| **Task list** | Shared work items teammates claim and complete |
| **Mailbox** | Messaging between agents |

### Key Commands

```text
# Specify teammates
Create a team with 4 teammates to refactor these modules. Use Sonnet for each.

# Require plan approval
Spawn an architect teammate. Require plan approval before changes.

# Shut down teammate
Ask the researcher teammate to shut down

# Clean up team (always from lead)
Clean up the team

# Wait for teammates
Wait for your teammates to complete their tasks before proceeding
```

### Best Practices

1. **Give enough context** — teammates don't inherit lead's conversation history
2. **3-5 teammates** for most workflows
3. **5-6 tasks per teammate** keeps everyone productive
4. **Avoid file conflicts** — each teammate owns different files
5. **Monitor and steer** — check in, redirect as needed
6. **Start with research/review** if new to agent teams

### Limitations

- No session resumption with in-process teammates
- Task status can lag
- One team per session
- No nested teams
- Lead is fixed (can't transfer leadership)
- Permissions set at spawn time
- Split panes require tmux or iTerm2

### Use Case: Competing Hypotheses

```text
Users report the app exits after one message. Spawn 5 teammates to
investigate different hypotheses. Have them debate and try to disprove
each other's theories. Update findings doc with consensus.
```

### Use Case: Parallel Refactor

```text
Create a team with 3 teammates to refactor the auth module:
- One migrates the session store to Redis
- One updates the middleware chain
- One rewrites the integration tests
Each teammate owns separate files to avoid conflicts.
```
