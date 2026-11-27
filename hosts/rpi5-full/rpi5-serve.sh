#!/usr/bin/env bash
# Tidy removes all handlers on the retired ports from the node Serve config.
# TS is the tailscale binary. The allowlist is passed as two JSON arrays.
set -uo pipefail

mode=${1:-}
case "$mode" in
  tidy|allowlist) ;;
  *) echo "Usage: rpi5-serve.sh tidy|allowlist" >&2; exit 2 ;;
esac

parse_inventory() {
  jq -escr --arg mode "$mode" --arg port "${1:-}" --arg fqdn "$fqdn" '
    def object:
      if type == "object" then . else error("expected object") end;
    def config_map:
      if . == null then {} else object end;
    def web_port:
      if test("^.+:[0-9]+$") then split(":") | last else error("invalid Web host:port: \(.)") end;
    def nonempty_string:
      type == "string" and length > 0;
    def tcp_kind:
      if type != "object" then "unknown"
      else {HTTP: false, HTTPS: false, TCPForward: "", TerminateTLS: ""} + .
        | if .TCPForward == "" and .TerminateTLS == "" and .HTTP == false and .HTTPS == true then "https"
          elif .TCPForward == "" and .TerminateTLS == "" and .HTTP == true and .HTTPS == false then "http"
          elif .HTTP == false and .HTTPS == false and (.TCPForward | nonempty_string)
               and (.TerminateTLS | type == "string") then "tcp"
          else "unknown" end
      end;
    def valid_web:
      type == "object" and (.Handlers | type == "object" and length > 0
        and all(to_entries[]; (.key | startswith("/")) and (.value | type == "object"
          and ([.Path, .Proxy, .Text] | map(select(. != null and . != ""))
            | length == 1 and all(.[]; nonempty_string)))));

    # Tidy only looks at the persisted node config. Reject ambiguous Web entries.
    def tidy_kind:
      (.TCP | config_map) as $tcp
      | (.Web | config_map | with_entries(select(.key | endswith(":" + $port)))) as $web
      | ($tcp[$port] | tcp_kind) as $kind
      | if ($web | length) == 0 then
          if ($tcp | has($port) | not) then "absent"
          elif $kind == "tcp" then $kind
          else "unknown" end
        elif ($kind == "http" or $kind == "https") and ($web | length) == 1
          and ($web[$fqdn + ":" + $port] | valid_web) then $kind
        else "unknown" end;

    def node_configs:
      object | ., (.Foreground | config_map | .[] | node_configs);
    def checked_ports($node_fqdn):
      (.TCP | config_map | map_values(tcp_kind)) as $tcp
      | [ .Web | config_map | to_entries[] | (.key | web_port) as $port
          | if $node_fqdn != null and .key != ($node_fqdn + ":" + $port)
            then error("unexpected Web hostname at \(.key), expected \($node_fqdn)")
            elif (.value | valid_web) and ($tcp[$port] == "http" or $tcp[$port] == "https")
            then $port else error("malformed Web handler at \(.key)") end ] as $web_ports
      | [ $tcp | to_entries[] | .key as $port
          | if .value == "tcp" or (.value != "unknown" and ($web_ports | index($port)) != null)
            then $port else error("malformed TCP handler on port \($port)") end ];
    def check_funnel:
      .AllowFunnel | config_map | to_entries[]
      | if .value == true then error("Funnel enabled at \(.key)")
        elif .value == false then empty
        else error("malformed AllowFunnel entry at \(.key)") end;

    if length != 1 then error("expected one Serve config") else .[0] | config_map end
    | if $mode == "tidy" then tidy_kind
      else
        [node_configs] as $nodes
        | [$nodes[] | .Services | config_map | to_entries[]] as $services
        | [($nodes[], ($services[].value | object)) | check_funnel]
        # Named Services have their own DNS names and are checked by service name.
        | [$services[].value | checked_ports(null)]
        | {ports: ([$nodes[] | checked_ports($fqdn)[]] | unique),
           services: ([$services[].key] | unique)}
      end
  ' || {
    echo "rpi5-serve: invalid Serve status JSON" >&2
    return 1
  }
}

running_status() {
  "$TS" status --json --peers=false 2>/dev/null |
    jq -esc 'select(length == 1) | .[0] | select(.BackendState == "Running")' 2>/dev/null
}

wait_running() {
  local attempt
  for ((attempt = 0; attempt < ${WAIT:-90}; attempt++)); do
    if running_status; then
      return 0
    fi
    sleep "${POLL_SLEEP:-1}"
  done
  echo "rpi5-serve-tidy: tailscaled did not reach Running" >&2
  return 1
}

serve_api() {
  curl --disable --silent --show-error --noproxy '*' --max-time 5 \
    --unix-socket "${TS_SOCKET:-/run/tailscale/tailscaled.sock}" "$@" \
    http://local-tailscaled.sock/localapi/v0/serve-config
}

