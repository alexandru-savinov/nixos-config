#!/usr/bin/env bash
set -euo pipefail

# verify-fix-shipped.sh — assert a security fix actually shipped before
# closing the issue. Guards against the claude-yolo failure mode (#458):
# a "fix" that lived on an unmerged branch (PR closed, mergedAt=null) so the
# vuln stayed deployed until it was removed a second time.
#
# Usage:
#   scripts/verify-fix-shipped.sh <fix-commit> [deployed-branch]
#
#   <fix-commit>       commit (or ref) claimed to fix the issue
#   [deployed-branch]  branch the hosts deploy from (default: origin/main)
#
# Exit 0 = fix IS an ancestor of the deployed branch (safe to close).
# Exit 1 = fix is NOT shipped, or the ref is unknown (DO NOT close).

print_usage() {
  echo "Usage: $0 <fix-commit> [deployed-branch]   (default branch: origin/main)"
  exit "${1:-0}"
}

case "${1:-}" in
  -h | --help) print_usage 0 ;;
  "") print_usage 1 ;;
esac

FIX="$1"
BRANCH="${2:-origin/main}"

# Refresh the deployed branch only when it is a remote ref (non-fatal).
if [[ "$BRANCH" == origin/* ]]; then
  git fetch --quiet origin "${BRANCH#origin/}" 2>/dev/null || true
fi

if ! git rev-parse --verify --quiet "${FIX}^{commit}" >/dev/null; then
  echo "ERROR: unknown commit '$FIX' (fetch it or check the SHA)." >&2
  exit 1
fi
if ! git rev-parse --verify --quiet "${BRANCH}^{commit}" >/dev/null; then
  echo "ERROR: unknown branch '$BRANCH'." >&2
  exit 1
fi

SHORT=$(git rev-parse --short "$FIX")
if git merge-base --is-ancestor "$FIX" "$BRANCH"; then
  echo "SHIPPED: $SHORT is an ancestor of $BRANCH — safe to close."
  exit 0
else
  echo "NOT SHIPPED: $SHORT is NOT an ancestor of $BRANCH." >&2
  echo "  The fix is not on the deployed branch (unmerged branch / closed PR?)." >&2
  echo "  DO NOT close the security issue until the fix is merged to $BRANCH." >&2
  exit 1
fi
