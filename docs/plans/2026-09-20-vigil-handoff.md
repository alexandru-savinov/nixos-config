# Vigil v1 operator handoff

The [2026-09-21 inspection](2026-09-20-vigil-postdeploy.md) confirms both public
rollouts are deployed. After PR #598 and approved activation, rpi5 has seven
green public checks and a successful channel probe. Choir disk capacity still
blocks its healthy-baseline acceptance. Implementation and local tests alone
are not deployment evidence. The owner performs
every switch, re-key, private-contract edit and live acceptance below. No live
incident date has been recorded. Explain/recovery remains in plan 2.

Public contracts pass two gates: Nix checks syntax, schema shape and service
prerequisites during evaluation; the required contract-bundle build uses Node's
runtime validator for full regex and URL semantics. The systemd command reads
that validated bundle, so a failed semantic check prevents building the system
before activation. Private runtime directories never enter a build derivation.
If runtime incident/channel contracts are loaded with delivery disabled, every
run emits `WARNING delivery-disabled for incident/channel contracts` to the
journal. Checks and local state continue in row-only mode. Before relying on
alerts, supply the Telegram environment and confirm a real channel success;
the warning must disappear. Public contracts enforce this prerequisite at build
time because their contents are available there.

Gatus displays Vigil through `/status`. Inspect its failed condition to distinguish
`picat` from `NECITIT`; stale or mismatched evidence cannot show green. This view
does not send a second set of incident alerts or advance Vigil's state. The
[reuse decision](2026-09-20-vigil-reuse.md) records why the incident engine remains.

The unit-age checks for `soul-mirror-pull.service` on rpi5 and
`sancta-soul-mirror.service` on choir use systemd’s current-boot completion
timestamp. After a reboot, a prior successful run is not observable through
that property: the contract stays `NECITIT` until a new successful run. A
persistent timer catches missed schedules, but does not rerun a schedule
that already completed before the reboot. Allow the next scheduled run
before requiring zero NECITIT; do not fabricate a success marker or treat
unknown evidence as green. Persisting backup success across boots requires
a separately reviewed change to the backup producer, outside this plan’s
restriction on modifying the soul-mirror services.

## 1. rpi5: seven public contracts

After the rpi5 implementation PR is merged and CI is green, run from the owner's
clean repository checkout on rpi5:

```sh
test -z "$(git status --porcelain)"
git switch main
git pull --ff-only
nixos-rebuild build --flake .#rpi5-full &&
  sudo nixos-rebuild switch --flake .#rpi5-full
systemctl is-active vigil.timer vigil-tick.socket
sudo systemctl start vigil.service
systemctl show vigil.service -p Result -p ExecMainStatus
sudo jq -e '(.verde + .picat + .necitit) == 7 and .necitit == 0' /var/lib/vigil/tick
run_id=$(sudo jq -r .run_id /var/lib/vigil/tick)
sudo journalctl _SYSTEMD_INVOCATION_ID="$run_id" -o cat --no-pager
sudo stat /var/lib/vigil/last-channel-ok
curl --fail --max-time 10 http://100.106.93.87:8747/status | jq '{stare, la}'
```

The complete run must exit 0 or 1, with seven contracts and zero NECITIT,
after a confirmed channel probe. Choir peer checks may be picat until its
socket is deployed. Failed Telegram probing leaves channel NECITIT honestly;
do not create a success marker by hand. `backup-telegram-env` retains root
ownership and mode `0400`: systemd reads the EnvironmentFile before starting
the unprivileged checker. The Home Assistant token is owned by `vigil`. The
status responder masks agenix storage, configured credential paths and private
contract directories; it receives no credential environment.

From choir, verify the peer endpoint and its embedded timestamp:

```sh
curl --fail --max-time 10 http://100.106.93.87:8747/ | jq -e '
  (.la | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t |
  $t <= now and $t > (now - 900)'
```

## 2. Isolated acknowledgement acceptance

Run the installed test as the service account. It uses a temporary missing-file
fixture and a loopback fake Telegram server; it does not use production state
or contact Telegram:

```sh
sudo systemd-run --unit=vigil-ack-acceptance --wait --collect \
  --property=User=vigil --property=PrivateTmp=yes \
  /run/current-system/sw/bin/vigil autoproba --ack-only
```

