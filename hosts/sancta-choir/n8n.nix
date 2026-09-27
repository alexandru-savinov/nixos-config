# n8n on sancta-choir — studio slice 1 (sq085).
#
# n8n sits next to the production engine as the conductor of the chain
# idea → scene → ENGINE → reality guards → manifest. It never touches
# physics, pixels, reality/PII judgement or a model; the walls for that are
# in ./n8n-guard.nix and hold even while this module is off.
#
# Reuses the host-agnostic modules/services/n8n.nix unchanged. Deliberately
# NOT copied from rpi5-full: model keys (forbidden here), Telegram, admin
# password, community packages, child_process built-ins, the relaxed
# blockEnvAccessInCode, and the rpi5 workflow set.
#
# OFF until the encryption key exists. The shared module requires
# encryptionKeyFile, and this host gets its OWN new key (not rpi5's), which
# is created from Alexandru's terminal, never by an agent:
#
#   1. secrets/secrets.nix: add
#        "n8n-encryption-key-choir.age".publicKeys = users ++ [ sancta-choir ];
#   2. openssl rand -hex 32 | agenix -e secrets/n8n-encryption-key-choir.age
#   3. hosts/sancta-choir/studio-n8n-gate.nix: default = true; (the one
#      shared fact — rpi5-full's Gatus dashboard follows the same flip)
#
# Step 3 without step 2 fails evaluation (assertion below) instead of
# evaluating green and failing at activation: lib/secrets.nix builds the
# .age path as a string, so nothing else would notice the file is missing.
#
# Still after the switch (not in this module): the `production run <id>`
# runner the slice-1 workflow calls, and the slice-1 closing check
# (execution success, mp4_sha256 == direct CLI run, unsourced parameter →
# guard exit 1 → red execution).
{ config, lib, self, ... }:
let
  cfg = config.sancta.studio.n8n;
  keyName = "n8n-encryption-key-choir";
  inherit (import ../../lib/secrets.nix { inherit self; }) secret;
in
{
  imports = [
    ../../modules/services/n8n.nix
    ./n8n-guard.nix
    ./studio-n8n-gate.nix
  ];

  options.sancta.studio.n8n.enable = lib.mkEnableOption ''
    n8n as the studio conductor on sancta-choir (sq085 slice 1). Requires
    secrets/${keyName}.age to exist'';

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.pathExists config.age.secrets.${keyName}.file;
        message = ''
          sancta.studio.n8n.enable = true, but ${toString config.age.secrets.${keyName}.file} does not exist.
          Create the choir n8n encryption key first (see hosts/sancta-choir/n8n.nix header).
        '';
      }
    ];

    # root-owned: only n8n's root ExecStartPre reads it into /run/n8n/env.
    age.secrets.${keyName} = secret keyName;

    services.n8n-tailscale = {
      enable = true;
      encryptionKeyFile = config.age.secrets.${keyName}.path;
      # 127.0.0.1:5678 → https://<choir>.ts.net:5678 on the tailnet only.
      tailscaleServe.enable = true;
      # Only the choir set, never the rpi5 set in the parent directory
      # (the sync unit globs <dir>/*.json, so the subdirectory is invisible
      # to rpi5-full). Validated by checks.n8n-workflows-valid.
      workflowsDir = "${self}/n8n-workflows/choir";
    };

    # Availability only ("does it answer", never what it does), through the
    # existing vigil channel. Lives in its own directory so it is watched
    # exactly when n8n exists; configuration.nix counts it in
    # services.vigil.expectedContracts.
    services.vigil.contractsDirs = [ ./vigil-contracts-n8n ];
  };
}
