#!/usr/bin/env bash
# Same-host writer — NO network, NO libraries (not even jq). Drop any payload
# into the inbox; the librarian accepts bare files (hashes the bytes, ingests),
# so the writer knows NOTHING about the schema. Atomic via temp+rename.
#   SM_STATE=/var/lib/shared-memory ./writer-file.sh '{"kind":"note","statement":"hi"}'
# (payload may also be piped on stdin)
set -euo pipefail
STATE="${SM_STATE:-$HOME/.sharedmem}"; INBOX="$STATE/inbox"; mkdir -p "$INBOX"
id="$(date +%s%N)-$$"; tmp="$INBOX/${id}.json.tmp"; fin="$INBOX/${id}.json"
{ [ $# -gt 0 ] && printf '%s' "$1" || cat; } > "$tmp"
mv "$tmp" "$fin"
echo "dropped $fin"