Expected output includes `AUTOPROBA:` and `(isolated ack)`, with exit 0.
Production ack acceptance remains pending until a natural NECITIT nota exists.
Then create only the matching generic contract's ack file and inspect its next
complete runs; the next run consumes it and restarts the nota threshold.

## 3. Private contracts: owner creation, then one activation commit

The active recipient registry cannot name missing ciphertexts: CI's existing
guard rejects that state. The separate pending policy has the intended
`users ++ [ rpi5 ]` recipients without activating them.

In the owner's feature branch, from the repository root:

```sh
git switch -c feat/vigil-private-contracts
cd secrets
RULES=./vigil-contracts.pending.nix agenix -e vigil-rpi5-contract-1.age
RULES=./vigil-contracts.pending.nix agenix -e vigil-rpi5-contract-2.age
RULES=./vigil-contracts.pending.nix agenix -e vigil-rpi5-contract-3.age
cd ..
```

Use this template inside the encrypted editor only; replace `sensor.example`
and the expected value with the actual fixed-location entity and state. Use
different generic names for the three files. Both validators reject `person`,
`device_tracker`, and `mobile_app` targets. For sensor entities, verify their HA
integration is fixed-location: a sensor name alone cannot exclude mobile-app
backing. Never copy the resulting
plaintext into a PR, journal excerpt, fixture, or commit message.

```toml
[contract]
nume = "private-1"
ce = "Local condition"
verifica = "hass-state"
tinta = "sensor.example"
astept = { valoare = "on" }
picat_dupa = 2

[spune]
nivel = "incident"
```

The prepared patch promotes the three rules and adds all three declarations
with `owner = "vigil"`, `group = "vigil"`, explicit `.toml` paths and
`symlink = false`. It adds the **string** `"/run/vigil-contracts"`, retains
`expectedContracts = 7`, and sets `expectedRuntimeContracts = 3`.
Apply it only after all three ciphertexts exist, then commit them together.
Run the x86_64 checks below from an x86_64 editing checkout or a checkout with
an x86_64 builder; the rpi5 deployment commands remain on rpi5:

```sh
test -s secrets/vigil-rpi5-contract-1.age
test -s secrets/vigil-rpi5-contract-2.age
test -s secrets/vigil-rpi5-contract-3.age
git apply --check docs/plans/vigil-private-activation.patch
git apply docs/plans/vigil-private-activation.patch
nix fmt -- hosts/rpi5-full/configuration.nix secrets/secrets.nix
git add hosts/rpi5-full/configuration.nix secrets/secrets.nix \
  secrets/vigil-rpi5-contract-1.age secrets/vigil-rpi5-contract-2.age \
  secrets/vigil-rpi5-contract-3.age
nix build .#checks.x86_64-linux.module-eval .#checks.x86_64-linux.secrets-recipient-guard --no-link
git commit -m "feat(vigil): activate three private contracts on rpi5"
git push -u origin feat/vigil-private-contracts
gh pr create --base main --title "feat(vigil): activate private rpi5 contracts" \
  --body "Adds three owner-authored encrypted contracts and their matching recipient rules/runtime declarations. Public count stays 7; runtime count becomes 3. Module evaluation and recipient guard passed. Owner deployment and live acceptance remain pending."
```

Review this activation PR and require green CI before the owner's switch.
Never use `agenix -r` as a substitute for a single-secret edit or re-key.

After activation, verify three regular `.toml` files owned by `vigil` and a
complete run reporting ten contracts with zero NECITIT:

```sh
sudo ls -l /run/vigil-contracts/
sudo systemctl start vigil.service
sudo jq -e '(.verde + .picat + .necitit) == 10 and .necitit == 0' /var/lib/vigil/tick
```


## 4. Choir: eight row-only contracts

After the choir row-only PR is merged and CI is green, use a clean owner
checkout on choir. Build successfully before switching, with one build job:

```sh
test -z "$(git status --porcelain)"
git switch main
git pull --ff-only
nixos-rebuild build --flake .#sancta-choir --max-jobs 1 --cores 1 &&
  sudo nixos-rebuild switch --flake .#sancta-choir --max-jobs 1 --cores 1
systemctl is-active vigil.timer vigil-tick.socket
sudo systemctl start vigil.service
sudo jq -e '.verde == 8 and .picat == 0 and .necitit == 0' /var/lib/vigil/tick
sudo jq -e 'all(.contracts[]; .open == null and .nota == null)' /var/lib/vigil/incidents.json
```

