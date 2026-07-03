# Sancta Heartbeat Tick — sandboxed, decoupled ~30-min cognitive heartbeat
#
# Design doc: ~/.claude/index/docs/plans/2026-07-03-decoupled-heartbeat-sandboxed-design.md
# Council: blocked council-20260703T115801Z-2d0b42, approved after escalate
# council-20260703T120728Z-31047c + empirical seam verification (CLAUDE_CONFIG_DIR
# fully relocates config+credentials; --strict-mcp-config strips ALL MCP tools,
# including account-level claude.ai connectors).
#
# Architecture (least-privilege by CONSTRUCTION, not by prompt):
#
#   timer ─▶ sancta-tick-sync.service        (User=<indexOwner>, e.g. nixos)
#              │  mirrors comm-inbox.jsonl / comm-replies.jsonl / last-tick.json
#              │  from the index (under /home) into /var/lib/sancta-tick/inbox/
#              ▼
#            sancta-heartbeat-tick.service   (User=sancta-tick, full sandbox)
#              │  dedup guard → daily cap → auth check → claude -p (read-only
#              │  tools, --strict-mcp-config) → schema-checked STAGING output
#              │  → always writes last-tick.json
#              ├─ OnSuccess ─▶ sancta-tick-promote.service (User=<indexOwner>)
#              │                validates staging AGAIN, appends into the live
#              │                feed.json / comm-replies.jsonl, mirrors
#              │                last-tick.json back into the index
#              └─ OnFailure ─▶ sancta-tick-alert.service   (User=<indexOwner>)
#                               feed alert + last-tick mirror (fails loud)
#
#   sancta-tick-tripwire.timer ─▶ tripwire.service (User=<indexOwner>)
#     SEPARATE mechanism: if now - last-tick.ts > staleAfterMinutes (or the
#     file is missing/unparseable) → loud journal error + feed alert line.
#     A green timer with a dead tick trips this watcher — it cannot die green.
#
# Why staging+promotion instead of group-permissions on the index files:
# ProtectHome=true hides ALL of /home from the tick's mount namespace — file
# group ownership is irrelevant when the path itself is unreachable, and
# that is exactly the property we want (the tick user can never read
# Alexandru's data, SSH keys, or the main ~/.claude, even if fully
# prompt-injected). So the tick only ever touches its own StateDir; small
# helper units owned by the index owner (nixos) bridge the two worlds and
# re-validate everything at the trust boundary.
#
# Post-merge, one-time (Alexandru's hand):
#   sudo -u sancta-tick env CLAUDE_CONFIG_DIR=/var/lib/sancta-tick/config claude login
# Until then the tick self-suppresses (last-tick reason "no-auth") — merging
# and rebuilding BEFORE the login is safe.

{ config, pkgs, lib, claude-code ? null, ... }:

