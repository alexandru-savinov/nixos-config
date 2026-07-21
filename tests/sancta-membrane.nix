{ pkgs }:

let
  relay = ../hosts/sancta-choir/membrane/relay.mjs;
  server = ../hosts/sancta-choir/membrane/comm/server.mjs;
  membrane = ../hosts/sancta-choir/membrane/bin/comm-membrane;

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
    HOME="$guard_home" node ${membrane} "hello" >/dev/null
    if HOME="$guard_home" node ${membrane} "sk-dummy-credential-value" >/dev/null; then
      echo "membrane accepted a credential-shaped message" >&2
      exit 1
    fi

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
    printf '%s\n' '{"reason":"old"}' > "$success/failure"
    set +e
    timeout 2s env \
      SANCTA_INBOX="$success/inbox" \
      SANCTA_REPLIES="$success/replies" \
      SANCTA_CURSOR="$success/cursor" \
      SANCTA_FAILURE="$success/failure" \
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
      if (reply.inbox_ts !== "success-ts" || fs.existsSync(dir + "/failure")) process.exit(1);
    ' "$success"

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
