#!/usr/bin/env bash
# Refresh the cached state the Claude Code status bar renders.
#
# The bar runs on EVERY prompt, so it must never do this work itself: no network,
# no systemctl, no gh. It reads one JSON file. This fills that file.
#
# WHY THIS EXISTS
# ---------------
# 2026-08-01: the bar was rewritten to show Alexandru's open asks instead of the
# agent's token spend, and the refresher was never written. It rendered a
# 15-hour-old snapshot while looking current — six PRs when there were fourteen.
# The only reason it was visible at all is that the bar carries its own staleness
# marker; the number itself looked perfectly plausible.
#
# Contract:
#   SANCTA_STATUSLINE_STATE   required — the JSON file to update, in place
#   SANCTA_STATUSLINE_REPO    required — owner/name of the repo whose PRs are "asks"
#   SANCTA_STATUSLINE_UNITS   optional — space-separated units to report on
#
# Exit 0 = the file now holds fresh state. Exit 1 = it was left exactly as it
# was. Never a partial write: a half-refreshed bar is worse than a stale one,
# because staleness is visible and partial truth is not.

set -uo pipefail

STATE="${SANCTA_STATUSLINE_STATE:-}"
REPO="${SANCTA_STATUSLINE_REPO:-}"
UNITS="${SANCTA_STATUSLINE_UNITS:-}"

if [ -z "$STATE" ] || [ -z "$REPO" ]; then
  echo "statusline-refresh: SANCTA_STATUSLINE_STATE and SANCTA_STATUSLINE_REPO are required" >&2
  exit 1
fi
if [ ! -r "$STATE" ]; then
  echo "statusline-refresh: cannot read $STATE — refusing to create one from nothing, because the schema note and any human-set deadline live in it" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# ── his asks: open PRs waiting on a human ──────────────────────────────────
# ready_now = the ones that cost him a click rather than an evening. THREE
# conditions, and the third was missing on the first day this ran:
#
#   1. no failing or pending checks
#   2. no unresolved review threads
#   3. GitHub would actually accept the merge
#
# Without (3) the bar reported seven clean and four of them had merge conflicts
# or were behind main — one was on an explicit hold. Green checks on a branch
# that cannot land is not readiness, and presenting it as such sends him to a
# PR that will refuse him. BLOCKED is the one state that DOES belong here: it is
# what GitHub says when the only thing missing is his approval.
#
# ABSENT DATA IS NOT GOOD NEWS. A PR enters ready_now only when every query came
# back and every one was satisfied. A failed call leaves it out, so a broken API
# path under-reports readiness instead of inventing it.
review='[]'
ready='[]'
owner="${REPO%%/*}"
name="${REPO##*/}"

nums=$(gh pr list --repo "$REPO" --state open --json number --jq '[.[].number] | sort' 2>/dev/null) || nums=''
if [ -n "$nums" ] && [ "$nums" != "[]" ]; then
  review="$nums"
  r='[]'
  for n in $(jq -r '.[]' <<< "$nums"); do
    meta=$(gh pr view "$n" --repo "$REPO" --json statusCheckRollup,mergeStateStatus,isDraft \
           --jq '[
             ([.statusCheckRollup[]? | select((.conclusion // "") | IN("SUCCESS","SKIPPED","NEUTRAL") | not)] | length | tostring),
             (.mergeStateStatus // "UNKNOWN"),
             (.isDraft | tostring)
           ] | @tsv' 2>/dev/null)
    [ -z "$meta" ] && continue
    IFS=$'\t' read -r bad mergestate draft <<< "$meta"

    thr=$(gh api graphql -f query="{repository(owner:\"$owner\",name:\"$name\"){pullRequest(number:$n){reviewThreads(first:60){nodes{isResolved}}}}}" \
          --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length' 2>/dev/null)

    if [ "${bad:-1}" = "0" ] \
      && [ "${thr:-1}" = "0" ] \
      && [ "${draft:-true}" = "false" ] \
      && { [ "${mergestate:-X}" = "CLEAN" ] || [ "${mergestate:-X}" = "BLOCKED" ] || [ "${mergestate:-X}" = "UNSTABLE" ]; }; then
      r=$(jq --argjson n "$n" '. + [$n]' <<< "$r")
    fi
  done
  ready="$r"
fi

# ── units: declared, and expected to be running ────────────────────────────
# An unknown state is reported as "unknown", never as "active". The bar shows
# anything that is not active in the down list, so an unreadable unit surfaces
# rather than disappearing.
units='{}'
for u in $UNITS; do
  s=$(systemctl is-active "$u" 2>/dev/null || true)
  [ -z "$s" ] && s="unknown"
  units=$(jq --arg u "$u" --arg s "$s" '. + {($u): $s}' <<< "$units")
done

# ── sidequests ─────────────────────────────────────────────────────────────
sqbin="$(dirname "$STATE")/bin/sidequest"
sq=0
[ -x "$sqbin" ] && sq=$("$sqbin" list 2>/dev/null | grep -c '^sq' || echo 0)

# ── write ──────────────────────────────────────────────────────────────────
# `deadline` is the HUMAN's field — a countdown he set. This script must never
# create, alter or clear it. Same for the `_schema` and `_meaning` notes: they
# explain why the file has the shape it has, and losing them would leave the
# next reader guessing at constraints that were argued for.
jq \
  --argjson review "$review" \
  --argjson ready "$ready" \
  --argjson units "$units" \
  --argjson sq "${sq:-0}" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '
    .updated = $now
  | .asks.review = $review
  | .asks.ready_now = $ready
  | .sidequests_open = $sq
  | .units = ((.units | with_entries(select(.key | startswith("_")))) + $units)
  ' "$STATE" > "$TMP" 2>/dev/null || {
  echo "statusline-refresh: could not build new state; leaving $STATE untouched" >&2
  exit 1
}

# Validate before replacing. jq exiting 0 on a malformed merge is not something
# to find out about via a status bar that has quietly stopped meaning anything.
jq -e '(.asks.review | type == "array") and (.asks.ready_now | type == "array") and (.updated | type == "string")' \
  "$TMP" > /dev/null 2>&1 || {
  echo "statusline-refresh: produced malformed state; leaving $STATE untouched" >&2
  exit 1
}

cat "$TMP" > "$STATE"

jq -c '{
  updated,
  asks: (.asks.review | length),
  clean: (.asks.ready_now | length),
  sidequests_open,
  down: [.units | to_entries[] | select((.key | startswith("_") | not) and .value != "active") | .key]
}' "$STATE"
