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
#                               feed alert + last-tick mirror (fails loud).
#                               ONLY a genuine crash (script bug / OOM / sandbox
#                               fault) trips this — HANDLED outcomes (claude
#                               exited non-zero, bad envelope, malformed output,
#                               capped, no-auth) exit 0 and are surfaced instead
#                               via last-tick.{ok:false,reason} + the journal, so
#                               a persistent handled error does not storm alerts.
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
# Authentication — long-lived OAuth token (headless-correct):
#   The tick authenticates via CLAUDE_CODE_OAUTH_TOKEN, the token minted by
#   `claude setup-token` (a one-year OAuth token for a Claude subscription —
#   https://code.claude.com/docs/en/authentication#generate-a-long-lived-token).
#   This is the correct headless-service mechanism: it survives OAuth reauth
#   better than an interactive-login .credentials.json and needs no browser.
#
#   The token is delivered to the unit via systemd LoadCredential=, which copies
#   the file (services.sancta-heartbeat-tick.oauthTokenFile) into the unit's
#   private $CREDENTIALS_DIRECTORY tmpfs — readable only by this service, never
#   world-readable, and never in the nix store. The token FILE itself is placed
#   by Alexandru's hand (chmod 600), NOT via git and NOT via chat; the module
#   only ever references its PATH.
#
# Post-merge, one-time (Alexandru's hand) — replaces the old `claude login`:
#   1. Mint a token (on any machine where he is logged in):  claude setup-token
#   2. Place it on the host, owner-only, off-git, off-store:
#        sudo install -m600 /dev/stdin /var/lib/sancta-tick/oauth-token
#        <paste the token, then Ctrl-D>
#   3. sudo nixos-rebuild switch --flake .#rpi5-full
# Until the token file exists the tick self-suppresses (last-tick reason
# "no-auth") — merging and rebuilding BEFORE the file is placed is safe.

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

  # ── Shared hardening for the indexOwner helper units (sync/promote/alert/
  # tripwire). These are pure local-file operations — no network, no new privs,
  # no capabilities, no namespaces. ProtectSystem=strict + an explicit
  # ReadWritePaths allowlist keeps the blast radius tight if staging content
  # (written by the sandboxed tick) ever exploited one of these scripts.
  # ReadWritePaths is passed per-unit (sync/tripwire touch only their own
  # StateDir subdir; promote/alert also write the live index).
  #
  # ProtectHome=tmpfs replaces /home with an empty tmpfs so the ONLY /home path
  # any helper can see is the index dir, re-exposed via BindPaths. This shrinks
  # the blast radius of a hypothetical exploit (via staging content the
  # sandboxed tick wrote) from "all of /home/<indexOwner>" — SSH keys, the main
  # ~/.claude, everything — down to exactly the one index dir the helper must
  # bridge. ProtectSystem=strict does NOT cover /home, so without this the
  # helpers had unrestricted read+write over the whole home; now they do not.
  # BindPaths (read-write) is used because promote/alert append to the index;
  # per-unit ReadWritePaths still scopes which of those bound paths are writable.
  helperHardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = "tmpfs";
    BindPaths = [ cfg.indexDir ];
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictNamespaces = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    LockPersonality = true;
    CapabilityBoundingSet = "";
    RestrictAddressFamilies = [ "AF_UNIX" ];
    SystemCallFilter = [ "@system-service" ];
    IPAddressDeny = "any";
  };

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
                  # write_last_tick <ok:true|false> <reason-or-empty> [quality-or-empty]
                  # quality (amendment 3): a low-cardinality tag on the tick's VALUE, so
                  # a "ticking but every reply is low-value/handled-fail" state is not
                  # invisible behind a green timestamp. Values:
                  #   reflected     — ok tick that staged a real reflection reply
                  #   bare-ack      — ok tick, no open message, reply=null (heartbeat only)
                  #   <reason>      — handled-fail ticks reuse their reason as the quality
                  # A simple check (or the deferred ok:false / low-value-streak detector,
                  # backlog sancta-tick-okfalse-streak-detector) can watch this field to
                  # surface a stuck-but-green heartbeat. Minimal by design: one string.
                  ${jqBin} -n --arg ts "$(${cu}/date -Is)" --argjson ok "$1" \
                    --arg reason "$2" --arg quality "''${3:-}" \
                    '{ts: $ts, ok: $ok, by: "sancta-heartbeat-tick"}
                     + (if $reason != "" then {reason: $reason} else {} end)
                     + (if $quality != "" then {quality: $quality} else {} end)' \
                    > "$STATE/last-tick.json.tmp"
                  ${cu}/mv "$STATE/last-tick.json.tmp" "$STATE/last-tick.json"
                }

                # Drop stale staging output from a previous run so the promotion path can
                # never promote yesterday's output after today's failure, and stale logs
                # don't accumulate.
                ${cu}/rm -f "$STAGING/tick-output.json" "$STAGING/raw-output.json" \
                  "$STAGING/result.txt" "$STAGING/stderr.log"

                # HOME="$STATE" (set below) makes the claude CLI drop its own cache/
                # state dot-dirs (~/.cache, ~/.config, ~/.claude, ~/.npm, ...) directly
                # under $STATE. Those are pure caches — re-created on demand — and have
                # no owner to prune them, so on a long-lived deployment they grow
                # unbounded. Clear them at the START of every tick. This is bounded and
                # reversible: it deletes only these known cache/state dot-dirs and never
                # touches the isolated config dir, the inbox/staging/tripwire exchange
                # dirs, the cap counters, or last-tick.json. Auth is supplied via the
                # CLAUDE_CODE_OAUTH_TOKEN env (from the LoadCredential tmpfs), so it is
                # unaffected by clearing these caches.
                for d in "$STATE/.cache" "$STATE/.config" "$STATE/.claude" \
                         "$STATE/.npm" "$STATE/.local" "$STATE/.anthropic"; do
                  ${cu}/rm -rf "$d"
                done

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
                # Sanitize to digits-only: a partial write / fs hiccup leaving
                # non-numeric content would otherwise crash the arithmetic under
                # set -e and wedge every subsequent tick until cleared by hand.
                COUNT=$(${cu}/cat "$CAPFILE" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -E '^[0-9]+$' || echo 0)
                if [ "$COUNT" -ge ${toString cfg.dailyCap} ]; then
                  echo "daily cap reached ($COUNT >= ${toString cfg.dailyCap}) — self-suppressing"
                  write_last_tick false "capped" "capped"
                  exit 0
                fi

                # ── 3. No-auth self-suppression: safe to merge+rebuild BEFORE the
                # one-time OAuth token file (services.sancta-heartbeat-tick.oauthTokenFile)
                # has been placed by hand. systemd delivers that file via LoadCredential=
                # into $CREDENTIALS_DIRECTORY/oauth-token (a private per-unit tmpfs). If
                # oauthTokenFile is unset the credential is absent; if the file is empty
                # the credential is empty — either way we self-suppress. The token value
                # is NEVER echoed.
                OAUTH_TOKEN_CRED="''${CREDENTIALS_DIRECTORY:-}/oauth-token"
                if [ ! -s "$OAUTH_TOKEN_CRED" ]; then
                  echo "no OAuth token credential present — self-suppressing (reason: no-auth)"
                  write_last_tick false "no-auth" "no-auth"
                  exit 0
                fi

                echo $((COUNT + 1)) > "$CAPFILE"

                # ── 4. The claude call. Verified seam (design doc §3, RESOLVED):
                #   * Auth comes from CLAUDE_CODE_OAUTH_TOKEN (the `claude setup-token`
                #     long-lived token), read from the LoadCredential tmpfs into the env
                #     ONLY — it is never logged or written to disk by this script. This
                #     is the headless-correct mechanism (survives OAuth reauth; no
                #     interactive login). NOTE: --bare would ignore this token; the tick
                #     deliberately does NOT use --bare.
                #   * CLAUDE_CONFIG_DIR still relocates config (isolated dot-dir + MCP
                #     strip) — the real ~/.claude is never consulted (ProtectHome stays
                #     ON). Auth no longer depends on a .credentials.json in that dir.
                #   * --strict-mcp-config strips ALL MCP tools, including account-level
                #     claude.ai connectors riding the OAuth account.
                #   * --tools is a TRUE built-in whitelist ("Specify the list of
                #     available tools from the built-in set") — it removes every other
                #     built-in (Bash/Edit/Write/WebFetch/WebSearch/Task/…) from the
                #     model's context, so the tick is read-and-report over the mirrored
                #     inbox only. This is a whitelist, not a denylist: it names what the
                #     tick CAN do, so it cannot break when a built-in is renamed —
                #     unlike --disallowedTools, whose "MultiEdit" entry became stale in
                #     Claude Code 2.1.x and made claude reject the ENTIRE run ("matches
                #     no known tool"), failing every tick. An unknown name in --tools is
                #     silently ignored; an unknown name in --disallowedTools is fatal.
                #     (Silent-ignore verified empirically against Claude Code 2.1.197 on
                #     2026-07-05, not a documented spec guarantee — but even if a future
                #     CLI made unknown --tools names fatal too, this list is exactly the
                #     three CANONICAL always-present read tools, so it has no name that
                #     can go stale the way a broad denylist did.)
                #   * --allowedTools "Read,Glob,Grep" additionally auto-approves those
                #     three (all no-permission read tools anyway) so the headless -p run
                #     never stalls on a permission prompt. All three names are stable.
                #   NOTE: --allowedTools is NOT a whitelist (it only skips permission
                #   prompts; other tools stay available) — the availability boundary is
                #   --tools. See code.claude.com/docs/en/tools-reference + cli-reference.
                export CLAUDE_CONFIG_DIR="$STATE/config"
                export HOME="$STATE"
                export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
                # Read the token from the LoadCredential tmpfs into the env ONLY (never
                # logged, never written to disk). The -s gate in §3 already proved the
                # file is non-empty; guard the read anyway so a transient read failure or
                # an all-whitespace file self-suppresses ("no-auth") cleanly instead of
                # exporting an empty/garbage token and hitting a guaranteed auth error.
                # $() strips the trailing newline `setup-token` / a stray Enter may add.
                OAUTH_TOKEN_VALUE="$(${cu}/cat "$OAUTH_TOKEN_CRED" 2>/dev/null || true)"
                if [ -z "''${OAUTH_TOKEN_VALUE//[[:space:]]/}" ]; then
                  echo "OAuth token credential unreadable/blank — self-suppressing (reason: no-auth)"
                  write_last_tick false "no-auth" "no-auth"
                  exit 0
                fi
                # Trim surrounding whitespace (stray spaces/newlines a hand-paste can add).
                # Deliberately NOT stripping INTERIOR whitespace: that would "repair" a
                # corrupt paste into a syntactically clean but wrong token — interior
                # junk must fail the charset gate below instead.
                OAUTH_TOKEN_VALUE="''${OAUTH_TOKEN_VALUE#"''${OAUTH_TOKEN_VALUE%%[![:space:]]*}"}"
                OAUTH_TOKEN_VALUE="''${OAUTH_TOKEN_VALUE%"''${OAUTH_TOKEN_VALUE##*[![:space:]]}"}"
                # Charset gate. A `claude setup-token` token (sk-ant-oat01-…) is plain
                # ASCII from [A-Za-z0-9_-] only. A terminal paste of the token can
                # capture TUI pane-border bytes (e.g. "│ │", U+2502 = e2 94 82)
                # MID-token; the whitespace-only check above passes such a token, and
                # the resulting corrupt Authorization header makes `claude -p` exit 1
                # with an EMPTY stderr (with --output-format json the real error goes
                # to stdout) — burning a daily-cap slot on a guaranteed failure every
                # tick. Reject any byte outside the token alphabet BEFORE spending the
                # invocation. LC_ALL=C keeps the bracket expression byte-safe (no
                # locale-dependent ranges); the token value itself is never echoed.
                if ${cu}/printf '%s' "$OAUTH_TOKEN_VALUE" \
                     | LC_ALL=C ${pkgs.gnugrep}/bin/grep -q '[^A-Za-z0-9_-]'; then
                  echo "OAuth token contains non-token characters — self-suppressing (reason: bad-token)"
                  write_last_tick false "bad-token" "bad-token"
                  exit 0
                fi
                export CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN_VALUE"

                # ── 4a. MECHANICAL trusted-context pre-compute (amendment 2). The
                # inbox/open/answered counts and the newest-open message are derived
                # HERE, deterministically, from the mirrored JSONL — NOT by the model
                # from untrusted inbox prose. A crafted inbox line therefore cannot fake
                # "0 open" or claim it is already answered: the model is told to trust
                # ONLY these numbers. The block is bounded and never fails the tick:
                # any parse error / missing file degrades to zero counts + null newest
                # (the model then falls back to the bare ACK).
                #
                # Rules (deterministic):
                #   inbox_count   = # of parseable JSON lines in comm-inbox.jsonl
                #   replies_count = # of parseable JSON lines in comm-replies.jsonl
                #   an inbox msg is ANSWERED iff some reply's ts is strictly greater than
                #     the msg's ts (ISO-8601 → epoch via fromdateiso8601; ties/unparseable
                #     ts count as NOT answered, the cautious direction);
                #   open          = inbox_count - answered;
                #   newest_open_message = .message of the newest-ts inbox line that is
                #     still open, truncated to 600 bytes (bounds a huge crafted line).
                # jq -R 'fromjson? // empty' silently drops non-JSON/garbage lines, so a
                # garbage inbox yields inbox_count 0 → newest_open_message null → bare ACK.
                INBOX_FILE="$INBOX/comm-inbox.jsonl"
                REPLIES_FILE="$INBOX/comm-replies.jsonl"
                [ -f "$INBOX_FILE" ] || INBOX_FILE=/dev/null
                [ -f "$REPLIES_FILE" ] || REPLIES_FILE=/dev/null
                TRUSTED_CONTEXT="$(
                  ${jqBin} -n \
                    --slurpfile inbox <(${jqBin} -R 'fromjson? // empty' "$INBOX_FILE") \
                    --slurpfile replies <(${jqBin} -R 'fromjson? // empty' "$REPLIES_FILE") '
                    # epoch of an ISO-8601 ts, or null if absent/unparseable
                    def epoch: (.ts // "") as $t
                      | try ($t | fromdateiso8601) catch null;
                    ($replies | map(epoch) | map(select(. != null))) as $rep_epochs
                    | ($inbox
                        | map(. + {e: epoch})
                        | map(.e as $me
                              | . + {answered:
                                  ($me != null and ($rep_epochs | any(. > $me)))})
                      ) as $msgs
                    | ($msgs | map(select(.answered)) | length) as $answered
                    | ($msgs | length) as $n
                    | ($msgs
                        | map(select(.answered | not))
                        | map(select(.e != null))
                        | sort_by(.e)
                        | last) as $newest_open
                    | {
                        inbox_count: $n,
                        replies_count: ($replies | length),
                        answered: $answered,
                        open: ($n - $answered),
                        newest_open_message:
                          ( ($newest_open.message // null)
                            | if type == "string" then .[0:600] else null end )
                      }'
                )" || TRUSTED_CONTEXT='{"inbox_count":0,"replies_count":0,"answered":0,"open":0,"newest_open_message":null}'
                # Non-secret, bounded — safe to log for the Witness closing check.
                echo "trusted-context: $TRUSTED_CONTEXT"

                # The prompt (static contract) + the mechanically-computed trusted block.
                # The model is instructed (in the prompt) to trust ONLY this block for
                # counts and the restatement source, never the raw inbox prose.
                PROMPT="$(${cu}/cat ${promptFile})
        TRUSTED-CONTEXT (computed mechanically OUTSIDE the model — authoritative):
        $TRUSTED_CONTEXT"

                RAW="$STAGING/raw-output.json"
                RC=0
                ${claudeCodePkg}/bin/claude \
                  -p "$PROMPT" \
                  --strict-mcp-config \
                  --tools "Read,Glob,Grep" \
                  --allowedTools "Read,Glob,Grep" \
                  --model "${cfg.model}" \
                  --max-turns ${toString cfg.maxTurns} \
                  --output-format json \
                  > "$RAW" 2> "$STAGING/stderr.log" || RC=$?

                if [ "$RC" -ne 0 ]; then
                  echo "claude exited non-zero ($RC); stderr tail:" >&2
                  ${cu}/tail -n 20 "$STAGING/stderr.log" >&2 || true
                  # With --output-format json the REAL error often lands on STDOUT
                  # inside the JSON envelope (.result / raw-output.json), leaving
                  # stderr EMPTY — the corrupt-token auth failure surfaced NOTHING in
                  # the journal this way. When stderr has nothing, also emit a
                  # REDACTED tail of the raw stdout: extract .result when the envelope
                  # parses (fall back to the raw bytes otherwise), scrub any
                  # token-shaped value FIRST so a token can never reach the journal,
                  # and byte-bound the tail. Makes the "error only on stdout" class
                  # visible on FIRST occurrence.
                  if [ ! -s "$STAGING/stderr.log" ] && [ -s "$RAW" ]; then
                    echo "stderr empty — redacted stdout tail:" >&2
                    { ${jqBin} -r '.result // .' "$RAW" 2>/dev/null || ${cu}/cat "$RAW"; } \
                      | ${gnused}/bin/sed 's/sk-ant-oat01-[A-Za-z0-9_-]*/sk-ant-oat01-<REDACTED>/g' \
                      | ${cu}/tail -c 2048 >&2 || true
                  fi
                  write_last_tick false "claude-exit-$RC" "claude-exit"
                  # HANDLED failure — exit 0 (like the other handled-fail paths below:
                  # output-too-large / bad-envelope / malformed-output). A non-zero
                  # claude exit is a recorded outcome, not a crash of THIS script:
                  # last-tick.json carries {ok:false, reason:claude-exit-$RC}, the
                  # promote unit mirrors that record into the index, and the journal
                  # keeps the loud stderr line. Exiting 0 keeps the two liveness signals
                  # honest without an OnFailure alert-storm on a PERSISTENT error (this
                  # exact stale-tool-name bug fired OnFailure every ~30 min):
                  #   * the tripwire trips on last-tick TIMESTAMP age — a tick that
                  #     stops running entirely still surfaces within staleAfterMinutes;
                  #   * a genuine tick CRASH (script bug, OOM, sandbox fault) still exits
                  #     non-zero here and DOES fire OnFailure, because it never reaches
                  #     this handled branch.
                  # The observable-failure guarantee is preserved via last-tick.ok +
                  # the journal; only the redundant per-tick unit-failure alert is
                  # dropped.
                  # KNOWN RESIDUAL GAP (accepted tradeoff): a PERSISTENT handled failure
                  # keeps writing a FRESH last-tick.ts with ok:false, so the tripwire —
                  # which fires on timestamp AGE, not on ok — stays green and no feed
                  # alert is raised. The failure is then visible ONLY in last-tick.ok +
                  # the journal, not pushed to the feed. This is deliberate (the storm we
                  # are killing), but it means "ticking but every tick fails" is a quiet
                  # state. Follow-up to close it: an ok:false-STREAK detector on the
                  # promote/tripwire side (alert once after N consecutive ok:false) —
                  # tracked as the quieter "persistently unhealthy" signal.
                  exit 0
                fi

                # ── 5. Staging + schema gate (first of two — promotion re-validates).
                # Size bound on the raw envelope, then extract .result, then require a
                # single JSON object {feed: string, reply: string|null} within bounds.
                SIZE=$(${cu}/stat -c %s "$RAW")
                if [ "$SIZE" -gt 262144 ]; then
                  echo "raw output too large ($SIZE bytes) — dropping" >&2
                  write_last_tick false "output-too-large" "output-too-large"
                  exit 0
                fi

                if ! ${jqBin} -e '.is_error != true and (.result | type == "string")' "$RAW" > /dev/null; then
                  echo "unexpected claude output envelope — dropping" >&2
                  write_last_tick false "bad-envelope" "bad-envelope"
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
                  # Quality tag (amendment 3): a staged non-null reply is a real
                  # REFLECTION; a null reply is the bare heartbeat ACK. This lets a
                  # simple check distinguish "ticking AND reflecting" from "ticking but
                  # every reply is the bare ack" — a stuck-but-green state that a green
                  # timestamp alone would hide. Seed of the deferred ok:false /
                  # low-value-streak detector (backlog sancta-tick-okfalse-streak-detector).
                  if [ "$(${jqBin} -r '.reply == null' "$STAGING/tick-output.json")" = "false" ]; then
                    QUALITY="reflected"
                  else
                    QUALITY="bare-ack"
                  fi
                  echo "tick OK ($QUALITY) — output staged for promotion"
                  write_last_tick true "" "$QUALITY"
                else
                  echo "model output failed schema check — dropped (kept in staging/result.txt for inspection)" >&2
                  write_last_tick false "malformed-output" "malformed-output"
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

    # Existence guard (matches promoteScript): with set -euo pipefail a missing
    # index dir would fail loudly on the append and obscure the real failure.
    if [ ! -d "$INDEX" ]; then
      echo "ERROR: index dir $INDEX missing — cannot write feed alert" >&2
      exit 1
    fi

    # Mirror whatever last-tick the tick managed to write before failing.
    if [ -f "$STATE/last-tick.json" ] \
       && ${jqBin} -e '(.ts | type == "string")' "$STATE/last-tick.json" > /dev/null; then
      ${cu}/cp "$STATE/last-tick.json" "$INDEX/last-tick.json.tmp"
      ${cu}/chmod 0644 "$INDEX/last-tick.json.tmp"
      ${cu}/mv "$INDEX/last-tick.json.tmp" "$INDEX/last-tick.json"
    fi

    # Byte cap on the shared feed (same cap promoteScript enforces): above it,
    # skip the append with a loud warning rather than growing it unbounded.
    FEED="$INDEX/feed.json"
    FSIZE=0
    if [ -f "$FEED" ]; then FSIZE=$(${cu}/stat -c %s "$FEED"); fi
    if [ "$FSIZE" -gt ${toString cfg.liveFileByteCap} ]; then
      echo "WARNING: $FEED is $FSIZE bytes (> ${toString cfg.liveFileByteCap} cap) — skipping alert append; rotate it (follow-up) to resume" >&2
    else
      ${jqBin} -cn --arg ts "$TS" \
        '{ts: $ts, source: "sancta-tick-alert", alert: "heartbeat-tick-unit-failed", hint: "journalctl -u sancta-heartbeat-tick"}' \
        >> "$FEED"
    fi
  '';

  # ── Tripwire: staleness detected by a DIFFERENT mechanism than the tick.
  # Cannot die green: a missing/unparseable last-tick.json is itself stale.
  tripwireScript = pkgs.writeShellScript "sancta-tick-tripwire" ''
    set -euo pipefail
    INDEX="${cfg.indexDir}"
    MARKER="${stateDir}/tripwire/last-alert"
    NOW=$(${cu}/date +%s)
    MAX_AGE=$((${toString cfg.staleAfterMinutes} * 60))

    # Existence guard (matches promoteScript): a missing index dir means the
    # last-tick record can't be read — fail loudly with a clear cause rather
    # than a set -euo pipefail abort on the append later.
    if [ ! -d "$INDEX" ]; then
      echo "ERROR: index dir $INDEX missing — cannot run tripwire" >&2
      exit 1
    fi

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
      # Byte cap on the shared feed (same cap promoteScript enforces): the
      # marker already rate-limits to one line per stale window, but honour the
      # cap for consistency so tripwire noise can't grow the feed unbounded.
      FEED="$INDEX/feed.json"
      FSIZE=0
      if [ -f "$FEED" ]; then FSIZE=$(${cu}/stat -c %s "$FEED"); fi
      if [ "$FSIZE" -gt ${toString cfg.liveFileByteCap} ]; then
        echo "WARNING: $FEED is $FSIZE bytes (> ${toString cfg.liveFileByteCap} cap) — skipping tripwire append; rotate it (follow-up) to resume" >&2
      else
        ${jqBin} -cn --arg ts "$(${cu}/date -Is)" --arg r "$stale_reason" \
          '{ts: $ts, source: "sancta-tick-tripwire", alert: "heartbeat-stale", reason: $r}' \
          >> "$FEED"
      fi
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

    oauthTokenFile = lib.mkOption {
      # str, NOT path: this is a RUNTIME path to a hand-placed file, so it must
      # stay a plain string. lib.types.path would coerce a Nix path literal
      # (e.g. ./token) into a world-readable /nix/store copy of the secret —
      # exactly what we must avoid. String means the path is referenced, never
      # the contents.
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/sancta-tick/oauth-token";
      description = ''
        Path to a chmod-600 file containing ONLY the long-lived OAuth token
        string minted by `claude setup-token` (no trailing structure — just the
        token). Placed by hand, owner-only, NOT in git and NOT in the nix store.

        When set, the file is delivered to the tick unit via systemd
        {option}`LoadCredential` (copied into the unit's private
        `$CREDENTIALS_DIRECTORY` tmpfs, readable only by the service) and
        exported as `CLAUDE_CODE_OAUTH_TOKEN` for the headless `claude -p` call.
        Residual exposure: once exported, the token is in the tick process
        environment (`/proc/<pid>/environ`, root-readable) for the lifetime of
        that `claude -p` call — inherent to the CLI's documented env-var auth
        (no fd-based alternative). The sandbox and the never-log/never-persist
        handling keep this to the minimum.

        When null (the default), no credential is loaded and the tick
        self-suppresses every run with last-tick reason "no-auth" — so merging
        and rebuilding BEFORE the token file exists is safe.
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
      # The tick is a read-and-report task (Read/Glob/Grep the mirrored inbox,
      # emit one JSON object) — it should finish in 1-3 turns. A low cap bounds
      # the blast radius of a prompt injection that tried to keep the agent
      # looping at billing cost. Raise only if a legitimate tick needs more.
      default = 4;
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
      # nature, and RestrictAddressFamilies + --strict-mcp-config + the
      # --tools read-only whitelist already bound egress meaningfully without
      # them (WebFetch/WebSearch are not in the whitelist, so not available).
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
      # nologin: this user is never meant to have an interactive session. With
      # OAuth-token auth there is no `claude login` step at all — auth arrives as
      # a file placed by hand + delivered via LoadCredential — so nothing ever
      # needs to run under this account interactively. nologin closes the
      # interactive-login path if the account ever gained a key.
      shell = "${pkgs.shadow}/bin/nologin";
    };
    users.groups.sancta-tick = { };

    # Index owner joins the tick's group (NOT vice versa) so the promotion
    # units can read staging. The tick gains nothing from this membership.
    users.users.${cfg.indexOwner}.extraGroups = [ "sancta-tick" ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 sancta-tick sancta-tick -"
      # Isolated CLAUDE_CONFIG_DIR (config + MCP strip) — owner-only. Auth no
      # longer lives here; it arrives via LoadCredential (CLAUDE_CODE_OAUTH_TOKEN).
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
      serviceConfig = helperHardening // {
        Type = "oneshot";
        User = cfg.indexOwner;
        ExecStart = syncScript;
        # Reads cfg.indexDir (under /home), writes only the sandbox inbox mirror.
        ReadWritePaths = [ "${stateDir}/inbox" ];
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
        # The inbox is DATA the tick only READS (mirrored by the sync unit);
        # keeping it read-only means a fully prompt-injected tick still cannot
        # rewrite last-tick-index.json to defeat the dedup guard. The tick only
        # ever WRITES its own config (credentials), staging (output), tripwire
        # marker, and last-tick.json / cap counters at the StateDir root.
        ReadWritePaths = [ stateDir ];
        ReadOnlyPaths = [ "${stateDir}/inbox" ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        # No capabilities are needed (unprivileged user, read-and-report);
        # dropping the whole bounding set + blocking namespace creation closes
        # user-namespace escalation vectors on top of NoNewPrivileges.
        CapabilityBoundingSet = "";
        RestrictNamespaces = true;
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
      } // lib.optionalAttrs (cfg.oauthTokenFile != null) {
        # Deliver the OAuth token securely: systemd copies the file into the
        # unit's private $CREDENTIALS_DIRECTORY tmpfs (readable only by this
        # service), never exposing the path contents to the sandbox filesystem
        # or the nix store. The tick reads it into CLAUDE_CODE_OAUTH_TOKEN.
        # When oauthTokenFile is null this key is absent → no credential → the
        # tick self-suppresses ("no-auth").
        #
        # LoadCredential= is enforced by systemd BEFORE ExecStart: a MISSING
        # source file fails the unit outright (the in-script self-suppress never
        # runs), so the "safe to rebuild before the token exists" property is
        # instead upheld by ConditionPathExists= in unitConfig below — an absent
        # file skips the unit as success, no onFailure alert storm.
        LoadCredential = "oauth-token:${cfg.oauthTokenFile}";
      } // lib.optionalAttrs cfg.egressPinning.enable {
        # Residual (b): IP-level egress bound. See egressPinning option docs
        # for the honest brittleness note.
        IPAddressDeny = "any";
        IPAddressAllow = cfg.egressPinning.allowedAddresses;
      };

      # Keep the "safe to rebuild BEFORE the token file is placed" guarantee even
      # with oauthTokenFile set: if the file is absent, ConditionPathExists=
      # makes systemd SKIP the unit (recorded as a success — no onFailure, so no
      # alert storm), rather than LoadCredential= failing the unit every tick.
      # Once the file exists the condition passes and LoadCredential delivers it.
      # (unitConfig → [Unit] section; conditions do NOT belong in serviceConfig.)
      unitConfig = lib.mkIf (cfg.oauthTokenFile != null) {
        ConditionPathExists = cfg.oauthTokenFile;
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
      serviceConfig = helperHardening // {
        Type = "oneshot";
        User = cfg.indexOwner;
        ExecStart = promoteScript;
        # Reads staging (under StateDir), writes the live index + last-tick mirror.
        ReadWritePaths = [ cfg.indexDir stateDir ];
      };
    };

    systemd.services.sancta-tick-alert = {
      description = "Surface a failed heartbeat tick into the feed (OnFailure hook)";
      serviceConfig = helperHardening // {
        Type = "oneshot";
        User = cfg.indexOwner;
        ExecStart = alertScript;
        # Reads StateDir last-tick, writes the live index (alert line + mirror).
        ReadWritePaths = [ cfg.indexDir stateDir ];
      };
    };

    # ── Liveness tripwire: separate mechanism, cannot die green ─────────────
    systemd.services.sancta-tick-tripwire = {
      description = "Sancta heartbeat liveness tripwire (alerts on stale last-tick)";
      serviceConfig = helperHardening // {
        Type = "oneshot";
        User = cfg.indexOwner;
        ExecStart = tripwireScript;
        # Reads the live index last-tick, writes the tripwire marker + a feed
        # alert line into the index.
        ReadWritePaths = [ cfg.indexDir "${stateDir}/tripwire" ];
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
