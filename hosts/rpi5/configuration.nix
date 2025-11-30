# Raspberry Pi 5 Configuration
# Lightweight server configuration for RPi5
#
# This host is designed for:
# - Remote SSH access via Tailscale
# - Running lightweight services
# - Headless operation

{ config
, pkgs
, pkgs-unstable
, lib
, self
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
    # Note: We don't import host.nix or networking.nix because they contain sancta-choir-specific settings:
    # - Hetzner Cloud networking with hardcoded static IPs
    # - MAC address binding for eth0
    # - sancta-choir hostname
    # ../../modules/system/host.nix
    # ../../modules/system/networking.nix  # Hetzner Cloud specific, incompatible with RPi5
    ../../modules/users/root.nix
    ../../modules/services/copilot.nix
    ../../modules/services/tailscale.nix
    # Add more services as needed:
    # ../../modules/services/tsidp.nix
    # ../../modules/services/open-webui.nix  # May be too heavy for RPi5
    # ../../modules/services/uptime-kuma.nix
  ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # VSCode Server support (for remote development)
  services.vscode-server.enable = true;

  # Firewall
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # System packages (merged for RPi5)
  environment.systemPackages = with pkgs; [
    # Development tools
    helix
    neovim
    tmux
    tree
    ripgrep
    fd
    nodejs_22
    gh
    pkgs-unstable.github-copilot-cli

    # Nix development tools
    nixpkgs-fmt
    nil

    # System utilities
    htop
    btop
    iotop
    lsof

    # Network tools
    dig
    tcpdump
    iperf3

    # Hardware monitoring
    lm_sensors
  ];

  # Agenix secrets
  age.secrets = {
    # Tailscale authentication
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";

    # Add more secrets as needed for enabled services:
    # open-webui-secret-key.file = "${self}/secrets/open-webui-secret-key.age";
    # openrouter-api-key.file = "${self}/secrets/openrouter-api-key.age";
  };

  # Hostname
  networking.hostName = "rpi5";
  networking.domain = "";

  # RPi5 specific networking
  networking.useDHCP = lib.mkDefault true;
  # Uncomment for static IP:
  # networking.interfaces.end0.ipv4.addresses = [{
  #   address = "192.168.1.100";
  #   prefixLength = 24;
  # }];
  # networking.defaultGateway = "192.168.1.1";
  # networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  # Enable wireless if needed (RPi5 has built-in WiFi)
  # networking.wireless.enable = true;
  # Or use NetworkManager:
  # networking.networkmanager.enable = true;

  # ============================================================
  # CRITICAL: SSH ACCESS WILL BE DISABLED IF THIS IS NOT UPDATED!
  # You MUST replace the placeholder below with your actual SSH public key
  # BEFORE deploying this system, or you will be locked out.
  # Example:
  #   "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... your-key-comment"
  # ============================================================
  users.users.root.openssh.authorizedKeys.keys = [
    "REPLACE_ME_WITH_YOUR_SSH_PUBLIC_KEY"
  ];

  # Optimize for RPi5 (limited resources)
  # Disable heavy documentation
  documentation = {
    enable = lib.mkDefault false;
    man.enable = lib.mkDefault true;
    nixos.enable = lib.mkDefault false;
  };

  # Reduce journal size
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    RuntimeMaxUse=50M
  '';

  # Enable automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Optimize nix store
  nix.settings = {
    auto-optimise-store = true;
    # Limit build jobs for RPi5 (4 cores, limited RAM)
    max-jobs = 2;
    cores = 2;
  };

  # Timezone (adjust as needed)
  time.timeZone = "UTC";

  # System state version (override common.nix default)
  # This should match the NixOS version used for initial installation
  system.stateVersion = lib.mkForce "24.05";
}
