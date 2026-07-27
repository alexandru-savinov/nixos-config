# Branch coverage for modules/services/sancta-doctrine-guard.sh.
#
# The guard exists because on 2026-07-21 six files vanished and nothing was
# capable of noticing. A guard that cannot itself be shown to FAIL would be the
# same problem with better paperwork — so every case below asserts a non-zero
# exit and the specific message, not merely "it ran".
{ pkgs }:

let
  guard = ../modules/services/sancta-doctrine-guard.sh;
in
pkgs.runCommand "sancta-doctrine-guard-tests"
{
  nativeBuildInputs = [
    pkgs.bash
    pkgs.git
    pkgs.jq
    pkgs.diffutils
    pkgs.util-linux
    pkgs.gnugrep
    pkgs.coreutils
  ];
}
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    git config --global user.email "test@example.com"
    git config --global user.name "test"
    git config --global init.defaultBranch main

    # Build a fixture soul root that the guard should find fully healthy.
    mkfixture() {
      root="$1"
      rm -rf "$root"
      mkdir -p "$root/skills/alpha" "$root/skills/beta" "$root/lenses"
      mkdir -p "$root/skills/council/assessors"

      echo "# alpha" > "$root/skills/alpha/SKILL.md"
      echo "# beta"  > "$root/skills/beta/SKILL.md"
      for a in compliance opportunity risk; do
        echo "# $a" > "$root/skills/council/assessors/$a.md"
      done
      echo "# claude" > "$root/CLAUDE.md"
      echo '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"date"}]}]}}' \
        > "$root/settings.json"
      echo "# a lens" > "$root/lenses/somelens.md"

      git -C "$root/skills" init -q
      git -C "$root/skills" add alpha/SKILL.md beta/SKILL.md
      git -C "$root/skills" commit -q -m "fixture"
      git -C "$root/lenses" init -q
      git -C "$root/lenses" add somelens.md
      git -C "$root/lenses" commit -q -m "fixture"
    }

    run() { SANCTA_DOCTRINE_ROOT="$1" bash ${guard}; }

    expect_pass() {
      if ! res=$(run "$1" 2>&1); then
        echo "EXPECTED PASS but guard failed:"; echo "$res"; exit 1
      fi
      echo "  ok: $2"
    }

    expect_fail() {
      root="$1"; want="$2"; label="$3"
      if res=$(run "$root" 2>&1); then
        echo "EXPECTED FAIL but guard passed: $label"; echo "$res"; exit 1
      fi
      if ! echo "$res" | grep -qF "$want"; then
        echo "FAILED for the wrong reason: $label"
        echo "  wanted substring: $want"
        echo "$res"; exit 1
      fi
      echo "  ok: $label"
    }

    R="$TMPDIR/root"

    echo "== positive =="
    mkfixture "$R"
    expect_pass "$R" "healthy fixture passes"

    echo "== the 2026-07-21 failure: a tracked file vanishes =="
    mkfixture "$R"; rm "$R/lenses/somelens.md"
    expect_fail "$R" "missing or empty" "deleted lens file fires"

    echo "== a tracked file emptied rather than deleted =="
    mkfixture "$R"; : > "$R/skills/alpha/SKILL.md"
    expect_fail "$R" "missing or empty" "empty SKILL.md fires"

    echo "== drift: a skill on disk that was never committed (FATAL) =="
    mkfixture "$R"; mkdir -p "$R/skills/gamma"; echo "# g" > "$R/skills/gamma/SKILL.md"
    expect_fail "$R" "NEVER COMMITTED" "uncommitted skill is fatal, not a warning"

    echo "== drift: committed but gone from disk =="
    mkfixture "$R"; rm -rf "$R/skills/beta"
    expect_fail "$R" "missing from disk" "deleted committed skill fires"

    echo "== lens drift: a lens on disk that was never committed (FATAL) =="
    # Section 1 only catches a lens that was committed and then vanished. This
    # is the other half — and it is the half that actually happened on
    # 2026-07-21, when six assessors sat on disk for days untracked.
    mkfixture "$R"; echo "# uncommitted" > "$R/lenses/ghost.md"
    expect_fail "$R" "lens on disk but NEVER COMMITTED" "uncommitted lens is fatal"

    echo "== lens drift: committed but gone from disk =="
    mkfixture "$R"; rm -f "$R/lenses/somelens.md"
    expect_fail "$R" "missing or empty" "deleted committed lens fires"

    echo "== lens drift: a nested path must NOT trip it =="
    # bin/ and any future subdirectory are covered by section 1's existence
    # check, deliberately not by the flat *.md comparison — otherwise the two
    # sets disagree by construction and the guard cries wolf on every run.
    mkfixture "$R"; mkdir -p "$R/lenses/bin"; echo "#!/bin/sh" > "$R/lenses/bin/tool.sh"
    expect_pass "$R" "an untracked NESTED file does not trip lens drift"

    echo "== symlinked skills are wiring, not doctrine — must NOT drift =="
    # The symlink MUST resolve. Bash's `for d in */` stats each entry, so a
    # DANGLING symlink never matches the glob at all — an earlier version of
    # this test used /nonexistent-store-path and therefore passed without ever
    # executing the `[ -L ] && continue` line it claimed to cover. In production
    # these point at real home-manager store directories, which do match the
    # glob and do need the skip. A test that passes for the wrong reason is the
    # same disease this whole module treats.
    mkfixture "$R"
    mkdir -p "$TMPDIR/fake-store/zeta"; echo "# zeta" > "$TMPDIR/fake-store/zeta/SKILL.md"
    ln -s "$TMPDIR/fake-store/zeta" "$R/skills/zeta"
    # prove the fixture is actually exercising the branch, not skipping it
    [ -d "$R/skills/zeta" ] || { echo "fixture broken: symlink does not resolve to a dir"; exit 1; }
    expect_pass "$R" "a RESOLVABLE symlink skill does not trip drift"

    echo "== the settings.json regression the obvious check misses =="
    mkfixture "$R"
    echo '{"hooks":{"UserPromptSubmit":[]}}' > "$R/settings.json"
    expect_fail "$R" "lost hooks.UserPromptSubmit" "empty hook ARRAY fires (jq -e alone would pass)"

    mkfixture "$R"; echo '{"hooks":{}}' > "$R/settings.json"
    expect_fail "$R" "lost hooks.UserPromptSubmit" "absent hook key fires"

    echo "== malformed JSON must NOT masquerade as the hooks regression =="
    mkfixture "$R"; echo '{"hooks": {' > "$R/settings.json"
    expect_fail "$R" "not valid JSON" "parse error gets its own message"

    echo "== git failing for a NON-empty reason must say so =="
    # Permission bits do not constrain uid 0, so this case is only meaningful
    # for an unprivileged builder. Skipped rather than silently passing.
    if [ "$(id -u)" -eq 0 ]; then
      echo "  SKIP: running as root, chmod cannot make the repo unreadable"
    else
      mkfixture "$R"; chmod 000 "$R/skills/.git"
      res=$(run "$R" 2>&1 || true)
      chmod 755 "$R/skills/.git"
      if echo "$res" | grep -qF "no tracked files at all"; then
        echo "REGRESSION: an unreadable repo was reported as an empty one"
        echo "$res"; exit 1
      fi
      echo "$res" | grep -qF "ls-files FAILED" || {
        echo "expected a distinct ls-files failure message"; echo "$res"; exit 1; }
      echo "  ok: unreadable repo is not mistaken for an empty one"
    fi

    echo "== whole skills repo gone: must fail AND must not print a reassuring drift line =="
    mkfixture "$R"; rm -rf "$R/skills/.git"
    res=$(run "$R" 2>&1 || true)
    echo "$res" | grep -qF "not a git repo" || { echo "expected 'not a git repo'"; echo "$res"; exit 1; }
    # Match the SKILLS drift line specifically. Since 2026-07-27 the lenses repo
    # has its own drift line whose text also contains "committed set == on-disk
    # set" — and there it is legitimate, because the lenses repo is fine. A
    # substring match would fail on a true statement about a different repo.
    if echo "$res" | grep -qE '^ok: +drift: committed set == on-disk set'; then
      echo "REGRESSION: printed a reassuring drift line for the catastrophic case"
      echo "$res"; exit 1
    fi
    echo "  ok: drift is skipped, not falsely green"

    echo "== a dirty worktree is NORMAL and must never fire =="
    mkfixture "$R"; echo "edited mid-thought" >> "$R/skills/alpha/SKILL.md"
    expect_pass "$R" "uncommitted MODIFICATION does not fire (no cry-wolf)"

    echo "== missing root env is a hard error, not a silent pass =="
    if res=$(bash ${guard} 2>&1); then
      echo "EXPECTED FAIL with no SANCTA_DOCTRINE_ROOT"; echo "$res"; exit 1
    fi
    echo "  ok: unset root fails loudly"

    touch $out
  ''
