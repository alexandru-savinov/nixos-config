{ pkgs, settings }:

pkgs.runCommand "sancta-guard-wrapper-tests"
{
  nativeBuildInputs = [ pkgs.python3 pkgs.git pkgs.bash ];
}
  ''
    python3 ${./check_sancta_guard_wrapper.py} \
      ${pkgs.writeText "sancta-managed-settings.json" settings} \
      ${./fixtures/sancta-guard-protocol.py}
    touch $out
  ''
