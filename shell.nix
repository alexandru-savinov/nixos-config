{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  buildInputs = with pkgs; [
    nixpkgs-fmt
    python3Packages.pytest
    python3Packages.flask
    python3Packages.requests
    python3Packages.pydantic
    python3Packages.urllib3 # Required for E2E test client retry logic
    python3Packages.genanki # Required for APKG generation tests
    nil
  ];
}
