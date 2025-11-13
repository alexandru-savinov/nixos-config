set -euo pipefail

# Fresh system installation script
# Usage: install.sh <hostname> [branch/commit]

# Arguments:
#   hostname: Name of the host configuration (required)
#   branch:   Git branch or commit (optional, default: main)

HOSTNAME="${1:-}"
BRANCH="${2:-main}"
REPO_URL="github:alexandru-savinov/nixos-config"

# Validation
if [ -z "$HOSTNAME" ]; then
    echo "Error: Hostname required"
    echo ""
    echo "Usage: $0 <hostname> [branch]"
    echo ""
    echo "Examples:"
    echo "  $0 sancta-choir              # Install from main branch"
    echo "  $0 sancta-choir dev          # Install from dev branch"
    echo "  $0 sancta-choir abc123       # Install from specific commit"
    echo ""
    echo "Available hosts:"
    echo "  - sancta-choir"
    exit 1
fi

# Handle help flag
case "$HOSTNAME" in
    -h|--help|help)
        echo "NixOS Config Fresh Installation Script"
        echo ""
        echo "Usage: $0 <hostname> [branch]"
        echo ""
        echo "This script installs NixOS configuration directly from GitHub."
        echo "Perfect for fresh system installations or recovery."
        echo ""
        echo "Prerequisites:"
        echo "  - NixOS installed with basic system"
        echo "  - Experimental features enabled (flakes, nix-command)"
        echo "  - Internet connection"
        echo "  - Root/sudo access"
        echo ""
        echo "Steps:"
        echo "  1. Enable flakes (if not already):"
        echo "     nix-shell -p git --run 'nix run $REPO_URL#install -- <hostname>'"
        echo ""
        echo "  2. The script will fetch and apply your configuration"
        echo ""
        echo "  3. Set up hardware-configuration.nix:"
        echo "     - Generate: nixos-generate-config"
        echo "     - Copy to: hosts/<hostname>/hardware-configuration.nix"
        echo "     - Commit and push to GitHub"
        echo ""
        echo "Note: This rebuilds the entire system. Backup important data first!"
        exit 0
        ;;
esac

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  NixOS Config Installation                                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Hostname:     $HOSTNAME"
echo "  Branch/Ref:   $BRANCH"
echo "  Repository:   $REPO_URL"
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then 
    echo "⚠️  Warning: Not running as root. Will need sudo for nixos-rebuild."
    SUDO="sudo"
else
    SUDO=""
fi

# Check if flakes are enabled
if ! nix flake --version &> /dev/null; then
    echo "❌ Error: Flakes not available"
    echo ""
    echo "Enable experimental features:"
    echo "  mkdir -p ~/.config/nix"
    echo "  echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf"
    exit 1
fi

# Build the flake URL
FLAKE_URL="$REPO_URL/$BRANCH#$HOSTNAME"

echo "📦 Fetching configuration from GitHub..."
echo "   URL: $FLAKE_URL"
echo ""

# First, try to build without applying
echo "🔨 Testing build (dry-run)..."
if $SUDO nixos-rebuild build --flake "$FLAKE_URL"; then
    echo "✅ Build successful!"
    echo ""
else
    echo "❌ Build failed!"
    echo ""
    echo "Common issues:"
    echo "  - Hardware configuration missing for this host"
    echo "  - Network connectivity problems"
    echo "  - Invalid hostname or branch"
    exit 1
fi

# Ask for confirmation
echo "⚠️  This will rebuild your entire system!"
echo ""
read -p "Continue with installation? (yes/no): " -r
echo ""

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# Apply the configuration
echo "🚀 Applying configuration..."
if $SUDO nixos-rebuild switch --flake "$FLAKE_URL"; then
    echo ""
    echo "✅ Installation complete!"
    echo ""
    echo "Next steps:"
    echo "  - Review the changes"
    echo "  - Reboot if kernel was updated"
    echo "  - Clone the config repo locally for future updates:"
    echo "    git clone https://github.com/alexandru-savinov/nixos-config.git"
else
    echo ""
    echo "❌ Installation failed!"
    echo ""
    echo "You can try to rollback:"
    echo "  sudo nixos-rebuild switch --rollback"
    exit 1
fi
