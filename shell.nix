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
    # Install/refresh the Trivy secret-scan pre-commit hook. Mirrors the
    # canonical CI boundary (.github/workflows/trivy.yml) so local and CI
    # agree on exactly what counts as a leak. The generated hook carries a
    # version marker on line 2: when you change the hook body, bump BOTH
    # SECRET_HOOK_VERSION below AND the "# nixos-config secret-hook v<N>"
    # line inside the heredoc (keep them equal) so every clone re-converges
    # on the new body — including clones that already carry an older,
    # marker-less Trivy hook (the previous "grep -q gitleaks" guard froze
    # those forever). A legacy hook that actually runs gitleaks (pre-#442) is
    # refreshed too, matched outside comments so a prose mention can't trip it.
    if [ -d .git ]; then
      SECRET_HOOK_VERSION=2
      _hook=.git/hooks/pre-commit
      _marker="# nixos-config secret-hook v$SECRET_HOOK_VERSION"
      _refresh=1
      if [ -f "$_hook" ]; then
        if grep -qxF "$_marker" "$_hook" 2>/dev/null; then _refresh=0; fi
        if grep -qE '^[^#]*\bgitleaks\b' "$_hook" 2>/dev/null; then _refresh=1; fi
      fi
      if [ "$_refresh" = 1 ]; then
        mkdir -p .git/hooks
        cat > "$_hook" << 'HOOK'
    #!/usr/bin/env bash
    # nixos-config secret-hook v2
    # Secret scan — mirrors the CI boundary (.github/workflows/trivy.yml): same
    # engine, same allowlist (trivy-secret.yaml). Scans the whole tree by
    # absolute path ($PWD) so the scan and config resolve even while trivy is
    # being realised on first use. trivy comes from PATH (present in the
    # nix-shell, see shell.nix) and otherwise from an ephemeral
    # `nix shell nixpkgs#trivy`, so a commit never fails with "command not
    # found" outside the dev shell. Silent on a clean tree; prints Trivy's
    # report only when it blocks a commit. To allowlist a known non-secret,
    # add a rule to trivy-secret.yaml.
    set -uo pipefail
    args=(fs --scanners secret --secret-config "$PWD/trivy-secret.yaml" --exit-code 1 --no-progress "$PWD")
    if command -v trivy >/dev/null 2>&1; then
      out=$(trivy "''${args[@]}" 2>&1); rc=$?
    else
      out=$(nix shell nixpkgs#trivy -c trivy "''${args[@]}" 2>&1); rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$out" >&2
    fi
    exit "$rc"
    HOOK
        chmod +x "$_hook"
      fi
      unset SECRET_HOOK_VERSION _hook _marker _refresh
    fi
  '';
}
