#!/usr/bin/env bash
# Tests for hosts/sancta-choir/svc-game.sh with a fake tailscale that logs its calls.
set -u
SCRIPT=$1
T=$(mktemp -d); trap 'chmod -R u+w "$T"; find "$T" -xdev -delete' EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; failn=$((failn+1)); }
mkdir -p "$T/bin" "$T/game"
cat > "$T/bin/tailscale" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$LOG"
[ "${FAKE_SERVE_FAIL:-}" = 1 ] && [ "${1:-}" = serve ] && [ "${2:-}" != clear ] && exit 1
exit 0
F
chmod +x "$T/bin/tailscale"
printf 'hello game\n' > "$T/content"
SHA=$(sha256sum "$T/content" | cut -d' ' -f1); LEN=$(stat -c %s "$T/content")
run() { # run <mode> ; sets rc and log
  : > "$T/log"
  env LOG="$T/log" TS="$T/bin/tailscale" SVC=svc:game DIR="$T/game" SHA="${PSHA:-$SHA}" LEN="${PLEN:-$LEN}" \
    FAKE_SERVE_FAIL="${FAKE_SERVE_FAIL:-}" bash "$SCRIPT" "$1" >/dev/null 2>&1
  rc=$?; log=$(cat "$T/log")
}
place() { rm -f "$T/game/"*; cp "$T/content" "$T/game/$SHA.html"; }
never_reset() { case "$log" in *reset*) bad "$1: called serve reset";; *) ok;; esac; }

place; run verify
[ $rc -eq 0 ] && ok || bad "verify valid rc=$rc"
[ "$log" = "serve --service=svc:game --https=443 --yes $T/game/$SHA.html" ] && ok || bad "verify valid log: $log"

run boot
[ $rc -eq 0 ] && ok || bad "boot valid rc=$rc"
[ "$(printf '%s\n' "$log" | head -1)" = "serve clear svc:game" ] && ok || bad "boot must clear first: $log"
[ "$(printf '%s\n' "$log" | sed -n 2p)" = "serve --service=svc:game --https=443 --yes $T/game/$SHA.html" ] && ok || bad "boot then serve: $log"

rm -f "$T/game/"*; run verify
[ $rc -ne 0 ] && ok || bad "missing file must fail"
[ "$log" = "serve clear svc:game" ] && ok || bad "missing: clear only: $log"

place; printf 'X' >> "$T/game/$SHA.html"; run verify
[ $rc -ne 0 ] && [ "$log" = "serve clear svc:game" ] && ok || bad "length change: rc=$rc log=$log"

place; printf 'jello game\n' > "$T/game/$SHA.html"; run verify   # same length, one byte flipped
[ $rc -ne 0 ] && [ "$log" = "serve clear svc:game" ] && ok || bad "byte flip: rc=$rc log=$log"

rm -f "$T/game/"*; ln -s "$T/content" "$T/game/$SHA.html"; run verify
[ $rc -ne 0 ] && [ "$log" = "serve clear svc:game" ] && ok || bad "symlink: rc=$rc log=$log"

place; FAKE_SERVE_FAIL=1 run verify
[ $rc -ne 0 ] && ok || bad "serve failure must fail"
case "$log" in *"serve clear svc:game"*) ok;; *) bad "serve failure must clear: $log";; esac

place; PSHA=abc run verify
[ $rc -ne 0 ] && [ "$log" = "serve clear svc:game" ] && ok || bad "short pin: rc=$rc log=$log"
place; PSHA=$(printf '%s' "$SHA" | tr 'a-f' 'A-F') run verify
[ $rc -ne 0 ] && ok || bad "uppercase pin must be refused"

place; run bogus
[ $rc -eq 2 ] && [ -z "$log" ] && ok || bad "unknown mode: rc=$rc log=$log"

for m in verify boot; do place; run $m; never_reset $m; done
echo "svc-game tests: $pass passed, $failn failed"
[ $failn -eq 0 ]
