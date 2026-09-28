# cache-trust — the trusted-public-keys allow-list.
#
# WHY THIS EXISTS
# ----------------
# sq099, from the NixCon 2026 talk "NixOS in the Corporate Trenches": a
# caching proxy or mirror placed in front of a binary cache can add its OWN
# signing key alongside (or instead of) the real one, and
# nix.settings.trusted-public-keys has no built-in notion of "this key is
# unexpected" — a host config just accumulates whatever any file sets on it.
# A future mirror/proxy for this fleet must not be able to make Nix trust a
# key nobody deliberately chose.
#
# This module is the notice. Any host that imports it gets an assertion that
# its own nix.settings.trusted-public-keys is a SUBSET of the allow-list
# below. To trust a new key, add it here FIRST — with a comment naming whose
# cache it is — before adding it to any host's trusted-public-keys. A key
# that lands in a host's settings without first landing on this list fails
# `nixos-rebuild switch` / `nix flake check` with that key named in the
# assertion message, instead of being silently trusted.
#
# tests/module-eval.nix carries both arms:
#   - positive: every real host's trusted-public-keys is checked against
#     this SAME allow-list (via the read-only option below, so the test
#     cannot drift from what this module actually enforces);
#   - negative: a synthetic host that imports this module and adds one
#     foreign key fails evaluation, and the failure message names that key.

{ config, lib, ... }:

let
  inherit (lib) mkOption types;

  allowedTrustedPublicKeys = [
    # cache.nixos.org — the official NixOS binary cache. Used by every host.
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="

    # nixos-raspberrypi.cachix.org — the nixos-raspberrypi project's cache
    # (prebuilt RPi5 kernel/bootloader packages, kernel 6.12.34).
    # Set in hosts/rpi5/configuration.nix; inherited by hosts/rpi5-full,
    # which imports rpi5's configuration.nix directly.
    "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="

    # nix-community.cachix.org — the nix-community public cache.
    # Set in hosts/sancta-choir/configuration.nix.
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="

    # claude-code.cachix.org — prebuilt Claude Code binaries (the house's own
    # reason to trust this cache: "Also add claude-code cachix for
    # pre-built Claude Code binaries", hosts/sancta-choir/configuration.nix).
    # Set in hosts/sancta-choir/configuration.nix.
    "claude-code.cachix.org-1:p3pMxGi7K+xT7I3dLghdlrUijD8s+wfQlmWp8gQ/TJA="
  ];

  thisHostKeys = config.nix.settings.trusted-public-keys or [ ];
  foreignKeys = builtins.filter (k: !(builtins.elem k allowedTrustedPublicKeys)) thisHostKeys;
in
{
  options.sancta.cacheTrust.allowedTrustedPublicKeys = mkOption {
    type = types.listOf types.str;
    readOnly = true;
    default = allowedTrustedPublicKeys;
    description = ''
      The only nix.settings.trusted-public-keys entries any host in this
      repo may set. Exposed read-only so tests/module-eval.nix can check the
      real hosts against the SAME list this module enforces, rather than a
      second hand-copied list that could drift out of sync with it.
    '';
  };

  config = {
    assertions = [
      {
        assertion = foreignKeys == [ ];
        message = ''
          nix.settings.trusted-public-keys has a key not on the modules/system/cache-trust.nix allow-list: ${builtins.concatStringsSep ", " foreignKeys}. A mirror or caching proxy must not be able to add its own signing key silently — if this key should be trusted, add it to that allow-list first, with a comment naming whose cache it is.
        '';
      }
    ];
  };
}
