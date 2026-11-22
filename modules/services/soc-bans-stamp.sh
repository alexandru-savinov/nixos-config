# soc-bans-stamp.sh — record the bans evaluator's outcome as TWO mtimes.
#
# Runs as the soc-alarm-bans unit's ExecStopPost (systemd hands it
# SERVICE_RESULT, EXIT_CODE and EXIT_STATUS). vigil reads each stamp with its
# file `age` check:
#
#   run                          bans stamp        health stamp
#   clean (exit 0)               now               now
#   a ban was found (exit 1)     epoch + 1s        now
#   a ban AND a source that      epoch + 1s        epoch + 1s
#   could not be read (exit 3)
#   anything else (exit 2, a     now               epoch + 1s
#   crash, a timeout, a signal)
#
# A ban pages (soc-bans.toml); an evaluator that could not evaluate only
# turns the health contract red (soc-bans-health.toml, page = false), so
# errors reach the journal and dashboard without a page. The health stamp
# carries the failure, so the bans stamp is not left to go stale and page.
#
# Whatever happens, no earlier fresh mtime may outlive a run that did not
# stamp it: a stamp that cannot be written is set to epoch + 1s, and if that
# fails too it is removed; the script then exits non-zero.
set -uo pipefail

bans="${SANCTA_DOCTRINE_STAMP:?SANCTA_DOCTRINE_STAMP is not set}"
health="${SOC_HEALTH_STAMP:?SOC_HEALTH_STAMP is not set}"

failed=0
fresh() {
  if ! touch -- "$1"; then
    invalidate "$1" || true
    failed=1
  fi
}
invalidate() {
  touch -d @1 -- "$1" && return 0
  rm -f -- "$1" || true
  return 1
}
stale() {
  invalidate "$1" || failed=1
}

if [ "${SERVICE_RESULT:-}" = success ] && [ "${EXIT_CODE:-}" = exited ] && [ "${EXIT_STATUS:-}" = 0 ]; then
  fresh "$bans"; fresh "$health"
elif [ "${EXIT_CODE:-}" = exited ] && [ "${EXIT_STATUS:-}" = 1 ]; then
  stale "$bans"; fresh "$health"
elif [ "${EXIT_CODE:-}" = exited ] && [ "${EXIT_STATUS:-}" = 3 ]; then
  stale "$bans"; stale "$health"
else
  # The evaluator could not see. Keep the last known ban state: a bans stamp
  # that is red (epoch + 1s) stays red, so a blind run never clears a ban
  # that may still be in place; one that is green is freshened.
  # "red" = mtime older than epoch + 2s, compared against a reference file.
  ref=$(mktemp) && touch -d @2 -- "$ref" || ref=""
  if [ -z "$ref" ]; then
    stale "$bans" # cannot tell: fail towards red on the paging stamp
  elif [ -e "$bans" ] && [ "$bans" -ot "$ref" ]; then
    : # red stays red
  else
    fresh "$bans"
  fi
  [ -n "$ref" ] && rm -f -- "$ref"
  stale "$health"
fi
exit "$failed"
