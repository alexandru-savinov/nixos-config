# choir-ssh-revert: stage-4 dead-man. Turns Tailscale SSH back ON and proves it.
#
# Armed by hand during the stage-4 window as a transient timer:
#   systemd-run --collect --on-active=30min --property=RuntimeMaxSec=90min \
#     --unit=choir-ssh-revert /run/current-system/sw/bin/choir-ssh-revert
# (--collect: a failed run is garbage-collected, so the same command re-arms.
# RuntimeMaxSec covers the worst case: 10 attempts of ~7.5 min with a hung
# daemon, so the final FAILED line is always logged.)
# and stopped (and proven gone) once the OpenSSH path is proven.
#
# Every tool comes from an absolute store path that the Nix wrapper sets; the
# wrapper does not take them from the caller's environment.
#
# Recoverable: tailscaled down or hung (each CLI call is time-bounded, so a hang
# counts as a failure and leads to a restart). NOT recoverable here: a backend
# that is logged out or deliberately stopped (`tailscale down`); the script
# then exits 1 after its retries and logs that the Hetzner console is needed.
set -u

: "${TS:?}" "${SYSTEMCTL:?}" "${JQ:?}" "${LOGGER:?}" "${SLEEP:?}" "${TIMEOUT:?}"
tries="${TRIES:-10}"
limit="${TS_LIMIT:-20}"

ts() { "$TIMEOUT" "$limit" "$TS" "$@"; }

log() { "$LOGGER" -t choir-ssh-revert -- "$*" </dev/null; }

# "Up" means BackendState Running: `status` also exits 0 while Starting.
running() { ts status --json --peers=false 2>/dev/null | "$JQ" -e '.BackendState == "Running"' >/dev/null 2>&1; }

run_ssh() { ts debug prefs 2>/dev/null | "$JQ" -r '.RunSSH' 2>/dev/null; }

i=1
while [ "$i" -le "$tries" ]; do
  if ! ts status >/dev/null 2>&1; then
    log "attempt $i: tailscale status failed; restarting tailscaled"
    "$TIMEOUT" 90 "$SYSTEMCTL" restart tailscaled.service || log "attempt $i: restart failed"
    w=0
    while [ "$w" -lt 12 ] && ! ts status >/dev/null 2>&1; do
      "$SLEEP" 5
      w=$((w + 1))
    done
  fi
  ts set --ssh=true || log "attempt $i: tailscale set --ssh=true failed"
  # Success needs the backend up AND the pref on: a pref set against a
  # stopped or logged-out backend restores nothing.
  if running && [ "$(run_ssh)" = "true" ]; then
    log "attempt $i: RunSSH=true, Tailscale SSH restored"
    exit 0
  fi
  log "attempt $i: backend not running or RunSSH not true; retrying"
  "$SLEEP" 15
  i=$((i + 1))
done
log "FAILED after $tries attempts: RunSSH is not true; use the Hetzner console"
exit 1
