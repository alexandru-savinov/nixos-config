{ config
, pkgs
, lib
, self
, claude-code
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../common.nix
    ../../modules/system/dev-tools.nix
    ../../modules/system/nix-ld.nix
    ../../modules/users/root.nix
    ../../modules/services/claude.nix
    ../../modules/services/tailscale.nix
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claude.enable = true;

  # Build tools for OpenClaw npm native compilation (llama.cpp, etc.)
  environment.systemPackages = with pkgs; [
    cmake
    gnumake
    gcc
    python3
  ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # ── Networking (inline — not importing host.nix/networking.nix) ──────────
  # Placeholders: replace after hcloud provisioning
  networking.hostName = "sancta-claw";
  networking.domain = "";
  networking.useDHCP = false;
  networking.usePredictableInterfaceNames = lib.mkForce false;
  networking.dhcpcd.enable = false;
  networking.nameservers = [ "8.8.8.8" "185.12.64.1" "185.12.64.2" ];

  networking.interfaces.eth0 = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "46.225.168.24";
      prefixLength = 32;
    }];
    ipv6.addresses = [{
      address = "fe80::9000:7ff:fe40:d620";
      prefixLength = 64;
    }];
    ipv4.routes = [{ address = "172.31.1.1"; prefixLength = 32; }];
  };

  networking.defaultGateway = {
    address = "172.31.1.1";
    interface = "eth0";
  };

  # MAC address binding for Hetzner Cloud
  services.udev.extraRules = ''
    ATTR{address}=="92:00:07:40:d6:20", NAME="eth0"
  '';

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Firewall: SSH only on public interface, Tailscale trusted
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # Time zone
  time.timeZone = "Europe/Chisinau";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── Agenix Secrets ──────────────────────────────────────────────────────
  age.secrets = {
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
  };

  # ── Home Manager ────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
  };

  # ── Swap (2GB — prevents OOM during builds on CX32) ────────────────────
  swapDevices = [
    {
      device = "/swapfile";
      size = 2048;
    }
  ];

  # ── OpenClaw User & Service ─────────────────────────────────────────────
  users.users.openclaw = {
    isSystemUser = true;
    group = "openclaw";
    home = "/var/lib/openclaw";
    createHome = true;
    shell = pkgs.bash;
    # npm global bin needs to be on PATH
    packages = with pkgs; [ nodejs_22 ];
  };
  users.groups.openclaw = { };

  systemd.services.openclaw = {
    description = "OpenClaw AI Agent";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HOME = "/var/lib/openclaw";
      PATH = lib.mkForce "/var/lib/openclaw/.npm-global/bin:${lib.makeBinPath (with pkgs; [ nodejs_22 git coreutils bash ])}:/run/current-system/sw/bin";
      # npm global prefix
      NPM_CONFIG_PREFIX = "/var/lib/openclaw/.npm-global";
    };

    serviceConfig = {
      Type = "simple";
      User = "openclaw";
      Group = "openclaw";
      WorkingDirectory = "/var/lib/openclaw";
      ExecStart = "/var/lib/openclaw/.npm-global/bin/openclaw start";
      Restart = "on-failure";
      RestartSec = 10;

      # Resource limits: 6GB memory, 300% CPU (3 of 4 cores)
      MemoryMax = "6G";
      MemoryHigh = "5G";
      CPUQuota = "300%";

      # Hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = false; # Needs access to /var/lib/openclaw
      ReadWritePaths = [ "/var/lib/openclaw" ];
      PrivateTmp = true;
    };
  };

  # ── Tailscale Serve for OpenClaw UI ─────────────────────────────────────
  systemd.services.openclaw-tailscale-serve = {
    description = "Tailscale Serve for OpenClaw UI";
    after = [ "openclaw.service" "tailscaled.service" ];
    requires = [ "openclaw.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "openclaw-tailscale-serve-start" ''
        # Wait for OpenClaw to be listening
        for i in $(seq 1 30); do
          if ${pkgs.curl}/bin/curl -sf http://127.0.0.1:18789/health >/dev/null 2>&1; then
            break
          fi
          sleep 2
        done
        # Set up Tailscale Serve (idempotent)
        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:18789"; then
          ${pkgs.tailscale}/bin/tailscale serve --bg --https 18789 http://127.0.0.1:18789
        fi
      '';
      ExecStop = pkgs.writeShellScript "openclaw-tailscale-serve-stop" ''
        ${pkgs.tailscale}/bin/tailscale serve --https 18789 off || true
      '';
    };
  };

  # ── SSH authorized keys ─────────────────────────────────────────────────
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2btaYomBlcKG+snrIrBuTXcEaBKEGQoAaF59YWwkal nixos@rpi5"
  ];

  # Fresh install — NixOS 25.05
  system.stateVersion = lib.mkForce "25.05";
}
