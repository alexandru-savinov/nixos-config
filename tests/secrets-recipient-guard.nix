# Guard against agenix recipient drift and fail-open corruption (#448).
#
# Two mechanical checks over secrets/*.age:
#
# 1. Recipient drift: the number of `-> ` recipient stanzas in each .age
#    header must equal the number of (unique) publicKeys declared for that
#    file in secrets/secrets.nix. Drift means the file was re-encrypted
#    against a stale declaration (or never re-keyed after one changed) —
#    extra recipients violate least privilege, missing ones break hosts.
#
# 2. Empty-plaintext corruption signature: when agenix re-encrypts on a
#    host whose SSH host key rotated away from the existing recipients, it
#    fails open and encrypts EMPTY plaintext. The result is well-formed but
#    its binary payload is exactly 32 bytes (16B STREAM nonce + 16B tag of
#    a zero-length chunk). Flag any payload <= 32 bytes.
#
# Also flags .age files present on disk but not declared (undecryptable
# orphans) and declared files missing on disk (the registered-but-never-
# created footgun that fails agenix activation at deploy time).
{ pkgs }:
let
  lib = pkgs.lib;
  declared = lib.mapAttrs (_: v: builtins.length (lib.unique v.publicKeys)) (
    import ../secrets/secrets.nix
  );
  declaredJson = pkgs.writeText "declared-recipients.json" (builtins.toJSON declared);
in
pkgs.runCommand "secrets-recipient-guard"
{
  nativeBuildInputs = [ pkgs.jq ];
  secrets = lib.fileset.toSource {
    root = ../secrets;
    fileset = lib.fileset.fileFilter (f: lib.hasSuffix ".age" f.name) ../secrets;
  };
}
  ''
    fail=0

    cd "$secrets"
    for f in *.age; do
      expected=$(jq -r --arg f "$f" '.[$f] // empty' ${declaredJson})
      if [ -z "$expected" ]; then
        echo "ERROR: secrets/$f exists on disk but is not declared in secrets/secrets.nix"
        fail=1
        continue
      fi

      actual=$(grep -ac '^-> ' "$f" || true)
      if [ "$actual" -ne "$expected" ]; then
        echo "ERROR: secrets/$f has $actual recipient stanzas on disk, but secrets.nix declares $expected — re-key with 'cd secrets && agenix -r' from a host whose key matches the on-disk recipients (see docs/SECRETS-ROTATION.md)"
        fail=1
      fi

      # Payload size = file size minus ASCII header (everything through the
      # '--- <MAC>' line). 32 bytes = encryption of empty plaintext.
      size=$(stat -c%s "$f")
      macoffset=$(grep -abm1 -- '^---' "$f" | cut -d: -f1)
      maclen=$(grep -am1 -- '^---' "$f" | wc -c)
      payload=$((size - macoffset - maclen))
      if [ "$payload" -le 32 ]; then
        echo "ERROR: secrets/$f payload is $payload bytes — empty-plaintext fail-open signature (see docs/SECRETS-ROTATION.md); restore from git history"
        fail=1
      fi
    done

    # Declared but missing on disk: agenix activation would fail the whole
    # nixos-rebuild switch on any host that wires this secret.
    for f in $(jq -r 'keys[]' ${declaredJson}); do
      if [ ! -f "$f" ]; then
        echo "ERROR: secrets/$f is declared in secrets.nix but missing on disk — create it with 'cd secrets && agenix -e $f' before any host references it"
        fail=1
      fi
    done

    if [ "$fail" -ne 0 ]; then
      echo "secrets-recipient-guard: FAILED"
      exit 1
    fi
    echo "secrets-recipient-guard: all $(ls *.age | wc -l) .age files match their declarations"
    touch $out
  ''
