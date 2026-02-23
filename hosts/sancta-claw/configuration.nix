{ pkgs
, lib
, self
, ...
}:

let
  # kuzeaTranscribe: openai-whisper (Python) + ffmpeg (OGG/Opus -> WAV).
  # whisper-cpp 1.7.5 from nixpkgs segfaults on Skylake-IBRS VMs (backends=0);
  # openai-whisper is the working fallback. Model files cached in ~/.cache/whisper/.
  # Download: python3 -c "import whisper; whisper.load_model('base')"
  kuzeaTranscribe = pkgs.writeShellApplication {
    name = "kuzea-transcribe";
    runtimeInputs = [
      pkgs.ffmpeg
      (pkgs.python3.withPackages (ps: [ ps.openai-whisper ]))
    ];
    text = ''
      usage() {
        echo "Usage: kuzea-transcribe [--model MODEL] [--language LANG] <input-file>" >&2
        echo "  MODEL: tiny, base, small, medium, large (default: base)" >&2
        exit 1
      }

      MODEL="base"
      LANGUAGE_ARG=""
      INPUT_FILE=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --model) MODEL="$2"; shift 2 ;;
          --language) LANGUAGE_ARG="$2"; shift 2 ;;
          --help|-h) usage ;;
          -*) shift ;;
          *) INPUT_FILE="$1"; shift ;;
        esac
      done

      [[ -z "$INPUT_FILE" ]] && usage

      TMP_WAV=$(mktemp /tmp/whisper-XXXXXX.wav)
      trap 'rm -f "$TMP_WAV"' EXIT

      ffmpeg -i "$INPUT_FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP_WAV" \
        -loglevel error -y

      CACHE_DIR="''${WHISPER_CACHE_DIR:-$HOME/.cache/whisper}"

      python3 - "$TMP_WAV" "$MODEL" "$CACHE_DIR" "$LANGUAGE_ARG" << 'PYEOF'
      import sys, whisper

      wav_path, model_name, cache_dir, language = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
      model = whisper.load_model(model_name, download_root=cache_dir)
      opts = {}
      if language:
          opts["language"] = language
      result = model.transcribe(wav_path, **opts)
      print(result["text"].strip())
      PYEOF
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
    # openai-whisper available via kuzeaTranscribe runtimeInputs (not system-wide).
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
      # kuzeaTranscribe: openai-whisper + ffmpeg (OGG/Opus -> WAV) via runtimeInputs.
      # Model auto-downloads to ~/.cache/whisper/ (override with WHISPER_CACHE_DIR).
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

  # Fresh install — NixOS 25.05
  system.stateVersion = lib.mkForce "25.05";
}
