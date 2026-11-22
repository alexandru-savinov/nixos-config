# The promotion rule of sancta-soc-page, driven in both directions.
#
# WHAT IT DRIVES: the REAL wrapper the unit executes — the store path taken
# from sancta-choir's rendered ExecStart, passed as a whole string so its
# store-path context realises it into this sandbox.
#
# Arms live in tests/sancta-soc-page-arms.sh (also runnable by hand).
#
# WHAT IT DOES NOT PROVE, said plainly: gallery/soc.mjs and gallery/publish.mjs
# live on the LUKS soul volume, which no build sandbox can read. The arms use
# STUBS with the same contract (generator writes soc.html + soc-decide.html
# beside --out, or exits non-zero; gate exits 0 and writes <file>.passed with
# the sha256, or exits 1 FAIL / 2 CLOSED and writes nothing). What is proven is
# the wrapper's rule: a refused or missing page never replaces a served one,
# and only a fully passed pair is promoted. The real generator + real gate run
# was done by hand on choir; that evidence is in the PR body.

{ pkgs
, self
,
}:

let
  svc = self.nixosConfigurations.sancta-choir.config.systemd.services.sancta-soc-page;
in
pkgs.runCommand "sancta-soc-page-arms"
{
  execStart = toString svc.serviceConfig.ExecStart;
  mirrorExcludes = builtins.concatStringsSep " " self.nixosConfigurations.sancta-choir.config.services.sancta-soul-mirror.excludePatterns;
  nativeBuildInputs = with pkgs; [
    bash
    nodejs
    jq
    coreutils
    util-linux
    gawk
  ];
} ''
  set -u
  WRAPPER=$(printf '%s' "$execStart" | awk '{print $2}')
  if [ ! -r "$WRAPPER" ]; then
    echo "SELF-TEST FAILED: could not realise the unit's wrapper ($WRAPPER)" >&2
    exit 1
  fi
  bash ${./sancta-soc-page-arms.sh} "$WRAPPER"

  # (c) The soul mirror must never archive a soc-page stage.
  set -f
  for pat in $mirrorExcludes; do
    [ "$pat" = "index/gallery/.soc-stage.*" ] && found=1
  done
  [ "''${found:-0}" = 1 ] || { echo "FAIL: mirror excludePatterns lacks index/gallery/.soc-stage.*" >&2; exit 1; }
  echo "ok   soul-mirror excludePatterns contains index/gallery/.soc-stage.*"
  echo "sancta-soc-page: all arms passed" > $out
''