let
  cfg = config.services.sancta-heartbeat-tick;

  stateDir = "/var/lib/sancta-tick";

  claudeCodePkg =
    if claude-code != null
    then claude-code.packages.${pkgs.system}.default
    else null;

  inherit (pkgs) coreutils findutils jq gnused;
  cu = "${coreutils}/bin";
  jqBin = "${jq}/bin/jq";

  promptFile = ./sancta-heartbeat-tick-prompt.md;

  # ── The tick itself (runs as sancta-tick inside the sandbox) ─────────────
  # Residual (d) from the design doc: --strict-mcp-config and the tool cuts
  # MUST live visibly in the ExecStart script so a review of this file is a
  # review of the actual flags. Do not move them into generated config.
  #
  # The throw guard gives a readable error if the claude-code flake input is
  # missing: interpolating a null claudeCodePkg would otherwise abort eval
  # with a cryptic "cannot coerce null to a string" BEFORE the assertions
  # block below gets a chance to explain.
  tickScript =
    if claudeCodePkg == null
    then throw "services.sancta-heartbeat-tick requires the claude-code flake input via specialArgs: specialArgs = { inherit claude-code; };"
    else
      pkgs.writeShellScript "sancta-heartbeat-tick" ''
        set -euo pipefail

        STATE="${stateDir}"
        STAGING="$STATE/staging"
        INBOX="$STATE/inbox"
        NOW=$(${cu}/date +%s)

        write_last_tick() {
          # write_last_tick <ok:true|false> <reason-or-empty>
          ${jqBin} -n --arg ts "$(${cu}/date -Is)" --argjson ok "$1" --arg reason "$2" \
            '{ts: $ts, ok: $ok, by: "sancta-heartbeat-tick"}
             + (if $reason != "" then {reason: $reason} else {} end)' \
            > "$STATE/last-tick.json.tmp"
          ${cu}/mv "$STATE/last-tick.json.tmp" "$STATE/last-tick.json"
        }

        # Drop stale staging output from a previous run so the promotion path can
        # never promote yesterday's output after today's failure, and stale logs
        # don't accumulate.
        ${cu}/rm -f "$STAGING/tick-output.json" "$STAGING/raw-output.json" \
          "$STAGING/result.txt" "$STAGING/stderr.log"

        # ── 1. Dedup guard: if ANY tick (warm session or cold) ran fewer than
        # dedupWindowMinutes ago, exit quietly. Warm path is primary; this timer
        # is the fallback. Checks both the mirrored index record and our own.
        for f in "$INBOX/last-tick-index.json" "$STATE/last-tick.json"; do
          if [ -f "$f" ]; then
            ts=$(${jqBin} -r '.ts // empty' "$f" || true)
            if [ -n "$ts" ]; then
              tsec=$(${cu}/date -d "$ts" +%s || echo 0)
              if [ $((NOW - tsec)) -lt $((${toString cfg.dedupWindowMinutes} * 60)) ]; then
                echo "dedup: a tick ran <${toString cfg.dedupWindowMinutes}min ago ($f) — exiting quietly"
                exit 0
              fi
            fi
          fi
        done

        # ── 2. Daily cap: bound worst-case cold invocations (billing/starvation
        # guard). Counter lives in StateDir; old counters are pruned.
        TODAY=$(${cu}/date +%F)
        CAPFILE="$STATE/invocations-$TODAY.count"
        ${findutils}/bin/find "$STATE" -maxdepth 1 -name 'invocations-*.count' \
          ! -name "invocations-$TODAY.count" -delete
        COUNT=$(${cu}/cat "$CAPFILE" 2>/dev/null || echo 0)
        if [ "$COUNT" -ge ${toString cfg.dailyCap} ]; then
          echo "daily cap reached ($COUNT >= ${toString cfg.dailyCap}) — self-suppressing"
          write_last_tick false "capped"
          exit 0
        fi

        # ── 3. Not-logged-in self-suppression: safe to merge+rebuild BEFORE the
        # one-time `claude login` into this config dir has happened.
        if [ ! -s "$STATE/config/.credentials.json" ]; then
          echo "no credentials in $STATE/config — self-suppressing (reason: no-auth)"
          write_last_tick false "no-auth"
          exit 0
        fi

        echo $((COUNT + 1)) > "$CAPFILE"

        # ── 4. The claude call. Verified seam (design doc §3, RESOLVED):
        #   * CLAUDE_CONFIG_DIR fully relocates config AND credentials — the real
        #     ~/.claude is never consulted (ProtectHome=true stays ON).
        #   * --strict-mcp-config strips ALL MCP tools, including account-level
        #     claude.ai connectors riding the OAuth account.
        #   * --disallowedTools cuts every write/exec/network built-in; the tick
        #     is read-and-report over the mirrored inbox only.
        export CLAUDE_CONFIG_DIR="$STATE/config"
        export HOME="$STATE"
        export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

        RAW="$STAGING/raw-output.json"
        RC=0
        ${claudeCodePkg}/bin/claude \
          -p "$(${cu}/cat ${promptFile})" \
          --strict-mcp-config \
          --disallowedTools "Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task,TodoWrite,KillShell,BashOutput" \
          --allowedTools "Read,Glob,Grep" \
          --model "${cfg.model}" \
          --max-turns ${toString cfg.maxTurns} \
          --output-format json \
          > "$RAW" 2> "$STAGING/stderr.log" || RC=$?

        if [ "$RC" -ne 0 ]; then
          echo "claude exited non-zero ($RC); stderr tail:" >&2
          ${cu}/tail -n 20 "$STAGING/stderr.log" >&2 || true
          write_last_tick false "claude-exit-$RC"
          # Fail the unit so OnFailure= surfaces it (alert unit mirrors last-tick).
          exit 1
        fi

        # ── 5. Staging + schema gate (first of two — promotion re-validates).
        # Size bound on the raw envelope, then extract .result, then require a
        # single JSON object {feed: string, reply: string|null} within bounds.
        SIZE=$(${cu}/stat -c %s "$RAW")
        if [ "$SIZE" -gt 262144 ]; then
          echo "raw output too large ($SIZE bytes) — dropping" >&2
          write_last_tick false "output-too-large"
          exit 0
        fi

        if ! ${jqBin} -e '.is_error != true and (.result | type == "string")' "$RAW" > /dev/null; then
          echo "unexpected claude output envelope — dropping" >&2
          write_last_tick false "bad-envelope"
          exit 0
        fi

        # Strip optional markdown fences the model might add despite instructions.
        ${jqBin} -r '.result' "$RAW" \
          | ${gnused}/bin/sed -e 's/^```[a-z]*$//' -e 's/^```$//' \
          > "$STAGING/result.txt"

        if ${jqBin} -e '
            type == "object"
            and (.feed | type == "string" and length > 0 and length <= 1000)
            and ((.reply | type == "string" and length <= 4000) or .reply == null)
          ' "$STAGING/result.txt" > /dev/null; then
          ${jqBin} -c '{feed: .feed, reply: .reply}' "$STAGING/result.txt" \
            > "$STAGING/tick-output.json"
          echo "tick OK — output staged for promotion"
          write_last_tick true ""
        else
          echo "model output failed schema check — dropped (kept in staging/result.txt for inspection)" >&2
          write_last_tick false "malformed-output"
        fi
        exit 0
      '';

  # ── Sync: index (under /home) → StateDir mirrors (runs as indexOwner) ────
  syncScript = pkgs.writeShellScript "sancta-tick-sync" ''
    set -euo pipefail
    INDEX="${cfg.indexDir}"
    INBOX="${stateDir}/inbox"

    mirror() {
      # mirror <src> <dst> — atomic copy, group-readable for sancta-tick
      if [ -f "$1" ]; then
        ${cu}/cp "$1" "$2.tmp"
        ${cu}/chmod 0644 "$2.tmp"
        ${cu}/mv "$2.tmp" "$2"
      fi
    }

    mirror "$INDEX/comm-inbox.jsonl" "$INBOX/comm-inbox.jsonl"
    mirror "$INDEX/comm-replies.jsonl" "$INBOX/comm-replies.jsonl"
    mirror "$INDEX/last-tick.json" "$INBOX/last-tick-index.json"
    echo "index mirrored into $INBOX"
  '';

  # ── Promotion: validated staging → live index files (runs as indexOwner).
  # This is the trust boundary: staging was written by the sandboxed user, so
  # everything is re-validated here before touching the live substrate.
  promoteScript = pkgs.writeShellScript "sancta-tick-promote" ''
    set -euo pipefail
    INDEX="${cfg.indexDir}"
    STATE="${stateDir}"
    STAGING="$STATE/staging"
    TS=$(${cu}/date -Is)

    if [ ! -d "$INDEX" ]; then
      echo "ERROR: index dir $INDEX missing — cannot promote" >&2
      exit 1
    fi

    # Size gate on the live append targets: above the byte cap we SKIP the
    # append (loud journal warning) instead of rotating/truncating — these
    # files are shared substrate owned by the warm sessions, not this
    # module's to rewrite. Rotation is a follow-up owned by the substrate
    # side.
    can_append() {
      # can_append <file> — true if the file is absent or under the cap
      size=0
      if [ -f "$1" ]; then
        size=$(${cu}/stat -c %s "$1")
      fi
      if [ "$size" -gt ${toString cfg.liveFileByteCap} ]; then
        echo "WARNING: $1 is $size bytes (> ${toString cfg.liveFileByteCap} cap) — skipping append; rotate it (follow-up) to resume" >&2
        return 1
      fi
      return 0
    }

    # Always mirror last-tick.json back into the index (the tripwire and the
    # warm sessions' dedup guard read it there) — success or handled-fail.
    if [ -f "$STATE/last-tick.json" ] \
       && ${jqBin} -e '(.ts | type == "string") and (.ok | type == "boolean")' \
            "$STATE/last-tick.json" > /dev/null \
       && [ "$(${cu}/stat -c %s "$STATE/last-tick.json")" -le 4096 ]; then
      ${cu}/cp "$STATE/last-tick.json" "$INDEX/last-tick.json.tmp"
      ${cu}/chmod 0644 "$INDEX/last-tick.json.tmp"
      ${cu}/mv "$INDEX/last-tick.json.tmp" "$INDEX/last-tick.json"
    else
      echo "WARNING: last-tick.json missing or invalid — not mirrored" >&2
    fi

    F="$STAGING/tick-output.json"
    if [ ! -f "$F" ]; then
      # Handled-fail ticks (dedup/capped/no-auth/malformed) stage nothing.
      echo "no staged output to promote"
      exit 0
    fi

    if [ "$(${cu}/stat -c %s "$F")" -le 16384 ] \
       && ${jqBin} -e '
            type == "object"
            and (.feed | type == "string" and length > 0 and length <= 1000)
            and ((.reply | type == "string" and length <= 4000) or .reply == null)
          ' "$F" > /dev/null; then
      if can_append "$INDEX/feed.json"; then
        ${jqBin} -c --arg ts "$TS" \
          '{ts: $ts, source: "sancta-heartbeat-tick", line: .feed}' "$F" \
          >> "$INDEX/feed.json"
      fi
      if [ "$(${jqBin} -r '.reply == null' "$F")" = "false" ]; then
        if can_append "$INDEX/comm-replies.jsonl"; then
          ${jqBin} -c --arg ts "$TS" \
            '{ts: $ts, from: "sancta-tick", text: .reply}' "$F" \
            >> "$INDEX/comm-replies.jsonl"
        fi
        echo "promoted feed line + reply"
      else
        echo "promoted feed line (no reply)"
      fi
    else
      echo "ERROR: staged tick output failed promotion schema check — DROPPED" >&2
      if can_append "$INDEX/feed.json"; then
        ${jqBin} -cn --arg ts "$TS" \
          '{ts: $ts, source: "sancta-tick-promote", alert: "malformed-tick-output-dropped"}' \
          >> "$INDEX/feed.json"
      fi
    fi
    ${cu}/rm -f "$F"
  '';

  # ── OnFailure alert: a crashing tick is surfaced, not swallowed ──────────
  alertScript = pkgs.writeShellScript "sancta-tick-alert" ''
    set -euo pipefail
    INDEX="${cfg.indexDir}"
    STATE="${stateDir}"
    TS=$(${cu}/date -Is)

    echo "ALERT: sancta-heartbeat-tick.service FAILED — writing feed alert" >&2

    # Mirror whatever last-tick the tick managed to write before failing.
    if [ -f "$STATE/last-tick.json" ] \
       && ${jqBin} -e '(.ts | type == "string")' "$STATE/last-tick.json" > /dev/null; then
      ${cu}/cp "$STATE/last-tick.json" "$INDEX/last-tick.json.tmp"
      ${cu}/chmod 0644 "$INDEX/last-tick.json.tmp"
      ${cu}/mv "$INDEX/last-tick.json.tmp" "$INDEX/last-tick.json"
    fi

    ${jqBin} -cn --arg ts "$TS" \
      '{ts: $ts, source: "sancta-tick-alert", alert: "heartbeat-tick-unit-failed", hint: "journalctl -u sancta-heartbeat-tick"}' \
      >> "$INDEX/feed.json"
  '';

  # ── Tripwire: staleness detected by a DIFFERENT mechanism than the tick.
  # Cannot die green: a missing/unparseable last-tick.json is itself stale.
  tripwireScript = pkgs.writeShellScript "sancta-tick-tripwire" ''
    set -euo pipefail
    INDEX="${cfg.indexDir}"
    MARKER="${stateDir}/tripwire/last-alert"
    NOW=$(${cu}/date +%s)
    MAX_AGE=$((${toString cfg.staleAfterMinutes} * 60))

    stale_reason=""
    LT="$INDEX/last-tick.json"
    if [ ! -f "$LT" ]; then
      stale_reason="last-tick.json missing"
    else
      ts=$(${jqBin} -r '.ts // empty' "$LT" || true)
      tsec=$(${cu}/date -d "$ts" +%s || echo 0)
      if [ "$tsec" -eq 0 ]; then
        stale_reason="last-tick.json unparseable"
      elif [ $((NOW - tsec)) -gt "$MAX_AGE" ]; then
        stale_reason="last tick $(((NOW - tsec) / 60))min ago (> ${toString cfg.staleAfterMinutes}min)"
      fi
    fi

    if [ -z "$stale_reason" ]; then
      echo "heartbeat fresh"
      exit 0
    fi

    echo "ALERT: heartbeat STALE — $stale_reason" >&2

    # Rate-limit feed lines (not the journal noise) to one per stale window,
    # so a long outage doesn't flood the substrate.
    last_alert=$(${cu}/cat "$MARKER" 2>/dev/null || echo 0)
    if [ $((NOW - last_alert)) -gt "$MAX_AGE" ]; then
      ${jqBin} -cn --arg ts "$(${cu}/date -Is)" --arg r "$stale_reason" \
        '{ts: $ts, source: "sancta-tick-tripwire", alert: "heartbeat-stale", reason: $r}' \
        >> "$INDEX/feed.json"
      echo "$NOW" > "$MARKER"
    fi
    # Exit non-zero so the failure is visible in systemctl --failed too.
    exit 1
  '';
