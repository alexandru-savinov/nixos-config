{ config, pkgs, pkgs-unstable, lib, ... }:

let
  specifySource = "git+https://github.com/github/spec-kit.git";
  pythonForSpecKit = pkgs.python312;
  # Use unstable uv which has the 'tool' subcommand
  uv = pkgs-unstable.uv;

  # Provide a copilot command that proxies to the GitHub Copilot CLI so `specify check`
  # can detect it like other CLI-based assistants.
  copilotShim = pkgs.writeShellApplication {
    name = "copilot";
    runtimeInputs = [ pkgs.github-copilot-cli ];
    text = ''
      exec ${pkgs.github-copilot-cli}/bin/github-copilot-cli "$@"
    '';
  };

  # Wrapper for specify command that points to the uv-installed version
  specifyWrapper = pkgs.writeShellScriptBin "specify" ''
    exec "$HOME/.local/bin/specify" "$@"
  '';
in
{
  # GitHub spec-kit (Spec-Driven Development toolkit)
  home-manager.users.root = {
    home.packages = [
      copilotShim
      specifyWrapper
    ];

    home.activation.installSpecKit = lib.mkAfter ''
            set -euo pipefail

            export PATH="${pkgs.git}/bin:$PATH"
      export UV_PYTHON_DOWNLOADS=never

      ${uv}/bin/uv tool install specify-cli \
        --from ${specifySource} \
        --python ${pythonForSpecKit}/bin/python3 \
        --force

            TOOL_ROOT=$(${uv}/bin/uv tool dir 2>/dev/null || true)
            if [ -n "$TOOL_ROOT" ]; then
              SPECIFY_ENV="$TOOL_ROOT/specify-cli"
            else
              SPECIFY_ENV=""
            fi

            if [ -n "$SPECIFY_ENV" ] && [ -d "$SPECIFY_ENV" ]; then
              SPECIFY_INIT=$(${pkgs.findutils}/bin/find "$SPECIFY_ENV" -path '*/site-packages/specify_cli/__init__.py' -print -quit 2>/dev/null)
              if [ -n "$SPECIFY_INIT" ] && [ -f "$SPECIFY_INIT" ]; then
                if ! grep -q 'https://github.com/github/copilot-cli' "$SPECIFY_INIT"; then
                  SPECIFY_INIT_PATH="$SPECIFY_INIT" ${pkgs.python3}/bin/python - <<'PY'
      import os
      from pathlib import Path

      path = Path(os.environ["SPECIFY_INIT_PATH"])
      text = path.read_text()
      old = """    \"copilot\": {\n        \"name\": \"GitHub Copilot\",\n        \"folder\": \".github/\",\n        \"install_url\": None,  # IDE-based, no CLI check needed\n        \"requires_cli\": False,\n    },"""

      if old in text:
          new = """    \"copilot\": {\n        \"name\": \"GitHub Copilot\",\n        \"folder\": \".github/\",\n        \"install_url\": \"https://github.com/github/copilot-cli\",\n        \"requires_cli\": True,\n    },"""
          path.write_text(text.replace(old, new, 1))
      PY
                fi
              fi
            fi
    '';

    home.sessionVariables = {
      PATH = "$HOME/.local/bin:$PATH";
    };
  };
}
