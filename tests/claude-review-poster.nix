# Runs tests/claude-review-poster.sh against the poster step EXTRACTED FROM THE
# WORKFLOW, not against a copy of it — a copy would drift and the test would
# then be certifying a script nobody runs.
#
# Run: nix build .#checks.<system>.claude-review-poster
{ pkgs }:

let
  workflow = ../.github/workflows/claude-code-review.yml;
  harness = ./claude-review-poster.sh;
  step = "Post findings as review threads";
  reviewStep = "Run Claude Code Review";
in
pkgs.runCommand "claude-review-poster-tests"
{
  nativeBuildInputs = [
    pkgs.bash
    pkgs.yq-go
    pkgs.jq
    pkgs.gnugrep
    pkgs.gnused
    pkgs.coreutils
  ];
} ''
  set -euo pipefail

  # ── Static: the reviewing agent must hold NO raw PR-comment channel ──────
  # This is the structural half of the LOW-comment-bypass fix (a CRITICAL
  # found on this PR's own claude-review run, 2026-08-19): the model cannot
  # emit an unfiltered `@claude` if it has no tool that posts to the PR at
  # all except by writing review-findings.json, which the poster step below
  # defuses for every severity. A test that only checks the poster's own
  # defusal behavior (below) would miss a regression that just re-grants the
  # comment tool next to it — so this is a SEPARATE assertion, on a
  # different part of the workflow, not a restatement of the same check.
  claude_args=$(yq -r '.jobs."claude-review".steps[] | select(.name == "${reviewStep}") | .with.claude_args' ${workflow})
  if [ -z "$claude_args" ] || [ "$claude_args" = "null" ]; then
    echo "ERROR: could not extract claude_args from ${builtins.baseNameOf workflow} — the step may have been renamed." >&2
    echo "       The claude_args guard is untested until this test is pointed at it again." >&2
    exit 1
  fi
  if grep -qi 'gh pr comment' <<< "$claude_args"; then
    echo "SECURITY REGRESSION: claude_args grants a raw 'gh pr comment' channel." >&2
    echo "The reviewing agent reads an attacker-influenced PR diff and can therefore be" >&2
    echo "prompt-injected into emitting an unfiltered @claude mention through it — the" >&2
    echo "exact CRITICAL this grant's removal closes. See the NOTE above claude_args in" >&2
    echo "${builtins.baseNameOf workflow}." >&2
    exit 1
  fi
  echo "ok: claude_args holds no raw PR-comment channel"

  yq -r '.jobs."claude-review".steps[] | select(.name == "${step}") | .run' \
    ${workflow} > poster.sh

  # If the step is ever renamed or removed, yq yields "null" or nothing and the
  # harness below would pass vacuously against an empty script. Fail loudly
  # instead: a test that cannot fail is the defect it is meant to catch.
  if [ ! -s poster.sh ] || [ "$(tr -d '[:space:]' < poster.sh)" = "null" ]; then
    echo "ERROR: no step named '${step}' in ${builtins.baseNameOf workflow}." >&2
    echo "       The poster is untested until this test is pointed at it again." >&2
    exit 1
  fi

  bash ${harness} "$PWD/poster.sh"
  echo ok > $out
''
