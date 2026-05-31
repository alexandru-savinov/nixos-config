{ config, pkgs, lib, claude-code ? null, ... }:

{
  # Claude Code - AI-powered coding assistant
  # Auto-updated hourly via github:sadjow/claude-code-nix flake
  #
  # IMPORTANT: This module requires the claude-code flake input to be passed via specialArgs:
  #   specialArgs = { inherit claude-code; };
  # See flake.nix for an example.

  options.customModules.claude = {
    enable = lib.mkEnableOption "Claude Code package";
  };

  config = lib.mkIf config.customModules.claude.enable {
    assertions = [
      {
        assertion = claude-code != null;
        message = ''
          The claude module requires the claude-code flake input to be passed via specialArgs.

          Add this to your flake inputs:
            claude-code = {
              url = "github:sadjow/claude-code-nix";
              inputs.nixpkgs.follows = "nixpkgs-unstable";
            };

          Then pass it to specialArgs in your nixosSystem:
            specialArgs = { inherit claude-code; };
        '';
      }
    ];

    # Guarded so the assertion above surfaces its friendly message: if
    # claude-code is null, lib.optional yields [] rather than forcing
    # null.packages.* (a cryptic "attempt to call 'null'" eval error).
    environment.systemPackages =
      lib.optional (claude-code != null) claude-code.packages.${pkgs.system}.default;
  };
}
