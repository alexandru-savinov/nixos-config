{ config, pkgs, lib, systemAccount ? true, ... }:

let
  rootWrapper = pkgs.writeShellScriptBin "opencode" ''
    set -eu

    FOUND=""
    for p in $PATH; do
      if [ -x "$p/opencode" ]; then
        FOUND="$p/opencode"
        break
      fi
    done

    if [ -z "${FOUND}" ]; then
      echo "opencode: could not find an executable 'opencode' in PATH" >&2
      exit 127
    fi

    exec -a opencode "${FOUND}" "$@"
  '';

in
{
  users.users.root = {
    isNormalUser = false;
    isSystemUser = systemAccount;
    shell = pkgs.zsh;

    packages = with pkgs; [
      rootWrapper
    ];
  };
}
