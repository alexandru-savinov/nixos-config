#!/usr/bin/env bash
# Tests for scripts/ci/gitleaks-commits.sh using throwaway repos and invented
# canaries assembled at runtime (no full canary string exists in this repo).
# Needs gitleaks, git, coreutils on PATH.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/ci/gitleaks-commits.sh
config=$root/.gitleaks.toml

work=$(mktemp -d)
trap 'find "$work" -xdev -delete' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

hex64() {
    local out
    out=$(printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; })
    printf '%s' "${out:0:64}"
}

shapes="telegram telegram_url telegram_dash openrouter hex64"

# emit SHAPE -> sets LINE (a source line), VALUE (the secret part), RULE
emit() {
    local h tail id
    h=$(hex64 "seed-$1")
    id=$(printf '%s' 4815162342)
    tail=$(printf '%s' "${h:0:35}" | tr 'a-f0-9' 'k-pQ-Z')
    case "$1" in
    telegram)
        VALUE="$id:$tail"
        LINE="BOT_TOKEN=$VALUE"
        RULE=telegram-bot-token-shape
        ;;
    telegram_url)
        VALUE="$id:$tail"
        LINE="url: https://api.example.invalid/bot$VALUE/getMe"
        RULE=telegram-bot-token-shape
        ;;
    telegram_dash)
        VALUE="$id:${tail:0:34}-"
        LINE="BOT_TOKEN=$VALUE"
        RULE=telegram-bot-token-shape
        ;;
    openrouter)
        VALUE="sk-or-v1-$h"
        LINE="OPENROUTER_KEY=$VALUE"
        RULE=openrouter-api-key
        ;;
    hex64)
        VALUE=$h
        LINE="api_key = \"$VALUE\""
        RULE=bare-hex64-key
        ;;
    esac
}

newrepo() {
    local d
    d=$(mktemp -d "$work/repo.XXXXXX")
    git -C "$d" init -q -b main
    printf 'hello\n' >"$d/README"
    git -C "$d" add -A
    git -C "$d" commit -q -m base
    printf '%s' "$d"
}

# scan SCRIPT REPO BASE HEAD -> exit status; combined output in $work/out
scan() {
    (cd "$2" && "$BASH" "$1" "$3" "$4" "$config") >"$work/out" 2>&1
}

# expect_caught LABEL RULE VALUE RC: the last scan must have exited 1 with RULE
# named in its output, and the output may carry neither the value nor the
# commit message sentinel.
expect_caught() {
    local label=$1 rule=$2 value=$3 rc=$4 good=1
    [ "$rc" -eq 1 ] || good=0
    grep -q "finding: rule=$rule " "$work/out" || good=0
    if grep -qF -- "$value" "$work/out"; then good=0; fi
    if grep -qF -- "msg-sentinel" "$work/out"; then good=0; fi
    if [ "$good" -eq 1 ]; then ok "$label (exit 1, rule $rule, redacted)"; else bad "$label (exit $rc, rule $rule)"; fi
}

add_then_remove() {
    printf '%s\n' "$LINE" >"$1/app.conf"
    git -C "$1" add -A
    git -C "$1" commit -q -m "msg-sentinel add"
    git -C "$1" rm -q app.conf
    git -C "$1" commit -q -m remove
}

# merge repo: canary exists only in the merge commit
make_merge_repo() {
    git -C "$1" checkout -q -b side
    printf 's\n' >"$1/side.txt"
    git -C "$1" add -A && git -C "$1" commit -q -m side
    git -C "$1" checkout -q main
    printf 'm\n' >"$1/main.txt"
    git -C "$1" add -A && git -C "$1" commit -q -m mainline
    git -C "$1" merge -q --no-ff --no-commit side >/dev/null 2>&1
    printf '%s\n' "$LINE" >"$1/evil.conf"
    git -C "$1" add -A
    git -C "$1" commit -q -m merge
}

# all_exit SCRIPT CODE: 0 if every shape ends with exactly exit CODE
all_exit() {
    local sc=$1 s r b
    for s in $shapes; do
        emit "$s"
        r=$(newrepo)
        b=$(git -C "$r" rev-parse HEAD)
        add_then_remove "$r"
        scan "$sc" "$r" "$b" HEAD
        [ "$?" -eq "$2" ] || return 1
    done
}

merge_exit() {
    local r b
    emit openrouter
    r=$(newrepo)
    b=$(git -C "$r" rev-parse HEAD)
    make_merge_repo "$r"
    scan "$1" "$r" "$b" HEAD
    [ "$?" -eq "$2" ]
}

echo "== (a) add then remove inside the range"
for s in $shapes; do
    emit "$s"
    r=$(newrepo)
    b=$(git -C "$r" rev-parse HEAD)
    add_then_remove "$r"
    scan "$script" "$r" "$b" HEAD
    expect_caught "a/$s" "$RULE" "$VALUE" $?
done

