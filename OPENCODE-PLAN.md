# Implementation Plan: OpenCode via nix-ld on NixOS

## Overview

Enable OpenCode CLI on NixOS by configuring `nix-ld` to run dynamically linked binaries. This approach fixes both the Zed-downloaded binary and allows the official installer to work.

## Background

- **Problem**: OpenCode distributes dynamically linked (glibc) binaries that NixOS cannot run natively
- **Solution**: Enable `nix-ld` which provides a compatibility layer for dynamic linkers
- **Benefit**: Also enables other dynamic binaries (VS Code extensions, language servers, etc.)

## Current State

- Zed downloaded opencode to: `/root/.local/share/zed/external_agents/opencode/opencode/v_8e7b3b34993a89a2/opencode`
- Error when running: "Could not start dynamically linked executable"
- Latest opencode version: 1.0.133 (as of 2025-12-04)

## Implementation Steps

### Step 1: Create nix-ld Module

Create a new module at `modules/system/nix-ld.nix`:

```nix
{ config, pkgs, lib, ... }:

{
  # Enable nix-ld for running dynamically linked binaries
  # Required for: opencode, VS Code extensions, external language servers
  programs.nix-ld = {
    enable = true;
    
    # Common libraries needed by most dynamic binaries
    libraries = with pkgs; [
      # Core C libraries (keep both for libstdc++ and the glibc dynamic linker)
      stdenv.cc.cc.lib
      glibc
      
      # Compression
      zlib
      zstd
      
      # SSL/TLS
      openssl
      
      # Networking
      curl
      
      # System libraries commonly needed
      icu
      libunwind
      libuuid
      util-linux
      
      # For GUI apps (optional but useful)
      xorg.libX11
      xorg.libXcursor
      xorg.libXrandr
      xorg.libXi
    ];
  };
}
```

### Step 2: Import Module in Host Configuration

Edit `hosts/sancta-choir/configuration.nix`, add to imports:

```nix
imports = [
  # ... existing imports ...
  ../../modules/system/nix-ld.nix
];
```

### Step 3: Deploy Configuration

```bash
cd /root/nixos-config
nixos-rebuild switch --flake .#sancta-choir
```

### Step 4: Verify Zed Binary Works

```bash
/root/.local/share/zed/external_agents/opencode/opencode/v_*/opencode --version
```

### Step 5: (Optional) Add opencode to PATH

Two options:

**Option A**: Symlink to a directory in PATH
```bash
mkdir -p ~/.local/bin
ln -sf /root/.local/share/zed/external_agents/opencode/opencode/v_*/opencode ~/.local/bin/opencode
```

Then add to `modules/users/root.nix`:
```nix
home.sessionPath = [ "$HOME/.local/bin" ];
```

**Option B**: Run official installer (creates ~/.opencode/bin/opencode)
```bash
curl -fsSL https://opencode.ai/install | bash
```

The installer auto-adds to PATH via .bashrc.

### Step 6: Configure OpenCode (Optional)

If using with Open WebUI as gateway, manage `~/.config/opencode/config.json` declaratively (e.g., via Home Manager or an activation script). Example contents:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "owui": {
      "name": "Open WebUI",
      "options": {
        "baseURL": "https://sancta-choir.tail4249a9.ts.net/api/v1"
      }
    }
  },
  "model": "owui/openrouter/anthropic/claude-sonnet-4"
}
```


Authentication should be injected via your secrets management flow (e.g., `sops-nix`, agenix) so that the API key lands in `~/.local/share/opencode/auth.json` with 0600 permissions.


## File Changes Summary

| File | Action |
|------|--------|
| `modules/system/nix-ld.nix` | Create new module |
| `hosts/sancta-choir/configuration.nix` | Add import |
| `hosts/rpi5/configuration.nix` | Add import (if needed on Pi) |

## Considerations

### For rpi5 (aarch64)

The same nix-ld config works. OpenCode provides `opencode-linux-arm64.tar.gz` for ARM64.

### Security Implications


- `nix-ld` enables running *any* dynamically linked binary, not just opencode

- This is a trade-off between NixOS purity and practicality

- The libraries list should be kept minimal to reduce attack surface
- Provider API keys and tokens should live in encrypted secrets, never in the repo or world-readable paths


### Updates

- Zed auto-updates its opencode agent binary
- Official installer can be re-run to update: `curl -fsSL https://opencode.ai/install | bash`
- No changes needed to NixOS config for opencode updates

### Rollback

If issues arise:
```bash
nixos-rebuild switch --rollback
```

Or remove the import and rebuild.

## Testing Checklist

- [x] `nixos-rebuild switch` succeeds on each target host (x86_64, aarch64) — ✅ sancta-choir (x86_64) deployed 2025-12-05
- [x] `nix-ld` is active: `/lib64/ld-linux-x86-64.so.2` points to nix-ld — ✅ verified
- [x] `ldd /root/.local/share/zed/external_agents/opencode/opencode/v_*/opencode` shows no "not found" entries with `nix-ld` enabled — ✅ all libs resolved
- [x] `/root/.local/share/zed/external_agents/opencode/opencode/v_*/opencode --version` runs under the root shell — ✅ reports 1.0.61
- [x] `opencode` command is available in terminal (after Step 5) and `which opencode` points to the expected path — ✅ symlinked to `~/.local/bin`, PATH set via home-manager sessionPath
- [ ] Declarative deployment surfaces `~/.config/opencode/config.json` with the expected provider settings
- [x] OpenCode can start a session in a project directory and open/edit a file — ✅ `opencode --help` and `opencode models` work in nixos-config directory
- [x] (Optional) OpenCode connects to the configured provider and lists available models — ✅ lists opencode/big-pickle, opencode/grok-code
- [ ] (Optional) A second dynamically linked binary (e.g., a VS Code language server) runs successfully via `nix-ld`

## References

- [nix-ld GitHub](https://github.com/Mic92/nix-ld)
- [NixOS Wiki: Packaging/Binaries](https://nixos.wiki/wiki/Packaging/Binaries)
- [OpenCode GitHub](https://github.com/sst/opencode)
- [OpenCode Docs](https://opencode.ai/docs)