#!/usr/bin/env bash
# Behaviour coverage for the "Check review verdict" step of
# .github/workflows/claude-code-review.yml.
#
# That step is the half of the merge gate that does not need a human to look.
# Its sibling — the poster step, covered by tests/claude-review-poster.sh —
# turns findings into resolvable threads, which gate only once someone reads
# them and resolves them. This step turns the same findings into a red check.
# Until 2026-08-22 it went red only on CRITICAL/HIGH, so a MEDIUM finding was
# posted and the check still passed (PR #569 is the worked example: a MEDIUM
# thread on modules/services/claude-code-managed-settings.nix:173 alongside a
# green `claude-review`). The cases below pin the new boundary in place.
#
# Every case asserts the exit code AND the message, because the failure mode
# this step exists to prevent is a silent PASS — an exit 0 that looks identical
# whether it was earned or reached by the predicate quietly matching nothing.
#
# $1 is the step's shell, extracted from the workflow YAML by the caller, so
# what is tested is what ships.
set -uo pipefail

VERDICT="${1:?usage: claude-review-verdict.sh <path-to-extracted-step>}"
VERDICT=$(readlink -f "$VERDICT")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0

# GitHub runs a `run:` block with NO explicit `shell:` key as `bash -e {0}`.
# That is specifically the no-`shell:` default; writing `shell: bash` instead
# selects `bash --noprofile --norc -e -o pipefail {0}`, which additionally sets
# pipefail. Both forms appear in one claude-review job log, which is what
# settles it rather than a reading of the docs (run 32591330468):
#
#   Check review verdict     shell: /usr/bin/bash -e {0}
#   Run Claude Code Review   shell: /usr/bin/bash --noprofile --norc -e -o pipefail {0}
#
# This step sets no `shell:` and, unlike the poster, does not `set -euo
# pipefail` itself, so it runs with -e and nothing more — and so does this
# harness. Adding `-o pipefail` here to be "safer" would be the same drift in
# the other direction: the harness would then accept or reject pipelines
# differently from the runner, which is exactly what extracting the step from
# the YAML exists to prevent. claude-review-verdict.nix asserts the step still
# declares no `shell:`, because that is the fact this invocation depends on.
run_case() {
  local name="$1" want_rc="$2" want_msg="$3"
  local out rc=0
  out=$(cd "$WORK" && bash -e "$VERDICT" 2>&1) || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "  FAIL: $name — expected exit $want_rc, got $rc"
    sed 's/^/        /' <<< "$out"
    fails=$((fails + 1))
    return 1
  fi
  if [ -n "$want_msg" ] && ! grep -qF -- "$want_msg" <<< "$out"; then
    echo "  FAIL: $name — exit $rc correct but message missing: '$want_msg'"
    sed 's/^/        /' <<< "$out"
    fails=$((fails + 1))
    return 1
  fi
  echo "  ok:   $name (exit $rc)"
  return 0
}

findings() { cat > "$WORK/review-findings.json"; }

echo "claude-code-review verdict step:"

# ── The reviewer itself failed ──────────────────────────────────────────────
# 1 — no findings file. The reviewer crashed, timed out, or never ran. This
#     MUST be red: a check that cannot tell "reviewed and found nothing" from
#     "never reviewed" is worth nothing, because the second case is the one an
#     attacker or an outage produces.
rm -f "$WORK/review-findings.json"
run_case "reviewer wrote no findings file -> exit 1" 1 "cannot derive a verdict"

# 2 — the file exists but is not the agreed shape. Same reasoning: a malformed
#     file is evidence the reviewer misbehaved, not evidence the diff is clean.
echo '{"oops": true}' > "$WORK/review-findings.json"
run_case "findings file is not a JSON array -> exit 1" 1 "cannot derive a verdict"

# ── Clean runs must stay green ──────────────────────────────────────────────
# A gate that fails on everything is not a gate, it is an outage. These two are
# the reason the predicate is "not LOW" and not "non-empty".
# 3 — a genuinely clean review.
findings <<'EOF'
[]
EOF
run_case "no findings at all -> exit 0" 0 "verdict: PASS"

