# Vigil post-deployment evidence

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
