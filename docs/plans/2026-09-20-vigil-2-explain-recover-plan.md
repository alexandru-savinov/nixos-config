vigil plan 2 — explain with a model and recover declared units — to be written in full only after vigil v1 (`2026-09-20-vigil-plan.md`) has been live on both hosts and the first real incident has reached Telegram.

## Context

This file is a **stub**, not an executable plan. It exists so that what three
review rounds established about the explain/recover half is not lost while v1
ships without it. Do not run ralphex on this file until it has Tasks with
closing checks.

What v1 leaves in place for it: three-valued verdicts, `incidents.json` with an
`incident_id` per open, the `ack` drop-file, the outbox, the `nota`/`incident`
levels, the tick, and a `[recuperare]` section that v1 parses and **rejects**.

## Requirements established by review (rounds 1–3), to be honoured here

- **Separation by files, two users.** explain runs as `sancta` (holds the model
  CLI's auth) in its own unit and timer (≈2 min); vigil-check (the journal-group
  account) writes the redacted journal slice and sends; explain only concludes.
  The handoff filename is one string defined once — `conclusions/<nume>-<incident_id>.json`
  — and both sides cite it. A conclusion is sent as its own transition
  (`explicatie`) while the incident is still open.
- **Shared directories need a setgid group** (`vigil-spool`: `vigil` + `sancta`),
  with an explicit tmpfiles parent line so `StateDirectory` never re-chowns.
- **Redaction is a closed, enumerated pattern list** (`homeassistant.components.http.ban`,
  `homeassistant.auth`, `mobile_app`, `person.*`, `device_tracker.*`,
  `/home/<user>`, IPv4/IPv6/MAC literals, `*.ts.net`, `@handles`) exercised by a
  separately checked-in corpus; the mutant names the disabled entry. Journal
  text never leaves the host. `journalctl`'s exit status is checked.
- **`jurnal` must be declared on the real contracts** (galeria, membrana,
  tailscaled, soul-mirror, open-webui, n8n), not only on a probe — or explain
  runs on the incident record alone when none is declared.
- **Recovery needs right #4**: a polkit rule derived **from the contracts'
  `[recuperare].act`** (`<abs systemctl> restart <unit>`, `.service` suffix
  normalised), `security.polkit.enable = true` set by the module (polkit is not
  enabled on choir today), the eval test reading the **installed** rules file.
  Proven as `vigil` from a `vigil-autoproba.service` with `OnBootSec` + a
  weekly timer — never by impersonating `vigil` — with a positive probe unit
  (`ExecStart = ${pkgs.coreutils}/bin/true`, `wantedBy multi-user.target` so it
  is verde from boot), a negative one absent from every contract, and a
  `vigil-probe-fail.service` that exits 0 unless the owner's drop-file exists;
  arms assert on `systemctl`'s stderr text (`Access denied` /
  `Interactive authentication required` vs `Job for … failed`) and skip with
  `SĂRIT` when the uid is not `vigil`'s.
- **Every contract file added moves `expectedContracts`** in the same commit.
- A restart has no inverse: the section is `[recuperare]` (bounded recovery),
  `max` per incident and 2 per 24 h, escalation then `ack`.

## Inputs still needed before this becomes a plan

- The date and shape of v1's first real incident (from
  `docs/plans/completed/2026-09-20-vigil-postdeploy.md`).
- The owner's choice of `explain.command` (which model CLI, which model).
- Whether polkit's enablement on choir has any effect on `herdr`/`sancta-worker`
  (both use `systemctl` from raw shells — see `hosts/sancta-choir/configuration.nix`
  near "polkit and sudoers").