If an incident is still open, wait for the normal green threshold and
30-minute hold-down; do not edit state to clear it. The fresh tick and eight
green verdicts are acceptance evidence even if no transition row exists.
The packaged `vigil autoproba` verifies that disabled delivery writes a row
without sending a request, queuing an event, or creating a success marker.

From rpi5, verify choir's timestamp and then its peer contract verdicts:

```sh
curl --fail --max-time 10 http://100.94.191.54:8747/ | jq -e '
  (.la | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t |
  $t <= now and $t > (now - 900)'
sudo systemctl start vigil.service
run_id=$(sudo jq -r .run_id /var/lib/vigil/tick)
sudo journalctl _SYSTEMD_INVOCATION_ID="$run_id" -o cat --no-pager
```

Both `choir-host` and `choir-tick` must report `verde`.

## 5. Choir: re-key and enable delivery together

Only after section 4 is accepted, use a clean owner x86_64 editing checkout
whose age identity can decrypt the existing Telegram ciphertext. The patch
adds choir's recipient, declares its runtime secret, enables delivery, flips
the eight contracts to incident mode and adds the ninth channel contract.
The owner must re-key the ciphertext before committing the recipient change.

```sh
git switch -c feat/vigil-choir-delivery
git apply --check docs/plans/vigil-choir-activation.patch
git apply docs/plans/vigil-choir-activation.patch
(cd secrets && EDITOR=: agenix -e backup-telegram-env.age)
nix fmt -- hosts/sancta-choir/configuration.nix secrets/secrets.nix
git add hosts/sancta-choir/configuration.nix hosts/sancta-choir/vigil-contracts \
  secrets/secrets.nix secrets/backup-telegram-env.age
nix build .#checks.x86_64-linux.module-eval \
  .#checks.x86_64-linux.vigil-public-contracts-choir \
  .#checks.x86_64-linux.secrets-recipient-guard --no-link
git commit -m "feat(vigil): enable choir delivery after secret re-key"
git push -u origin feat/vigil-choir-delivery
gh pr create --base main --title "feat(vigil): enable choir Telegram delivery" \
  --body "Activates delivery for nine choir contracts and includes the owner-rekeyed Telegram ciphertext with its matching recipient rule. Require green CI and review before deployment; live acceptance remains pending."
```

After review and green CI, repeat section 4's build-before-switch commands
on choir. Confirm nine contracts with zero NECITIT and a real channel marker:

```sh
sudo systemctl start vigil.service
sudo jq -e '(.verde + .picat + .necitit) == 9 and .necitit == 0' /var/lib/vigil/tick
sudo stat /var/lib/vigil/last-channel-ok
```

During a quiet hour, the owner performs the live gallery acceptance:

```sh
sudo systemctl stop sancta-gallery.service
sudo journalctl -fu vigil.service -o cat
```

Observe two consecutive scheduled `galeria` failures and exactly one Telegram
`open`. Exit the journal viewer and restore the gallery:

```sh
sudo systemctl start sancta-gallery.service
sudo journalctl -fu vigil.service -o cat
```

Observe two consecutive green results and a continuous 30-minute green
hold-down, then exactly one Telegram `close`. Restore the gallery even if the
notification test fails. Record the observed messages and timestamps only
after this test actually runs; a test incident is not the first real incident.

## Pending evidence

Use [the pending post-deployment checklist](2026-09-20-vigil-postdeploy.md) to
record owner acceptance. Keep it in `docs/plans/` while any evidence is pending;
move it to `docs/plans/completed/` only after all acceptance steps and the first
real incident delivery date are recorded.

- rpi5 seven-public-contract baseline is accepted after PR #598; private
  activation and live delivery/ack acceptance remain separate gates.
- Choir disk recovery and healthy row-only acceptance; row-only deployment is
  observed. Secret re-key and delivery activation remain pending.
- Owner-authored private ciphertexts and their activation PR.
- Live Telegram open/close acceptance and production ack acceptance.
- First real incident date; record it only after a real notification arrives.
