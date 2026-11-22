# choir-store-gc body. Keeps the newest KEEP system generations PLUS the
# booted generation (/run/booted-system) and the current one, whatever their
# age: the booted one is the only known-good boot target. Deletes an explicit
# list instead of `+N`. If the booted system cannot be resolved, nothing is
# deleted (fail closed).
#
# Also keeps whatever /run/current-system runs (it can differ from the profile
# after a manual rollback).
#
# Test seams (env): PROFILE, BOOTED_SYSTEM, CURRENT_SYSTEM, NIX_ENV, NIX_GC.
set -euo pipefail
KEEP=${KEEP:-10}
PROFILE=${PROFILE:-/nix/var/nix/profiles/system}
NIX_ENV=${NIX_ENV:-nix-env}
NIX_GC=${NIX_GC:-nix-collect-garbage}

log() { echo "choir-store-gc: $*"; }

booted=$(readlink -f "${BOOTED_SYSTEM:-/run/booted-system}") || booted=""
current=$(readlink -f "$PROFILE") || current=""
running=$(readlink -f "${CURRENT_SYSTEM:-/run/current-system}") || running=""
if [ -z "$booted" ] || [ ! -e "$booted" ]; then
  log "cannot resolve booted system; refusing to delete anything"
  exit 1
fi

nums=$(ls -1d "$PROFILE"-*-link 2>/dev/null \
  | sed -E 's|.*/[^/]*-([0-9]+)-link$|\1|' | sort -n || true)
total=$(printf '%s\n' "$nums" | grep -c . || true)
log "$total system generations; keeping newest $KEEP plus booted ($booted), profile ($current) and running ($running)"

del=""; kept=""; idx=0
for n in $nums; do
  idx=$((idx + 1))
  link=$PROFILE-$n-link
  top=$(readlink -f "$link" || echo "?")
  rev=$(cat "$top/configuration-revision" 2>/dev/null || echo "n/a")
  why=""
  if [ $((total - idx)) -lt "$KEEP" ]; then why="newest"; fi
  if [ "$top" = "$booted" ]; then why="$why booted"; fi
  if [ "$top" = "$current" ]; then why="$why current"; fi
  if [ -n "$running" ] && [ "$top" = "$running" ]; then why="$why running"; fi
  if [ -n "$why" ]; then
    kept="$kept $n"; log "generation $n -> $top revision=$rev [keep:${why}]"
  else
    del="$del $n"; log "generation $n -> $top revision=$rev [DELETE]"
  fi
done
log "kept set:${kept:- none}"
log "delete set:${del:- none}"

if [ -n "$del" ]; then
  # shellcheck disable=SC2086
  $NIX_ENV -p "$PROFILE" --delete-generations $del
fi
$NIX_GC
