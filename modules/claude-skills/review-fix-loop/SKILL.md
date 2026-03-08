---
name: review-fix-loop
description: >
  PR review-fix-review loop — review with parallel agents, fix all issues, re-review until clean,
  then wait for CI and offer to merge. Use when you have a branch ready for review, or when the
  user says "review", "review and fix", "review-fix loop", or "review until clean".
---

# Review-Fix Loop

Autonomous PR review-fix-review loop. Reviews code with parallel agents, fixes all real issues,
re-reviews until clean, waits for CI, and offers to merge.

---

## Phase 0: Pre-flight

1. Run `pwd` and `git branch --show-current` — abort if on `main`
2. Verify at least one commit ahead of main
3. Run `nix fmt` — commit formatting fixes if any
4. Run `nix flake check` — if it fails, fix and commit before proceeding
5. Push to origin if not already pushed
6. Create PR via `gh pr create` if none exists

## Phase 1: Review (parallel agents)

Get the full list of changed files vs main:
```bash
git diff --name-only main...HEAD
```

Launch **3 parallel Opus agents** to review ALL changed files (not just latest commit):

### Agent 1 — NixOS Correctness

Check for:
- Module `imports` placed inside `lib.mkIf` blocks (must be top-level)
- `stateVersion` conflicts (may need `lib.mkForce`)
- `fileSystems.*.options` empty list when using `mkForce` (NixOS requires non-empty)
- Unused function parameters (e.g., `{ config, lib, pkgs, ... }:` where config/pkgs unused)
- `with lib;` usage — prefer explicit `inherit (lib) mkIf mkOption;`
- Secrets using hardcoded paths instead of `age.secrets.*.path`
- `writeShellApplication` already injects `set -euo pipefail` — duplicate is harmless, do NOT flag as critical
- For Python files: `python3 -c "import py_compile; py_compile.compile('FILE', doraise=True)"`
- For shell scripts: `shellcheck FILE` if available

### Agent 2 — Logic Bugs

Check for:
- Off-by-one errors, null/undefined handling
- Race conditions, resource leaks
- Error handling gaps
- Dead code, unreachable branches
- Hardcoded values that should be configurable
- **IGNORE pre-existing issues** not introduced in this PR

### Agent 3 — Security + CLAUDE.md Compliance

Check for:
- Read `CLAUDE.md` first, verify all changes comply
- OWASP top 10: injection, XSS, auth bypass, data exposure
- Plaintext secrets, insecure defaults
- Network services binding to `0.0.0.0` instead of `127.0.0.1`
- Missing input validation at system boundaries

Each agent returns issues in this format:
```
SEVERITY: CRITICAL | HIGH | MEDIUM | LOW
FILE: path/to/file.nix
LINE: 42
DESCRIPTION: brief description
REASON: why this matters
FIX: suggested fix (code snippet if helpful)
```

## Phase 2: Score and Filter

For each issue, assess confidence (0-100):

| Score | Meaning |
|-------|---------|
| 0-25 | Likely false positive or pre-existing |
| 26-50 | Might be real but nitpicky |
| 51-75 | Real issue, moderate impact |
| 76-100 | Confirmed real, will cause problems |

**Keep only issues scoring >= 75.**

### False positives to discard

- Pre-existing issues not introduced in this PR
- Style preferences not documented in CLAUDE.md
- Things a linter/compiler would catch
- Intentional functionality changes
- `set -euo pipefail` in `writeShellApplication` scripts (harmless no-op)
- Unused variables prefixed with `_`

## Phase 3: Fix

If issues remain after filtering:

1. Present filtered issues in a summary table
2. Fix ALL issues scoring >= 75 (minimal, targeted fixes only)
3. After fixing, run:
   - `nix fmt`
   - `nix flake check`
4. Commit: `fix: address review findings`
5. Push to origin

## Phase 4: Re-review

1. Re-run Phase 1 with **Sonnet agents** (faster) focused ONLY on the fix commit
2. Re-run Phase 2 filtering
3. If new issues >= 75: go back to Phase 3 (**max 3 total loops**)
4. If clean: proceed to Phase 5

## Phase 5: Finalize

1. Poll CI: `gh pr view --json statusCheckRollup` every 30s (max 10 minutes)
2. Report CI status:
   - **All pass:** report "Ready to merge", ask user
   - **Failure:** diagnose, attempt fix, commit, push, re-poll (max 2 CI fix attempts)
   - **Known pre-existing failures to IGNORE:** `Python Tests` (missing PIL), `GitGuardian` (encrypted secrets)
3. If user says merge: `gh pr merge --squash --delete-branch`

## Output Format

After each phase, print:
```
=== Phase N: <name> ===
[status details]
```

Final summary:
```
=== Review-Fix Loop Complete ===
PR: #NNN — <title>
Loops: N review cycles
Issues found: N total, N fixed, N false-positive
CI: PASS / FAIL (details)
Status: Ready to merge / Needs attention
```

## Rules

- NEVER skip `nix fmt` before committing
- NEVER commit to main — abort if branch is main
- NEVER merge without CI passing (except known pre-existing failures)
- Max 3 review-fix loops to prevent infinite cycling
- Max 2 CI fix attempts before escalating to user
- Always verify `pwd` and branch before making changes
- When unsure about a finding, err on the side of NOT fixing — ask the user
