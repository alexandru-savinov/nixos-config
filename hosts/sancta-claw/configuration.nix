{ pkgs
, lib
, self
, ...
}:

let
  # whisper-cpp 1.7.5 in nixpkgs enables GGML_BACKEND_DL on x86_64, compiling
  # the CPU backend as a dynamic plugin (libggml-cpu*.so). However the plugin
  # .so files are not installed, causing a segfault at model load ("devices=0,
  # backends=0"). Override to statically link the CPU backend instead.
  whisper-cpp-fixed = pkgs.whisper-cpp.overrideAttrs (old: {
    cmakeFlags = builtins.filter
      (f: !builtins.elem f [
        "-DGGML_BACKEND_DL:BOOL=TRUE"
        "-DGGML_CPU_ALL_VARIANTS:BOOL=TRUE"
      ])
      old.cmakeFlags;
  });

  kuzeaTranscribe = pkgs.writeShellApplication {
    name = "kuzea-transcribe";
    runtimeInputs = [ whisper-cpp-fixed pkgs.ffmpeg ];
    text = ''
      if [[ $# -lt 1 ]]; then
        echo "Usage: kuzea-transcribe [whisper-cli options...] <input-file>" >&2
        exit 1
      fi
      # Use an array to split off the last argument safely (ShellCheck-clean).
      args=("$@")
      INPUT_FILE="''${args[-1]}"
      ARGS=("''${args[@]:0:$((''${#args[@]} - 1))}")
      TMP_WAV=$(mktemp /tmp/whisper-XXXXXX.wav)
      trap 'rm -f "$TMP_WAV"' EXIT
      # -loglevel error suppresses ffmpeg banner/progress spam in the journal.
      ffmpeg -y -loglevel error -i "$INPUT_FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP_WAV"
      whisper-cli "''${ARGS[@]}" "$TMP_WAV"
    '';
  };
in
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
  # Kept permanently for npm update -g openclaw recompilation
  environment.systemPackages = with pkgs; [
    cmake
    gnumake
    gcc
    python3
    # whisper-cpp is omitted: available via kuzeaTranscribe runtimeInputs.
  ];

  # Pre-built Claude Code binaries from cachix (avoids building from source)
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://claude-code.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "claude-code.cachix.org-1:p3pMxGi7K+xT7I3dLghdlrUijD8s+wfQlmWp8gQ/TJA="
    ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # ── Networking (inline — Hetzner CX33, nbg1-dc3) ───────────────────────
  networking.hostName = "sancta-claw";
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
    # IPv6: link-local auto-configured by kernel from MAC; no global IPv6 from Hetzner
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
    # Kuzea-specific secrets — decriptabile doar pe sancta-claw
    kuzea-caldav-credentials = {
      file = "${self}/secrets/kuzea-caldav-credentials.age";
      owner = "openclaw";
      group = "openclaw";
    };
    kuzea-github-token = {
      file = "${self}/secrets/kuzea-github-token.age";
      owner = "openclaw";
      group = "openclaw";
    };
  };

  # ── Home Manager (scaffolding — required by root.nix, no user configs yet) ──
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    sharedModules = [{ home.enableNixpkgsReleaseCheck = false; }];
  };

  # ── Swap (2GB — prevents OOM during builds on CX33) ────────────────────
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
    # Shell for: sudo -u openclaw npm install/openclaw configure
    shell = pkgs.bash;
  };
  users.groups.openclaw = { };

  systemd.services.openclaw = {
    description = "OpenClaw AI Agent";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HOME = "/var/lib/openclaw";
      # kuzeaTranscribe: whisper-cli + ffmpeg (OGG/Opus -> WAV) via runtimeInputs.
      # The whisper model path is passed via openclaw.json args (-m <path>), not
      # via an env var, so no WHISPER_CPP_MODEL entry is needed here.
      PATH = lib.mkForce "/var/lib/openclaw/.npm-global/bin:${lib.makeBinPath (with pkgs; [ nodejs_22 git coreutils bash kuzeaTranscribe ])}:/run/current-system/sw/bin";
      # npm global prefix
      NPM_CONFIG_PREFIX = "/var/lib/openclaw/.npm-global";
    };

    serviceConfig = {
      Type = "simple";
      User = "openclaw";
      Group = "openclaw";
      WorkingDirectory = "/var/lib/openclaw";
      # Binary installed manually: sudo -u openclaw npm install -g openclaw
      # ConditionPathExists prevents noisy restart loops if binary is missing
      ConditionPathExists = "/var/lib/openclaw/.npm-global/bin/openclaw";
      # Post-deploy setup (run once):
      #   sudo -u openclaw npm install -g openclaw
      #   sudo -u openclaw openclaw configure
      ExecStart = "/var/lib/openclaw/.npm-global/bin/openclaw gateway --port 18789";
      Restart = "on-failure";
      RestartSec = 10;

      # Resource limits: 6GB memory, 300% CPU (3 of 4 cores)
      MemoryMax = "6G";
      MemoryHigh = "5G";
      CPUQuota = "300%";

      # Hardening (no MemoryDenyWriteExecute — Node.js needs JIT)
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true; # /var/lib/openclaw is not under /home
      PrivateDevices = true;
      ReadWritePaths = [ "/var/lib/openclaw" ];
      PrivateTmp = true;
    };
  };

  # ── Tailscale Serve for OpenClaw UI ─────────────────────────────────────
  systemd.services.openclaw-tailscale-serve = {
    description = "Tailscale Serve for OpenClaw UI";
    after = [
      "network-online.target"
      "tailscaled.service"
      "openclaw.service"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "tailscaled.service"
      "openclaw.service"
    ];
    wantedBy = [ "multi-user.target" ];
    # PartOf propagates stop/restart of openclaw to this unit
    partOf = [ "openclaw.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Two sequential 60s wait loops = 120s max; default 90s would kill us
      TimeoutStartSec = 150;
      # Skip if openclaw binary not installed (ConditionPathExists on openclaw.service
      # causes it to be skipped, but a skipped unit still satisfies Requires=)
      ConditionPathExists = "/var/lib/openclaw/.npm-global/bin/openclaw";
      NoNewPrivileges = true;
    };

    script = ''
      # Wait for tailscaled to be ready (timeout: 60 seconds)
      ts_timeout=60
      while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
        ts_timeout=$((ts_timeout - 1))
        if [ $ts_timeout -le 0 ]; then
          echo "ERROR: tailscaled not ready after 60 seconds"
          exit 1
        fi
        sleep 1
      done

      # Wait for OpenClaw to be listening (timeout: 60 seconds)
      # The 'after' directive only waits for service start, not port availability
      port_timeout=60
      while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 18789 2>/dev/null; do
        port_timeout=$((port_timeout - 1))
        if [ $port_timeout -le 0 ]; then
          echo "ERROR: OpenClaw not listening on port 18789 after 60 seconds"
          exit 1
        fi
        sleep 1
      done

      # Check if serve is already configured for this port
      if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:18789"; then
        echo "Configuring Tailscale Serve for OpenClaw..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https 18789 http://127.0.0.1:18789
      else
        echo "Tailscale Serve already configured for OpenClaw"
      fi
    '';

    preStop = ''
      echo "Removing Tailscale Serve configuration for OpenClaw..."
      ${pkgs.tailscale}/bin/tailscale serve --https 18789 off || true
    '';
  };

  # ── SSH authorized keys ─────────────────────────────────────────────────
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2btaYomBlcKG+snrIrBuTXcEaBKEGQoAaF59YWwkal nixos@rpi5"
  ];

  # ── Declarative runtime files (openclaw user) ──────────────────────────
  # These files were previously created imperatively and would be lost on
  # rebuild. tmpfiles L+ creates forced symlinks into the nix store.
  # Todoist skill directory is built as a derivation and symlinked whole.
  systemd.tmpfiles.rules =
    let
      todoistSkill = pkgs.runCommand "todoist-natural-language" { } ''
        cp -r ${./kuzea/skills/todoist-natural-language} $out
      '';
    in
    [
      "d /var/lib/openclaw/bin 0755 openclaw openclaw -"
      "d /var/lib/openclaw/.claude 0700 openclaw openclaw -"
      # Ensure parent directories exist before creating the skills symlink.
      # systemd-tmpfiles does not auto-create missing intermediate parents.
      "d /var/lib/openclaw/.openclaw 0755 openclaw openclaw -"
      "d /var/lib/openclaw/.openclaw/workspace 0755 openclaw openclaw -"
      "d /var/lib/openclaw/.openclaw/workspace/skills 0755 openclaw openclaw -"
      # writeTextFile with executable=true sets 0555 on the nix store file so the
      # resulting symlink is directly executable (node cron-manage.mjs).
      "L+ /var/lib/openclaw/bin/cron-manage.mjs - - - - ${
        pkgs.writeTextFile {
          name = "cron-manage.mjs";
          text = builtins.readFile ./kuzea/cron-manage.mjs;
          executable = true;
        }
      }"
      "L+ /var/lib/openclaw/.claude/CLAUDE.md - - - - ${pkgs.writeText "claude-global.md" (builtins.readFile ./kuzea/claude-CLAUDE.md)}"
      # skipDangerousModePermissionPrompt is intentional: the openclaw user runs
      # under NoNewPrivileges=true with no sudo access, so Claude Code cannot
      # escalate privileges even with prompts disabled.
      "L+ /var/lib/openclaw/.claude/settings.json - - - - ${pkgs.writeText "claude-settings.json" (builtins.readFile ./kuzea/claude-settings.json)}"
      "L+ /var/lib/openclaw/.openclaw/workspace/skills/todoist-natural-language - - - - ${todoistSkill}"
    ];

  # Fresh install — NixOS 25.05
  system.stateVersion = lib.mkForce "25.05";
}
