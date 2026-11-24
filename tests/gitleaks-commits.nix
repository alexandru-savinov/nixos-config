# Runs tests/gitleaks-commits-test.sh against scripts/ci/gitleaks-commits.sh.
{ pkgs }:
pkgs.runCommand "gitleaks-commits-tests"
{
  nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gitleaks pkgs.git pkgs.gnugrep pkgs.gnused ];
} ''
  mkdir -p repo/tests repo/scripts/ci
  cp ${./gitleaks-commits-test.sh} repo/tests/gitleaks-commits-test.sh
  cp ${../scripts/ci/gitleaks-commits.sh} repo/scripts/ci/gitleaks-commits.sh
  cp ${../.gitleaks.toml} repo/.gitleaks.toml
  export HOME=$TMPDIR
  bash repo/tests/gitleaks-commits-test.sh
  touch $out
''
