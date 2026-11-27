{ pkgs }:
pkgs.runCommand "rpi5-serve-tests"
{
  nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.diffutils pkgs.jq ];
} ''
  bash ${./rpi5-serve.sh} ${../hosts/rpi5-full/rpi5-serve.sh}
  touch $out
''
