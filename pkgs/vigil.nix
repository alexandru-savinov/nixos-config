{ lib, stdenvNoCC, nodejs, makeWrapper, systemd }:

stdenvNoCC.mkDerivation {
  pname = "vigil";
  version = "1.0.0";
  src = ./vigil;
  nativeBuildInputs = [ nodejs makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    node vigil.mjs autoproba
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/vigil $out/bin
    cp -r . $out/libexec/vigil/
    for program in vigil vigil-check vigil-say vigil-tick; do
      makeWrapper ${nodejs}/bin/node $out/bin/$program \
        --add-flags "$out/libexec/vigil/$program.mjs" \
        --set-default VIGIL_BIN "$out/bin/vigil" \
        --set-default VIGIL_SYSTEMCTL "${systemd}/bin/systemctl"
    done
    runHook postInstall
  '';
  meta = {
    description = "Deterministic service checks, incident delivery and peer freshness";
    platforms = [ "aarch64-linux" "x86_64-linux" ];
    mainProgram = "vigil";
    license = lib.licenses.mit;
  };
}
