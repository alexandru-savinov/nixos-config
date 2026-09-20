# Vigil v1 operator handoff

Implementation and local tests are not deployment evidence. The owner performs
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
ownership for backup-pull and tailscale-dns-watchdog, with group `vigil` and
mode `0440`. The Home Assistant token is owned by `vigil`.

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
different generic names for the three files. Never copy the resulting
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

## Pending evidence

- rpi5 deployment and live peer acceptance.
- Choir row-only deployment, secret re-key, and subsequent delivery activation.
- Owner-authored private ciphertexts and their activation PR.
- Live Telegram open/close acceptance and production ack acceptance.
- First real incident date; record it only after a real notification arrives.

The remaining choir steps and final activation patches will be added before
the implementation is declared ready for deployment.
