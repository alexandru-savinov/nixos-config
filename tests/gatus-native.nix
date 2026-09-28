{ pkgs, settings }:
let
  configuration = pkgs.writeText "gatus-native-evaluated.json" (builtins.toJSON settings);
in
pkgs.runCommand "gatus-native-acceptance"
{
  nativeBuildInputs = [ pkgs.nodejs pkgs.gatus ];
}
  ''
    GATUS_BIN=${pkgs.gatus}/bin/gatus \
    ANKI_UI_WORKFLOW=${../n8n-workflows/image-to-anki-ui.json} \
    NIXFRAME_UI_WORKFLOW=${../n8n-workflows/nixframe-ui.json} \
      node ${./gatus-native.test.mjs} ${configuration}
    touch "$out"
  ''
