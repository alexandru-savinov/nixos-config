#!/usr/bin/env bash
# Tests for hosts/sancta-choir/svc-game.sh with a fake tailscale that logs its calls.
# Runs inside the Nix sandbox: the fake's shebang is the resolved bash, not /usr/bin/env.
set -u
unset SERVICE_RESULT VERIFY_STATUS_FAILURE_THRESHOLD
SCRIPT=$1
T=$(mktemp -d); trap 'chmod -R u+w "$T"; find "$T" -xdev -delete' EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAIL: $1"; failn=$((failn+1)); }
mkdir -p "$T/bin" "$T/game" "$T/run"
chmod 0700 "$T/game"
REAL_TIMEOUT=$(command -v timeout)
export REAL_TIMEOUT
{ printf '#!%s\n' "$(command -v bash)"; cat <<'F'
if [[ $1 == -k && $2 == 1 && $3 =~ ^([1-9]|1[0-9]|20)$ ]]; then
  export TIMED_TAILSCALE=1
fi
exec "$REAL_TIMEOUT" "$@"
F
} > "$T/bin/timeout"
{ printf '#!%s\n' "$(command -v bash)"; cat <<'F'
printf '%s\n' "$*" >> "$CALL_LOG"
[ "${TIMED_TAILSCALE:-}" = 1 ] || printf '%s\n' "$*" >> "$UNTIMED_LOG"
case "$*" in
  "status --json --peers=false")
    if [ "${FAKE_NOT_RUNNING:-}" = 1 ]; then echo '{"BackendState":"Starting"}'; else echo '{"BackendState":"Running","CurrentTailnet":{"MagicDNSSuffix":"example.ts.net"}}'; fi
    exit 0;;
  "serve status --json")
    [ "${FAKE_SERVE_STATUS_FAIL:-}" = 1 ] && exit 1
    printf '%s\n' "$FAKE_SERVE_STATUS_JSON"
    exit 0;;
esac
echo "$*" >> "$LOG"
[ "${1:-} ${2:-}" = "serve clear" ] && { [ "${FAKE_CLEAR_FAIL:-}" = 1 ] && exit 1; exit 0; }
[ "${FAKE_SERVE_FAIL:-}" = 1 ] && [ "${1:-}" = serve ] && exit 1
exit 0
F
} > "$T/bin/tailscale"
chmod +x "$T/bin/tailscale" "$T/bin/timeout"
printf 'hello game\n' > "$T/content"
SHA=$(sha256sum "$T/content" | cut -d' ' -f1); LEN=$(stat -c %s "$T/content")
run() { # run <mode>; sets rc, log, out, err
  : > "$T/log"
  : > "$T/calls"
  : > "$T/untimed"
  env PATH="$T/bin:$PATH" LOG="$T/log" CALL_LOG="$T/calls" UNTIMED_LOG="$T/untimed" TS="$T/bin/tailscale" SVC=svc:game DIR="${PDIR:-$T/game}" SHA="${PSHA:-$SHA}" LEN="${PLEN:-$LEN}" \
    LOCK="$T/lock" WAIT="${PWAIT:-3}" LOCKWAIT="${PLOCKWAIT:-120}" RETRY_SLEEP=0 EXPECT_OWNER="$(id -u)" FAKE_SERVE_FAIL="${FAKE_SERVE_FAIL:-}" \
    FAKE_CLEAR_FAIL="${FAKE_CLEAR_FAIL:-}" FAKE_NOT_RUNNING="${FAKE_NOT_RUNNING:-}" \
    FAKE_SERVE_STATUS_JSON="${FAKE_SERVE_STATUS_JSON-"{}"}" FAKE_SERVE_STATUS_FAIL="${FAKE_SERVE_STATUS_FAIL:-}" \
    RUNTIME_DIRECTORY="$T/run" \
    bash "$SCRIPT" "$1" >"$T/out" 2>"$T/err"
  rc=$?; log=$(cat "$T/log"); err=$(cat "$T/err"); out=$(cat "$T/out")
  [ ! -s "$T/untimed" ] || bad "$1 made tailscale calls without a timeout: $(cat "$T/untimed")"
}
place() { chmod -R u+w "$T/game"; rm -f "$T/game/"*; cp "$T/content" "$T/game/$SHA.html"; chmod 0400 "$T/game/$SHA.html"; }
SERVE="serve --service=svc:game --https=443 --yes $T/game/$SHA.html"
CLR="serve clear svc:game"

