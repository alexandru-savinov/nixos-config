# Runs tests/choir-diag.sh against hosts/sancta-choir/choir-diag.sh (fake tools on PATH).
{ pkgs }:
pkgs.runCommand "choir-diag-tests"
{
  nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.util-linux ];
} ''
  bash ${./choir-diag.sh} ${../hosts/sancta-choir/choir-diag.sh}
  touch $out
''
