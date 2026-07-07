# Regression guard for the Sancta heartbeat membrane reflection (#519).
#
# Runs the SAME committed jq program the tick uses
# (modules/services/sancta-heartbeat-trusted-context.jq) against
# REAL-format fixtures — inbox/reply timestamps with fractional seconds
# (…NNN Z), exactly what new Date().toISOString() emits. Before the fix,
# jq's fromdateiso8601 rejected the fractional form, so every message was
# unparseable → answered=0, open=inbox_count, newest_open_message=null and
# the Tier-1 reflection could never fire. This asserts the parsed result so
# the module and the guard can never drift (both read the one .jq file).
{ pkgs }:
pkgs.runCommand "heartbeat-trusted-context"
{
  nativeBuildInputs = [ pkgs.jq pkgs.bash ];
  trustedContextJq = ../modules/services/sancta-heartbeat-trusted-context.jq;
}
  ''
    export SHELL=${pkgs.bash}/bin/bash
    ${pkgs.bash}/bin/bash -euo pipefail <<'EOF'
    cat > inbox.jsonl <<'JSON'
    {"ts":"2026-07-07T10:00:00.123Z","message":"old, answered"}
    {"ts":"2026-07-07T12:30:45.784Z","message":"FRESH OPEN, no reply"}
    JSON
    cat > replies.jsonl <<'JSON'
    {"ts":"2026-07-07T11:00:00.500Z","from":"sancta","text":"reply to first"}
    JSON

    OUT="$(
      jq -n \
        --slurpfile inbox <(jq -R 'fromjson? // empty' inbox.jsonl) \
        --slurpfile replies <(jq -R 'fromjson? // empty' replies.jsonl) \
        -f "$trustedContextJq"
    )"
    echo "trusted-context output:"
    echo "$OUT"

    check() {
      local expr="$1" want="$2"
      local got
      got="$(printf '%s' "$OUT" | jq -r "$expr")"
      if [ "$got" != "$want" ]; then
        echo "ASSERTION FAILED: $expr => '$got' (expected '$want')" >&2
        exit 1
      fi
      echo "OK: $expr == $want"
    }

    check '.inbox_count'         '2'
    check '.replies_count'       '1'
    check '.answered'            '1'
    check '.open'                '1'
    check '.newest_open_message' 'FRESH OPEN, no reply'
    EOF
    touch $out
  ''
