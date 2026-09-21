{ pkgs, vigil, directories }:
let
  # Interpolation imports Nix paths and retains their store dependency context.
  sources = map (directory: "${directory}") directories;
in
pkgs.runCommand "vigil-public-contracts" { } ''
  ${vigil}/bin/vigil validate-public ${pkgs.lib.escapeShellArgs sources}
  mkdir -p "$out"
  shopt -s nullglob
  ${pkgs.lib.concatImapStringsSep "\n" (index: directory: ''
    mkdir -p "$out/${toString index}"
    contract_files=( ${pkgs.lib.escapeShellArg directory}/*.toml )
    if (( ''${#contract_files[@]} )); then
      cp -L "''${contract_files[@]}" "$out/${toString index}/"
    fi
  '') sources}
''
