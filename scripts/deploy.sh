#!/usr/bin/env bash
set -euo pipefail

# Simple deployment script for NixOS configurations
# Usage: ./scripts/deploy.sh <hostname>

HOSTNAME="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -z "$HOSTNAME" ]; then
    echo "Usage: $0 <hostname>"
    echo "Available hosts:"
    ls -1 "$REPO_ROOT/hosts" | grep -v common.nix
    exit 1
fi

echo "Deploying configuration for: $HOSTNAME"
cd "$REPO_ROOT"

# Check flake
echo "Checking flake..."
nix flake check

# Build configuration
echo "Building configuration..."
nixos-rebuild build --flake ".#$HOSTNAME"

# Ask for confirmation
read -p "Apply configuration? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Applying configuration..."
    sudo nixos-rebuild switch --flake ".#$HOSTNAME"
    echo "Deployment complete!"
else
    echo "Deployment cancelled."
    exit 0
fi
