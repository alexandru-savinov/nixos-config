{ config
, pkgs
, pkgs-unstable ? pkgs
, lib
, ...
}:

let
  cfg = config.customModules.codex;

  codexPackage =
    if cfg.preserveScrollback then
      pkgs.symlinkJoin
        {
          name = "${lib.getName cfg.package}-preserve-scrollback";
          paths = [ cfg.package ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/codex --add-flags --no-alt-screen
          '';
        }
    else
      cfg.package;
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

    preserveScrollback = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the Codex TUI with --no-alt-screen so terminal multiplexers such
        as Zellij retain normal pane scrollback.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      codexPackage
    ];
  };
}
