# Vigil post-deployment evidence

## 2026-09-22 detailed Gatus dashboard activation

PR #602 merged as `aa57a0b330d457a879268bdaf7112c885da85934`. The owner
approved switching choir first and then rpi5 after all CI passed. Every PR
check was successful before activation, including the previously pending n8n
VM test. Both systems were built in isolated detached worktrees with one job
and one core before switching. The native ARM Vigil build passed all 125 tests;
the Linux package and module checks had also passed during PR preparation.

Choir switched successfully to
`/nix/store/1gwl6w0g0mx5xjpzg0a5gjin4g89d0df-nixos-system-sancta-choir-25.11.20260318.fea3b36`.
Only its three Vigil unit files changed. A post-switch complete run
`bb8a852e2f6740db91d6e60f13347385` published `2026-09-22T10:35:55.108Z`:
**9 verde, 0 picat, 0 NECITIT**, exit 0. All nine `/checks/<public-name>`
responses returned fresh green evidence with that timestamp before rpi5's switch.
Gallery, the Vigil timer, and its socket remained active.

rpi5 activated
`/nix/store/i1izzrvq4mkm6djq2pxwyigylhff7rl6-nixos-system-rpi5-25.11.20260313.3e20095`.
The switch restarted Gatus and polkit, reloaded D-Bus, and ran the existing
n8n workflow-sync job. The sync script differed only in its source store path;
workflow and module sources were unchanged. Complete post-switch run
`30e09acd946440759c4bbbf8caee0dbc` published `2026-09-22T10:38:02.736Z`:
**7 verde, 0 picat, 0 NECITIT**, exit 0. All seven public detail responses
returned fresh green evidence. Gatus, n8n, and the Vigil timer/socket were active.
The switch exited 0, and workflow sync completed with `Result=success` and
`ExecMainStatus=0`. Both hosts had zero open incidents, notas, or queued events.

Gatus initially polled Pi detail routes before the first new snapshot existed;
those seven rows briefly failed closed. Following publication, all **16 detail
rows plus the two original host summaries** passed their normal polls; final
verification found all 18 green with polls at or after `10:40:05Z`. No
production fault was induced to demonstrate diagnostic text; the installed
Gatus version had already been tested with an isolated failure/recovery fixture.
No private contracts were exposed, monitoring thresholds changed, incident state
cleared, or health markers fabricated. Private Home Assistant conditions remain
deferred and production acknowledgement still awaits a natural NECITIT nota.

## 2026-09-22 controlled gallery delivery acceptance

The owner approved stopping only `sancta-gallery.service` for two scheduled
failures, with a 12-minute automatic restore and earlier restoration after
confirmed open delivery. A transient restore timer was armed before the stop
at `2026-09-22T06:18:12Z`. No deployment or incident-state edit occurred.

The first scheduled failed sample published at `06:19:49.034Z`, invocation
`ad8db1785f11474e9ced28bd54f50689`. The second, invocation
`69dbec0a5a1f4a5a9c229fdc9d6a2795`, published at `06:24:49.337Z`.
Only `galeria` failed: eight other checks stayed green. The gallery incident
opened at `06:24:48.997Z`, event
`5eff99e3-ed24-4b78-899f-784845f78b7a`; Telegram API success was recorded,
`openDelivered=true`, its queue drained, and `last-say-ok` updated at
`06:24:49.309Z`.

Gallery was started immediately after that confirmation. The immediate HTTP
probe raced listener startup; a read-only retry verified HTTP 200 and active
service at `06:25:15Z`. The automatic restore was left armed and later reported
success. The first scheduled green sample, invocation
`b4e77d566c174ae293332101b654e83c`, published at `06:29:49.073Z`.
Its recovery start was `06:29:49.051Z`; the unchanged 30-minute hold-down made
close eligible no earlier than `06:59:49.051Z`. Subsequent scheduled checks
remained green while the incident correctly stayed open.

