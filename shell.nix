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
    trivy # Pre-commit secret scanning (same engine as the CI boundary)
  ];

  shellHook = ''
    # Install/refresh the trivy secret-scan pre-commit hook. This mirrors the
    # canonical CI boundary (.github/workflows/trivy.yml) so local and CI agree
    # on exactly what counts as a leak. Refreshes the old gitleaks hook if found.
    if [ -d .git ]; then
      if [ ! -f .git/hooks/pre-commit ] || grep -q gitleaks .git/hooks/pre-commit 2>/dev/null; then
        mkdir -p .git/hooks
        cat > .git/hooks/pre-commit << 'HOOK'
    #!/usr/bin/env bash
    # Secret scan — mirrors the CI boundary (trivy.yml): same engine, same
    # allowlist (trivy-secret.yaml). Scans the whole tree (not just staged
    # files) so local results match CI exactly; fast enough on this config
    # repo. Note: a secret-like pattern in an UNSTAGED file will also block
    # the commit — if it is a known non-secret, add it to trivy-secret.yaml.
    trivy fs --scanners secret --secret-config trivy-secret.yaml --exit-code 1 --no-progress --quiet .
    HOOK
        chmod +x .git/hooks/pre-commit
      fi
    fi
  '';
}