place; run verify
[ $rc -eq 0 ] && [ -z "$log" ] && ok || bad "verify absent service: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON='{"Services":{"svc:game":null}}' run verify
[ $rc -eq 0 ] && [ -z "$log" ] && ok || bad "verify null service: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=null run verify
[ $rc -eq 0 ] && [ -z "$log" ] && [[ "$out" == *"verify ok"* ]] && ok || bad "verify null Serve config: rc=$rc log=$log err=$err"

serve_status() {
  jq -cn --argjson handler "$1" \
    '{Services: {"svc:game": {TCP: {"443": {HTTPS: true}}, Web: {"game.example.ts.net:443": {Handlers: {"/": $handler}}}}}}'
}
game_status=$(serve_status "$(jq -cn --arg path "$T/game/$SHA.html" '{Path: $path}')")
FAKE_SERVE_STATUS_JSON="$game_status" run verify
[ $rc -eq 0 ] && [ -z "$log" ] && [[ "$out" == *"verify ok"* ]] && ok || bad "verify pinned mapping: rc=$rc log=$log err=$err"

PDIR="$T/game/" FAKE_SERVE_STATUS_JSON="$game_status" run verify
[ $rc -eq 0 ] && [ -z "$log" ] && ok || bad "verify directory with trailing slash: rc=$rc log=$log err=$err"

FAKE_NOT_RUNNING=1 FAKE_SERVE_STATUS_JSON="$game_status" run verify
[ $rc -eq 1 ] && [ -z "$log" ] && [[ "$err" == *"tailnet DNS suffix is unavailable"* ]] && ok \
  || bad "verify with no tailnet DNS suffix: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(jq -c '.Services["svc:game"].TCP["8443"] = {HTTPS: true}' <<< "$game_status") run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify extra TCP port: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(jq -c '.Services["svc:game"].TCP["443"] = {HTTP: true}' <<< "$game_status") run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify plain HTTP on 443: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(serve_status '{"Path":"/another.html"}') run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify wrong mapping: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(serve_status '{"Proxy":"http://127.0.0.1:8080/"}') run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify proxy mapping: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(serve_status '{"Text":"hello"}') run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify text mapping: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(jq -c '.Services["svc:game"].Web = []' <<< "$game_status") run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify malformed mapping: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(jq -c '.Services["svc:game"].Web |= with_entries(.key = "game.other.ts.net:443")' <<< "$game_status") run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify wrong service host: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(jq -c '.Services["svc:game"].Web |= . + {"other.example.ts.net:443": .["game.example.ts.net:443"]}' <<< "$game_status") run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify additional host with the pinned file: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(jq -c '.Services["svc:game"].Tun = true' <<< "$game_status") run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify unexpected Tun field: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(jq -c '.Services["svc:game"].Web["game.example.ts.net:443"].Extra = true' <<< "$game_status") run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && ok || bad "verify unexpected Web field: rc=$rc log=$log err=$err"

FAKE_SERVE_STATUS_JSON=$(jq -c '.Services["svc:other"] = {Tun: true}' <<< "$game_status") run verify
[ $rc -eq 0 ] && [ -z "$log" ] && [[ "$out" == *"verify ok"* ]] && ok || bad "verify ignores other services: rc=$rc log=$log err=$err"

for miss in 1 2; do
  FAKE_SERVE_STATUS_FAIL=1 run verify
  [ $rc -eq 0 ] && [ -z "$log" ] && [[ "$out" == *"Serve status unavailable"* ]] && ok \
    || bad "verify status miss $miss: rc=$rc log=$log out=$out err=$err"
done
for miss in 3 4; do
  FAKE_SERVE_STATUS_FAIL=1 run verify
  [ $rc -eq 1 ] && [ -z "$log" ] && [[ "$err" == *"Serve status unavailable"* ]] && ok \
    || bad "verify status miss $miss must alert without clearing: rc=$rc log=$log err=$err"
