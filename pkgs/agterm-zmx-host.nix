{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  bash,
  zmx,
  systemd,
}:

stdenvNoCC.mkDerivation {
  pname = "agterm-zmx-host";
  version = "0.1.0";
  src = ../scripts/agterm-zmx;
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/libexec/agterm-zmx $out/bin
    cp host.py remote_ui.py $out/libexec/agterm-zmx/
    makeWrapper ${python3}/bin/python3 $out/bin/agt-ask \
      --add-flags "$out/libexec/agterm-zmx/remote_ui.py"
    ln -s agt-ask $out/bin/agt-ui
    makeWrapper ${python3}/bin/python3 $out/bin/agt-zmx-host \
      --add-flags "$out/libexec/agterm-zmx/host.py" \
      --prefix PATH : "$out/bin" \
      --prefix PATH : ${
        lib.makeBinPath [
          zmx
          bash
          systemd
        ]
      }
  '';
  meta = {
    description = "Isolated remote zmx sessions with per-session agterm status routing";
    platforms = lib.platforms.linux;
    mainProgram = "agt-zmx-host";
  };
}
