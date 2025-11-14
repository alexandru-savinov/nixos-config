{ config, pkgs, lib, ... }:

{
  # GitHub spec-kit (Spec-Driven Development toolkit)
  home-manager.users.root = {
    # Install spec-kit via pipx (alternative to uv tool install)
    home.packages = with pkgs; [
      pipx
      git
    ];

    home.activation.installSpecKit = lib.mkAfter ''
      # Install spec-kit using pipx if not already installed
      if ! ${pkgs.pipx}/bin/pipx list | grep -q specify-cli; then
        PATH="${pkgs.git}/bin:$PATH" ${pkgs.pipx}/bin/pipx install git+https://github.com/github/spec-kit.git
      fi
    '';

    # Add pipx bin directory to PATH so 'specify' command is available
    home.sessionPath = [ "$HOME/.local/bin" ];
  };
}
