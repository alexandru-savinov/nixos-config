{ pkgs }:
pkgs.runCommand "claude-review-report-tests"
{
  nativeBuildInputs = [ pkgs.bash pkgs.yq-go pkgs.jq pkgs.coreutils pkgs.gnugrep ];
} ''
  set -euo pipefail
  workflow=${../.github/workflows/claude-code-review.yml}
  yq -r '.jobs."claude-review".steps[] | select(.name == "Materialize review report") | .run' "$workflow" > report.sh
  yq -r '.jobs."claude-review".steps[] | select(.name == "Check review verdict") | .run' "$workflow" > verdict.sh
  test -s report.sh && test "$(tr -d '[:space:]' < report.sh)" != null
  test -s verdict.sh && test "$(tr -d '[:space:]' < verdict.sh)" != null
  # Pin the output wiring and the absence of permission expansion.
  yq -o=json '.jobs."claude-review".steps[] | select(.name == "Materialize review report")' "$workflow" |
    jq -e '.if == "always()" and (.env.REVIEW_OUTPUT | contains("outputs.structured_output")) and (.env.REVIEW_ACTION_OUTCOME | contains(".outcome"))' > /dev/null
  yq -r '.jobs."claude-review".steps[] | select(.name == "Run Claude Code Review") | .with.claude_args' "$workflow" > args
  grep -q -- '--json-schema' args
  if grep -Eq 'Bash\(gh api|Bash\(gh pr comment|Write|--dangerously-skip-permissions' args; then
    echo 'Reviewer gained a write/bypass tool' >&2
    exit 1
  fi
  bash ${./claude-review-report.sh} "$PWD/report.sh" "$PWD/verdict.sh"
  touch "$out"
''
