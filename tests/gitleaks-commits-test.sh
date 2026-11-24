#!/usr/bin/env bash
# Tests for scripts/ci/gitleaks-commits.sh using throwaway repos and invented
# canaries assembled at runtime (no full canary string exists in this repo).
# Needs gitleaks, git, coreutils on PATH.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/ci/gitleaks-commits.sh
export GITLEAKS_CONFIG=$root/.gitleaks.toml

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

# canary SHAPE -> one source line holding an invented value of that shape
canary() {
    local h
    h=$(hex64 "seed-$1")
    case "$1" in
    telegram)
        local tail
        tail=$(printf '%s' "${h:0:35}" | tr 'a-f0-9' 'k-pQ-Z')
        printf 'BOT_TOKEN=%s:%s\n' "$(printf '%s' 4815162342)" "$tail"
        ;;
    openrouter) printf 'OPENROUTER_KEY=%s%s\n' "sk-or-v1-" "$h" ;;
    hex64) printf 'api_key = "%s"\n' "$h" ;;
    esac
}

shapes="telegram openrouter hex64"

newrepo() {
    local d
    d=$(mktemp -d "$work/repo.XXXXXX")
    git -C "$d" init -q -b main
    printf 'hello\n' >"$d/README"
    git -C "$d" add -A
    git -C "$d" commit -q -m base
    printf '%s' "$d"
}

# run SCRIPT REPO BASE HEAD -> exit status; output in $work/out
run() { (cd "$2" && bash "$1" "$3" "$4") >"$work/out" 2>&1; }

# add a canary, then remove it; echo nothing, leaves repo at the removal commit
add_then_remove() {
    canary "$2" >"$1/app.conf"
    git -C "$1" add -A
    git -C "$1" commit -q -m add
    git -C "$1" rm -q app.conf
    git -C "$1" commit -q -m remove
}

# case (a): added-then-removed canary must fail for every shape. Returns 0 if
# the scanner caught all of them.
case_a() {
    local sc=$1 shape r base rc caught=0
    for shape in $shapes; do
        r=$(newrepo)
        base=$(git -C "$r" rev-parse HEAD)
        add_then_remove "$r" "$shape"
        run "$sc" "$r" "$base" HEAD
        rc=$?
        [ "$rc" -ne 0 ] || caught=1
        CASE_A_LAST=$rc
        [ "$sc" != "$script" ] || if [ "$rc" -ne 0 ]; then ok "a/$shape: add-then-remove fails (exit $rc)"; else bad "a/$shape: add-then-remove exited 0"; fi
    done
    return "$caught"
}

echo "== (a) add then remove inside the range"
case_a "$script"
[ "$?" -eq 0 ] || :

echo "== (b) clean range"
r=$(newrepo)
base=$(git -C "$r" rev-parse HEAD)
printf 'more text\n' >"$r/notes"
git -C "$r" add -A && git -C "$r" commit -q -m clean
run "$script" "$r" "$base" HEAD
if [ "$?" -eq 0 ]; then ok "b: clean range exits 0"; else bad "b: clean range failed"; cat "$work/out"; fi

echo "== (c)/(d) exception rule"
r=$(newrepo)
base=$(git -C "$r" rev-parse HEAD)
canary hex64 >"$r/app.conf"
git -C "$r" add -A && git -C "$r" commit -q -m add
git -C "$r" rm -q app.conf && git -C "$r" commit -q -m remove
tip=$(git -C "$r" rev-parse HEAD)
(cd "$r" && gitleaks git --log-opts="$base..$tip" --config "$GITLEAKS_CONFIG" --redact=100 \
    --no-banner --exit-code 0 --report-format json --report-path "$work/report.json" >/dev/null 2>&1)
fp=$(grep -o '"Fingerprint": *"[^"]*"' "$work/report.json" | head -1 | sed 's/^[^:]*: *"//; s/"$//')
if [ -z "$fp" ]; then bad "c/d: could not obtain a fingerprint"; fi
printf '# exceptions\n%s\n' "$fp" >"$r/.gitleaksignore"

# (d) first: ignore entry without a dated line
printf '# Rotation log\nno date here: %s\n' "$fp" >"$r/SECRETS-ROTATION.md"
run "$script" "$r" "$base" "$tip"
rc=$?
if [ "$rc" -ne 0 ] && grep -qF -- "$fp" "$work/out"; then ok "d: undated exception fails and names fingerprint"; else bad "d: undated exception (rc=$rc)"; fi

# (c) dated line
printf '# Rotation log\n2026-01-02 rotated: %s\n' "$fp" >"$r/SECRETS-ROTATION.md"
run "$script" "$r" "$base" "$tip"
rc=$?
if [ "$rc" -eq 0 ]; then ok "c: dated exception exits 0"; else bad "c: dated exception rc=$rc"; cat "$work/out"; fi

# (d2) ignore file present but rotation doc absent
find "$r/SECRETS-ROTATION.md" -xdev -delete
run "$script" "$r" "$base" "$tip"
if [ "$?" -ne 0 ]; then ok "d2: missing rotation doc fails"; else bad "d2: missing rotation doc passed"; fi

echo "== output never carries a canary value"
leak=0
for shape in $shapes; do
    v=$(canary "$shape")
    v=${v#*=}
    v=${v//\"/}
    r2=$(newrepo)
    b2=$(git -C "$r2" rev-parse HEAD)
    add_then_remove "$r2" "$shape"
    run "$script" "$r2" "$b2" HEAD
    grep -qF -- "$v" "$work/out" && leak=1
done
if [ "$leak" -eq 0 ]; then ok "redaction: no canary value in output"; else bad "redaction: value printed"; fi

echo "== (e) mutant: tree-only scan instead of --log-opts"
mut=$work/mutant.sh
sed 's|git --log-opts="\$log_opts"|dir .|' "$script" >"$mut"
if cmp -s "$script" "$mut"; then
    bad "e: mutation did not apply"
else
    case_a "$mut"
    if [ "$?" -ne 0 ]; then ok "e: mutant lets a removed canary through; test detects it"; else bad "e: mutant was NOT detected"; fi
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
