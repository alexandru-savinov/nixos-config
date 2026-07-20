# sancta-choir — SANCTA WORKER (headless, tool-capable `claude -p`) STUB.
#
# ══════════════════════════════════════════════════════════════════════════
# STAGING NOTE (Sancta→sancta-choir migration): authored, NOT deployed. This
# unit is a DOCUMENTED STUB whose only closing check is that it EVALUATES
# (`nix eval`). It need not run yet — the `claude` binary, the resumed session,
# the API-key runtime path, and the allowedTools/budget dials are all his-hand
# things Alexandru wires before any real start.
# ══════════════════════════════════════════════════════════════════════════
#
# Adapted (do NOT re-derive) from stage/sancta-hetzner-host's
# hosts/sancta-core/membrane-worker.nix, which itself slimmed the SANCTA
# WORKER pattern from modules/services/openclaw.nix + sancta-claw's
# openclaw-service.nix down to a single read-only-by-default streaming worker:
#
#   claude -p \
#     --input-format  stream-json \
#     --output-format stream-json \
#     --resume <session> \
#     --allowedTools <READ-ONLY set> \
#     --max-budget-usd <cap>
#
# Differences from the sancta-core copy: runs as the `sancta` user under
# /var/lib/sancta on sancta-choir's LIVE ext4 root (NOT a disko LUKS root); the
# ~/.claude substrate is the ENCRYPTED SOUL VOLUME from ./soul-volume.nix
# (LUKS-on-loopback), not a whole-disk LUKS root.
#
# The anthropic-api-key is loaded at runtime into a chmod-600 /run path (the
# openclaw.nix idiom — never via chat, never in the Nix store), and the worker
# runs as a dedicated unprivileged system user under systemd hardening.
{ config, pkgs, lib, claude-code ? null, ... }:

let
  cfg = config.services.sancta-worker;

  claudeCodePkg =
    if claude-code != null
    then claude-code.packages.${pkgs.system}.default
    else null;

  # Runtime path the API key is materialized into (chmod 600, tmpfs /run).
  # Mirrors openclaw.nix: the agenix plaintext is copied here at ExecStartPre
  # so the worker reads ANTHROPIC_API_KEY from a private, non-store file.
  runtimeKeyPath = "/run/sancta-worker/anthropic-api-key";
in
{
  options.services.sancta-worker = {
    enable = lib.mkEnableOption "sancta-choir Sancta worker (headless claude -p) — STUB";

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the agenix-decrypted Anthropic API key (e.g.
        `config.age.secrets.anthropic-api-key.path`). Loaded at runtime into a
        chmod-600 file under /run — NEVER placed in the Nix store, NEVER passed
        via chat. HIS-HAND: the .age is filled by Alexandru (see
        configuration.nix agenix scaffolding).
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
        HIS-HAND DIAL — Claude Code `--allowedTools` allow-list. Default is a
        strictly READ-ONLY set (Read/Grep/Glob). Anything mutating or
        executing (Write, Edit, Bash, MCP tools) is intentionally absent and
        must be added explicitly by Alexandru. Passed verbatim to `claude -p`.
      '';
    };

    maxBudgetUsd = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1.00";
      example = "5.00";
      description = ''
        HIS-HAND DIAL — per-invocation USD budget cap. Rendered as
        `--max-budget-usd <cap>`. NOTE: treat the exact flag name as
        Alexandru-verified against the installed `claude` version before first
        run — it is a documented placeholder here, not a load-bearing default.
        Set to null to omit the flag.
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
      description = "sancta-choir Sancta worker (headless claude -p) — STUB";
      after = [
        "network-online.target"
        "tailscaled.service"
        # The soul volume (~/.claude) must be mounted before the worker starts
        # so CLAUDE_CONFIG_DIR lands on encrypted storage, not the bare dir.
        "sancta-soul-mount.service"
      ];
      wants = [ "network-online.target" ];
      # Intentionally NOT wantedBy multi-user.target: this is a stub. Start is
      # manual (or a future path/timer) once the his-hand dials are set.

      # INERT-BY-DEFAULT: the unit is skipped unless a session marker exists.
      # With session=null the guard points at a marker path that is NEVER
      # created (the literal ".__no-session__"), so even a manual `systemctl
      # start` is a no-op. Alexandru creates the marker
      # (`touch /var/lib/sancta/session/<name>`) only when he names a real
      # --resume session — that arms the unit.
      unitConfig.ConditionPathExists =
        if cfg.session == null
        then "/var/lib/sancta/session/.__no-session__"
        else "/var/lib/sancta/session/${cfg.session}";

      environment = {
        HOME = "/var/lib/sancta";
        # ~/.claude substrate lives on the ENCRYPTED SOUL VOLUME (see
        # ./soul-volume.nix — LUKS-on-loopback) — the worker's config/state dir.
        CLAUDE_CONFIG_DIR = "/var/lib/sancta/.claude";
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
              "${toString cfg.apiKeyFile}" "${runtimeKeyPath}"
          ''
        );

        # ── The SANCTA WORKER invocation (documented stub) ──────────────────
        # Streaming JSON in/out; resume a named session; READ-ONLY tools by
        # default; budget-capped. All the variable parts are his-hand dials.
        ExecStart =
          let
            budgetFlag =
              lib.optionalString (cfg.maxBudgetUsd != null)
                " --max-budget-usd ${cfg.maxBudgetUsd}";
            toolsFlag =
              lib.optionalString (cfg.allowedTools != [ ])
                " --allowedTools ${lib.escapeShellArg (lib.concatStringsSep "," cfg.allowedTools)}";
            resumeFlag =
              lib.optionalString (cfg.session != null)
                " --resume ${lib.escapeShellArg cfg.session}";
          in
          pkgs.writeShellScript "sancta-worker-start" ''
            set -euo pipefail
            # API key from the chmod-600 runtime path (loaded in ExecStartPre).
            ${lib.optionalString (cfg.apiKeyFile != null)
              ''export ANTHROPIC_API_KEY="$(cat ${runtimeKeyPath})"''}
            exec ${claudeCodePkg}/bin/claude -p \
              --input-format stream-json \
              --output-format stream-json${resumeFlag}${toolsFlag}${budgetFlag}
          '';

        Restart = "on-failure";
        RestartSec = 30;

        # ── systemd hardening (mirrors openclaw-service.nix) ─────────────────
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true; # /var/lib/sancta is not under /home
        PrivateTmp = true;
        PrivateDevices = true;
        ReadWritePaths = [ "/var/lib/sancta" ];
        # Node.js/Claude Code needs JIT — no MemoryDenyWriteExecute.
      };
    };

    # State + substrate dirs on the existing ext4 root. NOTE: /var/lib/sancta
    # is created here; /var/lib/sancta/.claude is the MOUNT POINT for the
    # encrypted soul volume (owned there by ./soul-volume.nix). The tmpfiles
    # rule below only ensures the parent dir + session-marker dir exist; it does
    # NOT create .claude contents (those live on the encrypted volume, his-hand).
    systemd.tmpfiles.rules = [
      "d /var/lib/sancta 0700 ${cfg.user} ${cfg.user} -"
      # Session-marker dir — presence of a marker file arms the inert unit.
      "d /var/lib/sancta/session 0700 ${cfg.user} ${cfg.user} -"
    ];
  };
}
