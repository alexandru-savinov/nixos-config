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
