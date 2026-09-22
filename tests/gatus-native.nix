{ pkgs, settings }:
let
  configuration = pkgs.writeText "gatus-native-evaluated.json" (builtins.toJSON settings);
in
pkgs.runCommand "gatus-native-acceptance"
{
  nativeBuildInputs = [ pkgs.nodejs pkgs.gatus ];
}
  ''
    GATUS_BIN=${pkgs.gatus}/bin/gatus node ${./gatus-native.test.mjs} ${configuration}
    touch "$out"
  ''
