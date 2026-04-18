Add Open-WebUI to sancta-choir NixOS host with full features (OIDC, Tavily, memory, ZDR, E2E testing).

## Context

sancta-choir is a Hetzner cx33 VPS (x86_64, 4 cores, 8GB RAM) that needs Open-WebUI installed. The module already exists at `modules/services/open-webui.nix` (~1430 lines) and was previously used on rpi5-full (now disabled there due to ARM weight).

**sancta-choir SSH host key** (retrieved via Hetzner rescue mode):
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMhS/MNrRr4FLmfWv2jNWz7WTr/AnD9fD3keXltRWXe root@sancta-choir
```

**Tailscale hostname**: `sancta-choir-1.tail4249a9.ts.net` (re-authenticated after server upgrade, old `sancta-choir` entry is stale).

**Key files to reference:**
- `secrets/secrets.nix` — agenix key definitions, add sancta-choir host key to `systems` list
- `hosts/sancta-choir/configuration.nix` — host config, add imports + service config
- `modules/services/open-webui.nix` — existing module (DO NOT MODIFY)
- `lib/secrets.nix` — secret helper functions (DO NOT MODIFY)

**Existing secrets that Open-WebUI needs** (already exist as .age files):
- `open-webui-secret-key.age` (publicKeys = allKeys)
- `openrouter-api-key.age` (publicKeys = allPlusClaw)
- `tavily-api-key.age` (publicKeys = allKeys)
- `e2e-test-api-key.age` (publicKeys = allKeys)

**Current secrets.nix key groups:**
```nix
root-sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir";
rpi5 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBjZXKDY8Ve/wfMHpjsJGR7guDQFndGoNxDZKXegEfjr root@rpi5";
sancta-claw = "age1zex0chkw9swv62khuw73lftpcagu6t7d8vqa2h9mmnm23249hpuqx8f2kt";
users = [ root-sancta-choir ];
systems = [ rpi5 ];
allKeys = users ++ systems;
allPlusClaw = allKeys ++ [ sancta-claw ];
```

**Re-encryption**: After changing secrets.nix, run `agenix -r` in the secrets/ directory. This must be done on rpi5 which has the editing private key. SSH access: `ssh nixos@rpi5` (via Tailscale).

**sancta-choir SSH access**: `ssh -i /tmp/sancta-rescue root@116.203.223.113` or `ssh root@sancta-choir-1` via Tailscale SSH.

## Tasks

### Task 1: Update secrets.nix to include sancta-choir host key
- [x] Add `sancta-choir` host key variable to `secrets/secrets.nix`: `sancta-choir = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMhS/MNrRr4FLmfWv2jNWz7WTr/AnD9fD3keXltRWXe root@sancta-choir";`
- [x] Add `sancta-choir` to the `systems` list: `systems = [ rpi5 sancta-choir ];` — this automatically adds it to `allKeys` and `allPlusClaw`
- [x] Run `nix fmt` on the changed file

### Task 2: Configure Open-WebUI in sancta-choir configuration.nix
- [ ] Add `config` to the function arguments: `{ config, pkgs, lib, self, ... }:`
- [ ] Add import: `../../modules/services/open-webui.nix`
- [ ] Add agenix secret declarations using the `secret` helper from `lib/secrets.nix`: `open-webui-secret-key`, `openrouter-api-key`, `tavily-api-key`, `e2e-test-api-key`
- [ ] Configure `services.open-webui-tailscale` with: enable=true, secretKeyFile, openai.apiKeyFile, webuiUrl="https://sancta-choir-1.tail4249a9.ts.net", oidc.enable=true, tavilySearch.enable=true with apiKeyFile, memory.enable=true, autoMemory.enable=true, zdrModelsOnly.enable=true, testing.enable=true with apiKeyFile
- [ ] Increase swap from 2048 to 4096 MB for Open-WebUI headroom
- [ ] Run `nix fmt` on the changed file

### Task 3: Re-encrypt secrets with new key and validate
- [ ] SSH to rpi5 as nixos user, cd to nixos-config, pull latest changes from the branch
- [ ] Run `cd secrets && agenix -r` on rpi5 to re-encrypt all .age files with the updated key set
- [ ] Commit the re-encrypted .age files
- [ ] Push to the branch
- [ ] Run `nix flake check` to validate the configuration evaluates correctly

## Constraints
- DO NOT modify `modules/services/open-webui.nix` — it's a shared module
- DO NOT modify `lib/secrets.nix` — it's a shared helper
- DO NOT modify any other host's configuration
- Use `nix fmt` before committing any .nix file changes
- Follow the repo's worktree discipline: create a branch, don't commit to main
- The `webuiUrl` MUST be `https://sancta-choir-1.tail4249a9.ts.net` (not the default rpi5 URL)
- Vector DB should use default chromadb (no qdrant needed on x86_64)
- Follow existing patterns in `hosts/sancta-claw/configuration.nix` and `hosts/rpi5-full/configuration.nix` for how secrets and services are declared
