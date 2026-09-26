{ lib, runCommand, python3, bash, integration ? false, zmx ? null }:

runCommand (if integration then "agterm-zmx-integration-tests" else "agterm-zmx-protocol-tests")
{ nativeBuildInputs = [ python3 bash ] ++ lib.optional integration zmx; }
  ''
    cp -r ${../scripts/agterm-zmx} scripts
    cp ${../tests/test_agterm_zmx.py} test_agterm_zmx.py
    export AGT_ZMX_SCRIPTS=$PWD/scripts
    ${lib.optionalString integration "export AGT_ZMX_TEST_BINARY=${zmx}/bin/zmx"}
    python -m unittest -v test_agterm_zmx${lib.optionalString (!integration) ".ProtocolTests"}
    touch $out
  ''
