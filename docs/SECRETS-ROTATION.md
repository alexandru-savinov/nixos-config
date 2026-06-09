# Secrets rotation & agenix safety

Operator guide for rotating agenix secrets and — more importantly — for not
corrupting them. Distilled from the #57/#60/#61/#62 incident and the #448
retrospective.

## ⚠️ The fail-open trap: host-key rotation corrupts secrets

**Rotating an agenix-recipient SSH host key (e.g. re-imaging rpi5) corrupts
every secret subsequently re-encrypted on that host.** When `agenix -r` or
`agenix -e` runs on a host whose SSH host key no longer matches the key the
existing `.age` files were encrypted to, agenix cannot decrypt the old
ciphertext and silently re-encrypts **empty plaintext** to the new recipients.
The output *looks* healthy — valid `age-encryption.org/v1` header, valid
recipient stanzas — but carries zero useful bytes.

This happened in this repo: the `nixos-raspberrypi` image switch (`e5339b1`,
#57) rotated rpi5's host key as a side effect, corrupting five secrets and
triggering a restore → re-corrupt → restore thrash across #60/#61/#62.

### Diagnostic signature

- **Uniform file size across secrets that should differ in length**, and
- a **~32-byte binary payload** after the `---` MAC line (16-byte STREAM
  nonce + 16-byte tag of a zero-length chunk), and
- the **new** host key as a recipient stanza.

Do not key on a specific total file size — that is a recipient-count
artifact (a healthy short secret with two recipients is ~415 bytes).

### Mechanical guard

`nix flake check` runs `tests/secrets-recipient-guard.nix` (CI does too),
which fails on:

- recipient-stanza count drift between `secrets/*.age` headers and the
  `publicKeys` declared in `secrets/secrets.nix`,
- any `.age` payload ≤ 32 bytes (the empty-plaintext signature),
- `.age` files on disk that are not declared, and declared files missing on
  disk (the registered-but-never-created activation footgun).

## Safe re-keying procedure

Run `agenix -r` / `agenix -e` **only from a host whose current SSH host key
still matches its recipient stanza in the existing files**:

```bash
# 1. Confirm the host's key matches its entry in secrets/secrets.nix
cat /etc/ssh/ssh_host_ed25519_key.pub

# 2. Re-key
cd secrets && agenix -r

# 3. Verify BEFORE committing: stanza counts match declarations and
#    every file still decrypts to non-empty plaintext
nix build .#checks.x86_64-linux.secrets-recipient-guard   # or rely on CI
sudo age -d -i /etc/ssh/ssh_host_ed25519_key secrets/<file>.age | wc -c
```

If a host key has rotated: **first** restore the affected `.age` files from
git history (or re-create from the upstream credential), update the key in
`secrets/secrets.nix`, then re-key from a still-valid host.

## Recipient model & risk posture

Recipient lists serve **two roles**: they must cover the runtime-consuming
host *and* every machine secrets are edited from (that is why `rpi5` appears
in `clawKeys` — edits happen on rpi5-full).

| Host | Decryption identity | Rotation risk |
|------|--------------------|---------------|
| sancta-claw | stable `age1…` recovery key (`/root/.age/recovery.key`) | decoupled from host key — safe |
| hermes-claw | stable recovery key (`/root/.age/recovery.key`) | decoupled — safe |
| zero-kuzea | stable recovery key (shared with sancta-claw) | decoupled — safe |
| **rpi5 / rpi5-full** | **SSH host key** (`secrets.nix` `rpi5`) | **accepted risk** — see below |
| **sancta-choir** | **SSH host key** (`secrets.nix` `sancta-choir`) | **accepted risk** — see below |

**Accepted risk (recorded 2026-06, #448):** rpi5 and sancta-choir still use
their SSH host keys as agenix recipients. A host-key rotation there (rare:
re-image or fresh install, not a normal `nixos-rebuild`) re-opens the
fail-open trap. This is accepted for now because (a) the recipient-guard
check now catches the corruption signature mechanically before merge, and
(b) the planned recipient-model refactor (#414, "Shape C" bundles) moves all
hosts to stable age identities — fixing this structurally. If #414 stalls,
give rpi5 the same `recovery.key` + `age.identityPaths` treatment as the
VPS hosts.

## Related docs

- `docs/DISASTER-RECOVERY.md` — recovery-key bootstrap for the VPS hosts
- `secrets/secrets.nix` — single source of truth for recipients
