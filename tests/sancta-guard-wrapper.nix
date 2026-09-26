{ pkgs, settings }:

pkgs.runCommand "sancta-guard-wrapper-tests"
{
  nativeBuildInputs = [ pkgs.python3 pkgs.git pkgs.bash ];
}
  ''
    cp ${./fixtures/sancta-guard-protocol.py} fixture-guard
    chmod +x fixture-guard
    patchShebangs fixture-guard
    python3 ${./check_sancta_guard_wrapper.py} \
      ${pkgs.writeText "sancta-managed-settings.json" settings} \
      "$PWD/fixture-guard"
    touch $out
  ''
