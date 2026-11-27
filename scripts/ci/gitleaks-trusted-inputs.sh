#!/usr/bin/env bash
# Select the scanner and its config from a trusted ref (never from the change
# under review).
#
# usage: gitleaks-trusted-inputs.sh TRUSTED_REF SCANNER_OUT CONFIG_OUT
#   Run from inside the repository.
#
# Both files present at TRUSTED_REF: copy them from there.
# Both absent (the ref predates the scanner): copy the checkout's own files and
#   print a notice.
# Exactly one present, or the ref cannot be read: exit non-zero.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 TRUSTED_REF SCANNER_OUT CONFIG_OUT" >&2
    exit 2
fi
ref=$1
scanner_out=$2
config_out=$3

scanner_path=scripts/ci/gitleaks-commits.sh
config_path=.gitleaks.toml

if [ -z "$ref" ] || ! git cat-file -e "${ref}^{commit}" 2>/dev/null; then
    echo "error: trusted ref is unreadable or not a commit; refusing to fall back" >&2
    exit 2
fi

has_scanner=0
has_config=0
git cat-file -e "${ref}:${scanner_path}" 2>/dev/null && has_scanner=1
git cat-file -e "${ref}:${config_path}" 2>/dev/null && has_config=1

if [ "$has_scanner" -eq 1 ] && [ "$has_config" -eq 1 ]; then
    git show "${ref}:${scanner_path}" >"$scanner_out"
    git show "${ref}:${config_path}" >"$config_out"
    echo "using scanner and config from trusted ref"
elif [ "$has_scanner" -eq 0 ] && [ "$has_config" -eq 0 ]; then
    # TODO(remove-bootstrap): delete this branch in a follow-up PR right after
    # the scanner lands on the base branch.
    top=$(git rev-parse --show-toplevel)
    echo "NOTICE: the trusted ref has neither scanner file yet; using the copies from this checkout (bootstrap)."
    cp "$top/$scanner_path" "$scanner_out"
    cp "$top/$config_path" "$config_out"
else
    echo "error: the trusted ref has only one of $scanner_path and $config_path" >&2
    exit 1
fi
