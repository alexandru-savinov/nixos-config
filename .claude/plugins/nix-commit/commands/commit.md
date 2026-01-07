---
allowed-tools: Bash(nix fmt:*), Bash(git add:*), Bash(git status:*), Bash(git commit:*)
description: Format Nix files and create a commit
---

## Context

- Current git status: !`git status`
- Current git diff (staged and unstaged changes): !`git diff HEAD`
- Current branch: !`git branch --show-current`
- Recent commits: !`git log --oneline -10`

## Your task

Based on the above changes:

1. Run `nix fmt` to format all Nix files before committing
2. Stage all changes (including any formatting fixes from step 1)
3. Create a single git commit with an appropriate message

You have the capability to call multiple tools in a single response. Do all of the above in a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
