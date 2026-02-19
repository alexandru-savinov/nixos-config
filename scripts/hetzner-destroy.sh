#!/usr/bin/env bash
set -euo pipefail

# Destroy a Hetzner Cloud VPS with optional Tailscale cleanup
#
# Usage: hetzner-destroy --name NAME [--yes]

NAME=""
YES_FLAG=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)  NAME="$2"; shift 2 ;;
    --yes|-y) YES_FLAG=true; shift ;;
    --help|-h)
      echo "Usage: hetzner-destroy --name NAME [--yes]"
      echo ""
      echo "Options:"
      echo "  --name    Server name (required)"
      echo "  --yes     Skip confirmation prompt"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "Error: --name is required" >&2
  echo "Usage: hetzner-destroy --name NAME [--yes]" >&2
  exit 1
fi

# Verify server exists
if ! hcloud server describe "$NAME" >/dev/null 2>&1; then
  echo "Error: Server '$NAME' not found" >&2
  exit 1
fi

SERVER_IP=$(hcloud server ip "$NAME")
echo "Server: $NAME ($SERVER_IP)"

# Confirm unless --yes
if [ "$YES_FLAG" != true ]; then
  if [ ! -t 0 ]; then
    echo "Error: Interactive confirmation required (use --yes for non-interactive)" >&2
    exit 1
  fi
  read -p "Destroy server '$NAME'? This cannot be undone. (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

# Remove from Tailscale (best-effort)
echo "→ Removing from Tailscale (best-effort)..."
if command -v tailscale >/dev/null 2>&1; then
  # Try to find and remove the device by hostname
  DEVICE_ID=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"$NAME\") | .ID" 2>/dev/null || true)
  if [ -n "$DEVICE_ID" ]; then
    tailscale admin remove "$DEVICE_ID" 2>/dev/null && echo "  Removed Tailscale device $DEVICE_ID" || echo "  Could not remove Tailscale device (remove manually from admin console)"
  else
    echo "  Device '$NAME' not found in Tailscale peers (may not have joined yet)"
  fi
else
  echo "  tailscale CLI not found (remove device manually from admin console)"
fi

# Delete server
echo "→ Deleting server '$NAME'..."
hcloud server delete "$NAME"

echo ""
echo "Server '$NAME' destroyed."
