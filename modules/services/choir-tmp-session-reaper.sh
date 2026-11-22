# choir-tmp-session-reaper — remove whole, dead, idle /tmp/claude-<uid>/<proj>/<session>/ trees.
#
# A directory is removed ONLY if BOTH hold:
#   (i)  not live: no /proc/*/cwd or /proc/*/fd/* resolves under it, the
#        session id appears in no /proc/*/cmdline (covers `--resume <id>`,
#        `-r <id>`, `--session-id <id>`: a session resumed inside a zmx/agterm
#        pane is only visible there), and no /proc/*/environ contains the
#        session dir path. ANY error while checking means "live";
#   (ii) idle: the newest mtime in the tree is older than IDLE_DAYS, AND the
#        transcript ~uid/.claude/projects/<proj>/<session>.jsonl is older than
#        IDLE_DAYS or does not exist.
# EXCLUDE_SESSIONS (space-separated id prefixes) are never candidates.
# The delete runs AS THE OWNING UID (never root), on the literal path, with
# `find <path> -xdev -delete` (does not follow symlinks). DRY_RUN=1 only logs what would be removed.
# Any directory over ALERT_GIB gets a journal WARN (priority 4) line.
#
# Test seams (env): TMP_ROOT, PROC_ROOT, HOMES_ROOT (home = $HOMES_ROOT/<uid>
# instead of getent), RUN_AS (command prefix; default drops to the owner uid).
set -euo pipefail

TMP_ROOT=$(readlink -f "${TMP_ROOT:-/tmp}")
PROC_ROOT=${PROC_ROOT:-/proc}
DRY_RUN=${DRY_RUN:-1}
IDLE_DAYS=${IDLE_DAYS:-7}
ALERT_GIB=${ALERT_GIB:-10}
NOW=${NOW:-$(date +%s)}
cutoff=$((NOW - IDLE_DAYS * 86400))

log() { echo "choir-tmp-session-reaper: $*"; }
warn() { echo "<4>choir-tmp-session-reaper: WARN $*"; }

home_of() { # uid -> home dir
  if [ -n "${HOMES_ROOT:-}" ]; then echo "$HOMES_ROOT/$1"; else getent passwd "$1" | cut -d: -f6; fi
}
gid_of() {
  if [ -n "${HOMES_ROOT:-}" ]; then echo "$1"; else getent passwd "$1" | cut -d: -f4; fi
}

# Live if the session id is in any cmdline, cwd/fd resolves under $1, or any
# environ mentions $1. Any read error returns live (0): when in doubt, keep.
is_live() {
  local dir=$1 sid=$2 uid=$3 p t f rc po
  for p in "$PROC_ROOT"/[0-9]*; do
    [ -d "$p" ] || continue
    rc=0; grep -qaF -- "$sid" "$p/cmdline" 2>/dev/null || rc=$?
    [ "$rc" = 1 ] || return 0 # 0 = match, >1 = could not read
    rc=0; grep -qaF -- "$dir" "$p/environ" 2>/dev/null || rc=$?
    if [ "$rc" != 1 ]; then
      # Match, or unreadable. Unreadable only counts when the process belongs
      # to the directory's owner (or its owner cannot be determined).
      [ "$rc" = 0 ] && return 0
      po=$(stat -c %u "$p" 2>/dev/null) || return 0
      [ "$po" = "$uid" ] && return 0
    fi
    t=$(readlink "$p/cwd" 2>/dev/null) || return 0
    case "$t" in "$dir" | "$dir"/*) return 0 ;; esac
    [ -r "$p/fd" ] || return 0
    for f in "$p"/fd/*; do
      [ -L "$f" ] || continue
      t=$(readlink "$f" 2>/dev/null) || return 0
      case "$t" in "$dir" | "$dir"/*) return 0 ;; esac
    done
  done
  return 1
}

excluded() { # session id -> 0 when it matches an EXCLUDE_SESSIONS prefix
  local x
  for x in ${EXCLUDE_SESSIONS:-}; do
    case "$1" in "$x"*) return 0 ;; esac
  done
  return 1
}

newest_mtime() { # never follows symlinks (find -P is the default)
  find "$1" -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1
}

for udir in "$TMP_ROOT"/claude-*; do
  [ -d "$udir" ] && [ ! -L "$udir" ] || continue
  uid=${udir##*/claude-}
  case "$uid" in '' | *[!0-9]*) continue ;; esac
  [ "$uid" -gt 0 ] || { log "skip $udir: refusing uid 0"; continue; }
  home=$(home_of "$uid")
  for sdir in "$udir"/*/*/; do
    sdir=${sdir%/}
    [ -d "$sdir" ] && [ ! -L "$sdir" ] || continue
    [ "$(readlink -f "$sdir")" = "$sdir" ] || { log "skip $sdir: path is not canonical"; continue; }
    sid=${sdir##*/}
    proj=${sdir%/*}; proj=${proj##*/}
    if excluded "$sid"; then log "keep $sdir: excluded by configuration"; continue; fi
    kb=$(du -sk --one-file-system "$sdir" 2>/dev/null | cut -f1)
    kb=${kb:-0}
    if [ "$kb" -gt $((ALERT_GIB * 1024 * 1024)) ]; then
      warn "$sdir is $((kb / 1024 / 1024)) GiB (alert threshold ${ALERT_GIB} GiB)"
    fi

    [ "$(stat -c %u "$sdir")" = "$uid" ] || { log "keep $sdir: not owned by uid $uid"; continue; }
    if is_live "$sdir" "$sid" "$uid"; then log "keep $sdir: live"; continue; fi
    # No readable transcript root (e.g. soul volume not mounted) means we
    # cannot judge resumability: keep rather than guess.
    if [ -z "$home" ] || [ ! -d "$home/.claude/projects" ]; then
      log "keep $sdir: cannot see $home/.claude/projects"; continue
    fi
    newest=$(newest_mtime "$sdir")
    if [ -z "$newest" ] || [ "$newest" -ge "$cutoff" ]; then log "keep $sdir: tree modified within ${IDLE_DAYS}d"; continue; fi
    tx="$home/.claude/projects/$proj/$sid.jsonl"
    if [ -e "$tx" ]; then
      tm=$(stat -c %Y "$tx")
      if [ "$tm" -ge "$cutoff" ]; then log "keep $sdir: transcript fresh (resumable)"; continue; fi
    fi

    size=$(du -sh --one-file-system "$sdir" 2>/dev/null | cut -f1)
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN would remove $sdir ($size)"
    else
      log "removing $sdir ($size) as uid $uid"
      if [ -n "${RUN_AS:-}" ]; then
        # shellcheck disable=SC2086
        $RUN_AS find "$sdir" -xdev -delete
      else
        setpriv --reuid="$uid" --regid="$(gid_of "$uid")" --init-groups -- \
          find "$sdir" -xdev -delete
      fi
    fi
  done
done
