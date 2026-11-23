# choir-ssh-revert: stage-4 dead-man. Turns Tailscale SSH back ON and proves it.
#
# Armed by hand during the stage-4 window as a transient timer:
#   systemd-run --on-active=30min --unit=choir-ssh-revert /run/current-system/sw/bin/choir-ssh-revert
# and stopped (and proven gone) once the OpenSSH path is proven.
#
# Every tool comes from an absolute store path that the Nix wrapper sets; the
# wrapper does not take them from the caller's environment.
set -u

: "${TS:?}" "${SYSTEMCTL:?}" "${JQ:?}" "${LOGGER:?}" "${SLEEP:?}"
tries="${TRIES:-10}"

log() { "$LOGGER" -t choir-ssh-revert -- "$*" </dev/null; }

run_ssh() { "$TS" debug prefs 2>/dev/null | "$JQ" -r '.RunSSH' 2>/dev/null; }

i=1
while [ "$i" -le "$tries" ]; do
  if ! "$TS" status >/dev/null 2>&1; then
    log "attempt $i: tailscale status failed; restarting tailscaled"
    "$SYSTEMCTL" restart tailscaled.service || log "attempt $i: restart failed"
    w=0
    while [ "$w" -lt 12 ] && ! "$TS" status >/dev/null 2>&1; do
      "$SLEEP" 5
      w=$((w + 1))
    done
  fi
  "$TS" set --ssh=true || log "attempt $i: tailscale set --ssh=true failed"
  if [ "$(run_ssh)" = "true" ]; then
    log "attempt $i: RunSSH=true, Tailscale SSH restored"
    exit 0
  fi
  log "attempt $i: RunSSH not true yet; retrying"
  "$SLEEP" 15
  i=$((i + 1))
done
log "FAILED after $tries attempts: RunSSH is not true; use the Hetzner console"
exit 1
