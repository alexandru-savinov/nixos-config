#!/usr/bin/env bash
# Serve one pinned static file as a Tailscale Service, and only if its bytes match the pin.
# Inputs (environment): TS (tailscale binary), SVC (service name), DIR (root-owned 0700 dir),
# SHA (expected sha256, 64 hex), LEN (expected length in bytes), LOCK (lock file),
# WAIT (seconds to wait for tailscaled to be Running; default 90), LOCKWAIT (default 120).
# Argument: boot | verify | stop.
#   boot    clear the service first (tailscaled persists Serve config across reboots), then verify and serve.
#           This mode adds the mapping, and the unit clears it on stop or failed start.
#   verify  check the pinned file and any existing mapping, then clear and fail on mismatch.
#           A manual clear or a `serve drain` stays in effect.
#   stop    clear the service (unit stop, module disabled, rollback)
# It touches only $SVC: never a whole-config reset, never another port or service.
# Residual (accepted): tailscaled reopens the file on each request, so bytes changed after a check
# are served until the next check. The 0700 root dir and the 0400 root file limit that to root.
set -u
mode=${1:-verify}
f="$DIR/$SHA.html"
case "$mode" in boot|verify|stop) ;; *) echo "svc-game: unknown mode $mode" >&2; exit 2;; esac

# One writer at a time: the boot run and the timer's verify run can overlap on the first switch.
exec 9>"$LOCK" || { echo "svc-game: cannot open lock" >&2; exit 1; }
flock -w "${LOCKWAIT:-120}" 9 || { echo "svc-game: lock busy" >&2; exit 1; }

ready() { # tailscaled rejects Serve writes until it is Running
  local i=0
  while [ "$i" -lt "${WAIT:-90}" ]; do
    [ "$("$TS" status --json --peers=false 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)" = Running ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}
# Serve writes share one ETag across all Serve config, so another writer (on another port)
# can make one attempt fail; retry a few times before giving up.
retry() { local i; for i in 1 2 3; do "$@" >/dev/null 2>&1 && return 0; sleep "${RETRY_SLEEP:-2}"; done; return 1; }
clear_svc() {
  if retry "$TS" serve clear "$SVC"; then return 0; fi
  echo "svc-game: CLEAR FAILED for $SVC: the previous mapping may still be served" >&2; return 1
}
fail() {
  if clear_svc; then echo "svc-game: $1; $SVC cleared" >&2; else echo "svc-game: $1" >&2; fi
  exit 1
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
  if ! status=$("$TS" serve status --json 2>/dev/null); then
    echo "svc-game: file verified, Serve status unavailable"
    exit 0
  fi
  # Web is keyed by host:port. Each entry must serve only the pinned file at /.
  jq -e --arg svc "$SVC" --arg file "$f" '
    .Services[$svc]
    | . == null or (
        (.Web | type == "object" and length > 0)
        and all(.Web[]; .Handlers == {"/": {Path: $file}})
      )
    ' <<< "$status" >/dev/null 2>&1 || fail "Serve mapping does not match the pinned file"
  echo "svc-game: verify ok, $SHA ($LEN bytes)"
  exit 0
fi
retry "$TS" serve --service="$SVC" --https=443 --yes "$f" || fail "serve failed"
echo "svc-game: boot ok, $SVC serves $SHA ($LEN bytes)"
