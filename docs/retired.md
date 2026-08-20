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

| What | Retired on | Why | Last commit (where it lived) | Restore |
|---|---|---|---|---|
| `sancta-claw` (host) | 2026-08-20 | Destroyed machine — no tailnet response, confirmed gone for good. | `d6bcca5fde22fc5bf01435ecd636a13294f39ae2` | `git show d6bcca5fde22fc5bf01435ecd636a13294f39ae2:hosts/sancta-claw/configuration.nix` |
| `hermes-claw` (host) | 2026-08-20 | Destroyed machine — no tailnet response, confirmed gone for good. | `f51c117805d2e1df9b04ec6119ef89903a364e84` | `git show f51c117805d2e1df9b04ec6119ef89903a364e84:hosts/hermes-claw/configuration.nix` |
| `zero-kuzea` (host) | 2026-08-20 | Destroyed machine — no tailnet response, confirmed gone for good. | `c636a50b4775acac13d865c9fe43e8821c1d9380` | `git show c636a50b4775acac13d865c9fe43e8821c1d9380:hosts/zero-kuzea/configuration.nix` |
| `auto-approve-sancta-claw.yml` (workflow) | 2026-08-20 | Existed solely to auto-approve kuzea-bot PRs scoped to the now-destroyed `sancta-claw` host. Ran on `pull_request_target`; removing it is a small security win on top of being dead weight. | `a8b29f557bb475a91c2dfdf652bf6de4e8766e7a` | `git show a8b29f557bb475a91c2dfdf652bf6de4e8766e7a:.github/workflows/auto-approve-sancta-claw.yml` |
| Open-WebUI on `sancta-choir` | 2026-08-20 | Unused since ~29 July; kept failing its e2e-test-user oneshot on every switch. **Turned off, not deleted** — `services.open-webui-tailscale.enable` flag. | `433abe66dad93cf5b46ddd743d0f47c829a7afad` (PR #563, merged to main) | Flip `services.open-webui-tailscale.enable = true;` back in `hosts/sancta-choir/configuration.nix`. Data stays at `/var/lib/open-webui`; the agenix secret and config block are intact — no `git show` needed. |

## What stays

`sancta-choir` (VPS, live), `rpi5` (Raspberry Pi 5 bootstrap/SD-image
config — keep even though it isn't the daily driver, it's how a fresh Pi
gets imaged) and `rpi5-full` (the Pi's full-service config) are all active
and are not part of this retirement.

## Known follow-up, not done here

`secrets/secrets.nix` still declares decryption recipients for the three
destroyed machines above — roughly 35 grants across the various `.age`
files. Dropping dead recipients is a separate, gated phase (owner's call,
with council review before it happens), not part of this PR. See the
agenix rotation runbook in `docs/SECRETS-ROTATION.md` when that phase
starts.
