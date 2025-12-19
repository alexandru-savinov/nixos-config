{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  buildInputs = with pkgs; [
    nixpkgs-fmt
    python3Packages.pytest
    python3Packages.flask
    python3Packages.requests
    python3Packages.pydantic
    nil
  ];
}