The scheduled close invocation `4bb25d997ae14e83829d9986066e70a3`
published at `2026-09-22T07:00:13.627Z`, with all nine individual checks
`verde`, exit 0, and zero open incidents, notas, or queued events. The close
event was `9c1e8194-a513-4295-a335-b35e8b1bde5d`, recorded at
`07:00:13.323Z`; `last-say-ok` updated at `07:00:13.604Z` and the genuine
channel probe at `07:00:13.607Z`. Gallery, Vigil timer, and tick socket were
active. No hold-down was shortened and no incident state was cleared manually.

rpi5 remained seven green on invocation `6ee9ea0fa23444959e2cbdf3d015d336`
at `06:58:50.538Z`. Both existing Gatus Vigil summaries were green on their
07:00 UTC polls. PR #600 CI was subsequently verified fully green.

This confirms the controlled production open/recovery/close flow and Telegram
API success for both transitions. The owner confirmed exactly one open in
Telegram and supplied both received messages, matching the recorded open
`2026-09-22T06:24:48.997Z` and close `2026-09-22T07:00:13.323Z`. This
confirms receipt of both transitions; the close-message duplicate count was
not separately stated. Production acknowledgement acceptance still awaits a natural
NECITIT nota. This deliberate test does not establish the first real incident
date. Private Home Assistant conditions remain deferred.

## 2026-09-21 choir Telegram activation (18:52 UTC)

The disk incident closed naturally on scheduled run
`e8f6ada77c98404194d8efff669822fd` at `2026-09-21T18:50:49.295Z`.
All eight checks were green, and both open-incident and nota counts were zero.
This completes the row-only recovery gate without manual state edits.

PR #600 merged as `bd63ac64ffe7fccc971c98f3918ab6f202f2f77b`. The owner
approved the single-secret re-key and explicitly approved the production
switch after being informed that the unrelated CI n8n VM test was still
running. The local choir build, module evaluation, public contract bundle,
recipient guard, and formatting checks had passed. CI is not claimed fully
green at deployment time; its remaining x86_64 job was still in progress.

A clean detached checkout built successfully with `--max-jobs 1 --cores 1`
before switch, using the same throttle for activation. Only the three Vigil
unit files differed from the running units in the pre-switch comparison.
The switch exited 0 and activated:
`/nix/store/3cb38jijf482vx7m9fyqzd37x0w4gzvb-nixos-system-sancta-choir-25.11.20260318.fea3b36`.

The documented post-deployment checker was started once. Complete invocation
`24e4cced1ede42e8be77606827cd2e64` published `2026-09-21T18:52:20.036Z`:
**9 verde, 0 picat, 0 NECITIT**, exit 0. All nine individual contracts,
including `channel`, were green. The real channel probe created
`last-channel-ok` at `18:52:19.764Z` and `last-chataction` at `18:52:19.768Z`.
The credential remained root:root mode 0400; markers were vigil:vigil mode
0600. No success marker was fabricated. Open-incident and nota counts were
both zero; timer and socket remained active, as did gallery, worker, and
membrane. Root usage remained 62%, with about 28 GiB available.

This confirms deployed channel activation. Controlled gallery interruption,
exactly-one Telegram open/close acceptance, production acknowledgement
acceptance, and the first real incident date remain pending. Private Home
Assistant conditions remain deferred. Do not move this checklist to completed.

## 2026-09-21 choir approved storage recovery (18:15 UTC)

The owner explicitly approved removal of five reviewed build-result symlinks,
ordinary Nix garbage collection, and archived journal vacuum to 2 GiB.
All five symlink targets were checked against the reviewed store paths before
any was removed. No additional result links or profile generations were removed.

- `/root/nixos-config/result`
- `/root/result`
- `/tmp/sancta-deployment/choir-result`
- `/var/lib/sancta/.claude/continuity-private/2026-09-11-task-context-full-build-v1/system-result`
- `/var/lib/sancta/.claude/continuity-private/2026-09-11-task-context-retention-full-system-v1/system-result`

