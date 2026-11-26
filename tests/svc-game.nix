# Runs tests/svc-game.sh against hosts/sancta-choir/svc-game.sh (fake tailscale).
{ pkgs }:
pkgs.runCommand "svc-game-tests"
{
  nativeBuildInputs = [ pkgs.bash pkgs.coreutils ];
} ''
  bash ${./svc-game.sh} ${../hosts/sancta-choir/svc-game.sh}
  touch $out
''