# 4 — LOW findings only. LOW is bundled into one advisory comment by the poster
#     and is explicitly not something anyone must act on, so it must not turn
#     the check red or every style nit becomes a merge blocker.
findings <<'EOF'
[
  {"severity":"LOW","path":"a.nix","line":3,"side":"RIGHT","body":"**LOW** — style nit"},
  {"severity":"low","path":"b.nix","line":4,"side":"RIGHT","body":"**LOW** — lowercase severity"}
]
EOF
run_case "LOW findings only -> exit 0, stays green" 0 "verdict: PASS"

# ── THE CHANGE: MEDIUM blocks ───────────────────────────────────────────────
# 5 — the case this whole test exists for. Before 2026-08-22 this exited 0 with
#     "verdict: PASS — no CRITICAL/HIGH findings" while the poster had already
#     opened a gating thread for the same finding. Run this harness against the
#     previous revision of the workflow and THIS is the case that goes red; that
#     is the proof the test discriminates rather than passing along with
#     everything else.
findings <<'EOF'
[{"severity":"MEDIUM","path":"modules/services/x.nix","line":173,"side":"RIGHT","body":"**MEDIUM** — unverified precedence semantics"}]
EOF
if run_case "MEDIUM finding -> exit 1 (the 2026-08-22 change)" 1 "above LOW"; then
  # The human reading a red check has to be able to find the finding without
  # opening the job log and reading jq. Failing red while naming nothing is
  # only marginally better than passing green.
  out=$(cd "$WORK" && bash -e "$VERDICT" 2>&1) || true
  if grep -qF 'modules/services/x.nix:173' <<< "$out"; then
    echo "  ok:   the blocking finding is named with path:line in the output"
  else
    echo "  FAIL: the check went red without naming which finding blocked it"
    sed 's/^/        /' <<< "$out"
    fails=$((fails + 1))
  fi
fi

# 6 — severity spelling must not be a way through. The poster upcases with `tr`
#     before testing for LOW; this step uses jq's ascii_upcase. They have to
#     agree, or a finding gets a thread and a green check (or a bundle and a red
#     one).
findings <<'EOF'
[{"severity":"medium","path":"a.nix","line":9,"side":"RIGHT","body":"**MEDIUM** — lowercase severity"}]
EOF
run_case "lowercase 'medium' -> exit 1" 1 "above LOW"

# ── The severities that already blocked must keep blocking ──────────────────
# Widening the predicate is the kind of edit that can accidentally narrow it.
for sev in HIGH CRITICAL; do
  findings <<EOF
[{"severity":"$sev","path":"a.nix","line":12,"side":"RIGHT","body":"**$sev** — regression guard"}]
EOF
  run_case "$sev finding -> exit 1 (unchanged behaviour)" 1 "above LOW"
done

# ── Fail closed on anything unrecognised ────────────────────────────────────
# 7 — a severity nobody enumerated. The old predicate listed CRITICAL and HIGH,
#     so `MED` was silently non-blocking while the poster still opened a thread
#     for it. Stating the predicate as "not LOW" closes that by construction —
#     these two cases are what proves it closed, rather than the comment saying
#     it did.
findings <<'EOF'
[{"severity":"MED","path":"a.nix","line":5,"side":"RIGHT","body":"typo'd severity"}]
EOF
run_case "unrecognised severity 'MED' -> exit 1 (fails closed)" 1 "above LOW"

# 8 — no severity field at all.
findings <<'EOF'
[{"path":"a.nix","line":5,"side":"RIGHT","body":"no severity field"}]
EOF
if run_case "missing severity field -> exit 1 (fails closed)" 1 "above LOW"; then
  out=$(cd "$WORK" && bash -e "$VERDICT" 2>&1) || true
  # jq's `\(.severity)` renders a missing field as the four letters "null",
  # which reads in the log like a severity someone actually wrote. The step
  # substitutes a legible placeholder; if that regresses, a human debugging a
  # red check is sent looking for a severity level that does not exist.
  if grep -qF '<no severity>' <<< "$out"; then
    echo "  ok:   a missing severity is reported legibly, not as 'null'"
  else
    echo "  FAIL: a missing severity is not reported legibly"
    sed 's/^/        /' <<< "$out"
    fails=$((fails + 1))
  fi
