{ config
, pkgs
, pkgs-unstable ? pkgs
, lib
, ...
}:

let
  cfg = config.customModules.codex;
in
{
  options.customModules.codex = {
    enable = lib.mkEnableOption "OpenAI Codex CLI";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs-unstable.codex;
      defaultText = lib.literalExpression "pkgs-unstable.codex";
      description = ''
        Codex CLI package to install. Defaults to nixpkgs-unstable because
        Codex moves faster than stable nixpkgs branches.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ];
  };
}
