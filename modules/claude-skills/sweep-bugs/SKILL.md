---
name: sweep-bugs
description: >
  Triage open bug issues, present a fix/skip/close/defer plan for approval,
  then fix approved bugs one-by-one using /verify-first and /review-fix-loop.
  Use when user says "sweep bugs", "fix all bugs", or "triage issues".
---

# Sweep Bugs

Triage open bug issues, get user approval, then fix each approved bug autonomously
using `/verify-first` and `/review-fix-loop`.

---

## Arguments

`$ARGUMENTS` format: `[max_bugs]` (default: 5)

Example: `/sweep-bugs 3` -- fix at most 3 bugs this sweep.

---

## Phase 0: Gather

1. Fetch all open bug issues:
   ```bash
   gh issue list --state open --label bug --json number,title,labels,body,comments,createdAt
   ```

2. For each issue, read full details:
   ```bash
   gh issue view <number>
   ```

3. Check for existing open PRs or branches:
   ```bash
   gh pr list --search "fixes #<number> OR closes #<number>" --state open --json number,title,url
   git branch -l "fix/*"
   ```

4. Run `nix flake check` once to establish baseline -- record any pre-existing warnings or failures.

---

## Phase 1: Triage

For each bug, assess and assign a triage outcome.

### Assessment Criteria

| Question | How to check |
|----------|-------------|
| Already fixed? | Read comments, check if mentioned code still has the bug, test with `nix eval` or `grep` |
| Fixable by code changes? | vs needs manual action (GitHub login, API tokens, external service changes) |
| Worth the effort? | File count, dependency chain, risk of breaking other hosts |
| Verifiable locally? | `nix flake check` and `nix fmt` vs needs runtime/visual testing |
| Dependencies on other bugs? | Cross-references in issue body |
| Existing PR? | `gh pr list --search` result from Phase 0 |

### Triage Outcomes

| Outcome | Meaning | Criteria |
|---------|---------|----------|
| **FIX** | Automatable, worth it, proceed | Touches <=3 files, verifiable with `nix flake check`, no external deps |
| **SKIP** | Not worth effort or needs human | Needs manual login, external API fix, GitHub settings change |
| **CLOSE** | Already fixed, duplicate, or obsolete | Code already changed, warning gone, issue superseded |
| **DEFER** | Blocked or too complex for sweep | Needs runtime/visual testing, touches flake inputs, blocked by another bug |
| **EXISTING** | Open PR already exists | Found via `gh pr list --search` -- link it, let user decide |

### Auto-DEFER Rules

Classify as DEFER (user can override to FIX) if ANY of these apply:
- Fix requires changes to more than 3 files
- Fix modifies `flake.nix` inputs or `flake.lock`
- Fix requires runtime testing (service restart, visual inspection, API calls)
- Fix depends on another unfixed bug
- Issue has been open >60 days with multiple failed fix attempts in comments

---

## Phase 2: Present Plan (STOP -- wait for approval)

Print the triage table:

```
=== Sweep Bugs: Triage Plan ===

| # | Issue | Outcome | Reason | Est. Effort |
|---|-------|---------|--------|-------------|
| 1 | #NNN title | FIX | reason | N min |
| 2 | #NNN title | CLOSE | reason | 0 min |
| ... | ... | ... | ... | ... |

Bugs to fix: N (of M total)
Bugs to close: N
Bugs to skip: N
Bugs to defer: N

Shall I proceed? You can change any outcome before I start.
(e.g., "change #265 to FIX", "skip #126", "close #209", "proceed")
```

**DO NOT proceed past this phase without explicit user approval.**

If the user changes outcomes, update the table and re-confirm.

---

## Phase 3: Execute Fixes

Process approved FIX bugs in priority order:
`priority:critical` > `priority:high` > `priority:medium` > `priority:low`, then by issue age (oldest first).

**Budget:** Stop after fixing `$ARGUMENTS` bugs (default 5) or when all FIX bugs are done.

### For each FIX bug:

#### Step 3a: Setup

```bash
# Verify starting point
cd /home/nixos/nixos-config
git checkout main && git pull origin main

# Create worktree
git worktree add ../nixos-config-fix-<issue-slug> -b fix/<issue-slug>
cd ../nixos-config-fix-<issue-slug>
```

#### Step 3b: Fix with /verify-first

Run `/verify-first` -- follow the full hypothesis-test-fix-verify protocol:

1. **Hypothesis:** State root cause (from issue details) -- one sentence
2. **Test:** Design minimal check that confirms or refutes (grep, nix eval, dry-build)
3. **Run test:** If refuted, revise hypothesis (max 3 attempts)
4. **Apply fix:** Minimal change only
5. **Verify:** Re-run same test + `nix flake check`

If all 3 hypotheses are refuted, mark bug as **DEFER** and move to next bug.

#### Step 3c: PR with /review-fix-loop

Run `/review-fix-loop` -- this handles the full PR lifecycle:

- Phase 0: `nix fmt` + `nix flake check` + push + create PR
- Phase 1-2: Parallel review agents + confidence filtering
- Phase 3-4: Fix findings + re-review (max 3 loops)
- Phase 5: Poll CI + fix failures (max 2 attempts) + merge

**PR conventions:**
- Title: `fix(<area>): <description> (closes #<number>)`
- Body: must include `Closes #<number>` for auto-close

#### Step 3d: Clean up

```bash
cd /home/nixos/nixos-config
git worktree remove ../nixos-config-fix-<issue-slug>
git pull origin main   # sync merged changes before next bug
```

#### Step 3e: Close issue (if not auto-closed by PR merge)

```bash
gh issue close <number> --comment "Fixed in PR #<pr-number>"
```

#### Step 3f: Progress report

After each bug, print:
```
=== Bug N/M: #<number> <title> ===
Status: FIXED (PR #<pr>) | DEFERRED (reason) | FAILED (reason)
```

---

## Phase 4: Close CLOSE Bugs

For each bug triaged as CLOSE:
```bash
gh issue close <number> --comment "Closing: <reason>."
```

Include specific evidence (PR reference, commit hash, or `nix eval` output showing the issue is resolved).

---

## Phase 5: Summary Report

```
=== Sweep Bugs Complete ===

Fixed:    N bugs
Closed:   N bugs (already resolved)
Skipped:  N bugs (needs human action)
Deferred: N bugs (blocked/complex)
Failed:   N bugs (fix attempted but failed)

| # | Issue | Outcome | PR | Notes |
|---|-------|---------|-----|-------|
| 1 | #NNN | FIXED | #NNN | ... |
| 2 | #NNN | CLOSED | -- | reason |
| ... | ... | ... | ... | ... |

Remaining open bugs: N
```

---

## Rules

- NEVER fix a bug without user-approved triage (Phase 2 gate)
- NEVER skip `/verify-first` -- hypothesis must be confirmed before any code change
- NEVER commit to main -- always use worktree + branch
- NEVER attempt a bug that needs runtime testing without flagging the user first
- NEVER merge without CI passing (except known pre-existing failures: Python Tests, GitGuardian)
- Max 3 hypothesis attempts per bug before marking DEFER
- Max bugs per sweep: `$ARGUMENTS` (default 5)
- Always `git pull origin main` between bugs to avoid merge conflicts
- Always clean up worktrees after each bug (success or failure)
- If a bug fix breaks `nix flake check` for other hosts, revert immediately and mark DEFER
- Always verify `pwd` and `git branch --show-current` before making changes
