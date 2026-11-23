#!/usr/bin/env bash
# Harness for hosts/sancta-choir/choir-ssh-revert.sh with fake tools.
# usage: tests/choir-ssh-revert.sh <script>
set -u
script=$1
pass=0; fail=0
W=$(mktemp -d)
B=$(command -v bash)

mk() { printf '#!%s\n' "$B" >"$W/$1"; cat >>"$W/$1"; chmod +x "$W/$1"; }

# Fake tailscale: state in $W/state (status_fail_n, run_ssh, set_fails_n).
mk tailscale <<'F'
st=$FAKE/state
echo "tailscale $*" >>"$FAKE/calls"
case "$1" in
  status)
    n=$(cat "$st/status_fail_n" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n - 1)) >"$st/status_fail_n"; exit 1; fi
    exit 0 ;;
  set)
    n=$(cat "$st/set_fail_n" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n - 1)) >"$st/set_fail_n"; exit 1; fi
    [ "$2" = "--ssh=true" ] && echo true >"$st/run_ssh"; exit 0 ;;
  debug)
    printf '{"RunSSH":%s}\n' "$(cat "$st/run_ssh")" ;;
esac
F
mk systemctl <<'F'
echo "systemctl $*" >>"$FAKE/calls"
[ -e "$FAKE/state/systemctl_fails" ] && exit 1
exit 0
F
mk logger <<'F'
echo "logger $*" >>"$FAKE/calls"
F
mk sleep <<'F'
echo "sleep $*" >>"$FAKE/calls"
F

run() { # name expected_rc status_fail_n set_fail_n [systemctl_fails]
  local d="$W/$1"; mkdir -p "$d/state"; : >"$d/calls"
  [ "${5:-}" = fails ] && : >"$d/state/systemctl_fails"
  echo false >"$d/state/run_ssh"; echo "$3" >"$d/state/status_fail_n"; echo "$4" >"$d/state/set_fail_n"
  FAKE=$d TS=$W/tailscale SYSTEMCTL=$W/systemctl JQ=$(command -v jq) LOGGER=$W/logger SLEEP=$W/sleep TRIES=3 \
    bash "$script" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: rc=$rc want $2"; cat "$d/calls"; fi
}
has() { if grep -qF -- "$2" "$W/$1/calls"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: missing '$2'"; cat "$W/$1/calls"; fi; }
hasnt() { if grep -qF -- "$2" "$W/$1/calls"; then fail=$((fail + 1)); echo "FAIL $1: unexpected '$2'"; else pass=$((pass + 1)); fi; }

run healthy 0 0 0
has healthy "tailscale set --ssh=true"
has healthy "RunSSH=true, Tailscale SSH restored"
hasnt healthy "systemctl restart"

run daemon_down 0 2 0
has daemon_down "systemctl restart tailscaled.service"
has daemon_down "tailscale set --ssh=true"
has daemon_down "RunSSH=true"

run set_fails_once 0 0 1
has set_fails_once "retrying"
has set_fails_once "attempt 2: RunSSH=true"

run never 1 0 99
has never "FAILED after 3 attempts"

# The backend never comes back: the pref gets set, but that is NOT success.
run backend_dead 1 999 0
has backend_dead "tailscale set --ssh=true"
has backend_dead "backend not running or RunSSH not true"
has backend_dead "FAILED after 3 attempts"
hasnt backend_dead "Tailscale SSH restored"
n5=$(grep -c -- "sleep 5" "$W/backend_dead/calls")
if [ "$n5" -eq 36 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL backend_dead: sleep 5 x$n5, want 36 (12 polls x 3 attempts)"; fi

# The restart itself fails, then the backend recovers on its own.
run restart_fails 0 2 0 fails
has restart_fails "restart failed"
has restart_fails "RunSSH=true"

# Missing tool paths: refuse to run at all.
if env -i PATH="$PATH" bash "$script" >/dev/null 2>&1; then fail=$((fail + 1)); echo "FAIL: ran without tool paths"; else pass=$((pass + 1)); fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
