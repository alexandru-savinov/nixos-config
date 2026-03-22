# nixd-lsp

Nix language server for Claude Code, providing NixOS option completion, go-to-definition across flakes, and diagnostics.

## Supported Extensions
`.nix`

## Installation
```bash
nix-env -iA nixpkgs.nixd
```

Or in NixOS config:
```nix
environment.systemPackages = [ pkgs.nixd ];
```

## More Information
- [GitHub Repository](https://github.com/nix-community/nixd)
