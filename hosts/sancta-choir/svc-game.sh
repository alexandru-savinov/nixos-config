#!/usr/bin/env bash
# Serve one pinned static file as a Tailscale Service, and only if its bytes match the pin.
# Inputs (environment): TS (tailscale binary), SVC (service name), DIR (root-owned 0700 dir),
# SHA (expected sha256, 64 hex), LEN (expected length in bytes). Argument: boot | verify.
#   boot    clear the service first (tailscaled persists Serve config across reboots), then verify and serve
#   verify  verify; serve again (idempotent); on any mismatch clear the service and fail
# It touches only $SVC: never a whole-config reset, never another port or service.
set -u
mode=${1:-verify}
f="$DIR/$SHA.html"
clear_svc() { "$TS" serve clear "$SVC" >/dev/null 2>&1 || true; }
fail() { echo "svc-game: $1; $SVC cleared" >&2; clear_svc; exit 1; }
case "$mode" in boot|verify) ;; *) echo "svc-game: unknown mode $mode" >&2; exit 2;; esac
case "$SHA" in *[!0-9a-f]*|"") fail "pin is not a sha256";; esac
[ ${#SHA} -eq 64 ] || fail "pin is not a sha256"
[ "$mode" = boot ] && clear_svc
[ -L "$f" ] && fail "file is a symlink"
[ -f "$f" ] || fail "file missing"
size=$(stat -c %s -- "$f") || fail "cannot stat file"
[ "$size" = "$LEN" ] || fail "length $size, pinned $LEN"
got=$(sha256sum -- "$f" | cut -d' ' -f1) || fail "cannot hash file"
[ "$got" = "$SHA" ] || fail "sha256 differs from the pin"
"$TS" serve --service="$SVC" --https=443 --yes "$f" >/dev/null || fail "serve failed"
echo "svc-game: $mode ok, $SVC serves $SHA ($LEN bytes)"
