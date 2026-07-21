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
# --max-budget-usd are all present in `claude --help`. The --tools availability
# boundary plus --allowedTools headless auto-approval matches the deployed
# sancta-heartbeat-tick pattern in modules/services/sancta-heartbeat-tick.nix.
# The inline `--mcp-config '{"mcpServers":{}}'` form was also exercised with an
# isolated, unauthenticated CLAUDE_CONFIG_DIR: it passed MCP parsing and reached
# the expected auth gate; malformed JSON was rejected as invalid MCP config.
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
  indexDir = "/var/lib/sancta/.claude/index";
  inboxPath = "${indexDir}/comm-inbox.jsonl";
  repliesPath = "${indexDir}/comm-replies.jsonl";
  cursorPath = "${indexDir}/comm-worker-cursor.json";
  projectDir = "/home/nixos";

  relay = pkgs.writeText "sancta-worker-relay.mjs" ''
    import fs from "fs";
    import { open, readFile, rename, stat, writeFile } from "fs/promises";
    import { spawn } from "child_process";

    const inbox = process.env.SANCTA_INBOX;
    const replies = process.env.SANCTA_REPLIES;
    const cursorFile = process.env.SANCTA_CURSOR;
    const claudeBin = process.env.CLAUDE_BIN;
    const claudeArgs = JSON.parse(process.env.CLAUDE_ARGS_JSON);

    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const log = message => process.stdout.write(new Date().toISOString() + " " + message + "\n");

    async function saveCursor(offset) {
      const temporary = cursorFile + ".tmp";
      await writeFile(temporary, JSON.stringify({ offset }) + "\n", { mode: 0o600 });
      await rename(temporary, cursorFile);
    }

    async function loadCursor() {
      try {
        const saved = JSON.parse(await readFile(cursorFile, "utf8"));
        if (Number.isSafeInteger(saved.offset) && saved.offset >= 0) return saved.offset;
      } catch (error) {
        if (error.code !== "ENOENT") log("ignoring invalid cursor: " + error.message);
      }

      let size = 0;
      try { size = (await stat(inbox)).size; } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
      await saveCursor(size);
      log("initialized cursor at current inbox end: " + size);
      return size;
    }

    function textFromEvent(event) {
      if (event.type === "result" && typeof event.result === "string") return event.result;
      if (event.type !== "assistant" || !Array.isArray(event.message?.content)) return "";
      return event.message.content
        .filter(block => block.type === "text" && typeof block.text === "string")
        .map(block => block.text)
        .join("\n");
    }

    async function runTurn(message, inboxTs) {
      log("starting resumed turn for inbox ts=" + (inboxTs || "unknown"));
      const child = spawn(claudeBin, claudeArgs, {
        cwd: process.env.SANCTA_PROJECT_DIR,
        env: process.env,
        stdio: ["pipe", "pipe", "pipe"],
      });

      let stdoutBuffer = "";
      let stderr = "";
      let assistantText = "";
      let resultText = "";

      child.stdout.setEncoding("utf8");
      child.stdout.on("data", chunk => {
        stdoutBuffer += chunk;
        const lines = stdoutBuffer.split("\n");
        stdoutBuffer = lines.pop() || "";
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const event = JSON.parse(line);
            const text = textFromEvent(event);
            if (event.type === "result" && text) resultText = text;
            else if (event.type === "assistant" && text) assistantText = text;
          } catch (error) {
            log("ignoring malformed Claude output event: " + error.message);
          }
        }
      });
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", chunk => { stderr = (stderr + chunk).slice(-8192); });

      const input = {
        type: "user",
        message: { role: "user", content: [{ type: "text", text: message }] },
      };
      child.stdin.end(JSON.stringify(input) + "\n");

      const exitCode = await new Promise((resolve, reject) => {
        child.on("error", reject);
        child.on("close", resolve);
      });
      if (exitCode !== 0) {
        const detail = (resultText || assistantText || stderr).trim();
        throw new Error("Claude exited " + exitCode + (detail ? ": " + detail : ""));
      }

      const text = (resultText || assistantText).trim();
      if (!text) throw new Error("Claude completed without assistant text");
      const reply = {
        ts: new Date().toISOString(),
        from: "sancta",
        text,
        source: "sancta-worker",
        inbox_ts: inboxTs || null,
      };
      fs.appendFileSync(replies, JSON.stringify(reply) + "\n", { mode: 0o600 });
      log("appended live reply for inbox ts=" + (inboxTs || "unknown"));
    }

    let offset = await loadCursor();
    for (;;) {
      let size;
      try { size = (await stat(inbox)).size; } catch (error) {
        if (error.code === "ENOENT") { await sleep(500); continue; }
        throw error;
      }
      if (size < offset) {
        log("inbox shrank; resetting cursor to zero");
        offset = 0;
        await saveCursor(offset);
      }
      if (size === offset) { await sleep(500); continue; }

      const length = size - offset;
      const buffer = Buffer.alloc(length);
      const handle = await open(inbox, "r");
      try { await handle.read(buffer, 0, length, offset); } finally { await handle.close(); }
      const newline = buffer.lastIndexOf(10);
      if (newline < 0) { await sleep(500); continue; }

      const complete = buffer.subarray(0, newline + 1).toString("utf8");
      for (const line of complete.slice(0, -1).split("\n")) {
        const bytes = Buffer.byteLength(line + "\n");
        try {
          if (line) {
            const entry = JSON.parse(line);
            if (entry.decision === "proceed" && typeof entry.message === "string" && entry.message.trim()) {
              await runTurn(entry.message, entry.ts);
            }
          }
        } catch (error) {
          log("inbox record failed: " + error.message);
        }
        offset += bytes;
        await saveCursor(offset);
      }
    }
  '';
