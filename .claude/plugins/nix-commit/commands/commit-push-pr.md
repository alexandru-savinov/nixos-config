---
allowed-tools: Bash(nix fmt:*), Bash(git checkout --branch:*), Bash(git add:*), Bash(git status:*), Bash(git push:*), Bash(git commit:*), Bash(gh pr create:*)
description: Format Nix files, commit, push, and create a PR
---

## Context

- Current git status: !`git status`
- Current git diff (staged and unstaged changes): !`git diff HEAD`
- Current branch: !`git branch --show-current`

## Your task

Based on the above changes:

1. Run `nix fmt` to format all Nix files before committing
2. Create a new branch if on main
3. Stage all changes (including any formatting fixes from step 1)
4. Create a single commit with an appropriate message
5. Push the branch to origin
6. Create a pull request using `gh pr create`

You have the capability to call multiple tools in a single response. You MUST do all of the above in a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
