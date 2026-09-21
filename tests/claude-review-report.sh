#!/usr/bin/env bash
set -euo pipefail
report_step=$(readlink -f "$1")
verdict_step=$(readlink -f "$2")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

reject() {
  local name=$1 output=$2 outcome=${3:-success}
  # A stale clean report must never survive a failed materialization.
  echo '[]' > review-findings.json
  if REVIEW_OUTPUT="$output" REVIEW_ACTION_OUTCOME="$outcome" bash -e "$report_step" >log 2>&1; then
    echo "FAIL: $name accepted" >&2; exit 1
  fi
  test ! -e review-findings.json
  grep -q '::error::' log
  ! grep -q 'private-fixture-marker' log
  if bash -e "$verdict_step" >verdict.log 2>&1; then
    echo "FAIL: $name left a passing verdict" >&2; exit 1
  fi
  echo "ok: $name fails closed"
}

reject absent ''
reject malformed '{private-fixture-marker'
reject prose 'private-fixture-marker'
reject null null
reject missing-array '{}'
reject wrong-array '{"findings":{}}'
reject extra-root '{"findings":[],"extra":"private-fixture-marker"}'
reject multiple-results '{"findings":[]} {"findings":[]}'
reject missing-fields '{"findings":[{"severity":"HIGH"}]}'
reject failed-action '{"findings":[]}' failure
reject cancelled-action '{"findings":[]}' cancelled

finding='{"severity":"MEDIUM","path":"file.nix","line":1,"side":"RIGHT","body":"**MEDIUM** — literal $(touch injected), `touch injected`, @claude and quotes: \"fixture\""}'
valid=$(jq -cn --argjson f "$finding" '{findings:[$f]}')
for mutation in '.findings[0].severity="UNKNOWN"' '.findings[0].line=0' '.findings[0].line=1.5' '.findings[0].side="OTHER"' '.findings[0].body=null' '.findings[0].path=""' '.findings[0].extra=true'; do
  reject invalid-field "$(jq -c "$mutation" <<< "$valid")"
done

REVIEW_OUTPUT="$valid" REVIEW_ACTION_OUTCOME=success bash -e "$report_step"
test ! -e injected
jq -e --argjson f "$finding" '. == [$f]' review-findings.json >/dev/null
if bash -e "$verdict_step" >verdict.log 2>&1; then
  echo 'FAIL: a materialized MEDIUM finding must block' >&2; exit 1
fi
grep -q 'blocking (non-LOW) findings: 1' verdict.log
echo 'ok: findings preserved literally and MEDIUM still blocks'

REVIEW_OUTPUT='{"findings":[]}' REVIEW_ACTION_OUTCOME=success bash -e "$report_step"
jq -e '. == []' review-findings.json >/dev/null
bash -e "$verdict_step" >verdict.log
grep -q 'verdict: PASS' verdict.log
echo 'ok: explicit complete empty result passes'
