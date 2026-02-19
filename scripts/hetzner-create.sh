#!/usr/bin/env bash
set -euo pipefail

# Create and provision a Hetzner Cloud VPS with NixOS via nixos-anywhere
#
# Usage: hetzner-create [--name NAME] [--type TYPE] [--location LOC] [--config CONFIG]
#
# Requires: hcloud (with HCLOUD_TOKEN set), nixos-anywhere, ssh-keygen

# ── Defaults ────────────────────────────────────────────────────
NAME=""
SERVER_TYPE="cx22"          # 2 vCPU, 4GB RAM, 40GB disk
LOCATION="fsn1"             # Falkenstein, Germany
CONFIG="hetzner-ephemeral"  # Flake config name
SSH_KEY_NAME="nixos-deploy" # Hetzner SSH key name
FLAKE_DIR=""                # Auto-detected

# ── Parse args ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    NAME="$2"; shift 2 ;;
    --type)    SERVER_TYPE="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --config)  CONFIG="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: hetzner-create [--name NAME] [--type TYPE] [--location LOC] [--config CONFIG]"
      echo ""
      echo "Options:"
      echo "  --name      Server name (default: auto-generated)"
      echo "  --type      Server type (default: cx22 — 2 vCPU, 4GB RAM)"
      echo "  --location  Datacenter (default: fsn1 — Falkenstein)"
      echo "  --config    Flake config name (default: hetzner-ephemeral)"
      echo ""
      echo "Server types: cx22 (4GB), cx32 (8GB), cx42 (16GB), cx52 (32GB)"
      echo "Locations: fsn1 (Falkenstein), nbg1 (Nuremberg), hel1 (Helsinki)"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Auto-generate name if not provided
if [ -z "$NAME" ]; then
  NAME="nixos-$(date +%Y%m%d-%H%M%S)"
fi

# Find flake directory (script is in scripts/, flake is one level up)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLAKE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$FLAKE_DIR/flake.nix" ]; then
  echo "Error: Cannot find flake.nix (looked in $FLAKE_DIR)" >&2
  exit 1
fi

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Hetzner Cloud VPS Provisioning                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Name:     $NAME"
echo "  Type:     $SERVER_TYPE"
echo "  Location: $LOCATION"
echo "  Config:   $CONFIG"
echo "  Flake:    $FLAKE_DIR"
echo ""

# ── Step 1: Register SSH key (idempotent) ───────────────────────
echo "→ Registering SSH key with Hetzner..."
SSH_PUB_KEY=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null) || {
  echo "Error: No SSH public key found (~/.ssh/id_ed25519.pub or id_rsa.pub)" >&2
  exit 1
}

if hcloud ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1; then
  echo "  SSH key '$SSH_KEY_NAME' already registered"
else
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key "$SSH_PUB_KEY"
  echo "  SSH key '$SSH_KEY_NAME' registered"
fi

# ── Step 2: Create server ───────────────────────────────────────
echo ""
echo "→ Creating server '$NAME' ($SERVER_TYPE in $LOCATION)..."
hcloud server create \
  --name "$NAME" \
  --type "$SERVER_TYPE" \
  --location "$LOCATION" \
  --image ubuntu-24.04 \
  --ssh-key "$SSH_KEY_NAME"

# Get server IP
SERVER_IP=$(hcloud server ip "$NAME")
echo "  Server created: $SERVER_IP"

# ── Step 3: Wait for SSH ────────────────────────────────────────
echo ""
echo "→ Waiting for SSH to become available..."
TIMEOUT=120
ELAPSED=0
while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@"$SERVER_IP" true 2>/dev/null; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "Error: SSH not available after ${TIMEOUT}s" >&2
    exit 1
  fi
  echo "  Waiting... (${ELAPSED}s)"
done
echo "  SSH is ready"

# ── Step 4: Prepare --extra-files ───────────────────────────────
echo ""
echo "→ Preparing extra files..."
EXTRA_DIR=$(mktemp -d)
trap 'rm -rf "$EXTRA_DIR"' EXIT

# Inject Tailscale auth key if available
TS_KEY_FILE="/run/agenix/tailscale-auth-key"
if [ -r "$TS_KEY_FILE" ]; then
  mkdir -p "$EXTRA_DIR/etc"
  cp "$TS_KEY_FILE" "$EXTRA_DIR/etc/tailscale-auth-key"
  chmod 600 "$EXTRA_DIR/etc/tailscale-auth-key"
  echo "  Tailscale auth key injected"
else
  echo "  Warning: $TS_KEY_FILE not readable (Tailscale won't auto-join)" >&2
fi

# ── Step 5: Run nixos-anywhere ──────────────────────────────────
echo ""
echo "→ Running nixos-anywhere (this will take several minutes)..."
echo "  Building on remote: $SERVER_IP"
echo ""

nixos-anywhere \
  --build-on-remote \
  --extra-files "$EXTRA_DIR" \
  --flake "$FLAKE_DIR#$CONFIG" \
  root@"$SERVER_IP"

# ── Step 6: Summary ─────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Provisioning Complete                              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Name:       $NAME"
echo "  IP:         $SERVER_IP"
echo "  SSH:        ssh root@$SERVER_IP"
echo "  Tailscale:  Will appear as '$NAME' (if auth key was injected)"
echo ""
echo "  Destroy:    nix run .#hetzner-destroy -- --name $NAME"