Nix GC reported **20,726 store paths deleted, 20,585.58 MiB freed**; this actual
result exceeded the earlier NAR-based estimate. Journal vacuum reported another
**2 GiB** freed, leaving about **1.9 GiB** of journals. Root usage dropped from
**95% to 61%**, with about **29 GiB available**. System generations 38, 39, and
40 (current) remain. Owner checkout status was unchanged. Session history,
backups, source edits, encrypted files, and Vigil incident state were not edited.
No production service was stopped and no monitoring threshold was changed.

The next scheduled complete run, `afc0d8df20bb4dab8cf2e58e27bd14da`, published
`2026-09-21T18:20:06.861Z`: **8 verde, 0 picat, 0 NECITIT**. All eight
individual contracts, including `disk-root`, returned green. During subsequent
configuration validation, root usage was 62%, still below the unchanged 85%
threshold. The disk incident remains open in its normal recovery hold-down,
with `greenSince=2026-09-21T18:20:06.849Z`; its earliest eligible close is a
scheduled green run at or after 18:50:06.849 UTC. Do not clear it manually.
Healthy current checks are confirmed; final row-only acceptance with zero open
incidents remains pending. No choir delivery activation has occurred.

## 2026-09-21 rpi5 credential repair acceptance (18:10 UTC)

PR #598 merged as `18177f06956466cdd3573086cbd8974408b3c6b4`. The owner
replaced the credential through agenix using the approved rpi5 identity and
started the replacement bot. Read-only Telegram `getMe` and `getChat` both
returned HTTP 200 with `ok=true`; no credential values were printed.
The x86_64 secrets-recipient guard passed before merge.

A clean detached checkout of that merge built successfully before approved
activation. The resulting system is
`/nix/store/qyfjggh103nak6d9d40801a91wypc1b5-nixos-system-rpi5-25.11.20260313.3e20095`.
The incidental n8n workflow-sync script change is only the repository store
path; workflow contents compare equal. Activation starts that existing sync
job; it completed successfully, the switch exited 0, and the n8n service
remained active.

The next **scheduled** Vigil invocation, `894f9eb829174cfba9aa504945e7ca19`,
published `2026-09-21T18:10:52.585Z`: **7 verde, 0 picat, 0 NECITIT**, with
`ExecMainStatus=0`. All seven individual contract verdicts were green.
`last-chataction` was created at `18:10:50.657Z`, and `last-channel-ok` was
updated at `18:10:52.565Z` by real delivery code. No marker was fabricated.
The timer and socket stayed active. Choir fetched this tick and `/status`
returned `stare=verde`. Production state naturally reached zero open incidents
and zero notas; no state was cleared manually.

This accepts the **seven-public-contract rpi5 baseline**. It does not establish
choir delivery acceptance, a controlled Telegram open/close test, production
acknowledgement acceptance, or an owner-confirmed first real incident date.
Choir still reports 7 verde / 1 picat (`disk-root`) with delivery disabled.
Private HA conditions remain deferred.

## 2026-09-21 inspection (UTC)

PRs #595 and #596 are merged. Both hosts already run Vigil; no rebuild,
switch, production service restart, secret edit, garbage collection, or incident
state edit was performed during this inspection. Private Home Assistant checks
remain deferred until the owner supplies the desired conditions securely.

Administrative SSH targets used from the owner's Mac: `nixos@rpi5` and
`root@sancta-choir-1`. The Mac's `darwin-config` Sancta bridge configuration
also names `sancta@sancta-choir-1`; that account cannot read root-only evidence
with noninteractive sudo. No user `~/.ssh/config` was present.

### Deployed identity

Neither current system exports `configuration-revision`. Record the actual
store paths rather than inferring a deployed Git revision from an owner checkout:

- rpi5: `/nix/store/sjd80vj2w78230az0vaw74rrr682iz76-nixos-system-rpi5-25.11.20260313.3e20095`
- choir: `/nix/store/m8cbrrh2crzwvi41zfaxrazn66vzbz0y-nixos-system-sancta-choir-25.11.20260318.fea3b36`

