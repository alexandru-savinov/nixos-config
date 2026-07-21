{ pkgs }:

let
  relay = ../hosts/sancta-choir/membrane/relay.mjs;
  server = ../hosts/sancta-choir/membrane/comm/server.mjs;
  membrane = ../hosts/sancta-choir/membrane/bin/comm-membrane;
  authLogin = "owner@example.com";
  authHash = builtins.hashString "sha256" authLogin;
  authPassword = "test-membrane-password-0123456789abcdef";

  fakeSuccess = pkgs.writeShellScript "sancta-fake-success" ''
    ${pkgs.coreutils}/bin/cat >/dev/null
    ${pkgs.coreutils}/bin/printf '%s\n' \
      '{"type":"result","result":"live test reply"}'
  '';

  fakeFailure = pkgs.writeShellScript "sancta-fake-failure" ''
    ${pkgs.coreutils}/bin/cat >/dev/null
    exit 7
  '';
in
pkgs.runCommand "sancta-membrane-tests"
{
  nativeBuildInputs = [
    pkgs.coreutils
    pkgs.nodejs_22
  ];
}
  ''
        set -euo pipefail

        node --check ${relay}
        node --check ${server}
        node --check ${membrane}

        guard_home="$TMPDIR/guard-home"
        mkdir -p "$guard_home/.claude/index"
        printf '%s' "hello" | HOME="$guard_home" node ${membrane} >/dev/null
        if printf '%s' "sk-dummy-credential-value" | HOME="$guard_home" node ${membrane} >/dev/null; then
          echo "membrane accepted a credential-shaped message" >&2
          exit 1
        fi
        set +e
        printf '%s' "AKIAABCDEFGHIJKLMNOP" | HOME="$guard_home" node ${membrane} >/dev/null
        aws_status=$?
        printf '%s' "aB3dE5fG7hJ9kLmNpQrStUvWxYzAbCdEfGhIjKl" | HOME="$guard_home" node ${membrane} >/dev/null
        opaque_status=$?
        printf '%s' "Send 500 to Ion for rent" | HOME="$guard_home" node ${membrane} >/dev/null
        money_status=$?
        printf '%s' "buy the tickets now" | HOME="$guard_home" node ${membrane} >/dev/null
        purchase_status=$?
        printf '%s' "wipe the cache" | HOME="$guard_home" node ${membrane} >/dev/null
        irreversible_status=$?
        set -e
        test "$aws_status" -eq 1
        test "$opaque_status" -eq 2
        test "$money_status" -eq 2
        test "$purchase_status" -eq 2
        test "$irreversible_status" -eq 2
        for message in \
          "erase the disk" \
          "remove the account" \
          "kill the service" \
          "nuke the database" \
          "format the volume"; do
          set +e
          printf '%s' "$message" | HOME="$guard_home" node ${membrane} >/dev/null
          synonym_status=$?
          set -e
          test "$synonym_status" -eq 2
        done

        gateway="$TMPDIR/gateway"
        mkdir -p "$gateway"
        ready="$gateway/ready"
        failure_marker="$gateway/failure"
        mkdir -p "$gateway/credentials"
        printf '%s\n' '${authPassword}' > "$gateway/credentials/membrane-auth"
        chmod 0600 "$gateway/credentials/membrane-auth"
        printf '%s\n' null > "$gateway/comm-heartbeat.json"
        printf '%s\n' '{"offset":0}' > "$gateway/cursor"
        HOME="$guard_home" \
          BIND=127.0.0.1 \
          PORT=18743 \
          SANCTA_INDEX_DIR="$gateway" \
          SANCTA_WORKER_READY="$ready" \
          SANCTA_FAILURE="$failure_marker" \
          SANCTA_CURSOR="$gateway/cursor" \
          SANCTA_RATE_LIMIT_FILE="$gateway/rate-limit" \
          SANCTA_ALLOWED_LOGIN_SHA256=${authHash} \
          SANCTA_RATE_LIMIT_MAX=1 \
          SANCTA_RATE_LIMIT_WINDOW_MS=3600000 \
          SANCTA_MAX_PENDING_PROCEED=1 \
          CREDENTIALS_DIRECTORY="$gateway/credentials" \
          SANCTA_MEMBRANE_PATH=${membrane} \
          node ${server} > "$gateway/server.log" 2>&1 &
        server_pid=$!
        trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT
        for _ in $(seq 1 50); do
          if node -e 'const basic = Buffer.from("alexandru:${authPassword}").toString("base64"); fetch("http://127.0.0.1:18743/heartbeat", { headers: { "Tailscale-User-Login": "${authLogin}", Authorization: "Basic " + basic } }).then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))'; then
            break
          fi
          sleep 0.1
        done

        node - <<'NODE'
        (async () => {
          const url = "http://127.0.0.1:18743";
          const basic = Buffer.from("alexandru:test-membrane-password-0123456789abcdef").toString("base64");
          const auth = {
            "Tailscale-User-Login": "owner@example.com",
            Authorization: "Basic " + basic,
            "X-Sancta-Request": "send",
          };
          let response = await fetch(url + "/heartbeat");
          if (response.status !== 403) process.exit(1);
          response = await fetch(url + "/heartbeat", {
            headers: { ...auth, "Tailscale-User-Login": "intruder@example.com" },
          });
          if (response.status !== 403) process.exit(1);
          response = await fetch(url + "/heartbeat", {
            headers: { "Tailscale-User-Login": "owner@example.com" },
          });
          if (response.status !== 401 || !response.headers.get("www-authenticate")) process.exit(1);

          response = await fetch(url + "/send", {
            method: "POST",
            headers: {
              "Tailscale-User-Login": "owner@example.com",
              Authorization: "Basic " + basic,
              "content-type": "text/plain",
            },
            body: JSON.stringify({ message: "hello" }),
          });
          if (response.status !== 403) process.exit(1);

          response = await fetch(url + "/send", {
            method: "POST",
            headers: { ...auth, "content-type": "application/json" },
            body: JSON.stringify({ message: "hello" }),
          });
          let body = await response.json();
          if (response.status !== 503 || body.worker?.status !== "stopped") process.exit(1);

          response = await fetch(url + "/heartbeat", { headers: auth });
          body = await response.json();
          if (!response.ok || body.error !== "invalid heartbeat file") process.exit(1);
          if (body.worker?.status !== "stopped") process.exit(1);
        })().catch(error => { console.error(error); process.exit(1); });
    NODE

        touch "$ready"
        node - <<'NODE'
        (async () => {
          const basic = Buffer.from("alexandru:test-membrane-password-0123456789abcdef").toString("base64");
          const auth = {
            "Tailscale-User-Login": "owner@example.com",
            Authorization: "Basic " + basic,
            "X-Sancta-Request": "send",
          };
          const response = await fetch("http://127.0.0.1:18743/send", {
            method: "POST",
            headers: { ...auth, "content-type": "application/json" },
            body: JSON.stringify({ message: "hello" }),
          });
          const body = await response.json();
          if (!response.ok || body.decision !== "proceed") process.exit(1);

          const queued = await fetch("http://127.0.0.1:18743/send", {
            method: "POST",
            headers: { ...auth, "content-type": "application/json" },
            body: JSON.stringify({ message: "hello" }),
          });
          const queuedBody = await queued.json();
          if (queued.status !== 429 || queuedBody.error !== "worker queue full") process.exit(1);
        })().catch(error => { console.error(error); process.exit(1); });
    NODE

        node -e '
          const fs = require("fs");
          const dir = process.argv[1];
          const size = fs.statSync(dir + "/comm-inbox.jsonl").size;
          fs.writeFileSync(dir + "/cursor", JSON.stringify({ offset: size }) + "\n");
          const rate = fs.readFileSync(dir + "/rate-limit", "utf8");
          if (rate.includes("owner@example.com")) process.exit(1);
          if ((fs.statSync(dir + "/rate-limit").mode & 0o777) !== 0o600) process.exit(1);
        ' "$gateway"
        node - <<'NODE'
        (async () => {
          const response = await fetch("http://127.0.0.1:18743/send", {
            method: "POST",
            headers: {
              "Tailscale-User-Login": "owner@example.com",
              Authorization: "Basic " + Buffer.from("alexandru:test-membrane-password-0123456789abcdef").toString("base64"),
              "X-Sancta-Request": "send",
              "content-type": "application/json",
            },
            body: JSON.stringify({ message: "hello" }),
          });
          const body = await response.json();
          if (response.status !== 429 || body.error !== "rate limit exceeded") process.exit(1);
          if (!response.headers.get("retry-after")) process.exit(1);
        })().catch(error => { console.error(error); process.exit(1); });
    NODE

        printf '%s\n' '{"version":1,"identities":[]}' > "$gateway/rate-limit"
        node - <<'NODE'
        (async () => {
          const response = await fetch("http://127.0.0.1:18743/send", {
            method: "POST",
            headers: {
              "Tailscale-User-Login": "owner@example.com",
              Authorization: "Basic " + Buffer.from("alexandru:test-membrane-password-0123456789abcdef").toString("base64"),
              "X-Sancta-Request": "send",
              "content-type": "application/json",
            },
            body: JSON.stringify({ message: "hello" }),
          });
          const body = await response.json();
          if (response.status !== 503 || body.error !== "rate limiter unavailable") process.exit(1);
        })().catch(error => { console.error(error); process.exit(1); });
    NODE

        printf '%s\n' '{"ts":"failure-ts","inbox_ts":"inbox-ts","offset":0,"reason":"Claude exited 7","raw":"must not leak"}' > "$failure_marker"
        node - <<'NODE'
        (async () => {
          const url = "http://127.0.0.1:18743";
          const basic = Buffer.from("alexandru:test-membrane-password-0123456789abcdef").toString("base64");
          const auth = {
            "Tailscale-User-Login": "owner@example.com",
            Authorization: "Basic " + basic,
            "X-Sancta-Request": "send",
          };
          let response = await fetch(url + "/heartbeat", { headers: auth });
          let body = await response.json();
          if (!response.ok || body.worker?.status !== "failed") process.exit(1);
          if (body.worker.failure.reason !== "Claude exited 7" || "raw" in body.worker.failure) process.exit(1);

          response = await fetch(url + "/send", {
            method: "POST",
            headers: { ...auth, "content-type": "application/json" },
            body: JSON.stringify({ message: "hello again" }),
          });
          body = await response.json();
          if (response.status !== 503 || body.worker?.status !== "failed") process.exit(1);
        })().catch(error => { console.error(error); process.exit(1); });
    NODE

        kill "$server_pid"
        wait "$server_pid" || true
        trap - EXIT

        failure="$TMPDIR/failure"
        mkdir -p "$failure"
        printf '%s\n' '{"ts":"failure-ts","decision":"proceed","message":"test"}' > "$failure/inbox"
        printf '%s\n' '{"offset":0}' > "$failure/cursor"
        if env \
          SANCTA_INBOX="$failure/inbox" \
          SANCTA_REPLIES="$failure/replies" \
          SANCTA_CURSOR="$failure/cursor" \
          SANCTA_FAILURE="$failure/failure" \
          SANCTA_PROJECT_DIR="$TMPDIR" \
          CLAUDE_BIN=${fakeFailure} \
          CLAUDE_ARGS_JSON='[]' \
          node ${relay}; then
          echo "relay unexpectedly succeeded after a failed turn" >&2
          exit 1
        fi
        node -e '
          const fs = require("fs");
          const dir = process.argv[1];
          const cursor = JSON.parse(fs.readFileSync(dir + "/cursor", "utf8"));
          const failure = JSON.parse(fs.readFileSync(dir + "/failure", "utf8"));
          if (cursor.offset !== 0 || failure.offset !== 0) process.exit(1);
          if (failure.inbox_ts !== "failure-ts" || failure.reason !== "Claude exited 7") process.exit(1);
          if (fs.existsSync(dir + "/replies")) process.exit(1);
        ' "$failure"

        success="$TMPDIR/success"
        mkdir -p "$success"
        printf '%s\n' '{"ts":"success-ts","decision":"proceed","message":"test"}' > "$success/inbox"
        printf '%s\n' '{"offset":0}' > "$success/cursor"
        set +e
        timeout 2s env \
          SANCTA_INBOX="$success/inbox" \
          SANCTA_REPLIES="$success/replies" \
          SANCTA_CURSOR="$success/cursor" \
          SANCTA_FAILURE="$success/failure" \
          SANCTA_WORKER_READY="$success/ready" \
          SANCTA_PROJECT_DIR="$TMPDIR" \
          CLAUDE_BIN=${fakeSuccess} \
          CLAUDE_ARGS_JSON='[]' \
          node ${relay}
        success_status=$?
        set -e
        test "$success_status" -eq 124
        node -e '
          const fs = require("fs");
          const dir = process.argv[1];
          const size = fs.statSync(dir + "/inbox").size;
          const cursor = JSON.parse(fs.readFileSync(dir + "/cursor", "utf8"));
          const reply = JSON.parse(fs.readFileSync(dir + "/replies", "utf8").trim());
          if (cursor.offset !== size || reply.text !== "live test reply") process.exit(1);
          if (reply.inbox_offset !== 0 || reply.inbox_next_offset !== size) process.exit(1);
          if (!/^[a-f0-9]{64}$/.test(reply.inbox_hash)) process.exit(1);
          if (typeof reply.inbox_checkpoint !== "string") process.exit(1);
          if (reply.inbox_ts !== "success-ts" || fs.existsSync(dir + "/failure")) process.exit(1);
          if ((fs.statSync(dir + "/ready").mode & 0o777) !== 0o600) process.exit(1);
        ' "$success"

        replay="$TMPDIR/replay"
        mkdir -p "$replay"
        printf '%s\n' '{"ts":"replay-ts","decision":"proceed","message":"test"}' > "$replay/inbox"
        printf '%s\n' '{"offset":0}' > "$replay/cursor"
        printf '%s\n' '{"offset":0,"inbox_ts":"replay-ts","reason":"interrupted after reply commit"}' > "$replay/failure"
        node -e '
          const crypto = require("crypto");
          const fs = require("fs");
          const dir = process.argv[1];
          const line = fs.readFileSync(dir + "/inbox", "utf8").trimEnd();
          const hash = crypto.createHash("sha256").update(line, "utf8").digest("hex");
          const reply = {
            ts: "reply-ts",
            source: "sancta-worker",
            inbox_ts: "replay-ts",
            inbox_offset: 0,
            inbox_next_offset: Buffer.byteLength(line + "\n"),
            inbox_hash: hash,
            inbox_checkpoint: `0:replay-ts:''${hash}`,
            text: "already committed",
          };
          fs.writeFileSync(dir + "/replies", JSON.stringify(reply) + "\n");
        ' "$replay"
        set +e
        timeout 1s env \
          SANCTA_INBOX="$replay/inbox" \
          SANCTA_REPLIES="$replay/replies" \
          SANCTA_CURSOR="$replay/cursor" \
          SANCTA_FAILURE="$replay/failure" \
          SANCTA_WORKER_READY="$replay/ready" \
          SANCTA_PROJECT_DIR="$TMPDIR" \
          CLAUDE_BIN=${fakeFailure} \
          CLAUDE_ARGS_JSON='[]' \
          node ${relay}
        replay_status=$?
        set -e
        test "$replay_status" -eq 124
        node -e '
          const fs = require("fs");
          const dir = process.argv[1];
          const size = fs.statSync(dir + "/inbox").size;
          const cursor = JSON.parse(fs.readFileSync(dir + "/cursor", "utf8"));
          const replies = fs.readFileSync(dir + "/replies", "utf8").trim().split("\n");
          if (cursor.offset !== size || replies.length !== 1) process.exit(1);
          if (fs.existsSync(dir + "/failure")) process.exit(1);
        ' "$replay"

        commit_failure="$TMPDIR/commit-failure"
        mkdir -p "$commit_failure"
        printf '%s\n' '{"ts":"commit-failure-ts","decision":"proceed","message":"test"}' > "$commit_failure/inbox"
        printf '%s\n' '{"offset":0}' > "$commit_failure/cursor"
        set +e
        env \
          SANCTA_INBOX="$commit_failure/inbox" \
          SANCTA_REPLIES="$commit_failure/missing/replies" \
          SANCTA_CURSOR="$commit_failure/cursor" \
          SANCTA_FAILURE="$commit_failure/failure" \
          SANCTA_WORKER_READY="$commit_failure/ready" \
          SANCTA_PROJECT_DIR="$TMPDIR" \
          CLAUDE_BIN=${fakeSuccess} \
          CLAUDE_ARGS_JSON='[]' \
          node ${relay} >/dev/null 2>&1
        first_commit_status=$?
        set -e
        test "$first_commit_status" -ne 0
        node -e '
          const fs = require("fs");
          const dir = process.argv[1];
          const cursor = JSON.parse(fs.readFileSync(dir + "/cursor", "utf8"));
          const failure = JSON.parse(fs.readFileSync(dir + "/failure", "utf8"));
          if (cursor.offset !== 0 || failure.offset !== 0) process.exit(1);
          if (failure.reason !== "reply commit failed after Claude success") process.exit(1);
        ' "$commit_failure"
        set +e
        env \
          SANCTA_INBOX="$commit_failure/inbox" \
          SANCTA_REPLIES="$commit_failure/missing/replies" \
          SANCTA_CURSOR="$commit_failure/cursor" \
          SANCTA_FAILURE="$commit_failure/failure" \
          SANCTA_WORKER_READY="$commit_failure/ready" \
          SANCTA_PROJECT_DIR="$TMPDIR" \
          CLAUDE_BIN=${fakeFailure} \
          CLAUDE_ARGS_JSON='[]' \
          node ${relay} >/dev/null 2>&1
        retry_commit_status=$?
        set -e
        test "$retry_commit_status" -ne 0
        node -e '
          const fs = require("fs");
          const dir = process.argv[1];
          const cursor = JSON.parse(fs.readFileSync(dir + "/cursor", "utf8"));
          const failure = JSON.parse(fs.readFileSync(dir + "/failure", "utf8"));
          if (cursor.offset !== 0 || failure.reason !== "reply commit failed after Claude success") process.exit(1);
        ' "$commit_failure"

        shrink="$TMPDIR/shrink"
        mkdir -p "$shrink"
        printf '%s\n' '{"ts":"old-ts","decision":"proceed","message":"historical"}' > "$shrink/inbox"
        printf '%s\n' '{"offset":9999}' > "$shrink/cursor"
        set +e
        timeout 1s env \
          SANCTA_INBOX="$shrink/inbox" \
          SANCTA_REPLIES="$shrink/replies" \
          SANCTA_CURSOR="$shrink/cursor" \
          SANCTA_FAILURE="$shrink/failure" \
          SANCTA_PROJECT_DIR="$TMPDIR" \
          CLAUDE_BIN=${fakeFailure} \
          CLAUDE_ARGS_JSON='[]' \
          node ${relay}
        shrink_status=$?
        set -e
        test "$shrink_status" -eq 124
        node -e '
          const fs = require("fs");
          const dir = process.argv[1];
          const size = fs.statSync(dir + "/inbox").size;
          const cursor = JSON.parse(fs.readFileSync(dir + "/cursor", "utf8"));
          if (cursor.offset !== size) process.exit(1);
          if (fs.existsSync(dir + "/failure") || fs.existsSync(dir + "/replies")) process.exit(1);
        ' "$shrink"

        touch "$out"
  ''
