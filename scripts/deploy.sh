set -euo pipefail

# NixOS configuration deployment script
# Usage: deploy.sh [--yes|-y] <hostname> [flake-path]

# Parse flags
YES_FLAG=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)
            YES_FLAG=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--yes|-y] <hostname> [flake-path]"
            echo ""
            echo "Arguments:"
            echo "  hostname:    Name of the host configuration (required)"
            echo "  flake-path:  Path or URL to flake (optional, default: .)"
            echo ""
            echo "Options:"
            echo "  --yes, -y    Skip confirmation prompt (non-interactive mode)"
            echo "  --help, -h   Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 sancta-choir                                    # Deploy locally"
            echo "  $0 --yes sancta-choir                              # Deploy without prompt"
            echo "  $0 sancta-choir github:alexandru-savinov/nixos-config  # Deploy from GitHub"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

HOSTNAME="${1:-}"
FLAKE_PATH="${2:-.}"  # Default to current directory

if [ -z "$HOSTNAME" ]; then
    echo "Usage: $0 [--yes|-y] <hostname> [flake-path]"
    echo ""
    echo "Arguments:"
    echo "  hostname:    Name of the host configuration (required)"
    echo "  flake-path:  Path or URL to flake (optional, default: .)"
    echo ""
    echo "Options:"
    echo "  --yes, -y    Skip confirmation prompt (non-interactive mode)"
    echo "  --help, -h   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 sancta-choir                                    # Deploy locally"
    echo "  $0 --yes sancta-choir                              # Deploy without prompt"
    echo "  $0 sancta-choir github:alexandru-savinov/nixos-config  # Deploy from GitHub"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  NixOS Configuration Deployment                             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Hostname:    $HOSTNAME"
echo "  Flake Path:  $FLAKE_PATH"
if [ "$YES_FLAG" = true ]; then
    echo "  Mode:        Non-interactive (--yes)"
fi
echo ""

# Determine privilege escalation requirements
if [ "$EUID" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Error: This script must run as root or have sudo available"
        exit 1
    fi
    SUDO="sudo"
    echo "Running privileged commands via sudo"
else
    SUDO=""
fi

# Check if flake path is local or remote
if [[ "$FLAKE_PATH" =~ ^(github:|gitlab:|git\+) ]]; then
    FLAKE_REF="$FLAKE_PATH#$HOSTNAME"
    echo "Remote deployment mode"
else
    FLAKE_REF="$FLAKE_PATH#$HOSTNAME"
    echo "Local deployment mode"
    echo "Note: Run this from your repository directory for best results"
    echo ""
fi

# Check flake
echo "Checking flake..."
if FLAKE_CHECK_OUTPUT=$(nix flake check "$FLAKE_PATH" 2>&1); then
    echo "$FLAKE_CHECK_OUTPUT" | head -20
    echo "Flake check passed"
else
    echo "Flake check failed. Output (last 40 lines):"
    echo "$FLAKE_CHECK_OUTPUT" | tail -40
    echo ""
    echo "ERROR: Flake check failed!"
    echo ""
    if [ "$YES_FLAG" = true ]; then
        echo "Aborting deployment (non-interactive mode)."
        exit 1
    elif [ ! -t 0 ]; then
        echo "Aborting deployment (no TTY for confirmation)."
        echo "Use --yes flag to proceed despite errors in non-interactive mode."
        exit 1
    else
        echo "The flake has errors. Proceeding may result in a broken deployment."
        read -p "Continue despite errors? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Deployment cancelled due to flake check failure."
            exit 1
        fi
        echo "WARNING: Proceeding despite flake check errors at user request."
    fi
fi
echo ""

# Build configuration
echo "Building configuration..."
if nixos-rebuild build --flake "$FLAKE_REF"; then
    echo "Build successful!"
else
    echo "Build failed!"
    exit 1
fi
echo ""

# Ask for confirmation (unless --yes flag is set)
if [ "$YES_FLAG" = true ]; then
    echo "Applying configuration (--yes flag set)..."
else
    # Check for TTY - interactive mode requires a terminal
    if [ ! -t 0 ]; then
        echo "ERROR: Interactive mode requires a terminal (stdin is not a TTY)"
        echo "Use --yes flag for non-interactive deployments"
        exit 1
    fi
    echo "Ready to apply configuration"
    read -p "Apply configuration? (y/N): " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled by user."
        echo ""
        echo "The build result is available in ./result"
        exit 0
    fi
    echo "Applying configuration..."
fi

if $SUDO nixos-rebuild switch --flake "$FLAKE_REF"; then
    echo ""
    echo "Deployment complete!"
    echo ""
    echo "System rebuilt successfully. You may need to reboot for some changes."
else
    echo ""
    echo "Deployment failed!"
    exit 1
fi