SHA-256 comparisons of all four deployed Vigil entrypoints, seven library
modules, and each host's public TOML contracts match main at `79c70e9`.
This establishes the inspected Vigil payload, not the entire system revision.

### Complete runs and checks

Both `vigil.timer` units are active/waiting and both `vigil-tick.socket` units
are active/listening. Completed oneshots are inactive/dead with systemd
`Result=success`; exit 2 on rpi5 and exit 1 on choir represent contract verdicts,
not crashed services. Journals were selected by the tick's invocation ID.

| Host | Complete tick (UTC) | Run ID | Results |
| --- | --- | --- | --- |
| rpi5 | 2026-09-21T17:45:21.025Z | a1deeafd15c243a68814e618e9738201 | 6 verde, 0 picat, 1 NECITIT |
| choir | 2026-09-21T17:49:07.547Z | 9352eea697d44ebb9fd1f6ab15d9a57f | 7 verde, 1 picat, 0 NECITIT |

- rpi5 green: `choir-host`, `choir-tick`, `ha-alive`, `ha-served`,
  `soul-mirror-pull`, `tailscaled`.
- rpi5 unknown: `channel`, reason `age-unreadable`.
- Choir green: `build-volume`, `galeria`, `membrana`, `rpi5-host`, `rpi5-tick`,
  `soul-mirror`, `tailscaled`.
- Choir failing: `disk-root`, reason `disk-full`.

Both peer endpoints returned ticks less than five minutes old when inspected;
the rpi5 tick advanced again to `2026-09-21T17:50:41.498Z` with the same counts.
Choir's `/status` correctly returned `stare=picat`.

### Confirmed causes and remediation gates

**rpi5 channel:** `/var/lib/vigil/last-channel-ok` is absent. The configured
EnvironmentFile exists with root ownership and mode 0400. Credential shape
checks passed, but read-only Telegram `getMe` and `getChat` requests both returned
HTTP 401 with `ok=false`. The configured token is rejected; the precise reason
(e.g. revocation or incorrect value) is not established. No credential values,
API response bodies, or private entity names were printed. No Telegram message
was sent by this inspection. Do not manufacture a channel marker. The owner
must supply a working credential through the encrypted editor and approve its
replacement; merely re-keying the rejected credential will not fix delivery.
Require a genuine successful scheduled probe after approved activation.

**Choir disk:** `/dev/sda1` reports 95% used, approximately 67 GiB used and
4.2 GiB available. The contract's unchanged threshold is 85%, using available
space after reserved blocks. Roughly 6.5 GiB must be freed at this snapshot
just to cross that threshold; leave additional headroom. Major usage is
`/nix/store` (33 GiB), `/var/lib` (23 GiB), and journals (3.9 GiB).
Metadata-only inspection found 8.1 GiB of retained session history under
`/var/lib/sancta/.codex/sessions`; this is owner data, not disposable cache.
`nix-store --gc --print-dead` plus NAR size queries totals only 219,856,376
bytes, which is not an exact on-disk reclaim estimate and is insufficient.
The mounted build volume has approximately 50 GiB available. No history,
logs, GC roots, generations, or containers were deleted or moved. A reviewed
retention/capacity action is needed; do not raise the threshold to hide the fault.

Existing incident state is preserved: rpi5 still had two peer incidents in
recovery and one channel nota; choir had one disk incident. Green verdicts do
not imply incidents have completed their normal hold-down or been delivered.

### Acceptance and preserved work

- Installed isolated acknowledgement acceptance passed on **both** hosts via
  `systemd-run`, with `User=vigil`, `PrivateTmp=yes`, exit 0 and
  `AUTOPROBA: 1 assertions suites passed (isolated ack)`. It uses temporary
  fixtures and fake loopback Telegram, not production acknowledgement state.
