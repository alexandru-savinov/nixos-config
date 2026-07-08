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

    # ── Offset-timestamp case (membrane-ts-offset-fix, the never-close loop) ──
    # Exact live failure: his messages are `.NNN Z` (JS toISOString), but the
    # tick's OWN reply lines were written with `date -Is` → a LOCAL offset
    # (+HH:MM). jq's fromdateiso8601 rejects offsets, so those replies never
    # parsed, never counted as answered, and the tick re-reflected the same
    # newest-open message every 30 min forever. This pins BOTH the parser
    # tolerance (offset → correct instant) AND the producer contract: an
    # offset-carrying reply that is LATER than an inbox message must answer it.
    cat > inbox2.jsonl <<'JSON'
    {"ts":"2026-07-07T15:00:00.100Z","message":"asked at 15:00Z, answered by an offset reply"}
    {"ts":"2026-07-07T16:00:00.200Z","message":"asked at 16:00Z, still open"}
    JSON
    # +03:00 wall-clock 18:01:42 == 15:01:42Z (after msg 1 @15:00Z, before msg 2 @16:00Z).
    cat > replies2.jsonl <<'JSON'
    {"ts":"2026-07-07T18:01:42+03:00","from":"sancta-tick","text":"offset reply, 15:01:42Z"}
    JSON

    OUT2="$(
      jq -n \
        --slurpfile inbox <(jq -R 'fromjson? // empty' inbox2.jsonl) \
        --slurpfile replies <(jq -R 'fromjson? // empty' replies2.jsonl) \
        -f "$trustedContextJq"
    )"
    echo "trusted-context output (offset case):"
    echo "$OUT2"

    check2() {
      local expr="$1" want="$2"
      local got
      got="$(printf '%s' "$OUT2" | jq -r "$expr")"
      if [ "$got" != "$want" ]; then
        echo "ASSERTION FAILED (offset): $expr => '$got' (expected '$want')" >&2
        exit 1
      fi
      echo "OK (offset): $expr == $want"
    }

    # The +03:00 reply (15:01:42Z) is later than msg 1 (15:00:00Z) → answered;
    # msg 2 (16:00:00Z) is later than the reply → still open and newest.
    check2 '.inbox_count'         '2'
    check2 '.replies_count'       '1'
    check2 '.answered'            '1'
    check2 '.open'                '1'
    check2 '.newest_open_message' 'asked at 16:00Z, still open'
    EOF
    touch $out
  ''
