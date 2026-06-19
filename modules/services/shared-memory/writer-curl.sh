#!/usr/bin/env bash
# Cross-host writer — any agent with curl. Posts a memory/atom to the commons
# over Tailscale. The agent needs to know NOTHING about the storage schema.
#   SM_URL=http://rpi5.tail4249a9.ts.net:8730 SM_AGENT=nullclaw \
#     ./writer-curl.sh '{"kind":"learning","statement":"…"}'
# (payload may also be piped on stdin)
set -euo pipefail
URL="${SM_URL:-http://127.0.0.1:8730}"
curl -fsS -X POST "$URL/write" \
  -H "x-agent: ${SM_AGENT:-$(hostname)}" \
  ${SM_TO:+-H "x-to: ${SM_TO}"} \
  ${SM_TOPIC:+-H "x-topic: ${SM_TOPIC}"} \
  --data "${1:-$(cat)}"
echo
