#!/usr/bin/env bash
set -euo pipefail

# Manage Hetzner Cloud VPS instances
#
# Usage: hetzner-manage <command> [--name NAME] [options]
#
# Commands:
#   list      List all servers
#   status    Show server details
#   ssh       SSH into server
#   reboot    Reboot server
#   snapshot  Create server snapshot
#   resize    Resize server (poweroff → change-type → poweron)
#   deploy    SSH in and rebuild NixOS config

COMMAND="${1:-}"
shift 2>/dev/null || true

NAME=""
SERVER_TYPE=""
FLAKE_CONFIG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)   NAME="$2"; shift 2 ;;
    --type)   SERVER_TYPE="$2"; shift 2 ;;
    --config) FLAKE_CONFIG="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: hetzner-manage <command> [--name NAME] [options]"
      echo ""
      echo "Commands:"
      echo "  list              List all servers"
      echo "  status --name N   Show server details"
      echo "  ssh --name N      SSH into server"
      echo "  reboot --name N   Reboot server"
      echo "  snapshot --name N Create server snapshot"
      echo "  resize --name N --type TYPE  Resize (poweroff → resize → poweron)"
      echo "  deploy --name N [--config C] SSH in and nixos-rebuild switch"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

require_name() {
  if [ -z "$NAME" ]; then
    echo "Error: --name is required for '$COMMAND'" >&2
    exit 1
  fi
}

case "$COMMAND" in
  list)
    hcloud server list
    ;;

  status)
    require_name
    hcloud server describe "$NAME"
    ;;

  ssh)
    require_name
    SERVER_IP=$(hcloud server ip "$NAME")
    exec ssh -o StrictHostKeyChecking=no root@"$SERVER_IP"
    ;;

  reboot)
    require_name
    echo "Rebooting '$NAME'..."
    hcloud server reboot "$NAME"
    echo "Reboot initiated."
    ;;

  snapshot)
    require_name
    SNAPSHOT_DESC="$NAME-$(date +%Y%m%d-%H%M%S)"
    echo "Creating snapshot '$SNAPSHOT_DESC'..."
    hcloud server create-image --type snapshot --description "$SNAPSHOT_DESC" "$NAME"
    echo "Snapshot created."
    ;;

  resize)
    require_name
    if [ -z "$SERVER_TYPE" ]; then
      echo "Error: --type is required for resize" >&2
      echo "Example: hetzner-manage resize --name myserver --type cx32" >&2
      exit 1
    fi
    echo "Resizing '$NAME' to $SERVER_TYPE..."
    echo "→ Powering off..."
    hcloud server poweroff "$NAME"
    # Poll for poweroff
    TIMEOUT=60
    ELAPSED=0
    while [ "$(hcloud server describe "$NAME" -o format='{{.Status}}')" != "off" ]; do
      sleep 2
      ELAPSED=$((ELAPSED + 2))
      if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "Error: Server did not power off within ${TIMEOUT}s" >&2
        exit 1
      fi
    done
    echo "→ Changing type..."
    hcloud server change-type "$NAME" "$SERVER_TYPE"
    echo "→ Powering on..."
    hcloud server poweron "$NAME"
    echo "Resize complete. New type: $SERVER_TYPE"
    ;;

  deploy)
    require_name
    SERVER_IP=$(hcloud server ip "$NAME")
    REMOTE_CONFIG="${FLAKE_CONFIG:-$NAME}"
    echo "Deploying to '$NAME' ($SERVER_IP) with config '$REMOTE_CONFIG'..."
    echo "→ Building..."
    # shellcheck disable=SC2029
    ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" \
      "cd /etc/nixos && git pull && nixos-rebuild build --flake .#$REMOTE_CONFIG"
    echo "→ Switching..."
    # shellcheck disable=SC2029
    ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" \
      "nixos-rebuild switch --flake /etc/nixos#$REMOTE_CONFIG"
    echo "Deploy complete."
    ;;

  "")
    echo "Error: No command specified" >&2
    echo "Usage: hetzner-manage <command> [--name NAME] [options]" >&2
    echo "Commands: list, status, ssh, reboot, snapshot, resize, deploy" >&2
    exit 1
    ;;

  *)
    echo "Error: Unknown command '$COMMAND'" >&2
    echo "Commands: list, status, ssh, reboot, snapshot, resize, deploy" >&2
    exit 1
    ;;
esac
