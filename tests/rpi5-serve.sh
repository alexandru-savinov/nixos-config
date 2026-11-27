#!/usr/bin/env bash
set -euo pipefail

script=${1:-$(dirname "$0")/../hosts/rpi5-full/rpi5-serve.sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export TS="$tmp/tailscale" TS_SOCKET="$tmp/tailscaled.sock" CALLS="$tmp/calls" STATUS="$tmp/status.json"
export ALLOWED_PORTS='[3001,5678,8123]' ALLOWED_SERVICES='[]'
export WAIT=3 POLL_SLEEP=0 RETRY_SLEEP=0

# The Nix sandbox has no /usr/bin/env: give the fake the resolved bash as its shebang.
{ printf '#!%s\n' "$(command -v bash)"; cat <<'FAKE'
set -euo pipefail
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  'status --json --peers=false')
    case "${BACKEND:-Running}" in
      delayed)
        if [[ -f "$STATUS.polled" ]]; then echo '{"BackendState":"Running","Self":{"DNSName":"rpi5.example."}}'
        else touch "$STATUS.polled"; echo '{"BackendState":"Starting"}'; fi
        ;;
      *) jq -nc --arg state "${BACKEND:-Running}" --arg dns "${SELF_DNS_NAME-rpi5.example.}" \
           '{BackendState: $state, Self: {DNSName: $dns}}' ;;
    esac
    ;;
  'serve status --json') cat "$STATUS" ;;
  *) echo "unexpected tailscale command: $*" >&2; exit 99 ;;
esac
FAKE
} > "$TS"

