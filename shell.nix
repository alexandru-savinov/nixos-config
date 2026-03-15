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
    python3Packages.pillow # Required for image compression tests
    nil
    gitleaks # Pre-commit secret scanning
  ];

  shellHook = ''
    # Install gitleaks pre-commit hook if not already present
    if [ -d .git ] && [ ! -f .git/hooks/pre-commit ]; then
      mkdir -p .git/hooks
      cat > .git/hooks/pre-commit << 'HOOK'
    #!/usr/bin/env bash
    gitleaks protect --staged --verbose
    HOOK
      chmod +x .git/hooks/pre-commit
    fi
  '';
}
