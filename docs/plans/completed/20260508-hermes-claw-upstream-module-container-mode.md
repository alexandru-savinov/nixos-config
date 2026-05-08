# hermes-claw: migrate to upstream NixOS module in container mode

## Overview

Migrate the existing `hermes-claw` Hetzner host from `virtualisation.oci-containers` (running the upstream Docker image directly) to Hermes' upstream NixOS module in container mode (`services.hermes-agent` with `container.enable = true`). The new mode enables runtime self-modification — `apt install`, `pip install`, `npm install`, and plugin loading — with installations persisting across service restarts and `nixos-rebuild switch`.

This is a migration of an existing host, not a fresh deploy. Only the application layer changes. No state worth preserving — wipe `/var/lib/hermes/data` as part of the migration.

## Context

- Host: `hermes-claw`, Hetzner CCX (x86_64), Tailscale IP `100.106.126.114`, 75GB disk (61GB free), 7.6GB RAM, Podman 5.7.0
- We are on **rpi5 (aarch64)** — cannot build x86_64 closures locally (no remote builders). Must use `--build-host root@100.106.126.114` or build on target.
- SSH: `hermes-claw` / `hermes-claw.tail4249a9.ts.net` fail host key verification. Use Tailscale IP `100.106.126.114` (added to known_hosts).
- Repo: `github:alexandru-savinov/nixos-config`, branch `origin/feat/hermes-claw` has existing oci-containers implementation
- Upstream module: `github:NousResearch/hermes-agent` — confirmed exports `flake.nixosModules.default` via flake-parts with all required options. Package auto-resolved via `inputs.self.packages.${system}.default`. Issue #9305 (fastapi/dashboard build) is closed.
- Upstream uses `flake-parts`; `inputs.nixpkgs.follows = "nixpkgs"` works correctly
- Existing `secrets/secrets.nix` already has `hermes-claw` as recipient (ssh-ed25519 key); `openrouter-api-key` and `zero-kuzea-telegram-bot-token` already re-keyed for it
- Agenix decryption works from rpi5: `sudo agenix -d <file>.age -i /root/dr/recovery-sancta-claw.key` (must run from `secrets/` dir)
- Recovery key present at `/root/dr/recovery-hermes-claw.key`
- `tests/module-eval.nix` has `hermes-claw-rendered` test asserting on old oci-containers structure (`system.build.hermesAgentEnvBody`, `system.build.hermesConfigYamlBody`, image digest, container volumes, ExecStartPre). Needs full rewrite — new test must also receive hermes-agent flake input for module resolution.
- Preserved: hostname, disko, hardware-config, firewall (port 22 only), model config (`tencent/hy3-preview:free` on OpenRouter), Telegram chat ID `364749075`, existing agenix secrets
- Security tradeoff: dropping `--cap-drop=ALL` in exchange for self-modification capability; compensating with `--security-opt=no-new-privileges`, memory/CPU caps, namespace isolation, no inbound ports
- Networking change: old setup used podman bridge networking with explicit port mapping (`127.0.0.1:8642:8642`). New upstream module hardcodes `--network=host`. Agent API still loopback-only (hermes binds to 127.0.0.1 by default); firewall still blocks all inbound except SSH.
- Adopted from: inline migration specification (free-form markdown)

## Development Approach

- Branch from `origin/feat/hermes-claw` (which has the existing host skeleton + oci-containers setup)
- Testing approach: `nix flake check` for module-eval tests (aarch64-only, works locally), then deploy to target with `--build-host` for the actual x86_64 build
- Complete each task fully before moving to the next
- Update this plan when scope changes during implementation

## Testing Strategy

- `nix flake check` locally — module-eval tests are arch-independent (option merging, no package builds)
- `nix eval .#nixosConfigurations.hermes-claw.config.services.hermes-agent.settings` — verify settings resolve without building
- Full x86_64 build happens on-target via `--build-host root@100.106.126.114` (cannot build locally on aarch64 rpi5)
- Verify service health via `systemctl` and `journalctl` on host
- Verify config correctness via `hermes config` output
- Verify self-modification persistence across restart
- Verify Telegram round-trip

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Update plan if implementation deviates from original scope

## Technical Details

**What changes:**

| Aspect | Old (`oci-containers`) | New (upstream module, container mode) |
|---|---|---|
| Service mechanism | `virtualisation.oci-containers.containers.hermes-agent` | `services.hermes-agent` |
| Image source | Pinned Docker image by tag+digest | Built from source via flake's `uv2nix`, bind-mounted into Ubuntu container |
| Self-modification | Forbidden (cap-drop=ALL, read-only) | Enabled (writable `/usr`, `/usr/local`, `/tmp`; persistent `/home/hermes`) |
| Config delivery | Read-only bind-mount of Nix store path | Declarative `settings` attrset, deep-merged into `$HERMES_HOME/config.yaml` |
| Secrets | Shell script at ExecStartPre composes env file | Combined agenix env-file at `environmentFiles` |
| Container networking | Bridge with `127.0.0.1:8642:8642` port mapping | `--network=host` (upstream hardcoded) |
| Container recreation | Every restart uses same image | Only on identity hash change; writable layer survives `nixos-rebuild switch` |

