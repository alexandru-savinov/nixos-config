# sancta-doctrine-guard-stamp.sh — record the guard's last outcome as ONE mtime.
#
# Runs as the guard unit's ExecStopPost, so systemd hands it SERVICE_RESULT,
# EXIT_CODE and EXIT_STATUS for the run that just ended. vigil reads the stamp
# with its existing file `age` check (a stat, nothing else), which is why the
# outcome is carried in the mtime and not in the content:
#
#   success           -> mtime = now          -> verde while younger than prag
#   anything else     -> mtime = epoch + 1s   -> picat (age-stale) on the next tick
#   guard never runs  -> mtime keeps ageing   -> picat once older than prag
#
# Epoch + 1s, not 0 and not a deleted file: vigil treats a missing file or a
# non-positive mtime as NECITIT (unreadable, a note), and a failed guard is not
# "unreadable", it is a fail. The file is empty and says nothing about WHAT
# failed; the reason stays in the journal, where the private names already are.
#
# Success is a conjunction of all three variables. Any value this script does
# not recognise, including an unset one, counts as failure: the stamp may only
# ever be moved forward by a run that systemd itself called clean.
set -euo pipefail

stamp="${SANCTA_DOCTRINE_STAMP:?SANCTA_DOCTRINE_STAMP is not set}"

if [ "${SERVICE_RESULT:-}" = success ] && [ "${EXIT_CODE:-}" = exited ] && [ "${EXIT_STATUS:-}" = 0 ]; then
  touch -- "$stamp"
else
  touch -d @1 -- "$stamp"
fi
