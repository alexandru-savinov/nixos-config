# Runs tests/claude-review-verdict.sh against the verdict step EXTRACTED FROM
# THE WORKFLOW, not against a copy of it — a copy would drift and the test would
# then be certifying a script nobody runs. Same construction as
# tests/claude-review-poster.nix, which covers this step's sibling.
#
# Run: nix build .#checks.<system>.claude-review-verdict
{ pkgs }:

let
  workflow = ../.github/workflows/claude-code-review.yml;
  harness = ./claude-review-verdict.sh;
  step = "Check review verdict";
  posterStep = "Post findings as review threads";
in
pkgs.runCommand "claude-review-verdict-tests"
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
    ${workflow} > verdict.sh

  # If the step is ever renamed or removed, yq yields "null" or nothing and the
  # harness below would pass vacuously against an empty script. Fail loudly
  # instead: a test that cannot fail is the defect it is meant to catch.
  if [ ! -s verdict.sh ] || [ "$(tr -d '[:space:]' < verdict.sh)" = "null" ]; then
    echo "ERROR: no step named '${step}' in ${builtins.baseNameOf workflow}." >&2
    echo "       The verdict gate is untested until this test is pointed at it again." >&2
    exit 1
  fi

  # ── Static: the step must still run under the shell the harness assumes ───
  # The harness invokes the extracted step as `bash -e`, because a `run:` block
  # with no `shell:` key is what GitHub runs as `bash -e {0}`. Adding
  # `shell: bash` would silently switch the real step to
  # `bash --noprofile --norc -e -o pipefail {0}` — pipefail on — and the
  # harness would go on testing it without. That divergence is invisible until
  # the step grows a pipeline, at which point the check and the runner disagree
  # about whether it failed. So the harness's assumption is asserted here
  # rather than trusted: if someone sets a shell, this fails and says what to
  # change. (Both forms are visible in one claude-review job log, which is the
  # evidence this is a real distinction and not a docs reading.)
  declared_shell=$(yq -r '.jobs."claude-review".steps[] | select(.name == "${step}") | .shell // "none"' ${workflow})
  if [ "$declared_shell" != "none" ]; then
    echo "SHELL ASSUMPTION BROKEN: the '${step}' step now declares shell: $declared_shell." >&2
    echo "tests/claude-review-verdict.sh runs it as 'bash -e', which matches the no-shell" >&2
    echo "default. An explicit 'shell: bash' adds pipefail in CI but not in the harness," >&2
    echo "so the two would disagree about any pipeline in the step. Update the harness's" >&2
    echo "invocation to match, then update this assertion." >&2
    exit 1
  fi
  echo "ok: the verdict step declares no shell, so 'bash -e' is faithful to CI"

  # ── Static: the two steps must route on the SAME severity distinction ─────
  # The behavioural cases in the harness pin what the verdict step does with a
  # severity it is shown. They cannot see the OTHER half of the invariant: that
  # the poster opens a gating thread for exactly the same set. Both steps are
  # written as a single comparison against "LOW" so that "a thread was opened"
  # and "the check is red" are one condition. Re-enumerating severities in
  # either place is how they drift apart — and the drift is silent, because
  # each step keeps working perfectly on its own. That is the shape of the bug
  # this whole change removes (a MEDIUM thread beside a green check, PR #569),
  # so it gets an assertion and not just a comment.
  yq -r '.jobs."claude-review".steps[] | select(.name == "${posterStep}") | .run' \
    ${workflow} > poster.sh
  if [ ! -s poster.sh ] || [ "$(tr -d '[:space:]' < poster.sh)" = "null" ]; then
    echo "ERROR: no step named '${posterStep}' in ${builtins.baseNameOf workflow}." >&2
    echo "       The cross-step severity invariant is untested until this is repointed." >&2
    exit 1
  fi

  # Strip comments before matching: both steps NAME the other severities in
  # their prose (and this test would be trivially defeated, or trivially
  # broken, by a comment mentioning CRITICAL). Only executable lines count.
  for pair in "verdict:verdict.sh" "poster:poster.sh"; do
    label=''${pair%%:*}
    file=''${pair##*:}
    sed 's/#.*$//' "$file" > "$file.code"
    if ! grep -q 'LOW' "$file.code"; then
      echo "SEVERITY ROUTING REGRESSION: the $label step no longer routes on \"LOW\"." >&2
      echo "Both steps must express the gating boundary as a single comparison against" >&2
      echo "LOW, so that the set that becomes a resolvable thread and the set that fails" >&2
      echo "the check are the same set by construction. See tests/claude-review-verdict.nix." >&2
      exit 1
    fi
    if grep -qE '(CRITICAL|HIGH|MEDIUM)' "$file.code"; then
      echo "SEVERITY ROUTING REGRESSION: the $label step enumerates severities in code:" >&2
      grep -nE '(CRITICAL|HIGH|MEDIUM)' "$file.code" >&2
      echo "An enumeration in one step and not the other is how a finding ends up with a" >&2
      echo "gating thread and a green check (PR #569). Route on \"not LOW\" instead." >&2
      exit 1
    fi
  done
  echo "ok: both steps route on the same LOW/not-LOW boundary"

  # Negative arm for the assertion above: it is a grep, and a grep that never
  # fires is indistinguishable from one that cannot. Prove it catches the exact
  # regression it describes before trusting any of its passes.
  printf 'blocking=$(jq %s[.[] | select(.severity == "CRITICAL")]%s f.json)\n' "'" "'" > probe.code
  if grep -qE '(CRITICAL|HIGH|MEDIUM)' probe.code; then
    echo "ok: the routing detector DOES fire on a known enumeration (self-test)"
  else
    echo "SELF-TEST FAILED: the routing detector did not flag a known enumeration;" >&2
    echo "it cannot fail, so its passes above prove nothing." >&2
    exit 1
  fi

  bash ${harness} "$PWD/verdict.sh"
  echo ok > $out
''