in
{
  options.services.sancta-worker = {
    enable = lib.mkEnableOption "sancta-choir live membrane and resumed Claude worker";

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
            # API-key-authenticated worker. Session history still resumes.
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
              "${toString cfg.apiKeyFile}" "${runtimeKeyPath}"
          ''
        );

        ExecStart = pkgs.writeShellScript "sancta-worker-start" ''
          set -euo pipefail
          ${lib.optionalString (cfg.apiKeyFile != null)
            ''export ANTHROPIC_API_KEY="$(cat ${runtimeKeyPath})"''}
          exec ${pkgs.nodejs_22}/bin/node ${relay}
        '';

        Restart = "on-failure";
        RestartSec = 30;

        # ── systemd hardening (mirrors openclaw-service.nix) ─────────────────
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        # The resumed transcript belongs to the /home/nixos project key.
        # Expose that empty anchor read-only; all mutable state remains under
        # the encrypted CLAUDE_CONFIG_DIR in /var/lib/sancta.
        ProtectHome = "read-only";
        PrivateTmp = true;
        PrivateDevices = true;
        ReadWritePaths = [ "/var/lib/sancta" ];
        # Node.js/Claude Code needs JIT — no MemoryDenyWriteExecute.
      };
    };

    systemd.services.sancta-membrane = {
      description = "Sancta tailnet membrane gateway";
      wantedBy = lib.optional (cfg.session != null) "multi-user.target";
      after = [ "sancta-worker.service" "tailscaled.service" ];
      requires = [ "sancta-worker.service" ];
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
      };
      path = [ pkgs.nodejs_22 ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = indexDir;
        ExecStart = pkgs.writeShellScript "sancta-membrane-start" ''
          set -euo pipefail
          test -f ${indexDir}/comm/server.mjs
          test -x ${indexDir}/bin/comm-membrane
          bind="$(${pkgs.tailscale}/bin/tailscale ip -4 | ${pkgs.coreutils}/bin/head -n1)"
          test -n "$bind"
          exec ${pkgs.coreutils}/bin/env BIND="$bind" PORT=8743 \
            ${pkgs.nodejs_22}/bin/node ${indexDir}/comm/server.mjs
        '';
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

    # State + substrate dirs on the existing ext4 root. NOTE: /var/lib/sancta
    # is created here; /var/lib/sancta/.claude is the MOUNT POINT for the
    # encrypted soul volume (owned there by ./soul-volume.nix). The tmpfiles
    # rule below only ensures the parent dir + session-marker dir exist; it does
    # NOT create .claude contents (those live on the encrypted volume, his-hand).
    systemd.tmpfiles.rules = [
      # Claude resolves --resume within the original transcript's project cwd.
      "d ${projectDir} 0755 root root -"
      "d /var/lib/sancta 0700 ${cfg.user} ${cfg.user} -"
      # Session-marker dir — presence of a marker file arms the inert unit.
      "d /var/lib/sancta/session 0700 ${cfg.user} ${cfg.user} -"
    ];
  };
}
