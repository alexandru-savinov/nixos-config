# Runs tests/svc-game.sh against hosts/sancta-choir/svc-game.sh (fake tailscale).
{ pkgs }:
pkgs.runCommand "svc-game-tests"
{
  nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.jq pkgs.util-linux ];
} ''
  bash ${./svc-game.sh} ${../hosts/sancta-choir/svc-game.sh}
  touch $out
''
