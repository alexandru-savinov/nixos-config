#!/usr/bin/env bash
# sancta-doctrine-guard — assert the authored substrate is present and recoverable.
#
# A plain script rather than an inline Nix string so tests/sancta-doctrine-guard.nix
# can exercise its branches against fixture trees. Tools come from PATH; the unit
# supplies them via systemd `path`, the test via nativeBuildInputs.
#
# Contract:
#   SANCTA_DOCTRINE_ROOT      required — the soul root to assert against
#   SANCTA_DOCTRINE_REQUIRE_MOUNT=1  optional — refuse to run unless that root is
#                             a mountpoint. The unit sets it; tests do not. This
#                             is belt-and-braces only: the real gate is systemd's
#                             ConditionPathIsMountPoint, which no env var reaches.
#
# Exit 0 = every assertion holds. Exit 1 = at least one failed; all are printed.
#
# Proves existence and recoverability. NOT correctness: a committed file edited
# to garbage will not fire. Named here rather than hidden.

set -uo pipefail

CLAUDE="${SANCTA_DOCTRINE_ROOT:-}"
if [ -z "$CLAUDE" ]; then
  echo "FAIL: SANCTA_DOCTRINE_ROOT is unset" >&2
  exit 1
fi
SKILLS="$CLAUDE/skills"
LENSES="$CLAUDE/lenses"

export GIT_OPTIONAL_LOCKS=0 # the unit runs read-only over the volume

fails=0
miss() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
note() { printf 'ok:   %s\n' "$*"; }

# ── 0. the volume itself ───────────────────────────────────────────────────
if [ "${SANCTA_DOCTRINE_REQUIRE_MOUNT:-0}" = "1" ] && ! mountpoint -q "$CLAUDE"; then
  echo "SKIP: $CLAUDE is not a mountpoint — soul volume not mounted" >&2
  exit 0
fi

# ── 1. tracked: derived from git, never typed ──────────────────────────────
skills_usable=1
for repo in "$SKILLS" "$LENSES"; do
  if [ ! -d "$repo/.git" ]; then
    miss "not a git repo: $repo"
    [ "$repo" = "$SKILLS" ] && skills_usable=0
    continue
  fi

  # Capture status separately from output. `git ls-files` can fail for reasons
  # that are NOT "the repo is empty" — most realistically "detected dubious
  # ownership" if the volume's uid/gid ever drifts from the unit's User=.
  # Reporting that as "no tracked files at all" would send whoever is reading
  # this down a repo-is-empty path when the real answer is ownership.
  if ! listing=$(git -C "$repo" --no-optional-locks ls-files 2>&1); then
    miss "git ls-files FAILED in $repo (not an empty repo — check ownership/permissions): $listing"
    [ "$repo" = "$SKILLS" ] && skills_usable=0
    continue
  fi

  n=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    n=$((n + 1))
    [ -s "$repo/$f" ] || miss "missing or empty: $repo/$f"
  done <<<"$listing"

  if [ "$n" -eq 0 ]; then
    miss "no tracked files at all in $repo"
    [ "$repo" = "$SKILLS" ] && skills_usable=0
  fi
  note "$(basename "$repo"): $n tracked entries asserted"
done

# ── 2. drift — FATAL ───────────────────────────────────────────────────────
# Guarded on skills_usable: with the skills repo missing, BOTH sides degrade to
# the empty string and compare equal — so the worst case (whole tree gone) would
# print a reassuring "committed set == on-disk set" into the very journal
# someone is reading to diagnose the failure. A comforting line beside a failure
# is how a real signal gets talked away.
if [ "$skills_usable" -eq 0 ]; then
  note "drift: SKIPPED — skills repo unusable (see failures above)"