done
FAKE_SERVE_STATUS_JSON="$game_status" run verify
[ $rc -eq 0 ] && [ -z "$log" ] && [[ "$out" == *"verify ok"* ]] && ok || bad "verify recovers: rc=$rc log=$log err=$err"
FAKE_SERVE_STATUS_FAIL=1 run verify
[ $rc -eq 0 ] && [ -z "$log" ] && [[ "$out" == *"Serve status unavailable"* ]] && ok \
  || bad "verify first miss after recovery: rc=$rc log=$log out=$out err=$err"
FAKE_SERVE_STATUS_JSON=null run verify
VERIFY_STATUS_FAILURE_THRESHOLD=1 FAKE_SERVE_STATUS_JSON='' run verify
[ $rc -eq 1 ] && [ -z "$log" ] && [[ "$err" == *"Serve status unavailable"* ]] && ok \
  || bad "verify custom threshold with empty status: rc=$rc log=$log err=$err"

run boot
[ $rc -eq 0 ] && [ "$log" = "$CLR"$'\n'"$SERVE" ] && ok || bad "boot: clear then serve: rc=$rc log=$log"

run stop
[ $rc -eq 0 ] && [ "$log" = "$CLR" ] && ok || bad "stop clears only: rc=$rc log=$log"
FAKE_NOT_RUNNING=1 run stop
[ $rc -eq 0 ] && [ "$log" = "$CLR" ] && ok || bad "stop does not wait for Running: rc=$rc log=$log"
FAKE_CLEAR_FAIL=1 run stop
[ $rc -ne 0 ] && ok || bad "stop with a failed clear must fail"

SERVICE_RESULT=success run stop-post
[ $rc -eq 0 ] && [ ! -s "$T/calls" ] && ok || bad "stop-post after success: rc=$rc calls=$(cat "$T/calls") err=$err"
SERVICE_RESULT=exit-code run stop-post
[ $rc -eq 0 ] && [ "$log" = "$CLR" ] && ok || bad "stop-post after failure: rc=$rc log=$log err=$err"
run stop-post
[ $rc -eq 0 ] && [ "$log" = "$CLR" ] && ok || bad "stop-post with SERVICE_RESULT unset: rc=$rc log=$log err=$err"
SERVICE_RESULT=exit-code FAKE_CLEAR_FAIL=1 run stop-post
[ $rc -ne 0 ] && [ "$log" = "$CLR"$'\n'"$CLR"$'\n'"$CLR" ] && [[ "$err" == *"CLEAR FAILED"* ]] && ok \
  || bad "stop-post after a failed clear: rc=$rc log=$log err=$err"

chmod -R u+w "$T/game"; rm -f "$T/game/"*; run verify
[ $rc -ne 0 ] && [ "$log" = "$CLR" ] && ok || bad "missing: rc=$rc log=$log"

place; chmod u+w "$T/game/$SHA.html"; printf 'X' >> "$T/game/$SHA.html"; chmod 0400 "$T/game/$SHA.html"; run verify
[ $rc -ne 0 ] && [ "$log" = "$CLR" ] && ok || bad "length change: rc=$rc log=$log"

place; chmod u+w "$T/game/$SHA.html"; printf 'jello game\n' > "$T/game/$SHA.html"; chmod 0400 "$T/game/$SHA.html"; run verify
[ $rc -ne 0 ] && [ "$log" = "$CLR" ] && ok || bad "byte flip: rc=$rc log=$log"

chmod -R u+w "$T/game"; rm -f "$T/game/"*; ln -s "$T/content" "$T/game/$SHA.html"; run verify
[ $rc -ne 0 ] && [ "$log" = "$CLR" ] && ok || bad "symlink: rc=$rc log=$log"

place; chmod 0444 "$T/game/$SHA.html"; run verify
[ $rc -ne 0 ] && [ "$log" = "$CLR" ] && case "$err" in *"mode 0400"*) true;; *) false;; esac && ok || bad "mode 0444 refused: rc=$rc log=$log err=$err"

