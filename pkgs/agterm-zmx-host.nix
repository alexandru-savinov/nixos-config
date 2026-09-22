{ lib, stdenvNoCC, makeWrapper, python3, bash, zmx, systemd }:

stdenvNoCC.mkDerivation {
  pname = "agterm-zmx-host";
  version = "0.1.0";
  src = ../scripts/agterm-zmx;
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/libexec/agterm-zmx $out/bin
    cp host.py $out/libexec/agterm-zmx/host.py
    makeWrapper ${python3}/bin/python3 $out/bin/agt-zmx-host \
      --add-flags "$out/libexec/agterm-zmx/host.py" \
      --prefix PATH : ${lib.makeBinPath [ zmx bash systemd ]}
  '';
  meta = {
    description = "Isolated remote zmx sessions with per-session agterm status routing";
    platforms = lib.platforms.linux;
    mainProgram = "agt-zmx-host";
  };
}
