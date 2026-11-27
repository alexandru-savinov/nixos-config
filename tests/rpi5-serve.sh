#!/usr/bin/env bash
set -euo pipefail

script=${1:-$(dirname "$0")/../hosts/rpi5-full/rpi5-serve.sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export TS="$tmp/tailscale" CALLS="$tmp/calls" STATUS="$tmp/status.json"
export ALLOWED_PORTS='[3001,5678,8123]' ALLOWED_SERVICES='[]'
export WAIT=3 POLL_SLEEP=0 RETRY_SLEEP=0

cat > "$TS" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  'status --json --peers=false')
    case "${BACKEND:-Running}" in
      delayed)
        if [[ -f "$STATUS.polled" ]]; then echo '{"BackendState":"Running"}'
        else touch "$STATUS.polled"; echo '{"BackendState":"Starting"}'; fi
        ;;
      *) jq -nc --arg state "${BACKEND:-Running}" '{BackendState: $state}' ;;
    esac
    ;;
  'serve status --json') cat "$STATUS" ;;
  'serve --https='*' off')
    port=${2#--https=}
    [[ "${FAIL_PORT:-}" != "$port" ]] || exit 1
    if [[ "${RETRY_PORT:-}" == "$port" && ! -f "$STATUS.retried" ]]; then
      touch "$STATUS.retried"
      exit 1
    fi
    jq -e --arg port "$port" '.TCP | has($port)' "$STATUS" >/dev/null
    jq --arg port "$port" 'del(.TCP[$port], .Web["rpi5.example:" + $port])' "$STATUS" > "$STATUS.next"
    mv "$STATUS.next" "$STATUS"
    ;;
  *) echo "unexpected tailscale command: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$TS"

fixture() {
  jq -n --args '
    $ARGS.positional as $ports
    | {TCP: (reduce $ports[] as $port ({}; .[$port] = {HTTPS: true})),
       Web: (reduce $ports[] as $port ({}; .["rpi5.example:" + $port] =
               {Handlers: {"/": {Proxy: ("http://127.0.0.1:" + $port)}}}))}
  ' "$@"
}

run() {
  local expected=$1 mode=$2 message=$3 status=0
  : > "$CALLS"
  bash "$script" "$mode" > "$tmp/output" 2>&1 || status=$?
  if [[ "$status" != "$expected" ]] || { [[ -n "$message" ]] && ! grep -Fq "$message" "$tmp/output"; }; then
    cat "$tmp/output" >&2
    echo "FAIL: $mode exited $status, expected $expected and '$message'" >&2
    exit 1
  fi
}

assert_writes() {
  # Compare every non-read command, so this also catches an attempted reset.
  local port
  for port in "$@"; do printf 'serve --https=%s off\n' "$port"; done > "$tmp/expected"
  awk '$0 != "status --json --peers=false" && $0 != "serve status --json"' "$CALLS" > "$tmp/writes"
  diff -u "$tmp/expected" "$tmp/writes"
}

live=(3001 5678 8123)
dead=(6333 8739 8742 8743 8744)
keep=' .Services["svc:other"] = {TCP: {"6333": {HTTPS: true}}}
      | .Foreground.fixture = {TCP: {"8744": {HTTP: true}}}'
fixture "${live[@]}" "${dead[@]}" | jq "$keep" > "$tmp/full"
fixture "${live[@]}" | jq "$keep" > "$tmp/kept"
cp "$tmp/full" "$STATUS"

BACKEND=delayed run 0 tidy 'removed node HTTPS port 8744'
assert_writes "${dead[@]}"
head -n 2 "$CALLS" | diff -u - <(printf '%s\n' 'status --json --peers=false' 'status --json --peers=false')
diff -u "$tmp/kept" "$STATUS"
echo 'PASS tidy waits for Running and removes exactly five node ports (exit 0)'

run 0 tidy ''
assert_writes
diff -u "$tmp/kept" "$STATUS"
echo 'PASS tidy rerun is idempotent (exit 0)'

cp "$tmp/full" "$STATUS"
RETRY_PORT=6333 run 0 tidy 'removed node HTTPS port 6333'
assert_writes 6333 "${dead[@]}"
diff -u "$tmp/kept" "$STATUS"
echo 'PASS tidy retries a transient write failure (exit 0)'

cp "$tmp/full" "$STATUS"
FAIL_PORT=6333 run 1 tidy 'could not clear node HTTPS port 6333 after 3 attempts'
assert_writes 6333 6333 "${dead[@]}"
fixture "${live[@]}" 6333 | jq -S "$keep" | diff -u - <(jq -S . "$STATUS")
echo 'PASS tidy caps retries and still clears the other ports (exit 1)'

BACKEND=Starting run 1 tidy 'tailscaled did not reach Running'
printf '%s\n' 'status --json --peers=false'{,,} | diff -u - "$CALLS"
echo 'PASS tidy makes no Serve calls before Running (exit 1)'

check_allowlist() {
  run "$1" allowlist "$2"
  printf '%s\n' 'serve status --json' | diff -u - "$CALLS"
  echo "PASS allowlist $3 (exit $1)"
}

fixture "${live[@]}" > "$STATUS"
check_allowlist 0 'allowlist: ok' 'accepts the three approved ports'
echo 'null' > "$STATUS"
check_allowlist 0 'allowlist: ok' 'accepts empty Serve config'
fixture "${live[@]}" 9443 | jq 'del(.Web["rpi5.example:9443"])' > "$STATUS"
check_allowlist 1 'unexpected node port 9443' 'rejects an extra TCP port'
fixture "${live[@]}" 9443 | jq 'del(.TCP["9443"])' > "$STATUS"
check_allowlist 1 'unexpected node port 9443' 'rejects an extra Web port'
echo '{"Foreground":{"fixture":{"TCP":{"9443":{"HTTPS":true}}}}}' > "$STATUS"
check_allowlist 1 'unexpected node port 9443' 'rejects an extra foreground port'
echo '{"Services":{"svc:nixframe":{"TCP":{"443":{"HTTPS":true}}}}}' > "$STATUS"
check_allowlist 1 'unexpected Service svc:nixframe' 'rejects an undeclared Service'
ALLOWED_SERVICES='["svc:nixframe"]' check_allowlist 0 'allowlist: ok' 'accepts declared Service with its own port'
rm "$STATUS"
check_allowlist 1 'cannot read Serve status' 'fails on unreadable status'
echo '{"TCP":false}' > "$STATUS"
check_allowlist 1 'invalid Serve status JSON' 'fails on an invalid status object'
: > "$STATUS"
check_allowlist 1 'invalid Serve status JSON' 'fails on empty command output'
