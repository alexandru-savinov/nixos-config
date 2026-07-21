# sancta-choir — tailnet membrane gateway + resumed Claude worker.
#
# Adapted (do NOT re-derive) from stage/sancta-hetzner-host's
# hosts/sancta-core/membrane-worker.nix, which itself slimmed the SANCTA
# WORKER pattern from modules/services/openclaw.nix + sancta-claw's
# openclaw-service.nix. The long-running relay consumes only membrane-approved
# inbox records, invokes one resumed turn at a time, and writes successful
# responses to comm-replies.jsonl for /sim.
#
#   claude -p \
#     --input-format  stream-json \
#     --output-format stream-json \
#     --resume <session> \
#     --strict-mcp-config \
#     --tools <READ-ONLY set> \
#     --allowedTools <READ-ONLY set> \
#     --max-budget-usd <cap>
#
# CLI CONTRACT VERIFIED 2026-07-20 against the installed, flake-pinned Claude
# Code 2.1.215: --strict-mcp-config, --tools, --allowedTools, and
# --max-budget-usd are all present in `claude --help`. The --safe-mode path was
# exercised by a successful isolated headless invocation. The --tools
# availability boundary plus --allowedTools headless auto-approval matches the
# deployed sancta-heartbeat-tick pattern in
# modules/services/sancta-heartbeat-tick.nix.
# The inline `--mcp-config '{"mcpServers":{}}'` form was also exercised with an
# isolated, unauthenticated CLAUDE_CONFIG_DIR: it passed MCP parsing and reached
# the expected auth gate; malformed JSON was rejected as invalid MCP config.
#
# Differences from the sancta-core copy: runs as the `sancta` user under
# /var/lib/sancta on sancta-choir's LIVE ext4 root (NOT a disko LUKS root); the
# ~/.claude substrate is the ENCRYPTED SOUL VOLUME from ./soul-volume.nix
# (LUKS-on-loopback), not a whole-disk LUKS root.
#
# The Claude credential is loaded at runtime into a chmod-600 /run path (the
# openclaw.nix idiom — never via chat, never in the Nix store), and the worker
# runs as a dedicated unprivileged system user under systemd hardening.
{ config, pkgs, lib, claude-code ? null, ... }:

let
  cfg = config.services.sancta-worker;

  claudeCodePkg =
    if claude-code != null
    then claude-code.packages.${pkgs.system}.default
    else null;

  # Runtime path the credential is materialized into (chmod 600, tmpfs /run).
  # The agenix plaintext is copied here at ExecStartPre, then classified as an
  # API key or OAuth token without ever entering the Nix store.
  runtimeCredentialPath = "/run/sancta-worker/anthropic-credential";
  runtimeReadyPath = "/run/sancta-worker/ready";
  indexDir = "/var/lib/sancta/.claude/index";
  inboxPath = "${indexDir}/comm-inbox.jsonl";
  repliesPath = "${indexDir}/comm-replies.jsonl";
  cursorPath = "${indexDir}/comm-worker-cursor.json";
  failurePath = "${indexDir}/comm-worker-failure.json";
  rateLimitPath = "${indexDir}/comm-rate-limit.json";
  projectAnchor = "/var/lib/sancta/project-anchor";
  projectDir = "/home/nixos";
  membraneSrc = ./membrane;

  relay = ./membrane/relay.mjs;
