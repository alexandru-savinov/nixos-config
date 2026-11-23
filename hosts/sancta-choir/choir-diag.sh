# choir-diag: forced-command dispatcher for the read-only `diag` account.
#
# sshd runs this for every diag login and passes the client's requested command
# in SSH_ORIGINAL_COMMAND. That string is split on whitespace into words (no
# eval, no shell expansion, no globbing) and matched against a fixed verb list.
# Every word that reaches a tool was validated against a strict pattern first.
# Anything else prints "refused" and exits 2.
#
# Test seams (env, never reachable from an ssh client under `restrict`):
# CHOIR_DIAG_PROFILE_DIR, CHOIR_DIAG_CURRENT, CHOIR_DIAG_BOOTED.
set -euo pipefail

unit_re='^[A-Za-z0-9@._:][A-Za-z0-9@._:-]{0,127}\.(service|timer|socket|target|mount|path)$'
num_re='^[0-9]{1,4}$'
since_re='^([0-9]{1,5})(min|h|d)$'

usage() {
  cat <<'USAGE'
usage: <verb> [args]
  status <unit>            systemctl status
  is-active <unit>         systemctl is-active
  failed                   systemctl --failed
  journal <unit> [N] [SINCE]   last N lines (default 100, max 2000); SINCE = Nmin|Nh|Nd, up to 30d
  df | free | uptime | listeners | tailscale | generations
USAGE
}

refuse() {
  echo "refused"
  exit 2
}

raw="${SSH_ORIGINAL_COMMAND:-}"
# Log every request, control characters replaced so a client cannot forge lines.
logger -t choir-diag "${raw//[^[:print:]]/?}"

# `read` consumes one line only; a multi-line command must not pass as its first line.
if [[ "$raw" == *$'\n'* || "$raw" == *$'\r'* ]]; then
  refuse
fi

words=()
read -ra words <<<"$raw" || true

if [ "${#words[@]}" -eq 0 ]; then
  usage
  exit 2
fi

verb="${words[0]}"
argc=$((${#words[@]} - 1))

valid_unit() {
  [[ "$1" =~ $unit_re ]]
}

case "$verb" in
  status | is-active)
    [ "$argc" -eq 1 ] || refuse
    valid_unit "${words[1]}" || refuse
    exec systemctl --no-pager "$verb" "${words[1]}"
    ;;
  failed)
    [ "$argc" -eq 0 ] || refuse
    exec systemctl --no-pager --failed
    ;;
  journal)
    { [ "$argc" -ge 1 ] && [ "$argc" -le 3 ]; } || refuse
    valid_unit "${words[1]}" || refuse
    n=100
    if [ "$argc" -ge 2 ]; then
      [[ "${words[2]}" =~ $num_re ]] || refuse
      n=$((10#${words[2]}))
      { [ "$n" -ge 1 ] && [ "$n" -le 2000 ]; } || refuse
    fi
    since=()
    if [ "$argc" -eq 3 ]; then
      [[ "${words[3]}" =~ $since_re ]] || refuse
      amount=$((10#${BASH_REMATCH[1]}))
      unit="${BASH_REMATCH[2]}"
      case "$unit" in
        min) max=43200 ;;
        h) max=720 ;;
        d) max=30 ;;
      esac
      { [ "$amount" -ge 1 ] && [ "$amount" -le "$max" ]; } || refuse
      since=(--since "-${amount}${unit}")
    fi
    exec journalctl -u "${words[1]}" -n "$n" --no-pager ${since[@]+"${since[@]}"}
    ;;
  df | free | uptime)
    [ "$argc" -eq 0 ] || refuse
    exec "$verb"
    ;;
  listeners)
    [ "$argc" -eq 0 ] || refuse
    exec ss -ltn
    ;;
  tailscale)
    [ "$argc" -eq 0 ] || refuse
    exec tailscale status
    ;;
  generations)
    [ "$argc" -eq 0 ] || refuse
    profile_dir="${CHOIR_DIAG_PROFILE_DIR:-/nix/var/nix/profiles}"
    for link in "$profile_dir"/system-*-link; do
      [ -L "$link" ] || continue
      echo "${link##*/} -> $(readlink "$link")"
    done
    echo "current: $(readlink "${CHOIR_DIAG_CURRENT:-/run/current-system}")"
    echo "booted: $(readlink "${CHOIR_DIAG_BOOTED:-/run/booted-system}")"
    ;;
  *)
    refuse
    ;;
esac
