#!/usr/bin/env bash
# TS is the tailscale binary. The allowlist is passed as two JSON arrays.
set -uo pipefail

mode=${1:-}
case "$mode" in
  tidy|allowlist) ;;
  *) echo "Usage: rpi5-serve.sh tidy|allowlist" >&2; exit 2 ;;
esac

read_inventory() {
  local status
  if ! status=$("$TS" serve status --json); then
    echo "rpi5-serve: cannot read Serve status" >&2
    return 1
  fi

  # Foreground sessions also expose node ports. Tidy operates on persisted
  # node config only. Service ports belong to a separate address space.
  jq -esc --arg mode "$mode" '
    def config_map:
      if . == null then {} elif type == "object" then . else error("expected object") end;
    def web_port:
      if test("^.+:[0-9]+$") then split(":") | last else error("invalid Web host:port") end;
    if length != 1 then error("expected one Serve config") else .[0] | config_map end
    | [., (if $mode == "allowlist" then .Foreground | config_map | .[] | config_map else empty end)]
    | {
        ports: ([.[] | ((.TCP | config_map | keys[]), (.Web | config_map | keys[] | web_port))] | unique),
        services: ([.[] | .Services | config_map | keys[]] | unique)
      }
  ' <<< "$status" || {
    echo "rpi5-serve: invalid Serve status JSON" >&2
    return 1
  }
}

wait_running() {
  local attempt
  for ((attempt = 0; attempt < ${WAIT:-90}; attempt++)); do
    if "$TS" status --json --peers=false 2>/dev/null |
        jq -e '.BackendState == "Running"' >/dev/null 2>&1; then
      return 0
    fi
    sleep "${POLL_SLEEP:-1}"
  done
  echo "rpi5-serve-tidy: tailscaled did not reach Running" >&2
  return 1
}

has_port() {
  jq -e --arg port "$1" '.ports | index($port) != null' >/dev/null <<< "$2"
}

tidy_port() {
  local port=$1 attempt inventory
  # An off for an absent handler fails in the CLI. Re-read on each attempt
  # because all Serve writers share the same config ETag.
  for attempt in 1 2 3; do
    if inventory=$(read_inventory); then
      if ! has_port "$port" "$inventory"; then
        return 0
      fi
      if "$TS" serve "--https=$port" off </dev/null &&
          inventory=$(read_inventory) && ! has_port "$port" "$inventory"; then
        echo "rpi5-serve-tidy: removed node HTTPS port $port"
        return 0
      fi
    fi
    if ((attempt < 3)); then sleep "${RETRY_SLEEP:-2}"; fi
  done
  echo "rpi5-serve-tidy: could not clear node HTTPS port $port after 3 attempts" >&2
  return 1
}

if [[ "$mode" == tidy ]]; then
  wait_running || exit 1
  result=0
  for port in 6333 8739 8742 8743 8744; do
    tidy_port "$port" || result=1
  done
  exit "$result"
fi

inventory=$(read_inventory) || exit 1
violations=$(jq -r --argjson ports "$ALLOWED_PORTS" --argjson services "$ALLOWED_SERVICES" '
  ((.ports - ($ports | map(tostring)))[] | "unexpected node port \(.)"),
  ((.services - $services)[] | "unexpected Service \(.)")
' <<< "$inventory") || exit 1
if [[ -n "$violations" ]]; then
  printf 'rpi5-serve-allowlist:\n%s\n' "$violations" >&2
  exit 1
fi
echo "rpi5-serve-allowlist: ok"
