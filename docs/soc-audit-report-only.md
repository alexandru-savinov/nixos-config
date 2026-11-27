# Choir report-only Vigil contracts

Inventory and read-only systemd status as of 2026-11-27 at approximately
17:33 EET. The two deployed evaluators had both run successfully. Systemd
reported each completed oneshot as inactive with main exit status 0.

| Contract | Deployed target | Evaluator | Last observed successful run (EET) | Paging after hardening |
| --- | --- | --- | --- | --- |
| `soc-audit` | `/var/lib/soc-vigil-alarms/audit-clean` | `soc-alarm-audit.service` | 2026-11-27 17:29:42 | Hits remain report-only on `audit-hits-clean`. The independent `soc-audit-watchdog.timer` pages through `soc-audit-deadman` when `audit-clean` is older than 30 minutes or auditd reports it has stopped recording. A successful evaluation refreshes that heartbeat even when it reports a hit. |
| `soc-bans-health` | `/var/lib/soc-vigil-alarms/bans-health-clean` | `soc-alarm-bans.service` | 2026-11-27 17:29:14 | The existing health contract pages. |

After hardening, `soc-audit` is the only Choir contract with `page = false`.
The module evaluation checks the configured directories and requires a
paging health path for each report-only contract it finds.

A checkpoint recovery records `from` and `to` as audit epoch timestamps
and `cause` as the ausearch exit status in
`/var/lib/soc-vigil-alarms/audit.coverage-gap`. Status 10 can leave the
checkpoint timestamp unreadable, recorded as `from=unknown`. After
reviewing the retained evidence and gap record, an operator acknowledges
the coverage incident by removing only
`/var/lib/soc-vigil-alarms/audit.checkpoint-mismatch`. The next watchdog
run observes the acknowledgement. The evidence stamp remains in place.
The evaluator applies `chattr +a` on filesystems that support it and waits
for the gap record to be written before classifying replayed events.
Replay adds one retained log at a time and saves its progress after classifying
each chunk. A timed-out run resumes from that checkpoint. Only a completed
evaluation refreshes `audit-clean`.

Vigil starts the watchdog and waits for it before sampling the three stamps.
This refreshes healthy stamps left over from before boot. The watchdog keeps
its independent timer and the 30-minute heartbeat limit. Vigil can page on
the first sample of a confirmed failure.

An increase in the kernel audit `lost` counter within one boot pages
through the same coverage-gap contract. Acknowledge it by removing
`/var/lib/soc-vigil-alarms/audit.kernel-loss` after reviewing the audit
evaluator journal. If both incidents are present, each requires its own
acknowledgement.
