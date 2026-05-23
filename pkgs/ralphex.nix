# Ralphex — multi-step plan orchestrator for Claude Code agents.
# Upstream: https://github.com/umputun/ralphex (MIT, Go binary).
#
# Installed from upstream's prebuilt Linux release tarball. The Go binary is
# statically linked (verified via `file`), so no autoPatchelfHook is needed.
# Both aarch64-linux and x86_64-linux are supported by upstream; pick by host.
{ stdenv, fetchurl, lib }:

stdenv.mkDerivation rec {
  pname = "ralphex";
  version = "1.3.1";

  src = fetchurl (
    let
      sources = {
        "aarch64-linux" = {
          url = "https://github.com/umputun/ralphex/releases/download/v${version}/ralphex_${version}_linux_arm64.tar.gz";
          hash = "sha256-GIoFw8tzxflioBXF5Zz8AxwURcBSF8BpKYPEVj20lUc=";
        };
        "x86_64-linux" = {
          url = "https://github.com/umputun/ralphex/releases/download/v${version}/ralphex_${version}_linux_amd64.tar.gz";
          hash = "sha256-OJcT/r8zDFzIsn6Y44h8xomfs04EM2IUytM2J64vYIA=";
        };
      };
      system = stdenv.hostPlatform.system;
    in
      sources.${system} or (throw "ralphex: unsupported system ${system}")
  );

  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 ralphex $out/bin/ralphex
    runHook postInstall
  '';

  meta = with lib; {
    description = "Orchestrates AI coding agents to execute multi-step plans";
    homepage = "https://github.com/umputun/ralphex";
    license = licenses.mit;
    platforms = [ "aarch64-linux" "x86_64-linux" ];
    mainProgram = "ralphex";
  };
}
