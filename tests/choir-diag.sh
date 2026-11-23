#!/usr/bin/env bash
# Harness for hosts/sancta-choir/choir-diag.sh with fake tools on PATH.
# Every fake logs its exact argv; the harness compares that to the expected argv.
# Usage: choir-diag.sh <choir-diag.sh>
set -uo pipefail
script=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fake="$work/bin"
mkdir -p "$fake" "$work/profiles"
export LOG="$work/argv.log"
export MARKER="$work/pwned"

for t in systemctl journalctl ss df free uptime tailscale logger; do
  cat >"$fake/$t" <<'FAKE'
#!/usr/bin/env bash
{ printf '%s' "$(basename "$0")"; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >>"$LOG"
FAKE
  chmod +x "$fake/$t"
done

# generations fixture
mkdir -p "$work/store/sys-1" "$work/store/sys-2" "$work/store/sys-3"
ln -s "$work/store/sys-1" "$work/profiles/system-1-link"
ln -s "$work/store/sys-2" "$work/profiles/system-2-link"
ln -s "$work/profiles/system-2-link" "$work/profiles/system"
ln -s "$work/store/sys-2" "$work/current"
ln -s "$work/store/sys-1" "$work/booted"
export CHOIR_DIAG_PROFILE_DIR="$work/profiles" CHOIR_DIAG_CURRENT="$work/current" CHOIR_DIAG_BOOTED="$work/booted"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# run <cmd>: sets out, rc, log
run() {
  : >"$LOG"
  rm -f "$MARKER"
  out=$(SSH_ORIGINAL_COMMAND="$1" PATH="$fake:/usr/bin:/bin" bash "$script" 2>&1)
  rc=$?
  log=$(cat "$LOG")
}

# allow <cmd> <expected tool line>
allow() {
  run "$1"
  local want="logger [-t] [choir-diag] [$1]"$'\n'"$2"
  if [ "$rc" -eq 0 ] && [ "$log" = "$want" ]; then ok "allow: $1"; else
    bad "allow: $1 (rc=$rc)"; echo "  want: $want"; echo "  got:  $log"
  fi
}

# refuse <cmd> [expected-output]
refuse() {
  run "$1"
  local want="logger [-t] [choir-diag] [$(printf '%s' "$1" | tr -c '[:print:]' '?')]"
  if [ "$rc" -eq 2 ] && [ "$out" = "${2:-refused}" ] && [ "$log" = "$want" ] && [ ! -e "$MARKER" ]; then
    ok "refuse: $1"
  else
    bad "refuse: $1 (rc=$rc out=$out)"; echo "  log: $log"
  fi
}

allow "status foo.service" "systemctl [--no-pager] [status] [foo.service]"
allow "status a@b.c-d_e:f.timer" "systemctl [--no-pager] [status] [a@b.c-d_e:f.timer]"
allow "is-active sshd.service" "systemctl [--no-pager] [is-active] [sshd.service]"
allow "failed" "systemctl [--no-pager] [--failed]"
allow "  status    foo.socket  " "systemctl [--no-pager] [status] [foo.socket]"
allow "journal x.service" "journalctl [-u] [x.service] [-n] [100] [--no-pager]"
allow "journal x.service 2000" "journalctl [-u] [x.service] [-n] [2000] [--no-pager]"
allow "journal x.target 50 15min" "journalctl [-u] [x.target] [-n] [50] [--no-pager] [--since] [-15min]"
allow "journal x.mount 5 2h" "journalctl [-u] [x.mount] [-n] [5] [--no-pager] [--since] [-2h]"
allow "journal x.path 5 30d" "journalctl [-u] [x.path] [-n] [5] [--no-pager] [--since] [-30d]"
allow "journal x.path 5 720h" "journalctl [-u] [x.path] [-n] [5] [--no-pager] [--since] [-720h]"
allow "journal x.path 5 43200min" "journalctl [-u] [x.path] [-n] [5] [--no-pager] [--since] [-43200min]"
allow "df" "df"
allow "free" "free"
allow "uptime" "uptime"
allow "listeners" "ss [-ltn]"
allow "tailscale" "tailscale [status]"

# generations: no tool is called except logger; check output text.
run "generations"
want_gen="system-1-link -> $work/store/sys-1"$'\n'"system-2-link -> $work/store/sys-2"$'\n'"current: $work/store/sys-2"$'\n'"booted: $work/store/sys-1"
if [ "$rc" -eq 0 ] && [ "$out" = "$want_gen" ] && [ "$log" = "logger [-t] [choir-diag] [generations]" ]; then ok "allow: generations"; else
  bad "allow: generations"; echo "  out: $out"; echo "  log: $log"
fi

refuse 'status foo; id'
refuse 'status $(id).service'
refuse 'status $(touch '"$MARKER"').service'
refuse 'status `touch '"$MARKER"'`.service'
refuse 'journal x.service $(touch '"$MARKER"')'
refuse 'journal x.service 999999'
refuse 'journal x.service 2001'
refuse 'journal x.service 0'
refuse 'journal x.service 10 99999d'
refuse 'journal x.service 10 31d'
refuse 'journal x.service 10 721h'
refuse 'journal x.service 10 43201min'
refuse 'journal x.service 10 0d'
refuse 'journal x.service 10 5weeks'
refuse 'journal x.service 10 5d extra'
refuse 'journal x.service abc'
refuse 'rm -rf /'
refuse 'frobnicate'
refuse 'status foo'
refuse 'status foo.exe'
refuse 'status foo.service extra'
refuse 'status'
refuse 'status --version.service'
refuse 'status ../etc.service'
refuse 'status /etc/x.service'
refuse 'failed extra'
refuse 'df -h'
refuse 'is-active'
refuse $'failed\nrm -rf /'
refuse "status $(printf 'a%.0s' $(seq 1 129)).service"
allow "status $(printf 'a%.0s' $(seq 1 120)).service" "systemctl [--no-pager] [status] [$(printf 'a%.0s' $(seq 1 120)).service]"

# empty command: usage, exit 2
run ""
if [ "$rc" -eq 2 ] && [[ "$out" == usage:* ]] && [ "$log" = "logger [-t] [choir-diag] []" ]; then ok "empty command prints usage, exit 2"; else bad "empty command (rc=$rc)"; fi
run "   "
if [ "$rc" -eq 2 ] && [[ "$out" == usage:* ]]; then ok "blank command prints usage, exit 2"; else bad "blank command (rc=$rc)"; fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
