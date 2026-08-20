# Retired

This file is the single place a future reader looks to find out what used to
be here and why it isn't anymore, or isn't active anymore.

**Policy: retirement is declared, not implied.** A host or service does not
quietly stop being referenced — it gets a row in this table, a commit that
says why, and (for deletions) the exact commit to restore it from. Git
history is the archive; nothing here is actually lost, it's just not live.
Two shapes of retirement:

- **Deleted** — the config is gone from the tree. Restore with
  `git show <sha>:<path>` (or `git checkout <sha> -- <path>` to bring the
  whole tree back working-directory-side).
- **Turned off** — the config is still in the tree, just disabled behind a
  flag. Restore is flipping that flag back, nothing archaeological required.

| What | Retired on | Why | Last commit (before retirement) | Restore |
|---|---|---|---|---|
| `sancta-claw` (host) | 2026-08-20 | Destroyed machine — no tailnet response, confirmed gone for good. | `49481d3e4a0345fd17ae886f1b0da897dd0ab4d4` | See **Restoring a retired VPS host** below — a leaf config file alone will not rebuild this host. |
| `hermes-claw` (host) | 2026-08-20 | Destroyed machine — no tailnet response, confirmed gone for good. | `49481d3e4a0345fd17ae886f1b0da897dd0ab4d4` | See **Restoring a retired VPS host** below. |
| `zero-kuzea` (host) | 2026-08-20 | Destroyed machine — no tailnet response, confirmed gone for good. | `49481d3e4a0345fd17ae886f1b0da897dd0ab4d4` | See **Restoring a retired VPS host** below. |
| `auto-approve-sancta-claw.yml` (workflow) | 2026-08-20 | Existed solely to auto-approve kuzea-bot PRs scoped to the now-destroyed `sancta-claw` host. Ran on `pull_request_target`; removing it is a small security win on top of being dead weight. | `a8b29f557bb475a91c2dfdf652bf6de4e8766e7a` | `git show a8b29f557bb475a91c2dfdf652bf6de4e8766e7a:.github/workflows/auto-approve-sancta-claw.yml` |
| Open-WebUI on `sancta-choir` | 2026-08-20 | Unused since ~29 July; kept failing its e2e-test-user oneshot on every switch. **Turned off, not deleted** — `services.open-webui-tailscale.enable` flag. | `433abe66dad93cf5b46ddd743d0f47c829a7afad` (PR #563, merged to main) | Flip `services.open-webui-tailscale.enable = true;` back in `hosts/sancta-choir/configuration.nix`. Data stays at `/var/lib/open-webui`; the agenix secret and config block are intact — no `git show` needed. |
| `checks.x86_64-linux.openclaw-zdr-proxy` + `tests/openclaw-zdr-proxy.nix` (CI check) | 2026-08-20 | Not itself host-coupled (self-contained VM+stub), but its only *production* consumer — `hosts/sancta-claw/openclaw-service.nix` — is gone, so it was testing a module nothing deploys anymore. `modules/services/openclaw-zdr-proxy.nix` and `modules/services/openclaw.nix` are kept (still covered by `tests/module-eval.nix` in isolation) — deleting still-passing module code is an owner call, not bundled into this cleanup. | `13e6f1086b418f6d869902d23de61d12044c756c` | `git show 13e6f1086b418f6d869902d23de61d12044c756c:tests/openclaw-zdr-proxy.nix` + restore the `checks.x86_64-linux.openclaw-zdr-proxy` block in `flake.nix`. |

## Restoring a retired VPS host (`sancta-claw` / `hermes-claw` / `zero-kuzea`)

The per-host `git show <sha>:hosts/<host>/configuration.nix` shortcut is
**not sufficient** — each host was more than one file, and the flake
wiring that turns those files into a buildable `nixosConfigurations.<host>`
was removed too. To actually rebuild one of these hosts:

1. Restore the whole host directory (not just `configuration.nix`), e.g.:
   `git checkout 49481d3e4a0345fd17ae886f1b0da897dd0ab4d4 -- hosts/sancta-claw/`
   (`hosts/hermes-claw/`, `hosts/zero-kuzea/` respectively — each had
   3-11 files: config, disk-config, hardware-configuration, and for
   sancta-claw also openclaw-service/watchers/backup/restore/smoke-test).
2. Restore the matching `nixosConfigurations.<host> = nixpkgs.lib.nixosSystem { ... }`
   block in `flake.nix` from the same commit
   (`git show 49481d3e4a0345fd17ae886f1b0da897dd0ab4d4:flake.nix`) — it
   names the exact modules list (e.g. `disko.nixosModules.disko`,
   `hermes-agent.nixosModules.default` + the `hermesAgentPatched` package
   override for hermes-claw, `kuzea-workspace.packages` for sancta-claw's
   `specialArgs`).
3. Re-add the flake inputs that block depends on — **as of this PR they
   are gone too**: `disko` (sancta-claw + hermes-claw disk partitioning),
   `hermes-agent` (hermes-claw, plus the `hermesAgentPatched` overlay this
   PR also removed from the `outputs` `let`), and `kuzea-workspace`
   (sancta-claw's `specialArgs.kuzea-ws`). Pull their `inputs.<name>` blocks
   from `git show 49481d3e4a0345fd17ae886f1b0da897dd0ab4d4:flake.nix` and
   run `nix flake lock` to relock them.
4. Re-provision the recipient's decryption identity (see "Known follow-up"
   below — the age recipients are still declared, but if the deferred
   secrets-cleanup phase has since run, they'll need re-adding to
   `secrets/secrets.nix` first).
5. Only then does `nixos-rebuild build --flake .#<host>` (or
   `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel`)
   have a chance of working — verify that before attempting
   `nixos-anywhere`/`switch` against real hardware.

## What stays

`sancta-choir` (VPS, live), `rpi5` (Raspberry Pi 5 bootstrap/SD-image
config — keep even though it isn't the daily driver, it's how a fresh Pi
gets imaged) and `rpi5-full` (the Pi's full-service config) are all active
and are not part of this retirement.

## Known follow-up, not done here

`secrets/secrets.nix` still declares decryption recipients for the two
destroyed machines that ever had a distinct age identity —
**`sancta-claw` and `hermes-claw`** (`zero-kuzea` was never a distinct age
recipient; its one secret, `zero-kuzea-telegram-bot-token.age`, was
encrypted to `sancta-claw`'s recovery key). That's roughly **15 grants
across 12 `.age` files, for those two hosts** (verified by reading
`secrets/secrets.nix`: `tailscale-auth-key`, `openrouter-api-key` — 2
grants each, to both hosts; `kuzea-caldav-credentials`,
`kuzea-github-token`, `kuzea-todoist-credentials`,
`kuzea-airtable-credentials`, `kuzea-tavily-api-key`, `openai-api-key`,
`restic-password`, `anthropic-api-key` — 1 grant each, to sancta-claw;
`zero-kuzea-telegram-bot-token` — 1 grant each to both hosts; `hermes-env`
— 1 grant, to hermes-claw). Dropping dead recipients is a separate, gated
phase (owner's call, with council review before it happens), not part of
this PR. See the agenix rotation runbook in `docs/SECRETS-ROTATION.md`
when that phase starts.
