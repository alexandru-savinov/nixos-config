{ lib
, self
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
    ./backup-user.nix
    ./restore.nix
    ./smoke-test.nix
    ./openclaw-service.nix
    ./openclaw-watchers.nix
    ./openclaw-tailscale-serve.nix
    ./openclaw-backup-acl.nix
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

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # ── Networking (Hetzner Cloud — DHCP for DR portability) ────────────────
  networking = {
    hostName = "sancta-claw";
    useDHCP = true;
    usePredictableInterfaceNames = lib.mkForce false;
    nameservers = [ "8.8.8.8" "185.12.64.1" "185.12.64.2" ];
    # Firewall: SSH only on public interface, Tailscale trusted
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Time zone
  time.timeZone = "Europe/Chisinau";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── Agenix Secrets ──────────────────────────────────────────────────────
  # Use stable age recovery key (not SSH host key) for secret decryption.
  # Placed by nixos-anywhere --extra-files during DR; or manually for existing deploys.
  age.identityPaths = [ "/root/.age/recovery.key" ];
  age.secrets =
    let
      kuzeaSecret = name: {
        file = "${self}/secrets/${name}.age";
        owner = "openclaw";
        group = "openclaw";
      };
    in
    {
      tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";
      # Kuzea-specific secrets — decriptabile doar pe sancta-claw
      kuzea-caldav-credentials = kuzeaSecret "kuzea-caldav-credentials";
      kuzea-github-token = kuzeaSecret "kuzea-github-token";
      kuzea-todoist-credentials = kuzeaSecret "kuzea-todoist-credentials";
      kuzea-airtable-credentials = kuzeaSecret "kuzea-airtable-credentials";
      kuzea-tavily-api-key = kuzeaSecret "kuzea-tavily-api-key";
      # OpenAI API key for memory embeddings (semantic recall)
      openai-api-key = kuzeaSecret "openai-api-key";
    };

  # ── Home Manager (scaffolding — required by root.nix, no user configs yet) ──
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
  };

  # ── Swap (12GB — prevents OOM during builds and heavy workloads on CX33) ────────────────────
  swapDevices = [
    {
      device = "/swapfile";
      size = 12288;
    }
  ];

  # ── SSH authorized keys ─────────────────────────────────────────────────
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2btaYomBlcKG+snrIrBuTXcEaBKEGQoAaF59YWwkal nixos@rpi5"
  ];

  # ── Automatic security updates ──────────────────────────────────────────
  # Rebuilds from the latest commit on main nightly. nixpkgs advances when a
  # flake.lock update is committed to the repo. The .github/workflows/flake-update.yml
  # CI job handles this automatically: nightly (02:00 UTC) for nixpkgs security
  # patches, weekly (Mon 09:00 UTC) for all inputs — both open PRs automatically.
  # --update-input is intentionally omitted: with a remote GitHub flake URL
  # there is no local path to write an updated lock file back to, so the flag
  # would be a no-op. allowReboot=false: never reboots automatically (VPS —
  # schedule manual reboots for kernel updates).
  system.autoUpgrade = {
    enable = true;
    flake = "github:alexandru-savinov/nixos-config#sancta-claw";
    dates = "04:30";
    randomizedDelaySec = "30min";
    allowReboot = false;
  };

  # Fresh install — NixOS 25.05
  system.stateVersion = lib.mkForce "25.05";
}