read_serve_config() {
  local response
  response=$(serve_api --fail --write-out $'\n%header{etag}') || return 1
  serve_etag=${response##*$'\n'}
  [[ "$serve_etag" =~ ^[0-9a-f]{64}$ ]] || return 1
  serve_config=$(jq -cSe -s '
    if length == 1 and (.[0] | type == "object" or type == "null")
    then .[0] // {} else error("invalid Serve config") end
  ' <<< "${response%$'\n'*}")
}

tidy_port() {
  local port=$1 attempt kind expected http_status
  # Status 2 stops the entire cleanup on a changed or unverifiable snapshot.
  for attempt in 1 2 3; do
    if ! read_serve_config; then
      echo "rpi5-serve-tidy: cannot verify Serve config before removing node port $port" >&2
      return 2
    fi
    if [[ "$serve_config" != "$snapshot" ]]; then
      echo "rpi5-serve-tidy: Serve config changed before removing node port $port" >&2
      return 2
    fi
    kind=$(parse_inventory "$port" <<< "$serve_config") || return 1
    case "$kind" in
      absent) return 0 ;;
      unknown)
        echo "rpi5-serve-tidy: unrecognized node handler on port $port" >&2
        return 1
        ;;
    esac

    # Match Tailscale's removal of the Web port's Funnel entry and omission of
    # empty maps. Foreground sessions and named Services are part of the snapshot.
    expected=$(jq -cSe --arg port "$port" --arg hostport "$fqdn:$port" --arg kind "$kind" '
      del(.TCP[$port]) | if .TCP == {} then del(.TCP) else . end
      | if $kind == "tcp" then . else
          del(.Web[$hostport], .AllowFunnel[$hostport])
          | if .Web == {} then del(.Web) else . end
          | if .AllowFunnel == {} then del(.AllowFunnel) else . end
        end
    ' <<< "$serve_config") || return 1
    # Use the ETag of the config we just validated. The CLI's "serve off"
    # fetches its own snapshot, which could already contain new handlers.
    http_status=$(serve_api --output /dev/null --write-out '%{http_code}' \
      --header "If-Match: $serve_etag" --header 'Content-Type: application/json' \
      --data-binary @- <<< "$expected") || http_status=
    if [[ "$http_status" == 412 ]]; then
      echo "rpi5-serve-tidy: Serve config changed before removing node port $port" >&2
      return 2
    fi
    if ! read_serve_config; then
      echo "rpi5-serve-tidy: cannot verify Serve config after removing node port $port" >&2
      return 2
    fi
    if [[ "$serve_config" == "$expected" ]]; then
      snapshot=$expected
      echo "rpi5-serve-tidy: removed node ${kind^^} port $port"
      return 0
    fi
    if [[ "$http_status" == 200 || "$serve_config" != "$snapshot" ]]; then
      echo "rpi5-serve-tidy: unexpected Serve config after removing node port $port" >&2
      return 2
    fi
    if ((attempt < 3)); then sleep "${RETRY_SLEEP:-2}"; fi
  done
  echo "rpi5-serve-tidy: could not clear node port $port after 3 attempts" >&2
  return 1
}

if [[ "$mode" == tidy ]]; then
  backend=$(wait_running) || exit 1
elif ! backend=$(running_status); then
  echo "rpi5-serve-allowlist: tailscaled is not Running or backend status is unreadable" >&2
  exit 1
fi

if ! fqdn=$(jq -er '.Self.DNSName | strings | rtrimstr(".") | select(length > 0)' <<< "$backend"); then
  echo "rpi5-serve-$mode: cannot determine the node DNS name" >&2
  exit 1
fi

if [[ "$mode" == tidy ]]; then
  if ! read_serve_config; then
    echo "rpi5-serve-tidy: cannot read initial Serve config for node port 6333" >&2
    exit 1
  fi
  snapshot=$serve_config
  result=0
  for port in 6333 8739 8742 8743 8744; do
    if tidy_port "$port"; then
      continue
    else
      if [[ $? == 2 ]]; then exit 1; fi
      result=1
    fi
  done
  exit "$result"
fi

if ! status=$("$TS" serve status --json); then
  echo "rpi5-serve: cannot read Serve status" >&2
  exit 1
fi
inventory=$(parse_inventory <<< "$status") || exit 1
violations=$(jq -r --argjson ports "$ALLOWED_PORTS" --argjson services "$ALLOWED_SERVICES" '
  ($ports | map(tostring)) as $expected
  | ((.ports - $expected)[] | "unexpected node port \(.)"),
  (($expected - .ports)[] | "missing required node port \(.)"),
  ((.services - $services)[] | "unexpected Service \(.)")
' <<< "$inventory") || exit 1
if [[ -n "$violations" ]]; then
  printf 'rpi5-serve-allowlist:\n%s\n' "$violations" >&2
  exit 1
fi
echo "rpi5-serve-allowlist: ok"
