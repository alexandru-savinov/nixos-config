# Runs tests/choir-store-gc.sh against modules/services/choir-store-gc.sh (fake profile dir).
{ pkgs }:
pkgs.runCommand "choir-store-gc-tests"
{
  nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
} ''
  bash ${./choir-store-gc.sh} ${../modules/services/choir-store-gc.sh}
  touch $out
''
