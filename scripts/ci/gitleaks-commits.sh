#!/usr/bin/env bash
# Secret scan over every commit in BASE..HEAD (not just the final tree), so a
# value that is added and later removed inside one change is still caught.
#
# usage: gitleaks-commits.sh BASE HEAD CONFIG
#   Run from inside the repository to scan. CONFIG is an explicit gitleaks
#   config path (CI passes a copy taken from the trusted base ref).
#
# Exit codes: 0 clean, 1 findings or invalid exception, 2 unusable input
# (including an empty range), anything else is a gitleaks failure.
#
# Output never contains matched values, matched lines or commit messages: only
# rule id, commit, path and line of each finding, sanitised.
#
# Exceptions live in .gitleaksignore: one commit-scoped fingerprint per line
# (<40-hex commit>:<path>:<rule-id>:<line>). Each must also appear in
# SECRETS-ROTATION.md as a line, starting at column 0 and outside any HTML
# comment, of the exact form
#   - YYYY-MM-DD `<fingerprint>`
# with a real calendar date that is not in the future. Invalid entries are
# reported by line number only.
set -euo pipefail

# Isolate git from ambient and repository-controlled configuration.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1
unset GIT_CONFIG_PARAMETERS
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.attributesFile GIT_CONFIG_VALUE_0=/dev/null

if [ "$#" -ne 3 ]; then
    echo "usage: $0 BASE HEAD CONFIG" >&2
    exit 2
fi
base=$1
head=$2
config=$3

# Keep untrusted text from forming workflow commands or control sequences.
clean() { printf '%s' "$1" | tr -c 'A-Za-z0-9._/:@+ `=-' '?'; }

if [ -z "$base" ] || [ -z "${base//0/}" ]; then
    echo "error: no trusted lower bound (BASE is empty or all zeros)" >&2
    exit 2
fi
for ref in "$base" "$head"; do
    if ! git cat-file -e "${ref}^{commit}" 2>/dev/null; then
        echo "error: not a commit in this repository: $(clean "$ref")" >&2
        exit 2
    fi
done
if [ ! -f "$config" ]; then
    echo "error: config file not found: $(clean "$config")" >&2
    exit 2
fi
count=$(git rev-list --count "$base..$head")
if [ "$count" -eq 0 ]; then
    echo "error: the range $base..$head contains no commits" >&2
    exit 2
fi
echo "commits to scan: $count"

ignore_file=.gitleaksignore
rotation_doc=SECRETS-ROTATION.md
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

# --- tripwire: files that can weaken or bypass the scan -------------------
touched=()
for p in .gitleaksignore .gitleaks.toml scripts/ci/gitleaks-commits.sh \
    scripts/ci/gitleaks-trusted-inputs.sh .github/workflows/check.yml SECRETS-ROTATION.md; do
    if ! git diff --quiet --no-ext-diff "$base" "$head" -- "$p"; then
        touched+=("$p")
    fi
done
if [ "${#touched[@]}" -gt 0 ]; then
    echo "::warning::this change touches secret-scan inputs: ${touched[*]}"
    {
        echo '### Secret scan: inputs touched by this change'
        for p in "${touched[@]}"; do echo "- \`$p\`"; done
        echo
    } >>"$summary"
fi

# --- exceptions ------------------------------------------------------------
valid_date() {
    local d=$1 n today
    [[ $d =~ $date_re ]] || return 1
    if n=$(date -d "$d" +%F 2>/dev/null); then
        :
    elif n=$(date -j -f %Y-%m-%d "$d" +%F 2>/dev/null); then
        :
    else
        return 1
    fi
    [ "$n" = "$d" ] || return 1
    today=$(date -u +%F)
    [[ ! "$d" > "$today" ]]
}
date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
dated_re='^-[ ]([0-9]{4}-[0-9]{2}-[0-9]{2})[ ]`'
fp_re='^[0-9a-f]{40}:[^:[:space:]]+:[^:[:space:]]+:[0-9]+$'

if [ -L "$ignore_file" ] || [ -L "$rotation_doc" ]; then
    echo "error: $ignore_file and $rotation_doc must be regular files, not symlinks" >&2
    exit 1