**Key upstream module behaviors (from reading `nix/nixosModules.nix`):**
- Container mode uses `--network=host` and bind-mounts `/nix/store:ro` + stateDir
- Identity hash determines container recreation (schema version 4, image, extraVolumes, extraOptions)
- Entrypoint provisions apt (sudo, nodejs 22 via NodeSource, curl), uv, Python 3.12 venv on first boot — stored in writable layer
- Activation script merges `environmentFiles` into `$HERMES_HOME/.env` (runs `lib.stringAfter ["setupSecrets"]`)
- `configMergeScript` deep-merges Nix settings with existing config.yaml (user keys preserved, Nix keys win)
- Module sets `virtualisation.docker.enable = lib.mkDefault (backend == "docker")` — must explicitly set `false` when using podman
- Module auto-creates `hermes` user/group via `users.users` (before `setupSecrets` activation phase), so `age.secrets.hermes-env.owner = "hermes"` works
- GC roots created at `${stateDir}/.gc-root*` to prevent nix-collect-garbage from removing in-use store paths

**Hard rules:**
- Do NOT run `hermes setup`, `hermes config set`, `hermes config edit`, `hermes gateway install/uninstall`
- Do NOT enable the dashboard or expose port 9119
- Do NOT change the model pin to a paid model
- Do NOT add inbound firewall ports
- Do NOT restructure the agenix layout

## Implementation Steps

### Task 1: Set up working branch and fix SSH

- [x] Add hermes-claw Tailscale hostname to known_hosts: `ssh-keyscan hermes-claw.tail4249a9.ts.net >> ~/.ssh/known_hosts 2>/dev/null` (or use IP `100.106.126.114`)
- [x] Create worktree from `origin/feat/hermes-claw`: `git worktree add ../nixos-config-hermes-claw-flexible-mode -b hermes-claw-flexible-mode origin/feat/hermes-claw`
- [x] Verify branch is based on latest `feat/hermes-claw` commits (tip: `f105d82`)
- [x] run project tests - must pass before next task

### Task 2: Add combined agenix secret

- [x] Add `"secrets/hermes-env.age".publicKeys = allPlusBoth;` to `secrets/secrets.nix` (uses same recipient set that includes hermes-claw)
- [x] Decrypt existing values: `cd secrets && sudo agenix -d openrouter-api-key.age -i /root/dr/recovery-sancta-claw.key` and `sudo agenix -d zero-kuzea-telegram-bot-token.age -i /root/dr/recovery-sancta-claw.key`
- [x] Create `secrets/hermes-env.age` with `OPENROUTER_API_KEY=<value>` and `TELEGRAM_BOT_TOKEN=<value>` (pipe through stdin to `agenix -e` since non-interactive)
- [x] Verify existing .age files are byte-identical (`git diff` shows only new `hermes-env.age` + `secrets.nix` change)
- [x] run project tests - must pass before next task

### Task 3: Add hermes-agent flake input

- [x] Add `hermes-agent` input to `flake.nix`: `url = "github:NousResearch/hermes-agent"` with `inputs.nixpkgs.follows = "nixpkgs"`
- [x] Add `hermes-agent` to the `outputs` function argument list (after `owui-openrouter-stats`)
- [x] Add `inputs.hermes-agent.nixosModules.default` to `nixosConfigurations.hermes-claw` modules list
- [x] Run `nix flake update hermes-agent` to fetch and lock
- [x] Verify `nix flake metadata` shows hermes-agent locked revision
- [x] run project tests - must pass before next task

### Task 4: Replace hermes-service.nix with upstream module config

- [x] Delete existing contents of `hosts/hermes-claw/hermes-service.nix`
- [x] Write new module: `virtualisation.docker.enable = false`, `virtualisation.podman.enable = true`, `virtualisation.oci-containers.backend = "podman"`
- [x] Add `age.secrets.hermes-env` declaration (file = `../../secrets/hermes-env.age`, owner = "hermes", group = "hermes", mode = "0400")
- [x] Configure `services.hermes-agent.enable = true` with `addToSystemPackages = true`
- [x] Configure `container` block: `enable = true`, `backend = "podman"`, `image = "ubuntu:24.04"`, `hostUsers = ["root"]`
- [x] Set `container.extraOptions`: `--security-opt=no-new-privileges`, `--memory=4g`, `--cpus=2.0`
- [x] Configure `settings` attrset: model (`tencent/hy3-preview:free`, provider openrouter, base_url), auxiliary tasks (title_generation, compression, session_search, web_extract all on openrouter), toolsets, memory, terminal
- [x] Set `environmentFiles = [ config.age.secrets.hermes-env.path ]`
- [x] Set `environment` with `TELEGRAM_ALLOWED_USERS = "364749075"` and `HERMES_DASHBOARD = "0"`
- [x] Set `extraPackages` with git, ripgrep, jq, curl
- [x] Remove old `system.build.hermesAgentEnvBody` and `system.build.hermesConfigYamlBody` exports
- [x] Remove old `users.users.hermes` / `users.groups.hermes` / `systemd.tmpfiles.rules` (upstream module creates these)
- [x] Remove old `virtualisation.oci-containers.containers.hermes-agent` block
- [x] Remove old `systemd.services.podman-hermes-agent` override and `systemd.services.hermes-agent` alias
- [x] run project tests - must pass before next task

