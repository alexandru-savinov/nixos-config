#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper around hcloud CLI that injects the API token from agenix
# Usage: hcloud-wrap <any hcloud args>

TOKEN_FILE="/run/agenix/hcloud-api-token"

if [ ! -r "$TOKEN_FILE" ]; then
  echo "Error: Cannot read $TOKEN_FILE" >&2
  echo "Run with sudo or ensure agenix has decrypted the secret." >&2
  exit 1
fi

export HCLOUD_TOKEN
HCLOUD_TOKEN="$(cat "$TOKEN_FILE")"

exec hcloud "$@"
