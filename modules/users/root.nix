{ pkgs, ... }: {
  programs = {
    opencode = {
      enable = true;
      package = pkgs.writeShellApplication {
        name = "opencode";
        runtimeInputs = with pkgs; [
          ripgrep
          fzf
          bat
        ];
        text = ''
          FOUND=$(rg "^OPENAI_API_KEY=" "$HOME/.bashrc" > /dev/null 2>&1; echo $?)
          if [[ "''${FOUND}" -eq 0 ]]; then
            FOUND=$(rg "OPENAI_API_KEY" "$HOME/.config/zsh/zshrc" > /dev/null 2>&1; echo $?)
            if [[ "''${FOUND}" -eq 0 ]]; then
              echo "Can't find OPENAI_API_KEY"
              exit 2
            fi
          fi

          export OPENAI_API_KEY=$(rg "^OPENAI_API_KEY=" "$HOME/.bashrc" | cut -d'=' -f2)

          ${pkgs.opencode}/bin/opencode "$@"
        '';
      };
    };
  };
}
