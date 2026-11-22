{ lib, stdenvNoCC, nodejs, makeWrapper, systemd }:

stdenvNoCC.mkDerivation {
  pname = "vigil";
  version = "1.0.0";
  src = ./vigil;
  nativeBuildInputs = [ nodejs makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;
  # A few tests check the real sancta-choir SOC contracts (labels, paging,
  # stamp thresholds); the host directory is not under ./vigil, so it is
  # handed in here. Outside the build they read it relative to the repo.
  checkPhase = ''
    runHook preCheck
    export VIGIL_SOC_CONTRACTS_DIR=${../hosts/sancta-choir/vigil-contracts}
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
