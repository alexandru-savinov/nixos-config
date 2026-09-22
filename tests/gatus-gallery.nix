{ pkgs, settings }:
let
  configuration = pkgs.writeText "gatus-gallery-evaluated.json" (builtins.toJSON settings);
in
pkgs.runCommand "gatus-gallery-acceptance"
{
  nativeBuildInputs = [ pkgs.nodejs pkgs.gatus ];
}
  ''
    GATUS_BIN=${pkgs.gatus}/bin/gatus node ${./gatus-gallery.test.mjs} ${configuration}
    touch "$out"
  ''
