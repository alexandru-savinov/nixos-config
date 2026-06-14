# herdr on sancta-choir — findings

Evidence for running herdr as an **always-on server** on `sancta-choir` so
long-running AI-agent sessions live on the VPS and survive the Mac sleeping.
Attach from the Mac with:

    herdr --remote herdr@sancta-choir-1.tail4249a9.ts.net

> **Update (security redesign, PR #499):** the server now runs as a dedicated
> unprivileged `herdr` user, not root. The runtime evidence below was captured
> during the original root-era deploy, so its `User=root` / `root@` / socket
> `/root/.config/herdr/...` references describe that first deployment. The
> current design attaches as `herdr@…`, the socket lives under
> `/var/lib/herdr/.config/herdr/`, and herdr's only sudo is the fixed-flake
> `herdr-deploy` wrapper + `nixos-collect-garbage` (no raw nixos-rebuild/systemctl).

Branch `feat/herdr-sancta-choir`:
- `e9b11ef` feat: herdr module (`modules/services/herdr.nix`) + enable on sancta-choir
- `0cd2b2b` fix: `curl` on the herdr-server PATH (agent-state detection manifest)

## H1 — binary linkage (de-risked Mac-local, no execution, no VPS)

`nix store prefetch-file` of the v0.6.10 release binary →
`hash = sha256-eNKY1aHvB2tGB+jjyS2Y9d6fDLMNrzGqkQoabpq7T6E=`.
`file` → **"ELF 64-bit … static-pie linked"**, no `INTERP` segment, no `NEEDED`
libs ⇒ **statically linked** ⇒ runs directly on NixOS, **no `autoPatchelfHook`**.
The derivation is a plain `fetchurl` + `install -Dm755` (stdenvNoCC). PASS.

## Eval-tier (Mac — necessary, not sufficient)

- `herdr-server.serviceConfig`: `ExecStart=${herdr}/bin/herdr server`,
  `Restart=on-failure`, `User=root`; `environment.HOME=/root`;
  `wantedBy=[multi-user.target]`.
- `herdr` present in `environment.systemPackages`.
- rendered unit `Environment=PATH` includes `curl-8.18.0-bin` (after `0cd2b2b`).
- full closure `…system.build.toplevel.drvPath` instantiates;
  `nixpkgs-fmt --check` + trivy secret scan clean.

## Deploy gotcha (recorded for next time)

The Mac (aarch64) can't build the x86_64 closure, so deploy builds on the VPS.
`nixos-rebuild switch --flake github:…?ref=feat/herdr-sancta-choir#sancta-choir`
**served a STALE cached branch revision** (rebuilt `e9b11ef`, not the pushed
`0cd2b2b`) — the changed unit was therefore not restarted. Fix: **pin the full
commit SHA** to force the right revision:

    nixos-rebuild switch --flake github:alexandru-savinov/nixos-config/<full-sha>#sancta-choir

## Runtime-tier (on the VPS) — PASS

- `herdr-server.service`: **active (running)**, **enabled** (boot-start), pid 829768.
- socket `/root/.config/herdr/herdr.sock` (srw-------, root) present.
- `herdr 0.6.10` on PATH at `/run/current-system/sw/bin/herdr` (matches the Mac).
- **H2 (clients attach to the systemd server, not a rival):** `herdr status` →
  `server: running, compatible: yes, socket: /root/.config/herdr/herdr.sock`;
  `herdr workspace list` → valid JSON-RPC reply. Single server process. PASS.
  (`herdr --remote` uses this same client-attach path over SSH.)
- **curl fix:** after the restart (pid 829768) the log shows **0 "curl failed"**
  warnings (was 2 on the pre-curl start). Agent-detection manifest refresh works.
- **Open-WebUI unaffected:** `open-webui.service` active throughout.

## Auto-restart after reboot

Unit is `enabled` (`WantedBy=multi-user.target`) + `Restart=on-failure` ⇒ starts
on boot, restarts on crash. Not force-tested by rebooting prod; the `enabled`
state is the declarative guarantee. **Caveat:** pane *processes* don't survive a
kernel reboot — the workspace/tab layout restores from `session.json` and
official agent conversations are resumable (`claude --resume`). Live processes
only survive a client disconnect / Mac sleep.

## Survive-Mac-sleep (the point) — mechanism verified; final observation is user-side

The server runs on the VPS, so Mac sleep only drops the *client*; herdr keeps
panes/processes running across a client disconnect (documented behavior; H2
confirms re-attach). End-to-end check to run from the Mac:

    herdr --remote herdr@sancta-choir-1.tail4249a9.ts.net   # open a tab, start `claude` / a long task
    pmset sleepnow                                          # (or close the lid), then wake
    herdr --remote herdr@sancta-choir-1.tail4249a9.ts.net   # reattaches — session + process still alive

## Pre-existing issue flagged (NOT herdr, NOT fixed here)

`open-webui-memory-migration.service` fails on **every** activation
(`sqlite3.IntegrityError: NOT NULL constraint failed: config.version`) — it
partially applies (`enable_memories`, `enable_memory_tool`), then dies inserting
a config row without `version`. **Failed 7× across history → predates this
change.** Consequence: every `nixos-rebuild switch` on this host exits 4, and a
co-changed unit may be skipped in the same activation. Worth a separate fix in
`modules/services/open-webui.nix` (the migration should set `version` on insert,
or `UPSERT`).