{ printf '#!%s\n' "$(command -v bash)"; cat <<'FAKE'
set -euo pipefail
[[ "${*:1:9}" == "--disable --silent --show-error --noproxy * --max-time 5 --unix-socket $TS_SOCKET" ]]
[[ "${!#}" == 'http://local-tailscaled.sock/localapi/v0/serve-config' ]]
shift 9

etag() {
  local digest
  digest=$(sha256sum "$STATUS")
  printf '%s' "${digest%% *}"
}

add_mount() {
  jq --arg port "$1" '
    .Web["rpi5.example:" + $port].Handlers["/concurrent"] = {Text: "new"}
  ' "$STATUS" > "$STATUS.changed"
  mv "$STATUS.changed" "$STATUS"
}

if [[ "$1" == --fail ]]; then
  [[ $# == 4 && "$2" == --write-out && "$3" == $'\n%header{etag}' ]]
  echo 'localapi GET' >> "$CALLS"
  cat "$STATUS"
  printf '\n'
  if [[ "${MISSING_ETAG:-}" != 1 ]]; then etag; fi
  if [[ -n "${ADD_AFTER_FIRST_READ:-}" && ! -f "$STATUS.changed-on-read" ]]; then
    touch "$STATUS.changed-on-read"
    add_mount "$ADD_AFTER_FIRST_READ"
  fi
  exit 0
fi

[[ $# == 11 && "${*:1:5}" == '--output /dev/null --write-out %{http_code} --header' ]]
[[ "$6" == 'If-Match: '* && "$7" == --header && "$8" == 'Content-Type: application/json' ]]
[[ "$9" == --data-binary && "${10}" == @- ]]
cat > "$STATUS.next"
port=$(jq -sre '
  ((.[0].TCP // {} | keys) - (.[1].TCP // {} | keys))
  | if length == 1 then .[0] else error("expected exactly one retired TCP key to disappear") end
' "$STATUS" "$STATUS.next")
echo "localapi POST $port" >> "$CALLS"
if [[ "${ADD_BEFORE_WRITE:-}" == "$port" ]]; then add_mount "$port"; fi
if [[ "$6" != "If-Match: $(etag)" ]]; then
  echo 412
elif [[ "${FAIL_PORT:-}" == "$port" ]]; then
  echo 500
elif [[ "${RETRY_PORT:-}" == "$port" && ! -f "$STATUS.retried" ]]; then
  touch "$STATUS.retried"
  echo 500
else
  mv "$STATUS.next" "$STATUS"
  if [[ "${CHANGE_AFTER_WRITE:-}" == "$port" ]]; then add_mount 3001; fi
  echo 200
fi
FAKE
} > "$tmp/curl"
chmod +x "$TS" "$tmp/curl"
export PATH="$tmp:$PATH"

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
  if (($#)); then printf 'localapi POST %s\n' "$@"; fi > "$tmp/expected"
  awk '$0 != "status --json --peers=false" && $0 != "serve status --json" && $0 != "localapi GET"' "$CALLS" > "$tmp/writes"
  diff -u "$tmp/expected" "$tmp/writes"
}

assert_config() {
  jq -S . "$1" | diff -u - <(jq -S . "$STATUS")
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
assert_config "$tmp/kept"
echo 'PASS tidy waits for Running and removes exactly five node ports (exit 0)'

run 0 tidy ''
assert_writes
assert_config "$tmp/kept"
echo 'PASS tidy rerun is idempotent (exit 0)'

fixture "${live[@]}" 6333 | jq '.TCP["6333"] = {HTTP: true}' > "$STATUS"
run 0 tidy 'removed node HTTP port 6333'
assert_writes 6333
fixture "${live[@]}" | assert_config -
echo 'PASS tidy uses HTTP removal for a plain-HTTP handler (exit 0)'

fixture "${live[@]}" | jq '.TCP["6333"] = {TCPForward: "127.0.0.1:6333"}' > "$STATUS"
run 0 tidy 'removed node TCP port 6333'
assert_writes 6333
fixture "${live[@]}" | assert_config -
echo 'PASS tidy uses TCP removal for a TCP-only forward (exit 0)'

fixture 6333 | jq '.AllowFunnel["rpi5.example:6333"] = true' > "$STATUS"
run 0 tidy 'removed node HTTPS port 6333'
assert_writes 6333
echo '{}' | assert_config -
echo 'PASS tidy clears the last Web port and its Funnel entry (exit 0)'

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
assert_config "$tmp/kept"
echo 'PASS tidy retries a transient write failure (exit 0)'

cp "$tmp/full" "$STATUS"
FAIL_PORT=6333 run 1 tidy 'could not clear node port 6333 after 3 attempts'
assert_writes 6333 6333 "${dead[@]}"
fixture "${live[@]}" 6333 | jq "$keep" | assert_config -
echo 'PASS tidy caps retries and still clears the other ports (exit 1)'

cp "$tmp/full" "$STATUS"
ADD_AFTER_FIRST_READ=6333 run 1 tidy 'Serve config changed before removing node port 6333'
assert_writes
jq '.Web["rpi5.example:6333"].Handlers["/concurrent"] = {Text: "new"}' "$tmp/full" | assert_config -
echo 'PASS tidy revalidates the snapshot before issuing a write (exit 1)'

cp "$tmp/full" "$STATUS"
ADD_BEFORE_WRITE=6333 run 1 tidy 'Serve config changed before removing node port 6333'
assert_writes 6333
jq '.Web["rpi5.example:6333"].Handlers["/concurrent"] = {Text: "new"}' "$tmp/full" | assert_config -
echo 'PASS tidy leaves a concurrently added mount in place and stops (exit 1)'

cp "$tmp/full" "$STATUS"
CHANGE_AFTER_WRITE=6333 run 1 tidy 'unexpected Serve config after removing node port 6333'
assert_writes 6333
jq 'del(.TCP["6333"], .Web["rpi5.example:6333"])
    | .Web["rpi5.example:3001"].Handlers["/concurrent"] = {Text: "new"}' "$tmp/full" | assert_config -
echo 'PASS tidy detects an unrelated change on read-back and stops (exit 1)'

cp "$tmp/full" "$STATUS"
MISSING_ETAG=1 run 1 tidy 'cannot read initial Serve config for node port 6333'
assert_writes
assert_config "$tmp/full"
echo 'PASS tidy refuses to write without a config ETag (exit 1)'

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
fixture "${live[@]}" | jq '.Web |= with_entries(.key |= sub("^rpi5\\.example:"; "old-rpi5.example:"))' > "$STATUS"
check_allowlist 1 'unexpected Web hostname at old-rpi5.example:3001' 'rejects all approved ports under a stale hostname'
SELF_DNS_NAME=old-rpi5.example. check_allowlist 0 'allowlist: ok' 'uses the FQDN returned by tailscale status'
fixture "${live[@]}" | jq '.Web["old-rpi5.example:3001"] = .Web["rpi5.example:3001"]' > "$STATUS"
check_allowlist 1 'unexpected Web hostname at old-rpi5.example:3001' 'rejects a stale Web key alongside the current one'
fixture "${live[@]}" | jq '.Foreground.fixture = {
  TCP: {"3001": .TCP["3001"]}, Web: {"old-rpi5.example:3001": .Web["rpi5.example:3001"]}
}' > "$STATUS"
check_allowlist 1 'unexpected Web hostname at old-rpi5.example:3001' 'rejects a stale foreground Web key'
SELF_DNS_NAME= run 1 allowlist 'cannot determine the node DNS name'
printf '%s\n' 'status --json --peers=false' | diff -u - "$CALLS"
echo 'PASS allowlist fails when the node DNS name is empty (exit 1)'
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
fixture "${live[@]}" | jq '.Services["svc:nixframe"] = {
  TCP: {"443": {HTTPS: true}}, Web: {"nixframe.example:443": {Handlers: {"/": {Text: "ok"}}}}
}' > "$STATUS"
ALLOWED_SERVICES='["svc:nixframe"]' check_allowlist 0 'allowlist: ok' 'accepts declared Service with its own Web hostname'
rm "$STATUS"
check_allowlist 1 'cannot read Serve status' 'fails on unreadable status'
echo '{"TCP":false}' > "$STATUS"
check_allowlist 1 'invalid Serve status JSON' 'fails on an invalid status object'
: > "$STATUS"
check_allowlist 1 'invalid Serve status JSON' 'fails on empty command output'
