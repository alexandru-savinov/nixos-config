# Raspberry Pi 5 Configuration - MINIMAL (for SD image builds)
# Uses nvmd/nixos-raspberrypi for kernel 6.12.34 and firmware support
# See: https://github.com/nvmd/nixos-raspberrypi
#
# This is the MINIMAL config for SD image builds. For full services, use rpi5-full.
#
# Workflow:
#   1. Build SD image:  nix build .#images.rpi5-sd-image
#   2. Flash to SD card and boot the Pi
#   3. Switch to full config:  sudo nixos-rebuild switch --flake .#rpi5-full
#
# This minimal config includes:
# - SSH access via Tailscale
# - Basic development tools (helix, neovim, nodejs, etc.)
# - Claude Code CLI
#
# For Open-WebUI, n8n, Gatus → use rpi5-full after first boot

{ config
, pkgs
, lib
, self
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/copilot.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/unifi-mcp.nix
    ../../modules/services/n8n-skills.nix
    ../../modules/services/claude-skills.nix
    ../../modules/services/claude-agents.nix
    ../../modules/services/claude-settings.nix
    ../../modules/services/n8n-mcp-claude.nix
    # Additional services (open-webui, n8n, gatus) are in rpi5-full
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;

  # Home Manager: use system pkgs and suppress the version mismatch warning.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
  };

  # CRITICAL: Do NOT override boot.kernelPackages - nvmd/nixos-raspberrypi provides
  # the correct kernel for RPi5 via flake.nix module configuration.
  nixpkgs.config.allowUnfree = true;

  # SSH configuration (openssh.enable is set in common.nix)
  services.openssh.settings = {
    PermitRootLogin = "prohibit-password";
    PasswordAuthentication = lib.mkDefault true;
  };

  # VSCode Server support (for remote development)
  services.vscode-server.enable = true;

  # Firewall (enabled by default in NixOS)
  networking.firewall.allowedTCPPorts = [ 22 ];

  # RPi5-specific packages (common dev tools are in dev-tools.nix)
  environment.systemPackages = with pkgs; [
    neovim
    iotop
    lsof
    dig
    tcpdump
    iperf3
    lm_sensors
    cachix
  ];

  # Agenix secrets (additional secrets for Open-WebUI, n8n, etc. are in rpi5-full)
  age.secrets = {
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
    unifi-password = {
      file = "${self}/secrets/unifi-password.age";
      mode = "0440";
      group = "wheel"; # Only root and wheel group members can read
    };
  };

  # ==========================================================================
  # UniFi Network MCP - AI-assisted network management
  # ==========================================================================
  # Provides MCP server for Claude to read/modify UniFi controller config.
  # Run `unifi-mcp-config` to generate Claude Desktop/Code MCP config.
  services.unifi-mcp = {
    enable = true;
    host = "192.168.1.1";
    username = "tLoVYfJXE0eE";
    passwordFile = config.age.secrets.unifi-password.path;
    # verifySsl defaults to false (UDM uses self-signed certs)
    # toolRegistration defaults to "lazy" (96% fewer tokens)
    # permissions use safe defaults (high-risk ops disabled)
    # service.enable defaults to false (stdio mode for Claude Code)
  };

  # ==========================================================================
  # n8n Skills and MCP for Claude Code
  # ==========================================================================
  # Provides 7 skills for building production-ready n8n workflows.
  # Documentation-only mode (no API key) - for full workflow management,
  # use rpi5-full config which has local n8n running.
  services.n8n-skills = {
    enable = true;
    users = [ "nixos" "root" ];
  };

  services.claude-skills = {
    enable = true;
    users = [ "nixos" "root" ];
  };

  services.claude-agents = {
    enable = true;
    users = [ "nixos" "root" ];
  };

  services.claude-settings = {
    enable = true;
    users = [ "nixos" ]; # root excluded: skipDangerousModePermissionPrompt too risky for root
  };

  services.n8n-mcp-claude = {
    enable = true;
    users = [ "nixos" "root" ];
    # Documentation-only mode - no n8n instance on minimal config
  };

  # Hostname
  networking.hostName = "rpi5";
  networking.useDHCP = lib.mkDefault true;

  # Root SSH authorized keys
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];

  # Set initial root password for first boot (change immediately after!)
  # Password: nixos (same as default NixOS image)
  users.users.root.initialHashedPassword = "$6$rounds=424242$nixos$abc"; # placeholder, will use nixos default

  # Also create nixos user for compatibility with SD image default login
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "nixos";
  };

  # Allow wheel group to sudo without password for SD-card bootstrap
  # rpi5-full overrides this to require password (lib.mkForce true)
  security.sudo.wheelNeedsPassword = false;

  # ============================================================
  # RESOURCE CONSTRAINTS & OPTIMIZATION FOR RPi5
  # ============================================================

  # Disable heavy documentation to save space and build time
  documentation = {
    enable = lib.mkDefault false;
    man.enable = lib.mkDefault true;
    nixos.enable = lib.mkDefault false;
  };

  # Reduce journal size to save disk space
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    RuntimeMaxUse=50M
  '';

  # Enable automatic garbage collection (aggressive for limited storage)
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 3d";
  };

  # Nix build optimizations for limited resources
  nix.settings = {
    auto-optimise-store = true;
    # Limit concurrent builds to avoid OOM (RPi5 has 4 cores but limited RAM)
    max-jobs = 2;
    cores = 2;
    # Keep build logs short
    log-lines = 25;
    # Use less memory during evaluation
    max-free = 1024 * 1024 * 1024; # 1GB - trigger GC when free space drops
    min-free = 512 * 1024 * 1024; # 512MB - minimum free space to maintain
    # Binary caches - nixos-raspberrypi has kernel 6.12.34 builds
    substituters = [
      "https://cache.nixos.org"
      "https://nixos-raspberrypi.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  # Swap configuration for heavy workloads (Open-WebUI, builds)
  # Using a swap file instead of zram alone for better stability
  swapDevices = lib.mkForce [
    {
      device = "/swapfile";
      size = 8192; # 8GB swap file - needed for nix builds on 4GB RAM
    }
  ];

  # Enhanced zram configuration (enable is set in common.nix)
  zramSwap = {
    memoryPercent = 50;
    algorithm = "zstd";
    priority = 100; # Higher priority than disk swap
  };

  # Fix cgroup memory controller (disabled by RPi5 firmware/bootloader defaults)
  # Without this, all MemoryMax/MemoryHigh systemd limits are NOT enforced.
  # Also enable PSI (Pressure Stall Information) for resource pressure monitoring.
  boot.kernelParams = [ "cgroup_enable=memory" "psi=1" ];

  # Explicitly opt in to the modern direct-kernel-boot path (avoids deprecated "kernelboot" default)
  # See: https://github.com/nvmd/nixos-raspberrypi/pull/61
  boot.loader.raspberry-pi.bootloader = "kernel";

  # earlyoom - userspace OOM killer (defense-in-depth against kernel OOM killer)
  # RPi5 has only 4GB RAM with heavy services; zram alone is not sufficient protection.
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
    enableNotifications = true;
    extraArgs = [
      "--prefer"
      "(open-webui)"
      "--avoid"
      "^(sshd|tailscaled|n8n)"
    ];
  };

  # Kernel tweaks for better memory management under pressure
  boot.kernel.sysctl = {
    # Be more aggressive about swapping to avoid OOM
    "vm.swappiness" = 60;
    # Reduce disk write frequency (good for SD cards)
    "vm.dirty_ratio" = 40;
    "vm.dirty_background_ratio" = 10;
    # More aggressive memory overcommit for Python/Node apps
    "vm.overcommit_memory" = 1;
    # Keep some memory free for system stability
    "vm.min_free_kbytes" = 65536; # 64MB minimum free
  };

  # Systemd tweaks for resource-constrained environment
  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "90s";
    DefaultTimeoutStopSec = "90s";
  };

  # ============================================================
  # BTOP ON TTY1 - Auto-start system monitor on physical console
  # ============================================================
  # Auto-login root on tty1 only (other TTYs require normal login)
  systemd.services."getty@tty1" = {
    overrideStrategy = "asDropin";
    serviceConfig.ExecStart = [
      "" # Clear the default ExecStart
      "@${pkgs.util-linux}/sbin/agetty agetty --autologin root --noclear %I $TERM"
    ];
  };

  # Start btop automatically when logged into tty1
  # Quitting btop (q) returns to a bash shell; type 'exit' to trigger re-login and restart btop
  programs.bash.interactiveShellInit = ''
    # When su'd into nixos from root, cd to home instead of staying in /root
    if [[ "$(id -un)" == "nixos" && "$PWD" == "/root" ]]; then
      cd ~
    fi

    if [[ $(tty) == "/dev/tty1" ]] && [[ -z "$BTOP_RUNNING" ]]; then
      export BTOP_RUNNING=1
      ${pkgs.btop}/bin/btop
    fi
  '';

  time.timeZone = "Europe/Chisinau";

  # System state version - do NOT change on existing systems
  system.stateVersion = lib.mkForce "24.05";
}
