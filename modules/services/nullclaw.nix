# NullClaw — Zig-based AI Assistant (Telegram + Gateway)
#
# Lightweight replacement for OpenClaw (Node.js, ~1GB RAM).
# NullClaw is a 3MB static binary using ~4MB RAM with 20 channels,
# 14 built-in tools, and markdown memory.
#
# Usage in host configuration:
#   services.nullclaw = {
#     enable = true;
#     openrouterApiKeyFile = config.age.secrets.openrouter-api-key.path;
#     telegram.botTokenFile = config.age.secrets.zero-kuzea-telegram-bot-token.path;
#     telegram.allowedUsers = [ "364749075" ];
#   };
#
# Access via Tailscale HTTPS: https://<hostname>.tail<hex>.ts.net:18790

{
  config,
  pkgs,
  pkgs-unstable ? pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.nullclaw;

  # NullClaw requires Zig 0.15+ (--fetch=all flag).
  # nixpkgs-25.05 ships 0.14.1; use pkgs-unstable for 0.15.2.
  zig = pkgs-unstable.zig;

  # ── NullClaw Package ─────────────────────────────────────────────────
  nullclawSrc = pkgs.fetchFromGitHub {
    owner = "nullclaw";
    repo = "nullclaw";
    rev = "e94ffb0f55815bf45468b0600f82cc6c1d703f0b";
    hash = "sha256-Pm336TJ5NpEa+JIjXIyPh1T0xKSpsSYbjGI0IJsMH5U=";
  };

  # Fixed-output derivation: fetch Zig dependencies with network access.
  # Zig's package manager needs to download websocket.zig at build time.
  nullclawDeps = pkgs.stdenvNoCC.mkDerivation {
    name = "nullclaw-deps";
    src = nullclawSrc;
    nativeBuildInputs = [ zig ];
    dontConfigure = true;
    dontInstall = true;
    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-IQO7ZyGisbMF5GNDMBH0wDQGAr7RwztYk9mrVgIdWIU=";
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR="$out"
      zig build --fetch=all
    '';
  };

  defaultPkg = pkgs.stdenvNoCC.mkDerivation {
    pname = "nullclaw";
    version = "2026.2.26";
    src = nullclawSrc;
    nativeBuildInputs = [ zig ];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      # Copy pre-fetched deps to writable dir — Zig 0.15 writes
      # compilation artifacts alongside cached packages.
      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
      cp -r "${nullclawDeps}/." "$ZIG_GLOBAL_CACHE_DIR"
      chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"

      mkdir -p $out/bin
      zig build -Doptimize=ReleaseSmall \
        -Dcpu=baseline \
        --prefix "$out"
    '';
    installPhase = "true"; # zig build --prefix handles installation
    meta = with lib; {
      description = "Zig-based AI assistant with Telegram integration";
      homepage = "https://github.com/nullclaw/nullclaw";
      license = licenses.mit;
      platforms = platforms.linux;
      mainProgram = "nullclaw";
    };
  };

  # ── Config Template ──────────────────────────────────────────────────
  # Static JSON with placeholders. Secrets injected at runtime by ExecStartPre.
  configJson = builtins.toJSON {
    default_temperature = cfg.temperature;
    models.providers.openrouter.api_key = "__OPENROUTER_API_KEY__";
    agents.defaults.model.primary = "${cfg.provider}/${cfg.model}";
    channels =
      {
        cli = false;
      }
      // optionalAttrs cfg.telegram.enable {
        telegram.accounts.main = {
          bot_token = "__TELEGRAM_BOT_TOKEN__";
          allow_from = cfg.telegram.allowedUsers;
        };
      };
    memory = {
      profile = "markdown_only";
      backend = "markdown";
      auto_save = true;
    };
    gateway = {
      port = cfg.port;
      host = cfg.host;
      require_pairing = false;
    };
  };

  configTemplate = pkgs.writeText "nullclaw-config-template.json" configJson;