### Task 5: Update module-eval tests

- [x] Read `tests/module-eval.nix` fully to understand test structure and hermes-claw assertions
- [x] Remove old `hermes-claw-rendered` test block that asserts on oci-containers config, image digest, env body strings
- [x] Add new test asserting on `services.hermes-agent.settings.model.default == "tencent/hy3-preview:free"` and `services.hermes-agent.container.enable == true`
- [x] Ensure test evaluation has access to hermes-agent flake input (the nixosConfiguration already includes the module; test just needs to eval the config)
- [x] Run `nix flake check` to verify all tests pass (module-eval is arch-independent, runs on aarch64)
- [x] Run `nix eval .#nixosConfigurations.hermes-claw.config.services.hermes-agent.settings` to verify settings resolve
- [x] If eval fails due to uv2nix IFD on aarch64, test only on-target (document why)
- [x] run project tests - must pass before next task

### Task 6: Wipe stale state on host

- [x] SSH to hermes-claw (`ssh root@100.106.126.114`) and record `df -h /` before
- [x] Stop old service: `systemctl stop podman-hermes-agent`
- [x] Remove old container: `podman rm -f hermes-agent`
- [x] Remove stale data: `rm -rf /var/lib/hermes/data`
- [x] run project tests - must pass before next task

### Task 7: Deploy

- [x] Commit all changes with message: `hermes-claw: switch to upstream module, container mode`
- [x] Push branch to origin
- [x] Deploy using build-on-target: `nixos-rebuild switch --flake .#hermes-claw --target-host root@100.106.126.114 --build-host root@100.106.126.114`
- [x] If `--build-host` fails (flake not accessible from target), alternative: SSH to target and run `nixos-rebuild switch --flake github:alexandru-savinov/nixos-config/hermes-claw-flexible-mode#hermes-claw`
- [x] Monitor build output — expect 5-15 min for first uv2nix build, first boot entrypoint provisions apt/uv/venv (additional 2-5 min)
- [x] Confirm activation completes without errors
- [x] run project tests - must pass before next task

### Task 8: Verify deployment

- [x] Run `systemctl is-active hermes-agent` — must report `active`
- [x] Check `journalctl -u hermes-agent -n 80` for errors
- [x] Verify module-mode markers exist: `ls -la /var/lib/hermes/.hermes/{config.yaml,.env,.managed,.container-mode}`
- [x] Inspect `cat /var/lib/hermes/.hermes/config.yaml | head -40` — model must be `tencent/hy3-preview:free`
- [x] Verify `hermes version` works from host shell
- [x] Verify `hermes config` shows `provider: openrouter` and model `tencent/hy3-preview:free` (NOT anthropic/claude)
- [x] Test self-modification: `podman exec hermes-agent apt-get update -qq && podman exec hermes-agent apt-get install -y -qq fortune-mod`
- [x] Test persistence: `systemctl restart hermes-agent && sleep 10 && podman exec hermes-agent /usr/games/fortune` (extra wait for entrypoint)
- [x] Send `/start` to Telegram bot from chat ID 364749075 and confirm reply
- [x] Record hermes-agent flake input revision: `nix flake metadata --json | jq '.locks.nodes."hermes-agent".locked'`
- [x] Record disk usage delta: `df -h /` after vs before (from Task 6)
- [x] Verify no unexpected listening ports: `ss -tlnp | grep -v 127.0.0.1 | grep -v ::1`
- [x] run project tests - must pass before next task

### Task 9: Verify acceptance criteria

- [x] verify all requirements from Overview are implemented
- [x] confirm self-modification persists across restarts
- [x] confirm model config is declarative and correct (not overwritten by upstream defaults)
- [x] confirm no new inbound firewall ports were added
- [x] confirm existing agenix secrets are byte-identical (check on rpi5: `cd nixos-config && git diff -- secrets/*.age`)
- [x] confirm `--network=host` doesn't expose anything new (only loopback listeners, firewall blocks rest)
- [x] run full project test suite
- [x] run project linter - all issues must be fixed

## Post-Completion

*Items requiring manual intervention - no checkboxes, informational only*

- Report: output of all verification commands from Task 8
- Report: hermes-agent flake input revision pinned
- Report: first-build wall-clock time and disk usage delta
- Report: Telegram round-trip confirmation
- Report: any judgment calls made beyond the specification
- Push branch and create PR for review
- Fix `hermes-claw` / `hermes-claw.tail4249a9.ts.net` in SSH known_hosts if still broken after deploy (host key may have changed)
