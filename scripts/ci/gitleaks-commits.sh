#!/usr/bin/env bash
# Secret scan over every commit in BASE..HEAD (not just the final tree), so a
# value that is added and later removed inside one change is still caught.
#
# usage: gitleaks-commits.sh BASE HEAD CONFIG [REPORT_JSON]
#   Run from inside the repository to scan. CONFIG is an explicit gitleaks
#   config path (CI passes a copy taken from the trusted base ref).
#   REPORT_JSON, when given, receives a fully redacted JSON report.
#
# Exit codes: 0 clean, 1 findings or invalid exception, 2 unusable input,
# anything else is a gitleaks failure (the scan never passes by accident).
#
# Exceptions live in .gitleaksignore: one commit-scoped fingerprint per line
# (<40-hex commit>:<path>:<rule-id>:<line>). Each must also appear in
# SECRETS-ROTATION.md as a line of the exact form
#   - YYYY-MM-DD `<fingerprint>`
# Invalid entries are reported by line number only.
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: $0 BASE HEAD CONFIG [REPORT_JSON]" >&2
    exit 2
fi
base=$1
head=$2
config=$3
report=${4:-}

if [ -z "$base" ] || [ -z "${base//0/}" ]; then
    echo "error: no trusted lower bound (BASE is empty or all zeros)" >&2
    exit 2
fi
for ref in "$base" "$head"; do
    if ! git cat-file -e "${ref}^{commit}" 2>/dev/null; then
        echo "error: not a commit in this repository: $ref" >&2
        exit 2
    fi
done
if [ ! -f "$config" ]; then
    echo "error: config file not found: $config" >&2
    exit 2
fi

ignore_file=.gitleaksignore
rotation_doc=SECRETS-ROTATION.md
active=0
bad=0
if [ -f "$ignore_file" ]; then
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=${line%$'\r'}
        case "$line" in '' | '#'*) continue ;; esac
        active=$((active + 1))
        if ! [[ $line =~ ^[0-9a-f]{40}:[^:[:space:]]+:[^:[:space:]]+:[0-9]+$ ]]; then
            echo "error: .gitleaksignore line $lineno is not a commit-scoped fingerprint" >&2
            bad=1
            continue
        fi
        found=0
        if [ -f "$rotation_doc" ]; then
            while IFS= read -r doc || [ -n "$doc" ]; do
                if [[ $doc =~ ^-\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ \` ]]; then
                    rest=${doc:14}
                    if [[ $rest == "$line"'`'* ]]; then
                        found=1
                        break
                    fi
                fi
            done <"$rotation_doc"
        fi
        if [ "$found" -ne 1 ]; then
            echo "error: .gitleaksignore line $lineno has no dated entry in $rotation_doc" >&2
            bad=1
        fi
    done <"$ignore_file"
fi
echo "gitleaks exceptions active: $active"
if [ "$bad" -ne 0 ]; then
    exit 1
fi

# Neutralise repository-controlled diff behaviour: --text overrides -diff and
# binary attributes, and textconv / external diff drivers are not run.
export GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.attributesFile GIT_CONFIG_VALUE_0=/dev/null

log_opts="--text --no-textconv --no-ext-diff --diff-merges=first-parent $base..$head"

extra=()
if [ -n "$report" ]; then
    extra=(--report-format json --report-path "$report")
fi

gitleaks git --log-opts="$log_opts" --config "$config" --ignore-gitleaks-allow \
    --redact=100 --exit-code 1 --no-banner "${extra[@]}"