in
{
  options.services.nullclaw = {
    enable = mkEnableOption "NullClaw AI assistant (gateway + Telegram)";

    package = mkOption {
      type = types.package;
      default = defaultPkg;
      description = "NullClaw package to use.";
    };

    port = mkOption {
      type = types.port;
      default = 18790;
      description = "Port for NullClaw gateway.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address for NullClaw gateway.";
    };

    provider = mkOption {
      type = types.str;
      default = "openrouter";
      description = "AI provider name.";
    };

    model = mkOption {
      type = types.str;
      default = "anthropic/claude-sonnet-4-6";
      description = "Model identifier (appended to provider/).";
    };

    temperature = mkOption {
      type = types.float;
      default = 0.7;
      description = "Temperature for AI model responses.";
    };

    openrouterApiKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing OpenRouter API key (agenix).";
    };

    telegram = {
      enable = mkEnableOption "Telegram channel" // {
        default = true;
      };

      botTokenFile = mkOption {
        type = types.path;
        description = "Path to file containing Telegram bot token (agenix).";
      };

      allowedUsers = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "364749075" ];
        description = "Telegram user IDs allowed to interact with the bot.";
      };
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve HTTPS proxy for NullClaw gateway";

      httpsPort = mkOption {
        type = types.port;
        default = 18790;
        description = "HTTPS port for Tailscale Serve.";
      };
    };

    resourceLimits = {
      memoryMax = mkOption {
        type = types.str;
        default = "256M";
        description = "Maximum memory for NullClaw service.";
      };

      cpuQuota = mkOption {
        type = types.str;
        default = "100%";
        description = "CPU quota for NullClaw service.";
      };
    };
  };

  config = mkIf cfg.enable {

    # ── Assertions ───────────────────────────────────────────────────
    assertions = [
      {
        assertion = !(hasPrefix "/nix/store" (toString cfg.openrouterApiKeyFile));
        message = ''
          services.nullclaw.openrouterApiKeyFile points to the Nix store.
          Use agenix — files in /nix/store are world-readable.
        '';
      }
      {
        assertion = !(cfg.telegram.enable && hasPrefix "/nix/store" (toString cfg.telegram.botTokenFile));
        message = ''
          services.nullclaw.telegram.botTokenFile points to the Nix store.
          Use agenix — files in /nix/store are world-readable.
        '';
      }
    ];

    # ── User and Group ───────────────────────────────────────────────
    users.users.nullclaw = {
      isSystemUser = true;
      group = "nullclaw";
      home = "/var/lib/nullclaw";
      description = "NullClaw AI assistant";
    };
    users.groups.nullclaw = { };

    # ── Directories ──────────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d /var/lib/nullclaw 0700 nullclaw nullclaw -"
      "d /var/lib/nullclaw/workspace 0700 nullclaw nullclaw -"
    ];

    # ── Main Gateway Service ─────────────────────────────────────────
    systemd.services.nullclaw = {
      description = "NullClaw AI Assistant (Gateway)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "nullclaw";
        Group = "nullclaw";
        WorkingDirectory = "/var/lib/nullclaw";
        Environment = [
          "HOME=/run/nullclaw"
          "NULLCLAW_WORKSPACE=/var/lib/nullclaw/workspace"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        ];

        ExecStartPre = [
          (
            "+"
            + pkgs.writeShellScript "nullclaw-setup" ''
              set -euo pipefail

              # Create runtime directories
              ${pkgs.coreutils}/bin/mkdir -p /run/nullclaw/.nullclaw
              ${pkgs.coreutils}/bin/mkdir -p /run/nullclaw

              # Read OpenRouter API key
              OPENROUTER_KEY=$(${pkgs.coreutils}/bin/tr -d '\n' < "${cfg.openrouterApiKeyFile}")
              if [ -z "$OPENROUTER_KEY" ]; then
                echo "ERROR: OpenRouter API key is empty" >&2
                exit 1
              fi

              # Start building config from template
              ${pkgs.coreutils}/bin/cp ${configTemplate} /tmp/nullclaw-config-wip.json

              # Inject OpenRouter API key
              ${pkgs.jq}/bin/jq --arg key "$OPENROUTER_KEY" \
                '.models.providers.openrouter.api_key = $key' \
                /tmp/nullclaw-config-wip.json > /tmp/nullclaw-config-wip2.json
              ${pkgs.coreutils}/bin/mv /tmp/nullclaw-config-wip2.json /tmp/nullclaw-config-wip.json

              ${optionalString cfg.telegram.enable ''
                # Inject Telegram bot token
                BOT_TOKEN=$(${pkgs.coreutils}/bin/tr -d '\n' < "${cfg.telegram.botTokenFile}")
                if [ -z "$BOT_TOKEN" ]; then
                  echo "ERROR: Telegram bot token is empty" >&2
                  exit 1
                fi
                ${pkgs.jq}/bin/jq --arg token "$BOT_TOKEN" \
                  '.channels.telegram.accounts.main.bot_token = $token' \
                  /tmp/nullclaw-config-wip.json > /tmp/nullclaw-config-wip2.json
                ${pkgs.coreutils}/bin/mv /tmp/nullclaw-config-wip2.json /tmp/nullclaw-config-wip.json
              ''}

              # Install final config
              ${pkgs.coreutils}/bin/mv /tmp/nullclaw-config-wip.json /run/nullclaw/.nullclaw/config.json
              ${pkgs.coreutils}/bin/chmod 600 /run/nullclaw/.nullclaw/config.json

              ${pkgs.coreutils}/bin/chown -R nullclaw:nullclaw /run/nullclaw
            ''
          )
        ];

        ExecStart = "${cfg.package}/bin/nullclaw gateway --port ${toString cfg.port} --host ${cfg.host}";
        Restart = "on-failure";
        RestartSec = 10;

        # Resource limits
        MemoryMax = cfg.resourceLimits.memoryMax;
        CPUQuota = cfg.resourceLimits.cpuQuota;

        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ "/var/lib/nullclaw" ];
      };
    };

    # ── Tailscale Serve ──────────────────────────────────────────────
    systemd.services.nullclaw-tailscale-serve = mkIf cfg.tailscaleServe.enable {
      description = "Tailscale Serve for NullClaw";
      after = [
        "network-online.target"
        "tailscaled.service"
        "nullclaw.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "nullclaw.service"
      ];
      wantedBy = [ "multi-user.target" ];
      partOf = [ "nullclaw.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 150;
      };

      script = ''
        # Wait for tailscaled
        timeout=60
        while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: tailscaled not ready after 60s" >&2
            exit 1
          fi
          sleep 1
        done

        # Wait for NullClaw health endpoint
        timeout=60
        while ! ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString cfg.port}/health >/dev/null 2>&1; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: NullClaw not responding after 60s" >&2
            exit 1
          fi
          sleep 1
        done

        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${toString cfg.tailscaleServe.httpsPort}"; then
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://127.0.0.1:${toString cfg.port}
        fi
      '';

      preStop = ''
        ${pkgs.tailscale}/bin/tailscale serve --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };
  };
}