fi

# 8b — a severity that is not a string at all. `.severity | ascii_upcase`
#      throws on a number or an array, and the step would then die on a raw jq
#      stack trace instead of the `::error::` path — red, but illegibly so, and
#      the poster meanwhile routes it to a thread perfectly happily because
#      `jq -r` rendered it to text first. `tostring` makes both steps see the
#      same string. Asserting the MESSAGE, not just the exit code, is the whole
#      point of this case: without it, the pre-`tostring` crash passes too.
findings <<'EOF'
[{"severity":42,"path":"a.nix","line":5,"side":"RIGHT","body":"severity is a number"}]
EOF
run_case "non-string severity -> exit 1 via the ::error:: path, not a jq crash" 1 "above LOW"

# 8c — case-insensitivity is DELIBERATE, and this case exists to say so out
#      loud, because it reads like a hole and was raised as one in review of
#      this very change (PR #573, chatgpt-codex-connector). The poster has
#      always upcased with `tr` before testing for LOW, and its own suite pins
#      lowercase `low` as a legitimate advisory finding. Tightening only this
#      step to an exact-enum match would split the two apart again — a `low`
#      finding would be bundled as advisory AND fail the check — which is the
#      precise drift this change exists to remove. It is also not a bypass: a
#      reviewer intent on burying a finding writes `LOW`, not `low`. So the two
#      steps stay case-insensitive TOGETHER, and this case fails if one of them
#      is ever tightened alone.
findings <<'EOF'
[{"severity":"Low","path":"a.nix","line":7,"side":"RIGHT","body":"**LOW** — mixed case, still advisory"}]
EOF
run_case "mixed-case 'Low' -> exit 0 (matches the poster, deliberately)" 0 "verdict: PASS"

# ── Counting ────────────────────────────────────────────────────────────────
# 9 — LOW must not be counted among the blockers. If it were, the count in the
#     error message would overstate the work and — worse — the same off-by-LOW
#     error in the other direction is what case 4 guards.
findings <<'EOF'
[
  {"severity":"LOW","path":"a.nix","line":1,"side":"RIGHT","body":"**LOW** — nit"},
  {"severity":"LOW","path":"a.nix","line":2,"side":"RIGHT","body":"**LOW** — nit"},
  {"severity":"MEDIUM","path":"b.nix","line":3,"side":"RIGHT","body":"**MEDIUM** — real"}
]
EOF
run_case "2 LOW + 1 MEDIUM -> exit 1, counts only the MEDIUM" 1 "found 1 blocking finding"

# ── Self-test: this harness must be able to fail ────────────────────────────
# 10 — every assertion above is `run_case`, so if `run_case` could not fail,
#      the entire file would be a green rubber stamp — the same defect class it
#      is testing for, one level up. Feed it a case whose expectation is known
#      to be wrong and confirm it reports a failure, then undo the bookkeeping.
findings <<'EOF'
[]
EOF
before=$fails
run_case "SELF-TEST (expected to fail: clean run asserted as exit 1)" 1 "" > /dev/null 2>&1 || true
if [ "$fails" -gt "$before" ]; then
  fails=$before
  echo "  ok:   the harness DOES report a failure when an assertion is wrong (self-test)"
else
  echo "  FAIL: SELF-TEST FAILED — run_case did not flag a knowingly wrong expectation;"
  echo "        it cannot fail, so every 'ok' above proves nothing"
  fails=$((before + 1))
fi

echo
if [ "$fails" -ne 0 ]; then
  echo "claude-review-verdict: $fails case(s) FAILED" >&2
  exit 1
fi
echo "claude-review-verdict: all assertions hold"