place; chmod 0755 "$T/game"
run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && [[ "$err" == *"directory must be root-owned mode 0700"* ]] && ok || bad "verify directory mode 0755: rc=$rc log=$log err=$err"
run boot
[ $rc -eq 1 ] && [ "$log" = "$CLR"$'\n'"$CLR" ] && [[ "$err" == *"directory must be root-owned mode 0700"* ]] && ok || bad "boot directory mode 0755: rc=$rc log=$log err=$err"
chmod 0700 "$T/game"

mv "$T/game" "$T/real-game"
ln -s "$T/real-game" "$T/game"
run verify
[ $rc -eq 1 ] && [ "$log" = "$CLR" ] && [[ "$err" == *"directory is a symlink"* ]] && ok || bad "verify symlink directory: rc=$rc log=$log err=$err"
run boot
[ $rc -eq 1 ] && [ "$log" = "$CLR"$'\n'"$CLR" ] && [[ "$err" == *"directory is a symlink"* ]] && ok || bad "boot symlink directory: rc=$rc log=$log err=$err"
rm "$T/game"
mv "$T/real-game" "$T/game"

place; FAKE_SERVE_FAIL=1 run boot
[ $rc -ne 0 ] && [ "$log" = "$CLR"$'\n'"$SERVE"$'\n'"$SERVE"$'\n'"$SERVE"$'\n'"$CLR" ] && ok \
  || bad "serve failure: 3 attempts, then clear: rc=$rc log=$log"

place; chmod u+w "$T/game/$SHA.html"; printf 'jello game\n' > "$T/game/$SHA.html"; chmod 0400 "$T/game/$SHA.html"; FAKE_CLEAR_FAIL=1 run verify
[ $rc -ne 0 ] && case "$err" in *"CLEAR FAILED"*) true;; *) false;; esac && case "$err" in *"cleared"*) false;; *) true;; esac && ok \
  || bad "failed clear is reported, not claimed: rc=$rc err=$err"

place; FAKE_NOT_RUNNING=1 PWAIT=2 run boot
[ $rc -ne 0 ] && [ "$log" = "$CLR" ] && case "$err" in *"svc:game cleared"*) true;; *) false;; esac && ok \
  || bad "not Running: never serves, clears, fails: rc=$rc log=$log err=$err"

FAKE_CLEAR_FAIL=1 FAKE_NOT_RUNNING=1 PWAIT=1 run boot
[ $rc -ne 0 ] && case "$err" in *"CLEAR FAILED"*) true;; *) false;; esac && ok \
  || bad "not Running: failed clear is reported: rc=$rc err=$err"

place; PSHA=abc run verify
[ $rc -ne 0 ] && [ "$log" = "$CLR" ] && ok || bad "short pin: rc=$rc log=$log"
place; PSHA=$(printf '%s' "$SHA" | tr 'a-f' 'A-F') run verify
[ $rc -ne 0 ] && ok || bad "uppercase pin must be refused"

place; run bogus
[ $rc -eq 2 ] && [ -z "$log" ] && ok || bad "unknown mode: rc=$rc log=$log"

place; FAKE_NOT_RUNNING=1 PWAIT=2 run verify
[ $rc -eq 0 ] && [ -z "$log" ] && ok || bad "verify while not Running, valid file: no change: rc=$rc log=$log"
place; chmod u+w "$T/game/$SHA.html"; printf 'jello game\n' > "$T/game/$SHA.html"; chmod 0400 "$T/game/$SHA.html"; FAKE_NOT_RUNNING=1 PWAIT=2 run verify
[ $rc -ne 0 ] && [ "$log" = "$CLR" ] && ok || bad "verify while not Running, bad file: still revoked: rc=$rc log=$log"

# the lock serialises writers: while it is held a run never reaches tailscale, and gives up
place; exec 8>"$T/lock"; flock 8
PLOCKWAIT=1 run boot
[ $rc -ne 0 ] && [ -z "$log" ] && case "$err" in *"lock busy"*) true;; *) false;; esac && ok || bad "held lock blocks: rc=$rc log=$log err=$err"
exec 8>&-
place; run boot
[ $rc -eq 0 ] && ok || bad "released lock: rc=$rc"

for m in verify boot stop; do place; run $m; case "$log" in *reset*) bad "$m called a reset";; *) ok;; esac; done
echo "svc-game tests: $pass passed, $failn failed"
[ $failn -eq 0 ]
