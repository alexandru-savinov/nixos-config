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
        if [[ -f "$STATUS.polled" ]]; then echo '{"BackendState":"Running","Self":{"DNSName":"rpi5.example."}}'
        else touch "$STATUS.polled"; echo '{"BackendState":"Starting"}'; fi
        ;;
      *) jq -nc --arg state "${BACKEND:-Running}" '{BackendState: $state, Self: {DNSName: "rpi5.example."}}' ;;
    esac
    ;;
  'serve status --json') cat "$STATUS" ;;
  'serve --https='*' off'|'serve --http='*' off'|'serve --tcp='*' off')
    port=${2#*=}
    [[ "${FAIL_PORT:-}" != "$port" ]] || exit 1
    if [[ "${RETRY_PORT:-}" == "$port" && ! -f "$STATUS.retried" ]]; then
      touch "$STATUS.retried"
      exit 1
    fi
    jq -e --arg port "$port" --arg flag "${2%%=*}" '
      .TCP[$port] as $tcp
      | if $flag == "--tcp" then $tcp != null and $tcp.HTTP != true and $tcp.HTTPS != true
        else ($tcp.HTTP == true or $tcp.HTTPS == true) and (.Web["rpi5.example:" + $port].Handlers | length > 0)
        end
    ' "$STATUS" >/dev/null
    jq --arg port "$port" --arg flag "${2%%=*}" '
      del(.TCP[$port]) | if $flag == "--tcp" then . else del(.Web["rpi5.example:" + $port]) end
    ' "$STATUS" > "$STATUS.next"
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
  local target
  for target in "$@"; do
    [[ "$target" == *=* ]] || target="https=$target"
    printf 'serve --%s off\n' "$target"
  done > "$tmp/expected"
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

fixture "${live[@]}" 6333 | jq '.TCP["6333"] = {HTTP: true}' > "$STATUS"
run 0 tidy 'removed node HTTP port 6333'
assert_writes http=6333
fixture "${live[@]}" | diff -u - "$STATUS"
echo 'PASS tidy uses HTTP removal for a plain-HTTP handler (exit 0)'

fixture "${live[@]}" | jq '.TCP["6333"] = {TCPForward: "127.0.0.1:6333"}' > "$STATUS"
run 0 tidy 'removed node TCP port 6333'
assert_writes tcp=6333
fixture "${live[@]}" | diff -u - "$STATUS"
echo 'PASS tidy uses TCP removal for a TCP-only forward (exit 0)'

fixture "${live[@]}" 6333 | jq 'del(.Web["rpi5.example:6333"])' > "$STATUS"
cp "$STATUS" "$tmp/ambiguous"
run 1 tidy 'unrecognized node handler on port 6333'
assert_writes
diff -u "$tmp/ambiguous" "$STATUS"
echo 'PASS tidy preserves an HTTPS marker without a Web handler (exit 1)'

fixture "${live[@]}" 6333 | jq '.Web["other.example:6333"] = .Web["rpi5.example:6333"] | del(.Web["rpi5.example:6333"])' > "$STATUS"
cp "$STATUS" "$tmp/ambiguous"
run 1 tidy 'unrecognized node handler on port 6333'
assert_writes
diff -u "$tmp/ambiguous" "$STATUS"
echo 'PASS tidy preserves a Web handler for a different hostname (exit 1)'

cp "$tmp/full" "$STATUS"
RETRY_PORT=6333 run 0 tidy 'removed node HTTPS port 6333'
assert_writes 6333 "${dead[@]}"
diff -u "$tmp/kept" "$STATUS"
echo 'PASS tidy retries a transient write failure (exit 0)'

cp "$tmp/full" "$STATUS"
FAIL_PORT=6333 run 1 tidy 'could not clear node port 6333 after 3 attempts'
assert_writes 6333 6333 "${dead[@]}"
fixture "${live[@]}" 6333 | jq -S "$keep" | diff -u - <(jq -S . "$STATUS")
echo 'PASS tidy caps retries and still clears the other ports (exit 1)'

BACKEND=Starting run 1 tidy 'tailscaled did not reach Running'
printf '%s\n' 'status --json --peers=false'{,,} | diff -u - "$CALLS"
echo 'PASS tidy makes no Serve calls before Running (exit 1)'

check_allowlist() {
  run "$1" allowlist "$2"
  printf '%s\n' 'status --json --peers=false' 'serve status --json' | diff -u - "$CALLS"
  echo "PASS allowlist $3 (exit $1)"
}

fixture "${live[@]}" > "$STATUS"
check_allowlist 0 'allowlist: ok' 'accepts the three approved ports'
BACKEND=NeedsLogin run 1 allowlist 'tailscaled is not Running'
printf '%s\n' 'status --json --peers=false' | diff -u - "$CALLS"
echo 'PASS allowlist fails when tailscaled needs login (exit 1)'
echo 'null' > "$STATUS"
check_allowlist 1 'missing required node port 3001' 'rejects null Serve config'
echo '{}' > "$STATUS"
check_allowlist 1 'missing required node port 8123' 'rejects empty Serve config'
fixture 3001 8123 > "$STATUS"
check_allowlist 1 'missing required node port 5678' 'rejects a single missing required port'
echo '{"TCP":{"3001":false}}' > "$STATUS"
check_allowlist 1 'malformed TCP handler on port 3001' 'rejects a non-object TCP entry'
fixture "${live[@]}" | jq 'del(.Web["rpi5.example:3001"].Handlers)' > "$STATUS"
check_allowlist 1 'malformed Web handler at rpi5.example:3001' 'rejects a Web entry without Handlers'
fixture "${live[@]}" | jq 'del(.Web["rpi5.example:3001"])' > "$STATUS"
check_allowlist 1 'malformed TCP handler on port 3001' 'rejects an HTTPS port without a Web entry'
fixture "${live[@]}" | jq '.AllowFunnel["rpi5.example:3001"] = true' > "$STATUS"
check_allowlist 1 'Funnel enabled at rpi5.example:3001' 'rejects Funnel on an approved port'
fixture "${live[@]}" | jq '.AllowFunnel["rpi5.example:3001"] = false' > "$STATUS"
check_allowlist 0 'allowlist: ok' 'accepts an explicitly disabled Funnel entry'
fixture "${live[@]}" | jq '.Foreground.fixture.AllowFunnel["rpi5.example:443"] = true' > "$STATUS"
check_allowlist 1 'Funnel enabled at rpi5.example:443' 'rejects a foreground Funnel entry'
fixture "${live[@]}" | jq '.TCP["9443"] = {TCPForward: "127.0.0.1:9443"}' > "$STATUS"
check_allowlist 1 'unexpected node port 9443' 'rejects an extra TCP port'
fixture "${live[@]}" 9443 > "$STATUS"
check_allowlist 1 'unexpected node port 9443' 'rejects an extra HTTPS port'
fixture "${live[@]}" 9443 | jq 'del(.TCP["9443"])' > "$STATUS"
check_allowlist 1 'malformed Web handler at rpi5.example:9443' 'rejects a Web entry without TCP'
fixture "${live[@]}" | jq '.Foreground.fixture.TCP["9443"] = {TCPForward: "127.0.0.1:9443"}' > "$STATUS"
check_allowlist 1 'unexpected node port 9443' 'rejects an extra foreground port'
fixture "${live[@]}" | jq '.Services["svc:nixframe"].TCP["443"] = {TCPForward: "127.0.0.1:443"}' > "$STATUS"
check_allowlist 1 'unexpected Service svc:nixframe' 'rejects an undeclared Service'
ALLOWED_SERVICES='["svc:nixframe"]' check_allowlist 0 'allowlist: ok' 'accepts declared Service with its own port'
rm "$STATUS"
check_allowlist 1 'cannot read Serve status' 'fails on unreadable status'
echo '{"TCP":false}' > "$STATUS"
check_allowlist 1 'invalid Serve status JSON' 'fails on an invalid status object'
: > "$STATUS"
check_allowlist 1 'invalid Serve status JSON' 'fails on empty command output'
