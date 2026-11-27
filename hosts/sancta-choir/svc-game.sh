#!/usr/bin/env bash
# Serve one pinned static file as a Tailscale Service, and only if its bytes match the pin.
# Inputs (environment): TS (tailscale binary), SVC (service name), DIR (root-owned 0700 dir),
# SHA (expected sha256, 64 hex), LEN (expected length in bytes), LOCK (lock file),
# WAIT (seconds to wait for tailscaled to be Running; default 90), LOCKWAIT (default 120).
# Verify also takes RUNTIME_DIRECTORY and VERIFY_STATUS_FAILURE_THRESHOLD (default 3).
# Argument: boot | verify | stop | stop-post.
#   boot    clear the service first (tailscaled persists Serve config across reboots), then verify and serve.
#           This mode adds the mapping, and the unit clears it on stop or failed start.
#   verify  check the pinned file and any existing mapping, then clear and fail on mismatch.
#           Repeated Serve status failures alert without clearing.
#           A manual clear or a `serve drain` stays in effect.
#   stop    clear the service (unit stop, module disabled, rollback)
#   stop-post  clear the service when systemd reports a failed run.
# It touches only $SVC: never a whole-config reset, never another port or service.
# Residual (accepted): tailscaled reopens the file on each request, so bytes changed after a check
# are served until the next check. The 0700 root dir and the 0400 root file limit that to root.
set -uo pipefail
mode=${1:-verify}
case "$mode" in
  boot|verify|stop) ;;
  stop-post)
    if [ "${SERVICE_RESULT:-}" = success ]; then exit 0; fi
    mode=stop
    ;;
  *) echo "svc-game: unknown mode $mode" >&2; exit 2;;
esac

# One writer at a time: the boot run and the timer's verify run can overlap on the first switch.
exec 9>"$LOCK" || { echo "svc-game: cannot open lock" >&2; exit 1; }
flock -w "${LOCKWAIT:-120}" 9 || { echo "svc-game: lock busy" >&2; exit 1; }

