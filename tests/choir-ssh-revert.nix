# Runs tests/choir-ssh-revert.sh against hosts/sancta-choir/choir-ssh-revert.sh (fake tools).
{ pkgs }:
pkgs.runCommand "choir-ssh-revert-tests"
{
  nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.jq ];
} ''
  bash ${./choir-ssh-revert.sh} ${../hosts/sancta-choir/choir-ssh-revert.sh}
  touch $out
''
