# Raspberry Pi 5 Configuration
# Lightweight server configuration for RPi5 with Open-WebUI
#
# This host is designed for:
# - Remote SSH access via Tailscale
# - Running Open-WebUI with OpenRouter backend
# - Headless operation with optimized resources

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
    ../../modules/services/open-webui.nix
    # Add more services as needed:
    # ../../modules/services/tsidp.nix
    # ../../modules/services/uptime-kuma.nix
  ];

  # Allow unfree and broken packages (chromadb is marked broken on aarch64)
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowBroken = true;

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

    # Open-WebUI secrets
    open-webui-secret-key.file = "${self}/secrets/open-webui-secret-key.age";
    openrouter-api-key.file = "${self}/secrets/openrouter-api-key.age";
    tavily-api-key.file = "${self}/secrets/tavily-api-key.age";

    # OIDC (disabled for now, but secret available if needed)
    # oidc-client-secret.file = "${self}/secrets/oidc-client-secret.age";
  };

  # Open-WebUI with OpenRouter backend
  # Access via Tailscale HTTPS: https://rpi5.tail4249a9.ts.net
  services.open-webui-tailscale = {
    enable = true;
    enableSignup = false; # Closed signup - admin only
    secretKeyFile = config.age.secrets.open-webui-secret-key.path;
    openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;
    webuiUrl = "https://rpi5.tail4249a9.ts.net";

    # Tavily Search API for RAG web search
    tavilySearch = {
      enable = true;
      apiKeyFile = config.age.secrets.tavily-api-key.path;
    };

    # OIDC authentication - disabled (same issue as sancta-choir with tsidp on same host)
    oidc = {
      enable = false;
    };

    # Tailscale Serve for HTTPS
    tailscaleServe = {
      enable = true;
      httpsPort = 443;
    };
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
  # ============================================================
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
  ];

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
    min-free = 512 * 1024 * 1024;  # 512MB - minimum free space to maintain
  };

  # Swap configuration for heavy workloads (Open-WebUI, builds)
  # Using a swap file instead of zram alone for better stability
  swapDevices = [
    {
      device = "/var/swapfile";
      size = 4096; # 4GB swap file
    }
  ];

  # Enhanced zram configuration for better memory management
  zramSwap = {
    enable = true;
    memoryPercent = 50; # Use up to 50% of RAM for compressed swap
    algorithm = "zstd"; # Better compression ratio
    priority = 100;     # Higher priority than disk swap
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
  systemd = {
    # Default timeout for services (faster failure detection)
    extraConfig = ''
      DefaultTimeoutStartSec=90s
      DefaultTimeoutStopSec=90s
    '';

    # Open-WebUI specific optimizations
    services.open-webui = {
      serviceConfig = {
        # Memory limits to prevent runaway usage
        MemoryMax = "2G";
        MemoryHigh = "1536M";
        # CPU limits during peak usage
        CPUQuota = "300%"; # 3 cores max
        # Nice value for lower priority during builds
        Nice = 5;
        # IO priority
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 4;
      };
    };
  };

  # Timezone (adjust as needed)
  time.timeZone = "UTC";

  # System state version
  system.stateVersion = lib.mkForce "24.05";
}
