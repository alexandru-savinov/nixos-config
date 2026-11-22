# Runs tests/choir-tmp-session-reaper.sh against modules/services/choir-tmp-session-reaper.sh
# (fake /tmp, /proc and homes). Run: nix build .#checks.x86_64-linux.choir-tmp-session-reaper
{ pkgs }:
pkgs.runCommand "choir-tmp-session-reaper-tests"
{
  nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.util-linux ];
} ''
  bash ${./choir-tmp-session-reaper.sh} ${../modules/services/choir-tmp-session-reaper.sh}
  touch $out
''
