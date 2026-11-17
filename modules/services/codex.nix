{ config
, pkgs
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
      default = (pkgs.codexPkgs or pkgs.unstable or pkgs).codex;
      defaultText = lib.literalExpression "(pkgs.codexPkgs or pkgs.unstable or pkgs).codex";
      description = ''
        Codex CLI package to install. Defaults to the dedicated
        `nixpkgs-codex` flake input (nixpkgs-unstable branch), exposed as
        `pkgs.codexPkgs`, because Codex releases faster than even
        nixos-unstable; bumping it moves codex alone.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ];
  };
}
