set -euo pipefail

# NixOS Bootstrap/Infect Script
# This script bootstraps NixOS on a fresh system (e.g., Raspberry Pi 5)
# via SSH connection from another machine.
#
# Usage:
#   nix run github:alexandru-savinov/nixos-config#bootstrap -- <hostname> [options]
#
# Or run directly on target:
#   curl -L https://raw.githubusercontent.com/alexandru-savinov/nixos-config/main/scripts/bootstrap.sh | bash -s -- <hostname>

HOSTNAME="${1:-}"
BRANCH="${2:-main}"
REPO_URL="https://github.com/alexandru-savinov/nixos-config"
REPO_FLAKE="github:alexandru-savinov/nixos-config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_banner() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  NixOS Bootstrap/Infect Script                              ║${NC}"
    echo -e "${BLUE}║  For Raspberry Pi 5 and other aarch64/x86_64 systems        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_help() {
    print_banner
    echo "Usage: $0 <hostname> [branch]"
    echo ""
    echo "Arguments:"
    echo "  hostname    Name of the host configuration (required)"
    echo "              Available: sancta-choir, rpi5"
    echo "  branch      Git branch or commit (optional, default: main)"
    echo ""
    echo "Options:"
    echo "  -h, --help  Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Bootstrap RPi5 from main branch"
    echo "  $0 rpi5"
    echo ""
    echo "  # Bootstrap from specific branch"
    echo "  $0 rpi5 feature-branch"
    echo ""
    echo "Prerequisites:"
    echo "  - Target system has network access"
    echo "  - SSH access to target (for remote bootstrap)"
    echo "  - curl, git available on target"
    echo ""
    echo "For Raspberry Pi 5 Setup:"
    echo "  1. Flash Raspberry Pi OS Lite (64-bit) to SD card"
    echo "  2. Enable SSH (touch /boot/ssh or use Imager)"
    echo "  3. Boot the Pi and SSH into it"
    echo "  4. Run this script on the Pi"
    echo ""
    echo "Remote usage (from your workstation):"
    echo "  ssh root@<pi-ip> 'curl -L $REPO_URL/raw/main/scripts/bootstrap.sh | bash -s -- rpi5'"
    echo ""
}

log_info() {
    echo -e "${BLUE}ℹ${NC}  $1"
}

log_success() {
    echo -e "${GREEN}✓${NC}  $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

log_error() {
    echo -e "${RED}✗${NC}  $1"
}

# Handle help flag
case "${1:-}" in
    -h|--help|help|"")
        print_help
        exit 0
        ;;
esac

print_banner

echo "  Hostname:     $HOSTNAME"
echo "  Branch:       $BRANCH"
echo "  Repository:   $REPO_URL"
echo ""

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        SYSTEM="x86_64-linux"
        ;;
    aarch64)
        SYSTEM="aarch64-linux"
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac
log_info "Detected architecture: $ARCH ($SYSTEM)"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    echo "  Try: sudo $0 $*"
    exit 1
fi

# Detect current OS
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        # Normalize Raspberry Pi OS variants to debian
        case "$ID" in
            raspbian|raspberry-pi-os)
                echo "debian"
                ;;
            *)
                echo "$ID"
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

CURRENT_OS=$(detect_os)
log_info "Current OS detected: $CURRENT_OS"

# Check if Nix is already installed
check_nix() {
    if command -v nix &> /dev/null; then
        return 0
    fi
    if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        # shellcheck disable=SC1091
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        return 0
    fi
    return 1
}

# Install Nix package manager
install_nix() {
    log_info "Installing Nix package manager..."

    # Install dependencies
    case "$CURRENT_OS" in
        debian|ubuntu)
            apt-get update
            apt-get install -y curl xz-utils sudo
            ;;
        alpine)
            apk add xz curl sudo bash shadow
            ;;
        fedora|centos|rhel)
            dnf install -y curl xz sudo
            ;;
        arch)
            pacman -Sy --noconfirm curl xz sudo
            ;;
        nixos)
            log_info "Already running NixOS, skipping Nix installation"
            return 0
            ;;
        *)
            log_warning "Unknown OS, assuming dependencies are present"
            ;;
    esac

    # Install Nix using the official installer
    curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes

    # Source Nix
    if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        # shellcheck disable=SC1091
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi

    log_success "Nix installed successfully"
}

