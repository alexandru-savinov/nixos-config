{ pkgs
, lib
, config
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
          -*) echo "Unknown option: $1" >&2; usage ;;
          *) INPUT_FILE="$1"; shift ;;
        esac
      done

      [[ -z "$INPUT_FILE" ]] && usage

      TMP_WAV=$(mktemp /tmp/whisper-XXXXXX.wav)
      trap 'rm -f "$TMP_WAV"' EXIT

      # -y and -loglevel are global ffmpeg options and must precede the first -i.
      # -loglevel error suppresses progress spam in the journal.
      ffmpeg -y -loglevel error -i "$INPUT_FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP_WAV"

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

  # Chromium headless shell path from playwright-driver — shared by agentBrowser
  # and the openclawBrowserConfigScript below. Computed once to avoid duplication.
  chromiumRevision = pkgs.playwright-driver.browsersJSON."chromium-headless-shell".revision;
  chromiumBin = "${pkgs.playwright-driver.browsers}/chromium_headless_shell-${chromiumRevision}/chrome-linux/headless_shell";

  # agentBrowser: headless browser automation CLI for AI agents.
  # Rust CLI dispatches commands to a Node.js/Playwright daemon.
  # Uses nixpkgs playwright-driver.browsers — no runtime Chromium download.
  agentBrowser =
    let
      src = pkgs.fetchFromGitHub {
        owner = "vercel-labs";
        repo = "agent-browser";
        rev = "v0.14.0";
        hash = "sha256-oDgnxQ09e1IUd1kfgr75TNiYOf5VpMXG9DjfGG4OGwA=";
      };
      # Node.js daemon: TypeScript compiled to JS, uses playwright-core
      daemonDrv = pkgs.stdenv.mkDerivation {
        pname = "agent-browser-daemon";
        version = "0.14.0";
        inherit src;
        pnpmDeps = pkgs.pnpm.fetchDeps {
          pname = "agent-browser-daemon";
          version = "0.14.0";
          inherit src;
          hash = "sha256-W2UD2bCmyHwzAknw2jxfgVFvd1r2y0/XX5ujT6RO3xM=";
        };
        nativeBuildInputs = with pkgs; [
          nodejs_22
          pnpm.configHook
        ];
        buildPhase = "pnpm build";
        installPhase = ''
          mkdir -p $out
          # cp -rL would dereference pnpm virtual-store symlinks, breaking
          # transitive-dep resolution (Node.js traverses the real path, not the
          # .pnpm symlink chain). cp -r preserves relative symlinks so Node.js
          # still resolves packages through .pnpm/<pkg>/node_modules/<dep>/.
          cp -rL dist package.json $out/
          cp -r node_modules $out/
        '';
      };
      # Rust CLI: fast command dispatcher, spawns Node.js daemon on demand
      rustCli = pkgs.rustPlatform.buildRustPackage {
        pname = "agent-browser-cli";
        version = "0.14.0";
        inherit src;
        cargoRoot = "cli";
        buildAndTestSubdir = "cli";
        cargoHash = "sha256-94w9V+NZiWeQ3WbQnsKxVxlvsCaOJR0Wm6XVc85Lo88=";
      };
    in
    # AGENT_BROWSER_EXECUTABLE_PATH bypasses playwright-core's revision check,
      # allowing the nixpkgs-provided Chromium to be used even when the npm package
      # revision differs. chromiumBin is defined in the outer let block.
    pkgs.stdenv.mkDerivation {
      pname = "agent-browser";
      version = "0.14.0";
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      meta = with pkgs.lib; {
        description = "Headless browser automation CLI for AI agents (Rust CLI + Playwright daemon)";
        homepage = "https://github.com/vercel-labs/agent-browser";
        license = licenses.asl20;
        platforms = platforms.linux;
        mainProgram = "agent-browser";
      };
      installPhase = ''
        mkdir -p $out/bin $out/share/agent-browser
        cp -r ${daemonDrv}/. $out/share/agent-browser/
        makeWrapper ${rustCli}/bin/agent-browser $out/bin/agent-browser \
          --set AGENT_BROWSER_HOME "$out/share/agent-browser" \
          --set AGENT_BROWSER_EXECUTABLE_PATH "${chromiumBin}" \
          --set PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS "true" \
          --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.nodejs_22 ]}"
      '';
    };

  # Declarative browser config for OpenClaw: inject Chromium path (shared
  # chromiumBin binding above) into openclaw.json at service start.
  openclawBrowserConfigScript = pkgs.writeShellScript "openclaw-browser-config" ''
        ${pkgs.python3}/bin/python3 - <<'PYEOF'
    import json, os

    config_path = "/var/lib/openclaw/.openclaw/openclaw.json"

    if os.path.exists(config_path):
        try:
            with open(config_path) as f:
                config = json.load(f)
        except (json.JSONDecodeError, OSError):
            config = {}
    else:
        config = {}

    config["browser"] = {
        "enabled": True,
        "defaultProfile": "openclaw",
        "executablePath": "${chromiumBin}",
        "headless": True,
        # noSandbox is required: the openclaw user lacks CAP_SYS_ADMIN for
        # Chromium's user-namespace sandbox, and the setuid helper is not
        # available in the Nix store.  Defense-in-depth is provided by systemd
        # hardening (NoNewPrivileges, ProtectSystem=strict, PrivateDevices).
        "noSandbox": True,
    }

    # Ensure both sonnet and opus are in the allowed-models list so Kuzea
    # can switch to opus via /model or session_status without a manual edit.
    agents = config.setdefault("agents", {})
    defaults = agents.setdefault("defaults", {})
    models = defaults.setdefault("models", {})
    model = defaults.setdefault("model", {})
    model["primary"] = "anthropic/claude-opus-4-6"
    models.setdefault("anthropic/claude-sonnet-4-6", {})
    models.setdefault("anthropic/claude-opus-4-6", {})

    # Enable self-improvement hook (agent:bootstrap reminder to log learnings).
    # Declarative equivalent of: openclaw hooks enable self-improvement
    hooks = config.setdefault("hooks", {})
    internal = hooks.setdefault("internal", {})
    internal["enabled"] = True
    entries = internal.setdefault("entries", {})
    entries.setdefault("self-improvement", {})["enabled"] = True

    # Enable Telegram streaming so partial replies appear in real-time
    channels = config.setdefault("channels", {})
    tg = channels.setdefault("telegram", {})
    tg["streaming"] = "partial"

    tmp = config_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    os.replace(tmp, config_path)
    PYEOF
  '';
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
    # playwright-driver.browsers is a transitive closure dep of agentBrowser (via makeWrapper);
    # no need to list it here separately.
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
    kuzea-todoist-credentials = {
      file = "${self}/secrets/kuzea-todoist-credentials.age";
      owner = "openclaw";
      group = "openclaw";
    };
    kuzea-airtable-credentials = {
      file = "${self}/secrets/kuzea-airtable-credentials.age";
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

  # ── Swap (12GB — prevents OOM during builds and heavy workloads on CX33) ────────────────────
  swapDevices = [
    {
      device = "/swapfile";
      size = 12288;
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
      PATH = lib.mkForce "/var/lib/openclaw/.npm-global/bin:${lib.makeBinPath (with pkgs; [ nodejs_22 git coreutils bash kuzeaTranscribe agentBrowser ])}:/run/current-system/sw/bin";
      # npm global prefix
      NPM_CONFIG_PREFIX = "/var/lib/openclaw/.npm-global";
    };

    # ConditionPathExists prevents noisy restart loops if binary is missing
    # (must be in [Unit], not [Service] — systemd ignores it in [Service])
    unitConfig.ConditionPathExists = "/var/lib/openclaw/.npm-global/bin/openclaw";

    serviceConfig = {
      Type = "simple";
      User = "openclaw";
      Group = "openclaw";
      WorkingDirectory = "/var/lib/openclaw";
      # Inject Todoist and Airtable credentials from agenix secrets.
      # File format: KEY=value (one per line, no quotes needed).
      EnvironmentFile = [
        config.age.secrets.kuzea-todoist-credentials.path
        config.age.secrets.kuzea-airtable-credentials.path
      ];
      # Post-deploy setup (run once):
      #   sudo -u openclaw npm install -g openclaw
      #   sudo -u openclaw openclaw configure
      # Inject declarative browser config into openclaw.json before start.
      # Idempotent: merges browser section, preserves other keys.
      ExecStartPre = openclawBrowserConfigScript;
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
      # /dev/shm is required by Chromium (renderer <-> browser IPC).
      # PrivateDevices creates a minimal /dev without /dev/shm, so we bind it
      # explicitly. The host's /dev/shm tmpfs is mounted read-write in the
      # private namespace; no other devices are exposed.
      BindPaths = [ "/dev/shm" ];
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

    # Skip if openclaw binary not installed (ConditionPathExists on openclaw.service
    # causes it to be skipped, but a skipped unit still satisfies Requires=)
    unitConfig.ConditionPathExists = "/var/lib/openclaw/.npm-global/bin/openclaw";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Two sequential 60s wait loops = 120s max; default 90s would kill us
      TimeoutStartSec = 150;
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

  # ── Restart trigger (no sudo, no NoNewPrivileges change) ────────────────
  # Kuzea self-restart via file-based trigger:
  #   touch /var/lib/openclaw/restart-trigger
  # The path unit fires, the watcher service (root) deletes the file and
  # restarts openclaw. NoNewPrivileges=true on openclaw.service is preserved.
  systemd.paths.openclaw-restart-watcher = {
    description = "Watch for Kuzea self-restart trigger";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/var/lib/openclaw/restart-trigger";
      Unit = "openclaw-restart-watcher.service";
    };
  };

  systemd.services.openclaw-restart-watcher = {
    description = "Restart openclaw service on agent request";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "openclaw-do-restart" ''
        rm -f /var/lib/openclaw/restart-trigger
        systemctl restart openclaw
      '';
    };
  };

  # ── NixOS rebuild trigger (no sudo needed) ──────────────────────────────
  # Kuzea can trigger a full nixos-rebuild switch by:
  #   touch /var/lib/openclaw/rebuild-trigger
  # The path unit fires, the service (root) pulls latest config and rebuilds.
  # This allows Kuzea to apply merged PRs without waiting for autoUpgrade.
  systemd.paths.nixos-rebuild-watcher = {
    description = "Watch for NixOS rebuild trigger";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/var/lib/openclaw/rebuild-trigger";
      Unit = "nixos-rebuild-watcher.service";
    };
  };

  systemd.services.nixos-rebuild-watcher = {
    description = "Rebuild NixOS on agent request";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "nixos-do-rebuild" ''
        set -euo pipefail
        rm -f /var/lib/openclaw/rebuild-trigger

        # Pull latest config
        cd /var/lib/openclaw/nixos-config
        ${pkgs.git}/bin/git fetch origin main
        ${pkgs.git}/bin/git checkout main
        ${pkgs.git}/bin/git reset --hard origin/main

        # Rebuild
        nixos-rebuild switch --flake /var/lib/openclaw/nixos-config#sancta-claw 2>&1 | tee /var/lib/openclaw/rebuild.log

        # Notify Kuzea
        echo "$(date -Iseconds) rebuild completed" >> /var/lib/openclaw/rebuild.log
      '';
      TimeoutStartSec = "10min";
    };
  };

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

  # ── Declarative runtime files (openclaw user) ──────────────────────────
  # These files were previously created imperatively and would be lost on
  # rebuild. tmpfiles L+ creates forced symlinks into the nix store.
  # Todoist skill directory is built as a derivation and symlinked whole.
  systemd.tmpfiles.rules =
    let
      todoistSkill = pkgs.runCommand "todoist-natural-language" { } ''
        cp -r ${./kuzea/skills/todoist-natural-language} $out
      '';
      selfImprovingSkill = pkgs.runCommand "self-improving-agent" { } ''
        cp -r ${./kuzea/skills/self-improving-agent} $out
      '';
      agentBrowserSkill = pkgs.runCommand "agent-browser" { } ''
        cp -r ${./kuzea/skills/agent-browser} $out
      '';
      claudeCodeAgentsSkill = pkgs.runCommand "claude-code-agents" { } ''
        cp -r ${./kuzea/skills/claude-code-agents} $out
      '';
      codingAgentLocalSkill = pkgs.runCommand "coding-agent-local" { } ''
        cp -r ${./kuzea/skills/coding-agent-local} $out
      '';
      selfImprovingHook = pkgs.runCommand "self-improvement-hook" { } ''
        cp -r ${./kuzea/hooks/self-improvement} $out
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
      "d /var/lib/openclaw/.openclaw/workspace/hooks 0755 openclaw openclaw -"
      # Managed hooks dir — scanned by OpenClaw at startup (openclaw-managed source).
      # Must be a real directory, not a symlink: Node.js Dirent.isDirectory() does
      # not follow symlinks, so openclaw would silently skip symlinked hook dirs.
      "d /var/lib/openclaw/.openclaw/hooks 0755 openclaw openclaw -"
      # writeTextFile with executable=true sets 0555 on the nix store file so the
      # resulting symlink is directly executable (node cron-manage.mjs).
      "L+ /var/lib/openclaw/bin/cron-manage.mjs - - - - ${
        pkgs.writeTextFile {
          name = "cron-manage.mjs";
          text = builtins.readFile ./kuzea/cron-manage.mjs;
          executable = true;
        }
      }"
      # Source file is claude-CLAUDE.md to avoid the dot-prefix in the repo;
      # deployed as .claude/CLAUDE.md (the path Claude Code reads on startup).
      "L+ /var/lib/openclaw/.claude/CLAUDE.md - - - - ${pkgs.writeText "claude-global.md" (builtins.readFile ./kuzea/claude-CLAUDE.md)}"
      # skipDangerousModePermissionPrompt is intentional: the openclaw user runs
      # under NoNewPrivileges=true with no sudo access, so Claude Code cannot
      # escalate privileges even with prompts disabled.
      # The symlink is intentionally read-only (nix store). Claude Code reads
      # settings.json at startup but does not write to it during normal operation;
      # any attempt to persist config changes via /config will fail at the OS
      # level, keeping the declarative value intact.
      "L+ /var/lib/openclaw/.claude/settings.json - - - - ${pkgs.writeText "claude-settings.json" (builtins.readFile ./kuzea/claude-settings.json)}"
      # TODOIST_API_KEY is injected via EnvironmentFile from the agenix secret
      # kuzea-todoist-credentials (PR #297). Skill is fully operational post-rebuild.
      "L+ /var/lib/openclaw/.openclaw/workspace/skills/todoist-natural-language - - - - ${todoistSkill}"
      # Self-Improving Agent skill (pskoett/self-improving-agent v1.0.11).
      # Logs errors, corrections, and feature requests to .learnings/ for continuous
      # improvement. Hook injects a reminder at agent:bootstrap to capture learnings.
      "L+ /var/lib/openclaw/.openclaw/workspace/skills/self-improving-agent - - - - ${selfImprovingSkill}"
      # Agent Browser CLI reference (vercel-labs/agent-browser) — complete command docs
      # so Kuzea always has the full snapshot/click/fill/record reference available.
      "L+ /var/lib/openclaw/.openclaw/workspace/skills/agent-browser - - - - ${agentBrowserSkill}"
      # Claude Code agent-teams & subagents reference — documents custom subagent
      # creation, agent file locations, and experimental agent teams for parallel work.
      "L+ /var/lib/openclaw/.openclaw/workspace/skills/claude-code-agents - - - - ${claudeCodeAgentsSkill}"
      # Local overrides for coding-agent skill — documents --output-format text fix
      # so Claude Code -p output is captured by OpenClaw's PTY process manager.
      "L+ /var/lib/openclaw/.openclaw/workspace/skills/coding-agent-local - - - - ${codingAgentLocalSkill}"
      # Hook goes into the managed dir (.openclaw/hooks/), NOT workspace/hooks/.
      # Reason: openclaw scans hooks via Node.js readdirSync + Dirent.isDirectory(),
      # which returns false for symlinks-to-directories. Using C+ creates real files
      # that pass the isDirectory() check and are picked up as "openclaw-managed".
      # workspace/hooks/ symlink is intentionally omitted: it was non-functional and
      # only created confusion. .openclaw/hooks/ is the canonical location used by
      # `openclaw hooks install` and loadHookEntries(managedHooksDir).
      "C+ /var/lib/openclaw/.openclaw/hooks/self-improvement - openclaw openclaw - ${selfImprovingHook}"
      # .learnings/ is mutable state (grows over time) — created writable, never
      # symlinked to the Nix store. `f` creates the file only if it doesn't exist,
      # preserving accumulated learnings across rebuilds.
      "d /var/lib/openclaw/.openclaw/workspace/.learnings 0700 openclaw openclaw -"
      "f /var/lib/openclaw/.openclaw/workspace/.learnings/LEARNINGS.md 0600 openclaw openclaw -"
      "f /var/lib/openclaw/.openclaw/workspace/.learnings/ERRORS.md 0600 openclaw openclaw -"
      "f /var/lib/openclaw/.openclaw/workspace/.learnings/FEATURE_REQUESTS.md 0600 openclaw openclaw -"
      # GitHub credential helper: reads PAT from /run/agenix/kuzea-github-token at
      # runtime so the token is never stored in plaintext on disk.
      # Replaces the former ~/.git-credentials store helper approach.
      # writeShellScript patches the shebang to the nix store bash automatically.
      "L+ /var/lib/openclaw/bin/git-credential-agenix - - - - ${
        pkgs.writeShellScript "git-credential-agenix" (builtins.readFile ./kuzea/git-credential-agenix)
      }"
      # .gitconfig is managed declaratively so the credential helper path always
      # points to the nix-store copy. The file is read-only by intent; use
      # nixos-config to make config changes rather than git config --global.
      "L+ /var/lib/openclaw/.gitconfig - - - - ${pkgs.writeText "gitconfig" (builtins.readFile ./kuzea/gitconfig)}"
      # Remove legacy plaintext credential files left over from the pre-agenix
      # setup. 'r' removes the file if it exists; safe to leave in perpetually.
      "r /var/lib/openclaw/.git-credentials - - - -"
      "r /var/lib/openclaw/.git-credentials.bak - - - -"
    ];

  # Fresh install — NixOS 25.05
  system.stateVersion = lib.mkForce "25.05";
}
