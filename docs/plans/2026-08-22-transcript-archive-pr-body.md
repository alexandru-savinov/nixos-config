# PR body — append-only encrypted transcript archive

> Draft body for the `transcript-archive-build` PR. Kept in-tree so the open
> his-hand items are NAMED in the repo before the PR exists, not remembered at
> PR time. Paste as the PR description; keep it updated as tasks land.

Closed sessions under `/var/lib/sancta/.claude/projects/` become age-encrypted,
opaquely-named, content-addressed objects published on `sancta-choir` under the
directory rpi5 already pulls. Zero new transport, zero new keys, zero
plaintext on the wire or at rest off-host.

- Design: `docs/plans/2026-08-22-transcript-archive-design.md`
- Plan: `docs/plans/2026-08-22-transcript-archive-plan.md`

## Open his-hand item (does NOT block this PR)

- [ ] **rpi5 vault freshness probe — Alexandru's hand.** Prove
      `/var/lib/soul-mirror` on rpi5 actually holds FRESH
      `sancta-soul-*.tar.gz.age` tarballs:
      `ls -lt /var/lib/soul-mirror/sancta-soul-*.tar.gz.age | head`.
      If it is empty, the pull key is unprovisioned and
      `soul-mirror-pull` self-suppresses SILENTLY (`soul-mirror-pull.nix:75-81`,
      `exit 0` on a missing/placeholder key) — the archive would then publish
      into a vault that nobody pulls, and every check on the choir side would
      still read green. Repairing that key is a SEPARATE task (provisioning
      steps are already written in the mirror module header); it is deliberately
      NOT a blocker for building the producer.

  Indirect evidence, already gathered (2026-08-22 probe, his hand): the
  receiver-side dead-man `soul-mirror-staleness` ran OK three times in a row
  (20–22 Aug, `status=0`, no `Failed with result` in the journal). That unit
  exits 1 when the vault is empty or the newest tarball is older than 8 days
  (`soul-mirror-pull.nix:137-143`), so three green runs imply a non-empty,
  ≤8d-fresh vault. It is an INFERENCE from an exit code, not a directory
  listing — the listing above is what closes the item.

## Task 1 — transport verified from the repo (no host touched)

- [x] Choir publishes ciphertext at `services.sancta-soul-mirror.localDir`
      = `/var/lib/sancta/soul-mirror`, mode 700 owner `sancta`
      (`modules/services/sancta-soul-mirror.nix:248-252`, `:290-292`;
      host wiring `hosts/sancta-choir/configuration.nix:236-242`, with a REAL
      `pullPubKey` — the endpoint is live, not inert).
- [x] The endpoint is a per-key forced command:
      `restrict,command="…/rrsync -ro ${cfg.localDir}"`
      (`sancta-soul-mirror.nix:301-304`); rpi5 dials the PUBLIC IP with
      `remoteDir = "/"` and `rsync -az` (`hosts/rpi5-full/soul-mirror-pull.nix:92-95`,
      `:157-182`).
- [x] **Decision: the archive lives UNDER the published dir** —
      `/var/lib/sancta/soul-mirror/soul-archive/YYYY/MM/<sha256_cipher-16>.jsonl.age`.
      Justified against the real `rrsync 3.4.1` bytes: it takes exactly ONE
      positional `DIR` (`:376`), `chdir`s into it (`:203`), kills `..` and
      re-anchors absolute args under the root (`:295-307`) — but disables only
      symlink options on a restricted root (`short_disabled_subdir = 'KLk'`,
      `:30`), so recursion into subdirectories is untouched. A second directory
      would need a second forced command → a second key → a second agenix
      secret and pull unit on rpi5 (v1 does not touch rpi5's pull mechanics);
      re-rooting rrsync at a common parent would expose the soul volume itself
      (endpoint widening, forbidden). The subdirectory costs nothing and
      changes nothing on rpi5.
- [x] Confirmed from code, not assumed: both prune loops glob strictly
      `sancta-soul-*.tar.gz.age` (choir `:131-132`, rpi5 `:100-101`), so
      nothing ever prunes archive objects; the staleness dead-man watches the
      same tarball glob and is undisturbed; the mirror tars from `soulRoot`,
      which does not contain `localDir`, so the archive never packs itself into
      the mirror.
- [x] Corollary that fixes the layout: rpi5 pulls EVERYTHING under `localDir`,
      so the canonical plaintext `MANIFEST.jsonl`, `last-run.json` and
      `INDEX.md` stay in `/var/lib/sancta/transcript-archive/`, outside the
      published dir. Only ciphertext is publishable.

## Checks run

**Task 1 — the endpoint simulated locally against the real `rrsync 3.4.1`**, no
host touched: a fake remote shell does what sshd does under a forced command
(client command into `SSH_ORIGINAL_COMMAND`, then exec choir's literal
`rrsync -ro <published-dir>`), driven by rpi5's exact
`rsync -az -e … "$REMOTE:/" "$VAULT/"`.

```
=== A. PULL — rpi5's exact invocation, remoteDir="/" ===
./sancta-soul-2026-08-16.tar.gz.age
./soul-archive/2026/08/0123456789abcdef.jsonl.age
./soul-archive/2026/08/deadbeefcafe1234.jsonl.age
./soul-archive/MANIFEST.jsonl.age

=== B. CONFINEMENT — sibling dir via absolute path ===
rsync: [sender] change_dir "…/published/tmp/…/secret-sibling" failed: No such file or directory (2)
escape dir contents: 0 file(s)

=== C. .. traversal ===
rrsync error: do not use .. in arg (anchor the path at the root of your restricted dir)
escape2 contents: 0 file(s)

=== D. WRITE (endpoint is -ro) ===
rrsync error: sending to read-only server is not allowed
evil landed in published dir? NO
```

A nested `soul-archive/YYYY/MM/` subtree arrives with **zero** configuration
changes, while the same key still cannot escape the root, traverse with `..`,
or write. The decision rests on B/C/D observed, not on reading the source.

Every line-anchored citation in this body and in the design doc is checked
mechanically against the real file bytes (21/21 anchors OK) — one cited range
was off by one line and was corrected rather than left to rot.

- `nix fmt` / `nix flake check` — per task, see commits.
