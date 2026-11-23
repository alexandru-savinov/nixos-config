#!/usr/bin/env bash
# Harness for modules/services/choir-store-gc.sh with a fake profile dir.
# Usage: choir-store-gc.sh <choir-store-gc.sh>
set -euo pipefail
GC=$1
W=$(cd "$(mktemp -d)" && pwd -P); trap 'find "$W" -delete 2>/dev/null' EXIT
fails=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }

P=$W/profiles; mkdir -p "$P" "$W/store" "$W/bin"
for n in $(seq 1 20); do
  mkdir -p "$W/store/sys-$n/sw/bin"
  printf '#!/bin/sh\n[ "$1" = --configuration-revision ] && echo rev%s\n' "$n" > "$W/store/sys-$n/sw/bin/nixos-version"
  chmod +x "$W/store/sys-$n/sw/bin/nixos-version"
  ln -s "$W/store/sys-$n" "$P/system-$n-link"
done
ln -s system-20-link "$P/system"
ln -s "$W/store/sys-6" "$W/booted"            # booted = 15th newest of 20
printf '#!/bin/sh\necho "$@" > "%s/nixenv.args"\n' "$W" > "$W/bin/nix-env"
printf '#!/bin/sh\necho ran > "%s/gc.ran"\n' "$W" > "$W/bin/gc"
chmod +x "$W/bin/nix-env" "$W/bin/gc"

ln -s "$W/store/sys-20" "$W/running"
run() { env KEEP=10 PROFILE="$P/system" BOOTED_SYSTEM="$W/booted" CURRENT_SYSTEM="$W/running" NIX_ENV="$W/bin/nix-env" NIX_GC="$W/bin/gc" bash "$GC" 2>&1; }

out=$(run); sed 's/^/    /' <<<"$out" | grep -E "kept set|delete set|booted"
args=$(cat "$W/nixenv.args")
case " $args " in *" 6 "*) bad "booted gen 6 is in the delete list" ;; *) ok "booted gen (15th newest) survives" ;; esac
[ "$args" = "-p $P/system --delete-generations 1 2 3 4 5 7 8 9 10" ] && ok "explicit delete list = everything else older than newest 10" || bad "unexpected delete args: $args"
grep -q "generation 6 .*\[keep: booted\]" <<<"$out" && ok "booted gen logged as kept" || bad "booted gen not logged"
grep -q "generation 20 .*revision=rev20" <<<"$out" && ok "toplevel + revision logged" || bad "revision not logged"
[ -f "$W/gc.ran" ] && ok "collect-garbage ran" || bad "gc did not run"

# current gen older than the window is also protected
ln -sfn system-3-link "$P/system"; : > "$W/nixenv.args"
out=$(run); args=$(cat "$W/nixenv.args")
case " $args " in *" 3 "*) bad "current gen 3 deleted" ;; *) ok "current gen survives" ;; esac
ln -sfn system-20-link "$P/system"

# the RUNNING system (/run/current-system) differs from the profile, e.g. after a manual rollback: it is protected too
ln -sfn "$W/store/sys-2" "$W/running"; : > "$W/nixenv.args"
out=$(run); args=$(cat "$W/nixenv.args")
case " $args " in *" 2 "*) bad "running gen 2 deleted" ;; *) ok "running gen (not the profile) survives" ;; esac
ln -sfn "$W/store/sys-20" "$W/running"

# booted system unresolvable => fail closed
find "$W/nixenv.args" "$W/gc.ran" -delete; ln -sfn "$W/store/gone" "$W/booted"
if out=$(run); then bad "ran with unresolvable booted system"; else
  [ ! -e "$W/nixenv.args" ] && [ ! -e "$W/gc.ran" ] && ok "unresolvable booted system => nothing deleted" || bad "deleted despite unresolvable booted"; fi

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