echo "== (g) repository diff attributes cannot hide a value"
for attr in '* -diff' '* binary'; do
    emit openrouter
    r=$(newrepo)
    b=$(git -C "$r" rev-parse HEAD)
    printf '%s\n' "$attr" >"$r/.gitattributes"
    printf '%s\n' "$LINE" >"$r/app.conf"
    git -C "$r" add -A && git -C "$r" commit -q -m attrs
    scan "$script" "$r" "$b" HEAD
    expect_caught "g/attributes '$attr'" "$RULE" "$VALUE" $?
done

echo "== (h) inline allow comment does not suppress"
emit hex64
r=$(newrepo)
b=$(git -C "$r" rev-parse HEAD)
printf '%s # gitleaks:allow\n' "$LINE" >"$r/app.conf"
git -C "$r" add -A && git -C "$r" commit -q -m allow
scan "$script" "$r" "$b" HEAD
expect_caught "h/inline allow" "$RULE" "$VALUE" $?

echo "== (m) value introduced only in a merge commit"
emit openrouter
r=$(newrepo)
b=$(git -C "$r" rev-parse HEAD)
make_merge_repo "$r"
scan "$script" "$r" "$b" HEAD
expect_caught "m/merge-only" "$RULE" "$VALUE" $?

echo "== (b) clean range"
r=$(newrepo)
b=$(git -C "$r" rev-parse HEAD)
printf 'more text\n' >"$r/notes"
git -C "$r" add -A && git -C "$r" commit -q -m clean
scan "$script" "$r" "$b" HEAD
if [ "$?" -eq 0 ]; then ok "b: clean range exits 0"; else bad "b: clean range failed"; fi

echo "== (i) fail closed on bad input"
scan "$script" "$r" 0000000000000000000000000000000000000000 HEAD
[ "$?" -eq 2 ] && ok "i: all-zero base exits 2" || bad "i: all-zero base"
scan "$script" "$r" "" HEAD
[ "$?" -eq 2 ] && ok "i: empty base exits 2" || bad "i: empty base"
scan "$script" "$r" 1111111111111111111111111111111111111111 HEAD
[ "$?" -eq 2 ] && ok "i: unknown base exits 2" || bad "i: unknown base"
scan "$script" "$r" "$b" nonexistent-ref
[ "$?" -eq 2 ] && ok "i: unknown head exits 2" || bad "i: unknown head"

echo "== (c)/(d) exceptions"
emit hex64
r=$(newrepo)
b=$(git -C "$r" rev-parse HEAD)
add_then_remove "$r"
scan "$script" "$r" "$b" HEAD
fp=$(sed -n 's/.*fingerprint=\([^ ]*\)$/\1/p' "$work/out" | head -1)
[ -n "$fp" ] || bad "c/d: no fingerprint obtained"

printf '# exceptions\n%s\n' "$fp" >"$r/.gitleaksignore"
printf '# Rotation log\nno date here: %s\n' "$fp" >"$r/SECRETS-ROTATION.md"
scan "$script" "$r" "$b" HEAD
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'line 2 ' "$work/out" && ! grep -qF -- "$fp" "$work/out"; then
    ok "d: undated exception fails, reports line number only"
else bad "d: undated exception (rc=$rc)"; fi

printf '# Rotation log\n2026-01-02 `%s` missing dash\n' "$fp" >"$r/SECRETS-ROTATION.md"
scan "$script" "$r" "$b" HEAD
[ "$?" -ne 0 ] && ok "d: wrong line form fails" || bad "d: wrong line form passed"

printf '# Rotation log\n- 2026-01-02 `%s`: rotated\n' "$fp" >"$r/SECRETS-ROTATION.md"
scan "$script" "$r" "$b" HEAD
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'exceptions active: 1' "$work/out"; then ok "c: dated exception exits 0, count printed"; else bad "c: dated exception rc=$rc"; fi

printf 'not-a-fingerprint with spaces\n' >"$r/.gitleaksignore"
scan "$script" "$r" "$b" HEAD
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'line 1 ' "$work/out" && ! grep -q 'spaces' "$work/out"; then
    ok "d: malformed entry rejected by line number only"
else bad "d: malformed entry rc=$rc"; fi

printf '%s\n' "${fp#*:}" >"$r/.gitleaksignore"
scan "$script" "$r" "$b" HEAD
[ "$?" -ne 0 ] && ok "d: commit-less fingerprint rejected" || bad "d: commit-less fingerprint accepted"

