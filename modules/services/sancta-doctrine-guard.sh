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
  n=0
  while IFS= read -r f; do
    n=$((n + 1))
    [ -s "$repo/$f" ] || miss "missing or empty: $repo/$f"
  done < <(git -C "$repo" --no-optional-locks ls-files)
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
  committed=$(git -C "$SKILLS" --no-optional-locks ls-files -- '*/SKILL.md' 2>/dev/null | sort)
  ondisk=$(cd "$SKILLS" 2>/dev/null && for d in */; do
    b="${d%/}"
    [ -L "$b" ] && continue # home-manager symlinks are wiring, not doctrine
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

# ── 4. the settings.json hook block ────────────────────────────────────────
# `jq -e '.hooks.UserPromptSubmit'` PASSES on {"UserPromptSubmit":[]} — jq -e
# fails only on null/false. An empty array is the most likely shape of the
# 2026-07-25 10:32 regression, where a settings writer preserved the key and
# dropped the contents. So the obvious check passes on the exact bug it was
# written for. `length > 0` is the fix.
if [ -s "$CLAUDE/settings.json" ]; then
  jq -e '(.hooks.UserPromptSubmit // []) | length > 0' "$CLAUDE/settings.json" >/dev/null 2>&1 \
    || miss "settings.json lost hooks.UserPromptSubmit (empty or absent)"
fi

# ── verdict ────────────────────────────────────────────────────────────────
if [ "$fails" -gt 0 ]; then
  printf '\nsancta-doctrine-guard: %d assertion(s) FAILED\n' "$fails" >&2
  exit 1
fi
printf '\nsancta-doctrine-guard: all assertions hold\n'
exit 0