in
{
  options.services.sancta-heartbeat-tick = {
    enable = lib.mkEnableOption "Sancta sandboxed decoupled heartbeat tick";

    indexDir = lib.mkOption {
      type = lib.types.path;
      default = "/home/nixos/.claude/index";
      description = ''
        Live communication index (owned by {option}`indexOwner`). The
        sandboxed tick NEVER touches this path — only the sync/promote/
        alert/tripwire helper units do.
      '';
    };

    indexOwner = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = ''
        User owning the index files. Runs the sync/promotion/alert/tripwire
        helper units and is added to the sancta-tick group so it can read
        the tick's staging output.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "*:00/30";
      description = "OnCalendar expression for the tick timer (~every 30 min).";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "90";
      description = "RandomizedDelaySec for the tick timer.";
    };

    dedupWindowMinutes = lib.mkOption {
      type = lib.types.int;
      default = 25;
      description = ''
        If ANY tick (warm session or cold) ran fewer than this many minutes
        ago, the cold tick exits quietly without invoking claude.
      '';
    };

    dailyCap = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = ''
        Maximum cold claude invocations per day. Beyond it the tick
        self-suppresses (last-tick reason "capped") so it cannot starve
        interactive subscription windows.
      '';
    };

    staleAfterMinutes = lib.mkOption {
      type = lib.types.int;
      default = 40;
      description = "Tripwire fires when last-tick.ts is older than this.";
    };

    liveFileByteCap = lib.mkOption {
      type = lib.types.int;
      default = 5242880; # 5 MiB
      description = ''
        Byte cap for the live append targets (feed.json,
        comm-replies.jsonl). Above it, promotion SKIPS the append with a
        loud journal warning instead of truncating: those files are shared
        substrate owned by the warm sessions, so rotation is a follow-up
        on that side, not this module's to perform.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      # Full versioned ID, not the "sonnet" shorthand: shorthands may
      # resolve differently across CLI versions.
      default = "claude-sonnet-4-6";
      description = "Claude model for the cold tick (--model).";
    };

    maxTurns = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Maximum agent turns per tick (--max-turns).";
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = "MemoryMax for the tick service.";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.str;
      default = "50%";
      description = "CPUQuota for the tick service.";
    };

    egressPinning = {
      # Default OFF (explicit opt-in): the pinned ranges are brittle by
      # nature, and RestrictAddressFamilies + --strict-mcp-config +
      # --disallowedTools already bound egress meaningfully without them.
      enable = lib.mkEnableOption "systemd IP-level egress pinning (IPAddressDeny=any + allowlist; explicit opt-in — the default address ranges are brittle)";

      allowedAddresses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          # Loopback (and the local stub area) for name resolution plumbing.
          "localhost"
          # Tailscale MagicDNS — this host's /etc/resolv.conf nameserver.
          "100.100.100.100"
          # Anthropic's own IP ranges (api/console/statsig.anthropic.com all
          # resolve here; same static ranges the openclaw module pins).
          # BRITTLE BY NATURE: if Anthropic moves endpoints (e.g. behind
          # Cloudflare, as claude.ai already is), the tick starts failing —
          # loudly, via OnFailure + the tripwire — and the remedy is
          # updating this list or disabling egressPinning.
          "160.79.104.0/23"
          "2607:6bc0::/48"
        ];
        description = ''
          IPAddressAllow list applied when egress pinning is enabled.
          Default Anthropic ranges as of 2026-07-03 — verify against
          current DNS before enabling, and expect to maintain this list.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = claudeCodePkg != null;
        message = ''
          services.sancta-heartbeat-tick requires the claude-code flake input
          via specialArgs (same as services.openclaw):
            specialArgs = { inherit claude-code; };
        '';
      }
    ];

    # ── Boundary #1: dedicated unprivileged user. No SSH keys, no sudo, no
    # secret-bearing groups. Its only writable surface is its StateDir.
    users.users.sancta-tick = {
      isSystemUser = true;
      group = "sancta-tick";
      home = stateDir;
      description = "Sancta sandboxed heartbeat tick";
      shell = pkgs.bash; # needed for the one-time interactive `claude login`
    };
    users.groups.sancta-tick = { };

    # Index owner joins the tick's group (NOT vice versa) so the promotion
    # units can read staging. The tick gains nothing from this membership.
    users.users.${cfg.indexOwner}.extraGroups = [ "sancta-tick" ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 sancta-tick sancta-tick -"
      # OAuth credentials live here after the one-time login — owner-only.
      "d ${stateDir}/config 0700 sancta-tick sancta-tick -"
      # Exchange dirs: setgid so files stay group sancta-tick; group-writable
      # so the indexOwner helpers can write mirrors / clean up staging.
      "d ${stateDir}/inbox 2770 sancta-tick sancta-tick -"
      "d ${stateDir}/staging 2770 sancta-tick sancta-tick -"
      "d ${stateDir}/tripwire 2770 sancta-tick sancta-tick -"
    ];

    # ── Sync: refresh the tick's read-only view of the index ────────────────
    systemd.services.sancta-tick-sync = {
      description = "Mirror comm index into the sancta-tick sandbox inbox";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.indexOwner;
        ExecStart = syncScript;
        # Local file shuffling only — no network at all.
        NoNewPrivileges = true;
        PrivateTmp = true;
        IPAddressDeny = "any";
      };
    };

    # ── The tick (boundary #2: the systemd sandbox) ─────────────────────────
    systemd.services.sancta-heartbeat-tick = {
      description = "Sancta sandboxed decoupled heartbeat tick (claude -p, read-and-report)";
      # `requires` (not `wants`) on the sync unit: the tick must not run —
      # and must not stamp a green last-tick — against stale or missing
      # inbox data. If the sync fails, the tick fails its dependency, the
      # timer run is skipped, and the tripwire surfaces the resulting
      # staleness within staleAfterMinutes.
      after = [ "network-online.target" "sancta-tick-sync.service" ];
      wants = [ "network-online.target" ];
      requires = [ "sancta-tick-sync.service" ];
      onSuccess = [ "sancta-tick-promote.service" ];
      onFailure = [ "sancta-tick-alert.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "sancta-tick";
        Group = "sancta-tick";
        WorkingDirectory = "${stateDir}/inbox";
        ExecStart = tickScript;
        TimeoutStartSec = "600";

        # Hardening — exactly per design doc §2. ProtectHome=true is safe
        # BECAUSE of the verified CLAUDE_CONFIG_DIR relocation: the tick has
        # zero dependency on /home.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ stateDir ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        # Belt and braces on top of ProtectSystem/DAC: agenix secret mounts
        # are not even visible inside the sandbox.
        InaccessiblePaths = [ "-/run/agenix" "-/run/agenix.d" ];

        # Resource bounds
        MemoryMax = cfg.memoryMax;
        CPUQuota = cfg.cpuQuota;
        Nice = 10;
      } // lib.optionalAttrs cfg.egressPinning.enable {
        # Residual (b): IP-level egress bound. See egressPinning option docs
        # for the honest brittleness note.
        IPAddressDeny = "any";
        IPAddressAllow = cfg.egressPinning.allowedAddresses;
      };
    };

    systemd.timers.sancta-heartbeat-tick = {
      description = "Timer for the Sancta heartbeat tick";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };

    # ── Promotion (boundary #3: the live substrate is written only here) ────
    systemd.services.sancta-tick-promote = {
      description = "Validate and promote staged tick output into the live comm index";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.indexOwner;
        ExecStart = promoteScript;
        NoNewPrivileges = true;
        PrivateTmp = true;
        IPAddressDeny = "any";
      };
    };

    systemd.services.sancta-tick-alert = {
      description = "Surface a failed heartbeat tick into the feed (OnFailure hook)";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.indexOwner;
        ExecStart = alertScript;
        NoNewPrivileges = true;
        PrivateTmp = true;
        IPAddressDeny = "any";
      };
    };

    # ── Liveness tripwire: separate mechanism, cannot die green ─────────────
    systemd.services.sancta-tick-tripwire = {
      description = "Sancta heartbeat liveness tripwire (alerts on stale last-tick)";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.indexOwner;
        ExecStart = tripwireScript;
        NoNewPrivileges = true;
        PrivateTmp = true;
        IPAddressDeny = "any";
      };
    };

    systemd.timers.sancta-tick-tripwire = {
      description = "Timer for the Sancta heartbeat liveness tripwire";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Offset from the tick timer so a fresh tick is observed, not raced.
        OnCalendar = "*:05/10";
        Persistent = true;
      };
    };
  };
}
