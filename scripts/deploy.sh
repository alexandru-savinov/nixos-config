set -euo pipefail

# NixOS configuration deployment script
# Usage: deploy.sh <hostname> [flake-path]

HOSTNAME="${1:-}"
FLAKE_PATH="${2:-.}"  # Default to current directory

if [ -z "$HOSTNAME" ]; then
    echo "Usage: $0 <hostname> [flake-path]"
    echo ""
    echo "Arguments:"
    echo "  hostname:    Name of the host configuration (required)"
    echo "  flake-path:  Path or URL to flake (optional, default: .)"
    echo ""
    echo "Examples:"
    echo "  $0 sancta-choir                                    # Deploy locally"
    echo "  $0 sancta-choir github:alexandru-savinov/nixos-config  # Deploy from GitHub"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  NixOS Configuration Deployment                             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Hostname:    $HOSTNAME"
echo "  Flake Path:  $FLAKE_PATH"
echo ""

# Check if flake path is local or remote
if [[ "$FLAKE_PATH" =~ ^(github:|gitlab:|git\+) ]]; then
    FLAKE_REF="$FLAKE_PATH#$HOSTNAME"
    echo "📡 Remote deployment mode"
else
    FLAKE_REF="$FLAKE_PATH#$HOSTNAME"
    echo "💻 Local deployment mode"
    echo "⚠️  Note: Run this from your repository directory for best results"
    echo ""
fi

# Check flake
echo "🔍 Checking flake..."
if nix flake check "$FLAKE_PATH" 2>&1 | head -20; then
    echo "✅ Flake check passed"
else
    echo "⚠️  Flake check had warnings (may be normal)"
fi
echo ""

# Build configuration
echo "🔨 Building configuration..."
if nixos-rebuild build --flake "$FLAKE_REF"; then
    echo "✅ Build successful!"
else
    echo "❌ Build failed!"
    exit 1
fi
echo ""

# Ask for confirmation
echo "⚠️  Ready to apply configuration"
read -p "Apply configuration? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🚀 Applying configuration..."
    if sudo nixos-rebuild switch --flake "$FLAKE_REF"; then
        echo ""
        echo "✅ Deployment complete!"
        echo ""
        echo "System rebuilt successfully. You may need to reboot for some changes."
    else
        echo ""
        echo "❌ Deployment failed!"
        exit 1
    fi
else
    echo "Deployment cancelled."
    echo ""
    echo "The build result is available in ./result"
    exit 0
fi