in
{
  options.services.sancta-worker = {
    enable = lib.mkEnableOption "sancta-choir live membrane and resumed Claude worker";

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the agenix-decrypted Claude credential (Anthropic API key or
        Claude Code OAuth token; e.g. `config.age.secrets.anthropic-api-key.path`).
        Loaded at runtime into a chmod-600 file under /run — NEVER placed in the
        Nix store, NEVER passed via chat. The runtime loader classifies the
        prefix and exports only the matching Claude environment variable.
      '';
    };

    # ── HIS-HAND DIALS (read-only-safe defaults) ───────────────────────────
    # These three are the operator's steering wheel. Defaults are deliberately
    # the SAFEST possible: read-only tools, a low budget cap, and NO session
    # (so the unit is inert until Alexandru sets a real resume target).

    allowedTools = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # READ-ONLY default set — no Write/Edit/Bash/execution. Alexandru widens
      # this by hand only when a task needs it (and via the council/gate).
      default = [ "Read" "Grep" "Glob" ];
      example = [ "Read" "Grep" "Glob" "Bash(git status)" ];
      description = ''
        HIS-HAND DIAL — Claude Code tool availability and auto-approval list.
        The value is passed to both `--tools` (the structural built-in-tool
        whitelist) and `--allowedTools` (permission-prompt bypass for the same
        tools). Default is strictly READ-ONLY (Read/Grep/Glob); an empty list
        disables all built-in tools. MCP tools are independently disabled with
        `--strict-mcp-config` and an empty MCP config. Anything mutating or
        executing must be added explicitly by Alexandru.
      '';
    };

    maxBudgetUsd = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1.00";
      example = "5.00";
      description = ''
        HIS-HAND DIAL — per-invocation USD budget cap. Rendered as
        `--max-budget-usd <cap>`. The flag was verified against the installed,
        flake-pinned Claude Code 2.1.215 on 2026-07-20. Set to null to omit it.
      '';
    };

    session = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null; # inert until set — the unit will not start without a session
      example = "sancta-choir";
      description = ''
        HIS-HAND DIAL — session id/name for `--resume <session>`. Default null
        keeps the worker INERT (ConditionPathExists on the session marker is
        never satisfied, so the unit is skipped) until Alexandru names a real
        resumable session.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "sancta";
      description = "Unprivileged system user the Sancta worker runs as.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8743;
      description = "Loopback and Tailscale Serve HTTPS port for the membrane gateway.";
    };

    operatorLoginSha256 = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "^[a-f0-9]{64}$");
      default = null;
      description = ''
        SHA-256 of the lowercase Tailscale Serve user login authorized to use
        the membrane. The backend listens only on loopback and trusts Serve's
        anti-spoofed `Tailscale-User-Login` identity header. A live session
        requires this selector; tagged devices, which have no user header, are
        denied.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = claudeCodePkg != null;
        message = ''
          services.sancta-worker requires the claude-code flake input
          via specialArgs (inherit claude-code). See flake.nix.
        '';
      }
      {
        # Secure-by-construction: the key must come from agenix, never the store.
        assertion = cfg.apiKeyFile == null
          || !(lib.hasPrefix "/nix/store" (toString cfg.apiKeyFile));
        message = ''
          services.sancta-worker.apiKeyFile points into /nix/store
          (world-readable). Use an agenix secret path instead.
        '';
      }
      {
        assertion = cfg.session == null || cfg.operatorLoginSha256 != null;
        message = ''
          services.sancta-worker requires operatorLoginSha256 when a live
          session is configured, so the spend-capable gateway is not
          tailnet-wide.
        '';
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = "/var/lib/sancta";
      createHome = true;
      shell = pkgs.bash;
    };
    users.groups.${cfg.user} = { };

    systemd.services.sancta-worker = {
      description = "Sancta membrane inbox relay (resumed claude -p)";
      wantedBy = lib.optional (cfg.session != null) "multi-user.target";
      after = [
        "network-online.target"
        "tailscaled.service"
        # The soul volume (~/.claude) must be mounted before the worker starts
        # so CLAUDE_CONFIG_DIR lands on encrypted storage, not the bare dir.
        "sancta-soul-mount.service"
      ];
      wants = [ "network-online.target" ];
      # Encryption integrity: pull in + order after the soul mount so an armed
      # worker never runs onto the bare (unencrypted) ~/.claude dir. (`after`
      # alone is only ordering; `requires` also brings the mount into the txn.)
      requires = [ "sancta-soul-mount.service" ];
      # INERT-BY-DEFAULT: the unit is skipped unless a session marker exists.
      # With session=null the guard points at a marker path that is NEVER
      # created (the literal ".__no-session__"), so even a manual `systemctl
      # start` is a no-op. Alexandru creates the marker
      # (`touch /var/lib/sancta/session/<name>`) only when he names a real
      # --resume session — that arms the unit.
      unitConfig = {
        ConditionPathExists =
          if cfg.session == null
          then "/var/lib/sancta/session/.__no-session__"
          else "/var/lib/sancta/session/${cfg.session}";
        # Belt-and-suspenders: refuse to start unless the soul volume is actually
        # MOUNTED — otherwise CLAUDE_CONFIG_DIR would land on the bare,
        # unencrypted dir, writing soul state in plaintext. Derived from the
        # soul-volume option (not a duplicated literal) so an override of
        # mountPoint keeps this guard pointed at the real mount path.
        ConditionPathIsMountPoint = toString config.services.sancta-soul-volume.mountPoint;
      };

      environment = {
        HOME = "/var/lib/sancta";
        # ~/.claude substrate lives on the ENCRYPTED SOUL VOLUME (see
        # ./soul-volume.nix — LUKS-on-loopback) — the worker's config/state dir.
        CLAUDE_CONFIG_DIR = "/var/lib/sancta/.claude";
        SANCTA_INBOX = inboxPath;
        SANCTA_REPLIES = repliesPath;
        SANCTA_CURSOR = cursorPath;
        SANCTA_FAILURE = failurePath;
        SANCTA_WORKER_READY = runtimeReadyPath;
        SANCTA_REQUIRE_CREDENTIAL = if cfg.apiKeyFile != null then "1" else "0";
        SANCTA_PROJECT_DIR = projectDir;
        CLAUDE_BIN = "${claudeCodePkg}/bin/claude";
        CLAUDE_ARGS_JSON = builtins.toJSON (
          [
            "-p"
            "--input-format"
            "stream-json"
            "--output-format"
            "stream-json"
            "--verbose"
            # Disable migrated hooks/plugins/connectors in this unattended,
            # credential-authenticated worker. Session history still resumes.
            "--safe-mode"
            "--strict-mcp-config"
            "--mcp-config"
            (builtins.toJSON { mcpServers = { }; })
            "--tools"
            (lib.concatStringsSep "," cfg.allowedTools)
            "--allowedTools"
            (lib.concatStringsSep "," cfg.allowedTools)
          ]
          ++ lib.optionals (cfg.session != null) [ "--resume" cfg.session ]
          ++ lib.optionals (cfg.maxBudgetUsd != null) [ "--max-budget-usd" cfg.maxBudgetUsd ]
        );
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = "/var/lib/sancta";
        RuntimeDirectory = "sancta-worker"; # creates /run/... (0700, tmpfs)
        RuntimeDirectoryMode = "0700";

        # ── Load the API key into a chmod-600 /run path (openclaw.nix idiom) ──
        # Never in the store, never via chat. Only runs when apiKeyFile is set.
        ExecStartPre = lib.optional (cfg.apiKeyFile != null) (
          pkgs.writeShellScript "sancta-load-key" ''
            set -euo pipefail
            install -m 0600 -o ${cfg.user} -g ${cfg.user} \
              "${toString cfg.apiKeyFile}" "${runtimeCredentialPath}"
          ''
        );

        ExecStart = pkgs.writeShellScript "sancta-worker-start" ''
          set -euo pipefail
          ${lib.optionalString (cfg.apiKeyFile != null) ''
            credential="$(cat ${runtimeCredentialPath})"
            case "$credential" in
              sk-ant-api*) export ANTHROPIC_API_KEY="$credential" ;;
              sk-ant-oat*) export CLAUDE_CODE_OAUTH_TOKEN="$credential" ;;
              *) echo "unsupported Claude credential type" >&2; exit 1 ;;
            esac
            unset credential
          ''}
          exec ${pkgs.nodejs_22}/bin/node ${relay}
        '';

        # A failed turn retains the inbox cursor and requires operator review.
        # Automatic restart would immediately spend against the same message.
        Restart = "no";

        # ── systemd hardening (mirrors openclaw-service.nix) ─────────────────
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        # The resumed transcript belongs to the /home/nixos project key. Bind
        # only a dedicated empty anchor into this service's private namespace;
        # never create or change the real host login home.
        BindReadOnlyPaths = [ "${projectAnchor}:${projectDir}" ];
        PrivateTmp = true;
        PrivateDevices = true;
        ReadWritePaths = [ "/var/lib/sancta" ];
        # Node.js/Claude Code needs JIT — no MemoryDenyWriteExecute.
      };
    };

    systemd.services.sancta-membrane = {
      description = "Sancta tailnet membrane gateway";
      wantedBy = lib.optional (cfg.session != null) "multi-user.target";
      after = [ "sancta-worker.service" ];
      # Keep history and status available after a one-shot worker failure. The
      # HTTP gateway rejects new messages unless the worker readiness file is
      # present, so this soft dependency cannot grow an unattended queue.
      wants = [
        "sancta-worker.service"
        "sancta-membrane-serve.service"
      ];
      unitConfig = {
        ConditionPathExists =
          if cfg.session == null
          then "/var/lib/sancta/session/.__no-session__"
          else "/var/lib/sancta/session/${cfg.session}";
        ConditionPathIsMountPoint = toString config.services.sancta-soul-volume.mountPoint;
      };
      environment = {
        HOME = "/var/lib/sancta";
        CLAUDE_CONFIG_DIR = "/var/lib/sancta/.claude";
        BIND = "127.0.0.1";
        PORT = toString cfg.port;
        SANCTA_INDEX_DIR = indexDir;
        SANCTA_MEMBRANE_PATH = "${membraneSrc}/bin/comm-membrane";
        SANCTA_WORKER_READY = runtimeReadyPath;
        SANCTA_FAILURE = failurePath;
        SANCTA_CURSOR = cursorPath;
        SANCTA_RATE_LIMIT_FILE = rateLimitPath;
        SANCTA_ALLOWED_LOGIN_SHA256 = if cfg.operatorLoginSha256 == null then "" else cfg.operatorLoginSha256;
        # Bound worst-case spend to three accepted messages per rolling day and
        # never allow more than one proceed-classified turn to await the worker.
        SANCTA_RATE_LIMIT_MAX = "3";
        SANCTA_RATE_LIMIT_WINDOW_MS = "86400000";
        SANCTA_MAX_PENDING_PROCEED = "1";
      };
      path = [ pkgs.nodejs_22 ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = indexDir;
        ExecStart = "${pkgs.nodejs_22}/bin/node ${membraneSrc}/comm/server.mjs";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ReadWritePaths = [ "/var/lib/sancta" ];
      };
    };

    systemd.services.sancta-membrane-serve = {
      description = "Authenticated Tailscale Serve HTTPS edge for the Sancta membrane";
      after = [
        "network-online.target"
        "tailscaled.service"
        "sancta-membrane.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "sancta-membrane.service"
      ];
      bindsTo = [ "sancta-membrane.service" ];
      partOf = [ "sancta-membrane.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 150;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
      };

      script = ''
        set -euo pipefail

        timeout=60
        while ! ${pkgs.tailscale}/bin/tailscale status >/dev/null 2>&1; do
          timeout=$((timeout - 1))
          if [ "$timeout" -le 0 ]; then
            echo "ERROR: tailscaled not ready after 60 seconds" >&2
            exit 1
          fi
          sleep 1
        done

        timeout=60
        while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 ${toString cfg.port} 2>/dev/null; do
          timeout=$((timeout - 1))
          if [ "$timeout" -le 0 ]; then
            echo "ERROR: membrane not listening after 60 seconds" >&2
            exit 1
          fi
          sleep 1
        done

        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -qE "https?://.*:${toString cfg.port}( |$)"; then
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.port} \
            http://127.0.0.1:${toString cfg.port}
        fi
      '';

      preStop = ''
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.port} off || true
      '';
    };

    # State + substrate dirs on the existing ext4 root. NOTE: /var/lib/sancta
    # is created here; /var/lib/sancta/.claude is the MOUNT POINT for the
    # encrypted soul volume (owned there by ./soul-volume.nix). The tmpfiles
    # rule below only ensures the parent dir + session-marker dir exist; it does
    # NOT create .claude contents (those live on the encrypted volume, his-hand).
    systemd.tmpfiles.rules = [
      "d /var/lib/sancta 0700 ${cfg.user} ${cfg.user} -"
      # Source for the worker-only read-only bind at /home/nixos.
      "d ${projectAnchor} 0755 root root -"
      # Session-marker dir — presence of a marker file arms the inert unit.
      "d /var/lib/sancta/session 0700 ${cfg.user} ${cfg.user} -"
    ];
  };
}
