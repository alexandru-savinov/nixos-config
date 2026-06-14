Add herdr to hermes-claw declaratively and wire Hermes agent status reporting into the container so idle/working/blocked shows correctly in herdr via `herdr --remote`.

## Context

`hermes-claw` is an x86_64-linux Hetzner VPS (CX33, GRUB, 4GB swap) running the
**NousResearch hermes-agent** as a **podman container** named `hermes-agent`.
The container is created by the upstream NixOS module (`services.hermes-agent`,
input `hermes-agent` in `flake.nix`); its declarative config lives in
`hosts/hermes-claw/hermes-service.nix`. The upstream module **recreates the
container on identity-hash change**, so any socket mount / env / plugin wired in
imperatively is wiped on the next `nixos-rebuild switch` — everything MUST be
declarative.

**Goal:** run a `herdr` server on hermes-claw, attach to it from the Mac with
`herdr --remote root@hermes-claw`, and have the in-container Hermes report its
live status to herdr's sidebar.

**Verified mechanism (do not re-derive):** the herdr hermes integration plugin
(`~/.hermes/plugins/herdr-agent-state/`, both `plugin.yaml` and `__init__.py`)
reads exactly two env vars at runtime and connects to a unix socket:

```python
pane_id     = os.environ.get("HERDR_PANE_ID", "").strip()
socket_path = os.environ.get("HERDR_SOCKET_PATH", "").strip()
# connects to socket_path, calls JSON-RPC method "pane.report_agent"
```

So status reporting needs THREE things to reach the hermes process *inside* the
container: env `HERDR_PANE_ID`, env `HERDR_SOCKET_PATH`, and the socket file
itself reachable at that path (bind-mounted from the host). herdr injects
`HERDR_PANE_ID` into any pane process it spawns; `podman exec -e HERDR_PANE_ID`
forwards it into the container.

**herdr facts (verified):** AGPL-3.0 Rust, repo `github.com/ogulcancelik/herdr`,
current tag `v0.6.10`. Upstream flake builds from source (heavy Rust build — risky
on this small VPS). A prebuilt Linux x86_64 ELF is published at
`https://github.com/ogulcancelik/herdr/releases/download/v0.6.10/herdr-linux-x86_64`.
`herdr server` is a headless daemon owning a unix socket (default
`~/.config/herdr/herdr.sock`, overridable via `HERDR_SOCKET_PATH`). `herdr --remote
<ssh-target>` makes the local herdr a thin client that starts/attaches a herdr
server **on the remote** and streams the UI back — the remote MUST already have the
herdr binary on PATH (non-interactive runs do NOT auto-install).

**Build/deploy constraints:** the ralphex agent runs on macOS (aarch64-darwin) in
`~/nixos-config`. It CAN evaluate the x86_64-linux config locally
(`nix eval`) but CANNOT build x86_64 closures locally. Deploy with:
`nixos-rebuild switch --flake .#hermes-claw --build-host root@hermes-claw --target-host root@hermes-claw`
(builds on target, evaluates locally). SSH as `root@hermes-claw` works (Tailscale
SSH; only the `root` login is permitted).

## Tasks