else
  # :(glob) is load-bearing: git's DEFAULT pathspec is wildmatch, where a bare *
  # crosses '/', so '*/SKILL.md' would also match a/b/SKILL.md while the on-disk
  # side below enumerates exactly one level. The two sets would then disagree
  # permanently and drift would fire forever, unfixable by renaming - the
  # cry-wolf outcome this module exists to avoid.
  committed=$(git -C "$SKILLS" --no-optional-locks ls-files -- ':(glob)*/SKILL.md' 2>/dev/null | sort)
  ondisk=$(cd "$SKILLS" 2>/dev/null && for d in */; do
    b="${d%/}"
    # home-manager symlinks are wiring, not doctrine. In production these point
    # at REAL store directories, so they DO match the */ glob above and this
    # skip is load-bearing: without it every symlinked skill would be reported
    # as "on disk but NEVER COMMITTED" on every run, and a guard that cries
    # wolf gets muted. (A *dangling* symlink never matches */ at all, which is
    # why the test fixture must use a resolvable one to cover this line.)
    [ -L "$b" ] && continue
    [ -f "$b/SKILL.md" ] && echo "$b/SKILL.md"
  done | sort)

  if [ "$committed" != "$ondisk" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in
        \>*) miss "skill on disk but NEVER COMMITTED: ${line#> }" ;;
        \<*) miss "skill committed but missing from disk: ${line#< }" ;;
      esac
    done < <(diff <(echo "$committed") <(echo "$ondisk") | grep -E '^[<>]')
  else
    note "drift: committed set == on-disk set"
  fi
fi

# ── 2b. drift in the LENSES repo — also FATAL ──────────────────────────────
# Section 1 catches a lens that was committed and then vanished. It cannot catch
# the opposite: a lens WRITTEN but never committed — and that half is exactly
# how the 2026-07-21 loss happened. The six assessors sat on disk for days and
# nothing minded, because nothing was tracking them.
#
# Skills are directories with a manifest, so their on-disk set is `*/SKILL.md`.
# Lenses are flat markdown at the repo root, so theirs is `*.md`, compared
# against the tracked set filtered the same way. Nested paths (bin/, any future
# subdirectory) stay covered by section 1's existence check and deliberately not
# by this one — widening it would make the two sets disagree by construction and
# the guard would cry wolf on every run.
if [ ! -d "$LENSES/.git" ]; then
  note "lens drift: SKIPPED — lenses repo unusable (see failures above)"
else
  lens_committed=$(git -C "$LENSES" --no-optional-locks ls-files -- ':(glob)*.md' 2>/dev/null | sort)
  lens_ondisk=$(cd "$LENSES" 2>/dev/null && for f in *.md; do
    [ -e "$f" ] || continue # no matches leaves the pattern itself; skip it
    [ -L "$f" ] && continue # symlinks are wiring, same rule as skills
    echo "$f"
  done | sort)

  if [ "$lens_committed" != "$lens_ondisk" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in
        \>*) miss "lens on disk but NEVER COMMITTED: ${line#> }" ;;
        \<*) miss "lens committed but missing from disk: ${line#< }" ;;
      esac
    done < <(diff <(echo "$lens_committed") <(echo "$lens_ondisk") | grep -E '^[<>]')
  else
    note "lens drift: committed set == on-disk set"
  fi
fi

# ── 3. present: lives outside both repos. Small, static. ───────────────────
# This list does NOT grow when a skill is added — that half is derived above.
for p in "$CLAUDE/settings.json" "$CLAUDE/CLAUDE.md"; do
  [ -s "$p" ] || miss "missing or empty: $p"
done
# The three PUBLIC voting assessors, reached THROUGH the council symlink and
# never via a hardcoded target, so the contract survives claude-shared being
# relaid out internally. These are the only entries that cannot be derived:
# they live outside both private repos, so no `git ls-files` reaches them.
for a in compliance opportunity risk; do
  p="$SKILLS/council/assessors/$a.md"
  [ -s "$p" ] || miss "missing or empty public assessor: council/assessors/$a.md"
done