# Enable flakes
enable_flakes() {
    log_info "Enabling Nix flakes..."

    mkdir -p /etc/nix
    if ! grep -q "experimental-features" /etc/nix/nix.conf 2>/dev/null; then
        echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf
    fi

    # Also enable for current user
    mkdir -p ~/.config/nix
    echo "experimental-features = nix-command flakes" > ~/.config/nix/nix.conf

    log_success "Flakes enabled"
}

# Install NixOS (infect method)
install_nixos_infect() {
    log_info "Installing NixOS using nixos-infect method..."

    # Set environment for nixos-infect
    export NIX_CHANNEL="nixos-24.05"

    # Download and run nixos-infect
    curl -L https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect | \
        NIX_CHANNEL="$NIX_CHANNEL" bash -x
}

# Generate hardware configuration
generate_hardware_config() {
    log_info "Generating hardware configuration..."

    if command -v nixos-generate-config &> /dev/null; then
        nixos-generate-config --show-hardware-config > /tmp/hardware-configuration.nix
        log_success "Hardware config generated at /tmp/hardware-configuration.nix"
        echo ""
        echo "Review and copy to your host configuration:"
        echo "  cat /tmp/hardware-configuration.nix"
        echo ""
    else
        log_warning "nixos-generate-config not available yet"
    fi
}

# Apply NixOS configuration
apply_config() {
    log_info "Applying NixOS configuration..."

    FLAKE_REF="$REPO_FLAKE/$BRANCH#$HOSTNAME"

    log_info "Building configuration (this may take a while)..."
    if nixos-rebuild build --flake "$FLAKE_REF"; then
        log_success "Build successful!"
    else
        log_error "Build failed!"
        exit 1
    fi

    echo ""
    log_warning "Ready to apply configuration"
    read -p "Apply configuration now? (y/N): " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Applying configuration..."
        if nixos-rebuild switch --flake "$FLAKE_REF"; then
            log_success "Configuration applied successfully!"
        else
            log_error "Failed to apply configuration"
            exit 1
        fi
    else
        log_info "Configuration not applied. Run manually:"
        echo "  sudo nixos-rebuild switch --flake $FLAKE_REF"
    fi
}

# Main installation flow
main() {
    echo "Step 1/5: Checking Nix installation..."
    if check_nix; then
        log_success "Nix is already installed"
    else
        install_nix
    fi

    echo ""
    echo "Step 2/5: Enabling flakes..."
    enable_flakes

    echo ""
    echo "Step 3/5: Checking if NixOS is installed..."
    if [ "$CURRENT_OS" = "nixos" ]; then
        log_success "Already running NixOS"
    else
        echo ""
        log_warning "This system is not running NixOS."
        echo ""
        echo "Options:"
        echo "  1) Use nixos-infect (converts current system to NixOS)"
        echo "  2) Skip infection (just prepare for manual installation)"
        echo ""
        read -p "Choose option (1/2): " -n 1 -r
        echo ""

        case $REPLY in
            1)
                log_warning "nixos-infect will REPLACE your current OS!"
                read -p "Are you sure? Type 'yes' to continue: " -r
                if [ "$REPLY" = "yes" ]; then
                    install_nixos_infect
                else
                    log_info "Skipping nixos-infect"
                fi
                ;;
            *)
                log_info "Skipping NixOS installation"
                ;;
        esac
    fi

    echo ""
    echo "Step 4/5: Generating hardware configuration..."
    generate_hardware_config

    echo ""
    echo "Step 5/5: Applying configuration..."
    if [ "$CURRENT_OS" = "nixos" ]; then
        apply_config
    else
        log_info "Configuration will be applied after NixOS is installed"
        echo ""
        echo "After nixos-infect completes and you reboot:"
        echo "  sudo nixos-rebuild switch --flake $REPO_FLAKE/$BRANCH#$HOSTNAME"
    fi

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Bootstrap Complete!                                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Review hardware configuration: cat /tmp/hardware-configuration.nix"
    echo "  2. Update hosts/$HOSTNAME/hardware-configuration.nix with actual values"
    echo "  3. Add your SSH public key to hosts/$HOSTNAME/configuration.nix"
    echo "  4. Commit and push changes to the repository"
    echo "  5. Rebuild: sudo nixos-rebuild switch --flake $REPO_FLAKE#$HOSTNAME"
    echo ""
    echo "For Raspberry Pi 5 specific notes:"
    echo "  - Update filesystem UUIDs in hardware-configuration.nix"
    echo "  - Verify boot partition is correctly configured"
    echo "  - Consider using NVMe for better performance"
    echo ""
}

main