### Task 1: De-risk the socket+plugin chain on hermes-claw (no repo changes)
- [ ] SSH to `root@hermes-claw`. Create `/run/herdr` (mode 0700, root). Download the prebuilt binary to a temp dir: `curl -fsSL https://github.com/ogulcancelik/herdr/releases/download/v0.6.10/herdr-linux-x86_64 -o /tmp/herdr && chmod +x /tmp/herdr`. Run `file /tmp/herdr` and record whether it is dynamically or statically linked (this decides packaging in Task 2). On NixOS a dynamic ELF won't run directly — if dynamic, run it via `nix run nixpkgs#steam-run -- /tmp/herdr ...` (or skip to Task 2 packaging) just enough to start a server for this test.
- [ ] Start a herdr server with a fixed socket: `HERDR_SOCKET_PATH=/run/herdr/herdr.sock <herdr> server &`. Confirm the socket exists: `ls -l /run/herdr/herdr.sock`.
- [ ] Prove cross-namespace reporting works: run a THROWAWAY container that bind-mounts the socket and pretends to be the plugin — `podman run --rm --network=host -v /run/herdr:/run/herdr -e HERDR_PANE_ID=test-pane -e HERDR_SOCKET_PATH=/run/herdr/herdr.sock ubuntu:24.04 sh -c '...python snippet that opens the unix socket and sends a newline-delimited JSON {"id":"1","method":"pane.report_agent","params":{...}} ...'`. (Inspect the extracted plugin `__init__.py` from Task 4's extraction step, or `herdr pane report-agent --help`, to get the exact params shape: needs `pane_id`, `source`, `agent`, `state`.)
- [ ] **Closing check:** from the host, query `<herdr> agent list` / `pane get` and confirm the state pushed from inside the container is visible. Record PASS/FAIL in `docs/plans/herdr-hermes-status-findings.md` (create it). If FAIL, STOP — do not proceed; document why (the whole design depends on this link).
- [ ] Clean up: stop the test herdr server, remove the throwaway container, leave `/run/herdr` removed (it will be created declaratively later). Do NOT touch the running `hermes-agent` container.
- [ ] Commit the findings file.

### Task 2: Package herdr (prebuilt binary) and install it on hermes-claw
- [ ] Add the herdr release binary as a Nix package. Prefer a `fetchurl` + `autoPatchelfHook` derivation pinned to `v0.6.10` with the sha256 hash (get it via `nix store prefetch-file <url>` or `nix-prefetch-url`), since building the Rust source on this 4GB VPS risks OOM. If Task 1 found the binary is statically linked, drop `autoPatchelfHook`. Put the derivation in a new module file following the repo's existing module layout (e.g. `modules/packages/herdr.nix` or inline in a new `hosts/hermes-claw/herdr.nix`); match how other packages/modules are structured in this repo. Pin the exact tag — no floating refs.
- [ ] Wire the package into `environment.systemPackages` for hermes-claw only (read `flake.nix` to see how `nixosSystem` for `hermes-claw` passes inputs/specialArgs, and follow that pattern; do not add a global package to all hosts).
- [ ] **Closing check (local, no build):** `nix eval .#nixosConfigurations.hermes-claw.config.environment.systemPackages --apply 'ps: builtins.length ps' ` succeeds, and `nix eval .#nixosConfigurations.hermes-claw.config.system.build.toplevel.drvPath` evaluates without error. Run `nix fmt`. Commit.

### Task 3: Run `herdr server` as a systemd service on hermes-claw
- [ ] Add a `systemd.services.herdr-server` (new file e.g. `hosts/hermes-claw/herdr-service.nix`, imported from `configuration.nix`). It must: run as root; set `Environment=HERDR_SOCKET_PATH=/run/herdr/herdr.sock`; use `RuntimeDirectory=herdr` with `RuntimeDirectoryMode=0700` so `/run/herdr` is created root-owned 0700; `ExecStart` = `${herdrPkg}/bin/herdr server`; `Restart=on-failure`; `WantedBy=multi-user.target`.
- [ ] Make the hermes-agent container service order **after** herdr-server so the socket exists at container creation: add `After`/`Requires` (or `Wants`) on `herdr-server.service` to the podman unit (`podman-hermes-agent.service` or whatever the upstream module names it — verify the actual unit name via `nix eval` of the systemd services, or `systemctl list-units` on the host).
- [ ] **Closing check (local):** `nix eval .#nixosConfigurations.hermes-claw.config.systemd.services.herdr-server.serviceConfig` shows the env + RuntimeDirectory; the dependency ordering evaluates. Run `nix fmt`. Commit.

### Task 4: Vendor the hermes plugin and wire it + socket into the container
- [ ] Extract the exact plugin files for herdr 0.6.10. On a machine with herdr (the Mac the agent runs on has `herdr` at `/opt/homebrew/bin/herdr`): create a scratch hermes home — `mkdir -p /tmp/herdr-extract/.hermes && printf 'model: {}\n' > /tmp/herdr-extract/.hermes/config.yaml` — then `HOME=/tmp/herdr-extract herdr integration install hermes`, and read the generated `/tmp/herdr-extract/.hermes/plugins/herdr-agent-state/` (both `plugin.yaml` and `__init__.py`). Vendor BOTH files into the repo (e.g. `hosts/hermes-claw/herdr-agent-state/`). Do NOT hand-write the plugin — use the generated files verbatim.
- [ ] In `hermes-service.nix`, bind-mount the vendored plugin dir read-only into the container at `/home/hermes/.hermes/plugins/herdr-agent-state` and bind-mount the socket dir: add to `services.hermes-agent.container.extraOptions` two `--volume=` entries — `/run/herdr:/run/herdr:ro` (or rw if the socket needs write; sockets generally need rw on the file, use `/run/herdr:/run/herdr`) and the plugin dir from its Nix store path `:ro`. Keep ALL existing extraOptions (`--security-opt=no-new-privileges`, `--memory=4g`, `--cpus=2.0`).
- [ ] Set container env so the plugin finds the socket: add `HERDR_SOCKET_PATH = "/run/herdr/herdr.sock"` to `services.hermes-agent.environment` (keep existing `TELEGRAM_ALLOWED_USERS`, `HERDR_DASHBOARD`).
- [ ] Enable the plugin in the deep-merged `config.yaml`: add the correct key to `services.hermes-agent.settings` (verify the exact hermes plugin-enable schema — check the hermes-agent repo / `hermes plugins --help` / `hermes config show`; from the binary it is a `plugins:` list referencing `herdr-agent-state`). Do not guess the key blind — confirm it.
- [ ] **Closing check (local):** `nix eval .#nixosConfigurations.hermes-claw.config.system.build.toplevel.drvPath` evaluates; grep the rendered container args / settings via `nix eval` to confirm the two volumes, the env, and the plugin enable are present. Run `nix fmt`. Commit.

### Task 5: Deploy and verify end-to-end status reporting
- [ ] Deploy: `nixos-rebuild switch --flake .#hermes-claw --build-host root@hermes-claw --target-host root@hermes-claw`. Watch for activation errors. The hermes container will be recreated (expect a brief Telegram-frontend downtime + first-boot provisioning delay).
- [ ] Verify infra on host: `systemctl is-active herdr-server` = active; `ls -l /run/herdr/herdr.sock` exists; `podman exec hermes-agent ls -l /run/herdr/herdr.sock` (socket visible in container); `podman exec hermes-agent cat /home/hermes/.hermes/plugins/herdr-agent-state/plugin.yaml` (plugin present); `podman exec hermes-agent hermes plugins list` (or equivalent) shows `herdr-agent-state` enabled.
- [ ] **Closing check (the real one):** scripted over SSH on the host, drive the host herdr CLI — start the hermes pane through herdr so it injects `HERDR_PANE_ID`: `herdr agent start hermes --cwd /root -- podman exec -e HERDR_PANE_ID -e HERDR_SOCKET_PATH=/run/herdr/herdr.sock -it hermes-agent /home/hermes/.local/bin/hermes chat`. Then `herdr agent send hermes "say hello"` and poll `herdr agent get hermes` — confirm `agent_status` transitions to `working` while it generates and back to `idle`/`done` after. This proves the in-container plugin reports through the bind-mounted socket. Record the observed transitions in the findings file.
- [ ] Document the user-facing usage in the findings file: from the Mac, `herdr --remote root@hermes-claw`, then start the hermes pane with the same `podman exec -e HERDR_PANE_ID ...` wrapper. Commit. Move the findings + plan to `docs/plans/completed/` if the repo convention is to archive completed plans.

## Constraints

- **Secrets:** never read, decrypt, print, copy, or modify any `secrets/*.age`, the agenix recovery key (`/root/.age/recovery.key`), or `hermes-env`. Do not log env that may contain API keys/tokens.
- **Do not change** the running Hermes model/provider/auxiliary/Telegram settings in `hermes-service.nix` — only ADD the herdr socket/env/plugin wiring.
- **Do not weaken** container hardening: keep `--security-opt=no-new-privileges`, `--memory=4g`, `--cpus=2.0`. Do not add `--privileged` or extra capabilities.
- **No new inbound ports.** herdr uses a unix socket only — keep the firewall at `allowedTCPPorts = [ 22 ]`. Do not expose herdr over TCP. Keep `/run/herdr` root-owned 0700.
- **Pin herdr to `v0.6.10`** with a content hash. No floating branches/tags.
- **Eval before deploy.** Run the `nix eval` closing checks and `nix fmt` before any `nixos-rebuild`. Only ONE deploy, in Task 5. Build on target (`--build-host root@hermes-claw`) — never attempt a local x86_64 build.
- **Do not delete** `/var/lib/hermes` data or the `hermes-agent` container's writable layer outside the normal module-driven recreation.
- **Branch only.** Work on a feature branch; do not push to or force-push `main`. Do not enable `system.autoUpgrade`.
- **One concern per file.** Follow the repo's existing module/import conventions (mirror `hermes-service.nix` style). Verify every NixOS/systemd option name with `nix eval` rather than assuming it exists.
- If Task 1's closing check FAILS, stop the whole plan and report — do not write the declarative wiring against a broken mechanism.