- The full installed Linux test suite passed on both hosts: 120 tests each.
- The Mac suite was not a valid Linux acceptance substitute: its sandbox blocked
  loopback listeners and macOS injected an extra child environment variable.
- The local owner checkout on `feat/vigil-private-contracts` is clean at
  `79c70e9`. Only the pending recipient policy exists there; no private-contract
  ciphertexts were found in the inspected local checkout or bounded remote
  owner-checkout searches. This is not a whole-filesystem inventory.
- The separate Mac `~/nixos-config` has unrelated tracked and untracked edits.
  Choir's `/root/nixos-config` is on `feat/vigil-secrets`, with a local HA-token
  ciphertext commit and an untracked file. All were preserved. Neither remote
  owner checkout HEAD establishes the deployed system revision.
- No private-contract or choir-delivery activation PR exists at inspection time.
  The prepared choir activation patch passes `git apply --check` against main.
  It remains gated on a healthy baseline, approved credential repair/re-key,
  required Nix checks, review, and an explicitly approved deployment.
- Live Telegram open/close acceptance, production acknowledgement acceptance,
  and the first real delivered incident date remain pending. Gallery interruption
  requires owner approval. Do not move this checklist to `completed/`.

## Remaining operator commands

```sh
# Deployment is observed on both hosts; healthy baseline and live delivery
# acceptance remain pending. See the dated evidence above.
# Run on each deployed host; choose expected=10 on rpi5 after private activation,
# or expected=9 on choir after delivery activation (7/8 before those gates).
expected=9
# Set delivery_enabled=false only for choir before delivery activation (expected=8).
delivery_enabled=true
systemctl is-active vigil.timer vigil-tick.socket
systemctl list-timers vigil.timer --no-pager
sudo systemctl start vigil.service
systemctl show vigil.service -p Result -p ExecMainStatus
sudo jq -e --argjson expected "$expected" \
  '(.verde + .picat + .necitit) == $expected and .necitit == 0' /var/lib/vigil/tick
run_id=$(sudo jq -r .run_id /var/lib/vigil/tick)
sudo journalctl _SYSTEMD_INVOCATION_ID="$run_id" -o cat --no-pager
if [ "$delivery_enabled" = true ]; then
  channel_age=$(( $(date +%s) - $(sudo stat -c %Y /var/lib/vigil/last-channel-ok) ))
  test "$channel_age" -ge 0 && test "$channel_age" -lt 172800
fi

# From choir, inspect rpi5's tick.
curl --fail --max-time 10 http://100.106.93.87:8747/ | jq -e '
  (.la | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t |
  $t <= now and $t > (now - 900)'

# From rpi5, inspect choir's tick.
curl --fail --max-time 10 http://100.94.191.54:8747/ | jq -e '
  (.la | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t |
  $t <= now and $t > (now - 900)'

# Isolated acknowledgement acceptance on either host; fake Telegram only.
sudo systemd-run --unit=vigil-ack-acceptance --wait --collect \
  --property=User=vigil --property=PrivateTmp=yes \
  /run/current-system/sw/bin/vigil autoproba --ack-only

# PENDING: live acknowledgement, only after a natural NECITIT notification.
# Replace this with its generic contract name, never a private entity/device ID.
contract=replace-with-generic-contract-name
sudo test -f "/var/lib/vigil/nota-sent/$contract"
sudo touch "/var/lib/vigil/ack/$contract"
sudo systemctl start vigil.service
sudo test ! -e "/var/lib/vigil/ack/$contract"
run_id=$(sudo jq -r .run_id /var/lib/vigil/tick)
sudo journalctl _SYSTEMD_INVOCATION_ID="$run_id" -o cat --no-pager
# Observe the next threshold crossing and exactly one new NECITIT notification.

# PENDING: first real incident delivery date. Do not substitute the gallery test.
# After a real incident reaches Telegram, record its observed date here.
# Plan 2 starts from that evidence; no date has been recorded yet.
```
