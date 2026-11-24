#!/usr/bin/env bash
# Secret scan over every commit in BASE..HEAD (not just the final tree), so a
# value that is added and later removed inside one PR is still caught.
#
# usage: gitleaks-commits.sh BASE HEAD
#   BASE empty or all zeros: scan only the single commit HEAD.
#
# Exceptions live in .gitleaksignore (one gitleaks fingerprint per line).
# Each fingerprint must also appear in SECRETS-ROTATION.md on a line carrying
# an ISO date (YYYY-MM-DD); otherwise this script fails and names it.
#
# Findings are always fully redacted; no matched value is ever printed.
# Run from inside the repository to scan. GITLEAKS_CONFIG overrides the config.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 BASE HEAD" >&2
    exit 2
fi
base=$1
head=$2

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config=${GITLEAKS_CONFIG:-$script_dir/../../.gitleaks.toml}

ignore_file=.gitleaksignore
rotation_doc=SECRETS-ROTATION.md

if [ -f "$ignore_file" ]; then
    bad=0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        fp=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$fp" in '' | '#'*) continue ;; esac
        if ! { [ -f "$rotation_doc" ] &&
            grep -F -- "$fp" "$rotation_doc" |
            grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}'; }; then
            echo "error: .gitleaksignore entry has no dated line in $rotation_doc: $fp" >&2
            bad=1
        fi
    done <"$ignore_file"
    if [ "$bad" -ne 0 ]; then
        exit 1
    fi
fi

case "$base" in
'' | *[!0]*) ;;
*) base= ;;
esac
if [ -z "$base" ]; then
    log_opts="-1 $head"
else
    log_opts="$base..$head"
fi

gitleaks git --log-opts="$log_opts" --config "$config" --redact=100 --exit-code 1 --no-banner