# ── 4. hooks.UserPromptSubmit + statusLine — asserted on the EFFECTIVE config ──
# `jq -e '.hooks.UserPromptSubmit'` PASSES on {"UserPromptSubmit":[]} — jq -e
# fails only on null/false. An empty array is the most likely shape of the
# 2026-07-25 10:32 regression, where a settings writer preserved the key and
# dropped the contents. So the obvious check passes on the exact bug it was
# written for. `length > 0` is the fix.
#
# 2026-08-20 retarget (PR #569, finding P1): before claude-code-managed-settings
# existed, ~/.claude/settings.json WAS the only copy of these two keys, so
# checking it here was checking the real thing. That module now renders the
# authoritative copy to /etc/claude-code/managed-settings.json specifically
# BECAUSE the interactive harness proved (twice, same day) that it rewrites
# settings.json from a stale in-memory copy and erases any key added after the
# session started — the managed file is immune to that by design, read fresh
# off disk every time. Continuing to require these two keys in settings.json
# after that module ships would make this guard fail EVERY DAY: the file it
# is guarding is now allowed — expected — to go without them. A guard that
# cries wolf on a known-benign state gets muted within a fortnight (this
# module's own header, rule 3), and a muted guard is worse than none. So the
# source of truth here follows the SAME precedence Claude Code itself applies:
# the managed file when it exists and parses, the user file as a fallback for
# a host that has not enabled that module (or mid-migration).
#
# When the managed file exists and parses, it is AUTHORITATIVE for this check
# — not a first-of-two-tries fallback source. A managed file that renders but
# has lost a key is a real regression in that module and must fail here even
# if settings.json happens to still carry a stale copy of the same key from
# before the module was enabled; treating the user file as a safety net in
# that case would hide exactly the class of loss this guard exists to catch.
#
# Validity is checked FIRST, per file, and reported distinctly from key-loss:
# malformed JSON and hooks-were-stripped are different incidents with
# different fixes, and giving them the same message would send whoever reads
# it looking for the wrong one.
#
# The two key checks below (hooks.UserPromptSubmit, statusLine) are SIBLINGS,
# not an elif chain: they are independent keys with independent failure
# histories, and this file's own contract is "exit 1 = at least one failed;
# all are printed" — chaining them would let one loss silently hide the other
# from the same run's output.
MANAGED="${SANCTA_DOCTRINE_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"

managed_valid=0
if [ -s "$MANAGED" ]; then
  if jq -e . "$MANAGED" >/dev/null 2>&1; then
    managed_valid=1
  else
    miss "managed settings ($MANAGED) is not valid JSON (parse error — NOT the hooks regression)"
  fi
fi

user_valid=0
if [ -s "$CLAUDE/settings.json" ]; then
  if jq -e . "$CLAUDE/settings.json" >/dev/null 2>&1; then
    user_valid=1
  else
    miss "settings.json is not valid JSON (parse error — NOT the hooks regression)"
  fi
fi

# $1 = key label (for messages)   $2 = jq boolean predicate   $3 = loss message
check_effective_key() {
  keylabel="$1" pred="$2" losemsg="$3"
  if [ "$managed_valid" = 1 ] && jq -e "$pred" "$MANAGED" >/dev/null 2>&1; then
    note "$keylabel present in managed settings ($MANAGED)"
    return
  fi
  if [ "$managed_valid" = 1 ]; then
    # Managed file exists and parses but does not have this key: authoritative
    # and failing — no fallback to the user file (see the note above this
    # function; falling back here would mask the exact regression this exists
    # to catch).
    miss "$losemsg — managed settings ($MANAGED) present but missing $keylabel"
    return
  fi
  # No usable managed file (absent, empty, or malformed — already reported
  # above if malformed): fall back to settings.json, the pre-managed-module
  # source of truth, for a host that has not enabled that module yet.
  if [ "$user_valid" = 1 ] && jq -e "$pred" "$CLAUDE/settings.json" >/dev/null 2>&1; then
    note "$keylabel present in settings.json (no usable managed file on this host)"
    return
  fi
  miss "$losemsg — checked both managed ($MANAGED) and user ($CLAUDE/settings.json) settings; $keylabel missing/empty in both"
}

check_effective_key "hooks.UserPromptSubmit" \
  '(.hooks.UserPromptSubmit // []) | length > 0' \
  "lost hooks.UserPromptSubmit (empty or absent)"

# Twin of the hooks check, same shape of bug: the Aug-7 eater took the
# statusLine key once already (statusline died silently for 12 days before
# anyone noticed the bar had gone quiet, not loud) — `length > 0` so an
# empty-string command, not just a missing key, also fires.
check_effective_key "statusLine" \
  '.statusLine.command // "" | length > 0' \
  "lost statusLine (the Aug-7 eater took this once; statusline died 12 days)"

# ── verdict ────────────────────────────────────────────────────────────────
if [ "$fails" -gt 0 ]; then
  printf '\nsancta-doctrine-guard: %d assertion(s) FAILED\n' "$fails" >&2
  exit 1
fi
printf '\nsancta-doctrine-guard: all assertions hold\n'
exit 0