ts_timeout=20
tailscale_cli() {
  local duration=$1
  shift
  timeout -k 1 "$duration" "$TS" "$@"
}
ready() { # tailscaled rejects Serve writes until it is Running
  local deadline=$((SECONDS + ${WAIT:-90})) remaining state
  while [ "$SECONDS" -lt "$deadline" ]; do
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || return 1
    if [ "$remaining" -gt "$ts_timeout" ]; then remaining=$ts_timeout; fi
    if state=$(tailscale_cli "$remaining" status --json --peers=false 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null) \
      && [ "$state" = Running ]; then return 0; fi
    if [ "$SECONDS" -lt "$deadline" ]; then sleep 1; fi
  done
  return 1
}
# Serve writes share one ETag across all Serve config, so another writer (on another port)
# can make one attempt fail; retry a few times before giving up.
retry() { local i; for i in 1 2 3; do "$@" >/dev/null 2>&1 && return 0; sleep "${RETRY_SLEEP:-2}"; done; return 1; }
clear_svc() {
  if retry tailscale_cli "$ts_timeout" serve clear "$SVC"; then return 0; fi
  echo "svc-game: CLEAR FAILED for $SVC: the previous mapping may still be served" >&2; return 1
}
fail() {
  if clear_svc; then echo "svc-game: $1; $SVC cleared" >&2; else echo "svc-game: $1" >&2; fi
  exit 1
}
status_unavailable() {
  local misses=0 threshold=${VERIFY_STATUS_FAILURE_THRESHOLD:-3}
  if [ -e "$miss_file" ]; then
    if ! IFS= read -r misses < "$miss_file" || ! [[ "$misses" =~ ^(0|[1-9][0-9]*)$ ]]; then
      echo "svc-game: cannot read Serve status miss counter" >&2
      exit 1
    fi
  fi
  if [ "$misses" -lt "$threshold" ]; then
    misses=$((misses + 1))
    printf '%s\n' "$misses" > "$miss_file.tmp" && mv -f -- "$miss_file.tmp" "$miss_file" || exit 1
  fi
  if [ "$misses" -ge "$threshold" ]; then
    echo "svc-game: Serve status unavailable for at least $threshold consecutive verification runs" >&2
    exit 1
  fi
  echo "svc-game: file verified, Serve status unavailable ($misses/$threshold consecutive misses)"
  exit 0
}
# Stop retries the clear without a readiness wait because it may run at shutdown.
if [ "$mode" = stop ]; then clear_svc || exit 1; echo "svc-game: $SVC cleared (stop)"; exit 0; fi
# boot waits for Running before any write; if it never gets there it still tries a clear
# (a clear can succeed while Starting). verify checks the file even when Serve status is unavailable.
if [ "$mode" = boot ] && ! ready; then fail "tailscaled not Running after ${WAIT:-90}s"; fi
case "$SHA" in *[!0-9a-f]*|"") fail "pin is not a sha256";; esac
[ ${#SHA} -eq 64 ] || fail "pin is not a sha256"
if [ "$mode" = boot ]; then clear_svc || exit 1; fi
dir=$DIR
# A trailing slash would make the symlink check follow the link.
while [[ "$dir" == ?*/ ]]; do dir=${dir%/}; done
f="$dir/$SHA.html"
[ -L "$dir" ] && fail "directory is a symlink"
[ -d "$dir" ] || fail "directory missing or invalid"
own=$(stat -c '%u %a' -- "$dir") || fail "cannot stat directory"
[ "$own" = "${EXPECT_OWNER:-0} 700" ] || fail "directory must be root-owned mode 0700, is $own"
[ -L "$f" ] && fail "file is a symlink"
[ -f "$f" ] || fail "file missing"
own=$(stat -c '%u %a' -- "$f") || fail "cannot stat file"
[ "$own" = "${EXPECT_OWNER:-0} 400" ] || fail "file must be root-owned mode 0400, is $own"
size=$(stat -c %s -- "$f") || fail "cannot stat file"
[ "$size" = "$LEN" ] || fail "length $size, pinned $LEN"
got=$(sha256sum -- "$f" | cut -d' ' -f1) || fail "cannot hash file"
[ "$got" = "$SHA" ] || fail "sha256 differs from the pin"
if [ "$mode" = verify ]; then
  miss_file=${RUNTIME_DIRECTORY:?}/serve-status-misses
  if ! status=$(tailscale_cli "$ts_timeout" serve status --json 2>/dev/null) \
    || ! mapping=$(jq -cs --arg svc "$SVC" '
      if length == 1 then .[0].Services[$svc] else error("expected one Serve status value") end
      ' <<< "$status" 2>/dev/null); then
    status_unavailable
  fi
  reset_status=0
  rm -f -- "$miss_file" || reset_status=$?
  if [ "$mapping" != null ]; then
    # Tailscale 1.90.9 derives the service's host from its name and CurrentTailnet.MagicDNSSuffix.
    if ! suffix=$(tailscale_cli "$ts_timeout" status --json --peers=false 2>/dev/null \
      | jq -er '.CurrentTailnet.MagicDNSSuffix | select(type == "string" and length > 0)' 2>/dev/null); then
      echo "svc-game: cannot verify Serve mapping because the tailnet DNS suffix is unavailable" >&2
      exit 1
    fi
    # ServiceConfig has TCP, Web and an optional Tun. Require exactly the HTTPS file mapping.
    jq -e --arg hostport "${SVC#svc:}.$suffix:443" --arg file "$f" '
      . == {TCP: {"443": {HTTPS: true}}, Web: {($hostport): {Handlers: {"/": {Path: $file}}}}}
      ' <<< "$mapping" >/dev/null 2>&1 || fail "Serve mapping does not match the pinned file"
  fi
  [ "$reset_status" -eq 0 ] || exit 1
  echo "svc-game: verify ok, $SHA ($LEN bytes)"
  exit 0
fi
retry tailscale_cli "$ts_timeout" serve --service="$SVC" --https=443 --yes "$f" || fail "serve failed"
echo "svc-game: boot ok, $SVC serves $SHA ($LEN bytes)"