fi

# Eligible rotation lines: column 0, outside HTML comments, real past date.
eligible=()
if [ -f "$rotation_doc" ]; then
    in_comment=0
    while IFS= read -r doc || [ -n "$doc" ]; do
        doc=${doc%$'\r'}
        if [ "$in_comment" -eq 0 ] && [[ $doc =~ $dated_re ]] && valid_date "${BASH_REMATCH[1]}"; then
            eligible+=("$doc")
        fi
        rest=$doc
        while :; do
            if [ "$in_comment" -eq 1 ]; then
                case "$rest" in
                *'-->'*) rest=${rest#*-->}; in_comment=0 ;;
                *) break ;;
                esac
            else
                case "$rest" in
                *'<!--'*) rest=${rest#*<!--}; in_comment=1 ;;
                *) break ;;
                esac
            fi
        done
    done <"$rotation_doc"
fi

active=0
bad=0
matched=()
if [ -f "$ignore_file" ]; then
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=${line%$'\r'}
        case "$line" in '' | '#'*) continue ;; esac
        active=$((active + 1))
        if ! [[ $line =~ $fp_re ]]; then
            echo "error: .gitleaksignore line $lineno is not a commit-scoped fingerprint" >&2
            bad=1
            continue
        fi
        found=
        i=0
        while [ "$i" -lt "${#eligible[@]}" ]; do
            doc=${eligible[$i]}
            i=$((i + 1))
            rest=${doc:13}
            if [[ $rest == '`'"$line"'`'* ]]; then
                found=$doc
                break
            fi
        done
        if [ -z "$found" ]; then
            echo "error: .gitleaksignore line $lineno has no valid dated entry in $rotation_doc" >&2
            bad=1
        else
            matched+=("$found")
        fi
    done <"$ignore_file"
fi
echo "gitleaks exceptions active: $active"
if [ "$active" -gt 0 ]; then
    {
        echo '### Secret scan: active exceptions'
        for doc in ${matched[@]+"${matched[@]}"}; do echo "- $(clean "$doc")"; done
        echo
    } >>"$summary"
fi
if [ "$bad" -ne 0 ]; then
    exit 1
fi

# --- scan ------------------------------------------------------------------
# --text overrides -diff/binary attributes; textconv and external diff drivers
# are not run; merge commits are shown against their first parent.
log_opts="--text --no-textconv --no-ext-diff --diff-merges=first-parent $base..$head"

tmp=$(mktemp -d)
trap 'find "$tmp" -xdev -delete' EXIT
report=$tmp/report.json

set +e
gitleaks git --log-opts="$log_opts" --config "$config" --ignore-gitleaks-allow \
    --report-format json --report-path "$report" \
    --redact=100 --exit-code 1 --no-banner
rc=$?
set -e

if [ "$rc" -eq 1 ] && [ -f "$report" ]; then
    # One line per finding; values, matched lines and messages are not printed.
    awk '
        /^ \{/ { rule=""; commit=""; file=""; line=""; fp="" }
        /^  "RuleID":/ { rule=$0; sub(/^[^:]*: *"/, "", rule); sub(/".*$/, "", rule) }
        /^  "Commit":/ { commit=$0; sub(/^[^:]*: *"/, "", commit); sub(/".*$/, "", commit) }
        /^  "File":/ { file=$0; sub(/^[^:]*: *"/, "", file); sub(/".*$/, "", file) }
        /^  "StartLine":/ { line=$0; sub(/^[^:]*: */, "", line); sub(/,.*$/, "", line) }
        /^  "Fingerprint":/ { fp=$0; sub(/^[^:]*: *"/, "", fp); sub(/".*$/, "", fp) }
        /^ \}/ { print rule "\t" commit "\t" file "\t" line "\t" fp }
    ' "$report" | while IFS=$'\t' read -r r c f l fp; do
        echo "  finding: rule=$(clean "$r") commit=$(clean "$c") file=$(clean "$f") line=$(clean "$l") fingerprint=$(clean "$fp")"
    done
fi
exit "$rc"