echo "== (c2) exception line validation"
doc_case() { # LABEL EXPECT(pass|fail) ; SECRETS-ROTATION.md already written
    printf '%s\n' "$fp" >"$r/.gitleaksignore"
    scan "$script" "$r" "$b" HEAD
    local rc=$?
    if [ "$2" = pass ] && [ "$rc" -eq 0 ]; then ok "c2/$1"
    elif [ "$2" = fail ] && [ "$rc" -ne 0 ] && ! grep -qF -- "$fp" "$work/out"; then ok "c2/$1 rejected"
    else bad "c2/$1 (rc=$rc, expected $2)"; fi
}
printf '<!--\n- 2026-01-02 `%s`\n-->\n' "$fp" >"$r/SECRETS-ROTATION.md"
doc_case "multi-line html comment" fail
printf '<!-- note -->\n- 2026-01-02 `%s`\n' "$fp" >"$r/SECRETS-ROTATION.md"
doc_case "line after a closed comment" pass
printf ' - 2026-01-02 `%s`\n' "$fp" >"$r/SECRETS-ROTATION.md"
doc_case "indented line" fail
printf -- '- 2999-01-01 `%s`\n' "$fp" >"$r/SECRETS-ROTATION.md"
doc_case "future date" fail
printf -- '- 2026-02-30 `%s`\n' "$fp" >"$r/SECRETS-ROTATION.md"
doc_case "impossible date" fail
printf -- '- 2026-01-02 `%s`\n' "$fp" >"$work/real-doc"
find "$r/SECRETS-ROTATION.md" -xdev -delete
ln -s "$work/real-doc" "$r/SECRETS-ROTATION.md"
doc_case "symlinked rotation doc" fail
find "$r/SECRETS-ROTATION.md" -xdev -delete
printf -- '- 2026-01-02 `%s`\n' "$fp" >"$r/SECRETS-ROTATION.md"

echo "== (t) tripwire, summary and commit count"
git -C "$r" add -A && git -C "$r" commit -q -m exceptions
printf '%s\n' "$fp" >"$r/.gitleaksignore"
GITHUB_STEP_SUMMARY=$work/summary scan "$script" "$r" "$b" HEAD
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^::warning::' "$work/out" && grep -q 'commits to scan: 3' "$work/out" \
    && grep -q '.gitleaksignore' "$work/summary" && grep -qF -- "- 2026-01-02" "$work/summary"; then
    ok "t: warning, commit count and summary present"
else bad "t: tripwire (rc=$rc)"; fi
scan "$script" "$r" HEAD HEAD
[ "$?" -eq 2 ] && ok "t: empty range exits 2" || bad "t: empty range"

echo "== (s) trusted inputs selection"
ti=$root/scripts/ci/gitleaks-trusted-inputs.sh
tr_repo=$(newrepo)
mkdir -p "$tr_repo/scripts/ci"
printf 'S\n' >"$tr_repo/scripts/ci/gitleaks-commits.sh"
printf 'C\n' >"$tr_repo/.gitleaks.toml"
git -C "$tr_repo" add -A && git -C "$tr_repo" commit -q -m both
both=$(git -C "$tr_repo" rev-parse HEAD)
none=$(git -C "$tr_repo" rev-parse HEAD~1)
git -C "$tr_repo" rm -q .gitleaks.toml && git -C "$tr_repo" commit -q -m one
one=$(git -C "$tr_repo" rev-parse HEAD)
printf 'WORKTREE-S\n' >"$tr_repo/scripts/ci/gitleaks-commits.sh"
printf 'WORKTREE-C\n' >"$tr_repo/.gitleaks.toml"
ti_run() { (cd "$tr_repo" && "$BASH" "$ti" "$1" "$work/ti-s" "$work/ti-c") >"$work/out" 2>&1; }
ti_run "$both"
if [ "$?" -eq 0 ] && grep -qx 'S' "$work/ti-s" && grep -qx 'C' "$work/ti-c"; then ok "s: both present -> trusted copies"; else bad "s: both present"; fi
ti_run "$none"
if [ "$?" -eq 0 ] && grep -q NOTICE "$work/out" && grep -qx 'WORKTREE-S' "$work/ti-s"; then ok "s: both absent -> bootstrap with notice"; else bad "s: bootstrap"; fi
ti_run "$one"
[ "$?" -ne 0 ] && ok "s: exactly one file at trusted ref fails" || bad "s: one file passed"
ti_run 0000000000000000000000000000000000000000
[ "$?" -ne 0 ] && ok "s: all-zero trusted ref fails" || bad "s: zero ref passed"
ti_run ""
[ "$?" -ne 0 ] && ok "s: empty trusted ref fails" || bad "s: empty ref passed"
ti_run 1111111111111111111111111111111111111111
[ "$?" -ne 0 ] && ok "s: unreadable trusted ref fails" || bad "s: unreadable ref passed"

echo "== (e) mutants"
mut=$work/mutant-tree.sh
sed 's|git --log-opts="\$log_opts"|dir .|' "$script" >"$mut"
if cmp -s "$script" "$mut"; then bad "e: tree-only mutant did not apply"
elif ! all_exit "$script" 1; then bad "e: real script misses a shape"
elif all_exit "$mut" 0; then ok "e: tree-only mutant exits 0 on a removed canary (real miss); test detects it"
else bad "e: tree-only mutant did not exit 0 everywhere"; fi

mut2=$work/mutant-nomerge.sh
sed 's| --diff-merges=first-parent||' "$script" >"$mut2"
if cmp -s "$script" "$mut2"; then bad "e: no-merge mutant did not apply"
elif ! merge_exit "$script" 1; then bad "e: real script misses merge case"
elif merge_exit "$mut2" 0; then ok "e: no-merge mutant exits 0 on a merge-only value (real miss); test detects it"
else bad "e: no-merge mutant did not exit 0"; fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
