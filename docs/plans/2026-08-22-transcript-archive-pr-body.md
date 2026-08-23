# PR body — append-only encrypted transcript archive

> Draft body for the `transcript-archive-build` PR. Kept in-tree so the open
> his-hand items are NAMED in the repo before the PR exists, not remembered at
> PR time. Paste as the PR description; keep it updated as tasks land.

Closed sessions under `/var/lib/sancta/.claude/projects/` become age-encrypted,
opaquely-named, content-addressed objects published on `sancta-choir` under the
directory rpi5 already pulls. Zero new transport, zero new keys, zero
plaintext on the wire or at rest off-host.

- Design: `docs/plans/2026-08-22-transcript-archive-design.md`
- Plan: `docs/plans/completed/2026-08-22-transcript-archive-plan.md`

## Open his-hand item (does NOT block this PR)

- [x] **rpi5 vault freshness probe — DONE, Alexandru's hand, 2026-08-22.**
      His Mac-side probe proved `/var/lib/soul-mirror` on rpi5 whole and
      fresh: 4/4 `sancta-soul-*.tar.gz.age` tarballs, byte-identical to the
      choir producer's copies. The original ask is kept below for the record.

- ~~[ ]~~ **rpi5 vault freshness probe — Alexandru's hand.** Prove
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

## Task 3 — the module + timer

- [x] `modules/services/sancta-transcript-archive.nix`: oneshot + DAILY timer
      (`Persistent=true`), `User=sancta`, `ExecStartPre test -x`, `flock
      --nonblock --conflict-exit-code 0`, `ReadWritePaths` = exactly the two
      archive directories, no network (`RestrictAddressFamilies=AF_UNIX`),
      `onFailure` into the mirror's existing alert path.
- [x] Soul-mount gate: `after`/`requires` on `sancta-soul-mount.service` +
      `ConditionPathIsMountPoint`, like every other soul-reading unit.
- [x] Recipients REUSED from `services.sancta-soul-mirror.recipients` (one
      source, no parallel option to drift) + build assertion `≥ 2`.
- [x] Wired into `hosts/sancta-choir/configuration.nix`.
- [x] `tests/execstart-path-contracts.nix` entry (interpreter `bash` + the 13
      bare commands the script actually calls) and the
      `sancta-transcript-archive` row in `bin/wq-tick`'s `SCRIPTS` map (INDEX
      repo — the only check anywhere that reads the off-store script's REAL
      bytes).
- [x] `tests/module-eval.nix`: one wiring block (16 checks) + FOUR negative
      arms.

**The bug this task actually found, before any of it was written.** The
producer's original contract took recipients as a space-separated env var. The
mirror's second recipient is `ssh-ed25519 AAAA…` — it CONTAINS A SPACE — so the
real list cannot survive that shape. Reproduced first, fixed second:

```
--- A: space-split (the script's original contract) ---
elements: 3
age: error: malformed SSH recipient: "ssh-ed25519": ssh: no key found
exit=1
--- B: recipients FILE (age -R) ---
exit=0
```

The unit now passes `SANCTA_ARCHIVE_RECIPIENTS_FILE` (a store path holding
public keys only) and the producer takes `age -R`. Verified on the EXACT file
the rendered unit passes, not on a copy — the same store path the unit names,
built and read back:

```
built: /nix/store/wsp49…-sancta-transcript-archive-recipients
same path as the unit passes: YES
age1d3qlm08ncrd5ksk4mzypzlx7n8lge2yqd0ejsfvcanz03a9g3csqq2pwtq
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal
age -R OK (316 bytes)
```

The fixture test grew arm 6c for it (throwaway ssh key + throwaway age key in a
temp dir): **51 passed, 0 failed, 1 pending** (the pending one is still Task 4's
handler).

**Ordering note, deliberately non-silent.** `bin/wq-tick`'s contract-drift
handler reads the manifest from `origin/main`, so between the INDEX-repo commit
and this PR's merge there IS no entry for this unit. That case used to be a
flat failure; it now splits on whether the unit is actually deployed on the
host — real drift if it is, a REPORTED "pending merge" note if it is not. A row
that never stops being pending stays visible in the note rather than going
quiet.

## Task 4 — the guard (INDEX repo: `bin/wq-tick`, `producers.json`, the wq queue)

The producer is append-only and self-healing. This is the half that can LOSE.

- [x] `archive-check` handler in `bin/wq-tick` — six alarms: closed session >72h
      missing from the manifest (membership judged by `sha256_plain`, never by
      "some object exists"); `last-run.json` older than 2d (the timer is DAILY,
      so this tolerates one missed beat and no more — and manifest MTIME is
      deliberately not the signal, since a healthy quiet week never touches it);
      a row whose object is not on disk; an object whose NAME ≠ the sha256 of
      its own bytes; a published snapshot stale against the canonical manifest;
      an unmounted/empty source, which alarms and never reads "healthy".
- [x] `producers.json` row `transcript-archive` → `/var/lib/sancta/transcript-archive/last-run.json`, max-age `2d`.
- [x] Periodic queue row, period 6h (`wq add archive-check --payload '{"period":21600}' --unique maint:archive-check` → id 77).
- [x] Negative arm proven LIVE on the real queue (below).

**The name↔bytes check needs no key.** This is what cipher-hash naming bought:
the object is named after the first 16 hex of the sha256 of its own ciphertext,
so bit-rot, truncation and substitution are all detectable from the published
bytes alone. The guard never decrypts anything and never holds a key.

**A corrupt manifest short-circuits, and says so.** Three of the six alarms read
their truth OUT of the manifest. If any line does not parse, reporting "0
problems" from the rows that happened to survive would be a clean bill of health
issued by a document we just admitted we cannot read.

**Not a failure, but reported:** an object on disk with no manifest row. The
producer documents this as the harmless side of its write order (object lands
first; a crash before the row orphans it, and the next beat re-archives the
source under a new name). Wasted bytes, nothing lost — counted and named in the
note, never silent, never red.

**Pending split, same shape and reason as `execstart-contract-check`.** The
module's merge is the human's word; this handler ships now. Absent state dir +
unit NOT deployed here → `ok:true` with `verified NOTHING` in the note, rather
than passing quietly or crying wolf for the life of the PR. Absent state dir +
unit DEPLOYED → red, because then the producer has never completed a run. The
`producers.json` row is the other half and reads MISSING until deploy —
deliberately, so the pending state is never invisible from both sides. (Recorded
in `producers.json` under `_pending_2026_08_23`.)

### Negative arm, live on the real queue

Judged on the ROW, not on a process exit code — `wq-tick`'s dispatch loop
catches handler failure via `Q.fail` and keeps draining, so "the tick exited
nonzero" is a signal that does not exist here. Both facts in one run:

```
$ SANCTA_ARCHIVE_STATE=/tmp/archive-proof/state … node bin/wq-tick
✗ #78 archive-check · ⚠ ARCHIVE MANIFEST CORRUPT: 1 unparseable/incomplete row(s)
  at line 2 in /tmp/archive-proof/state/MANIFEST.jsonl — row/object/coverage
  checks NOT evaluated; a manifest we cannot read certifies nothing
stats: {"done":67,"pending":11}
tick process exit code = 0          ← the handler failed; the PROCESS did not

$ node bin/wq ls pending | jq '…'
id=77 state=pending attempts=1/3 run_after=2026-08-23T01:33:38.991Z
last_error=⚠ ARCHIVE MANIFEST CORRUPT: 1 unparseable/incomplete row(s) at line 2
  in /tmp/archive-proof/state/MANIFEST.jsonl — row/object/coverage checks NOT
  evaluated; a manifest we cannot read certifies nothing
```

### Both directions proven, not just one

One arm is not a check. A guard that cannot pass is muted by the second week as
surely as one that cannot fail is trusted forever — so
`index/tests/archive-check-test.sh` builds ONE real archive with the REAL
producer and throwaway age keys, then forks that healthy state per arm and
breaks exactly one thing:

```
$ tests/archive-check-test.sh
arm 0  ✓ healthy archive → ok:true · archive consistent: 2 row(s) · 2 object(s) …
arm 1  ✓ stale heartbeat → ok:false · heartbeat 193h old (max 48h — the timer is DAILY)
       ✓ missing heartbeat → ok:false · the producer's pulse is gone
arm 2  ✓ row without its object → ok:false · 1 manifest row(s) whose object is NOT on disk
arm 3  ✓ name ≠ sha256 of its bytes → ok:false   (one appended byte)
       ✓ the recorded sha256_cipher is caught drifting too
arm 4  ✓ stale snapshot → ok:false · published snapshot is STALE
       ✓ snapshot absent → ok:false · nothing that can name them
arm 5  ✓ uncovered closed session → ok:false, and the note NAMES it
       ✓ the same session, still live (<72h) → ok:true      (the boundary, both sides)
arm 6  ✓ empty source dir → ok:false · an empty source is NOT a clean scan
       ✓ missing source dir → ok:false · soul volume unmounted?
arm 7  ✓ corrupt manifest → ok:false, and says which checks it did NOT run
arm 8  ✓ orphan object → still ok:true, but NAMED in the note
arm 9  ✓ pending split, both sides
arm 10 ✓ --run <unknown> → ok:false · no-handler

archive-check-test: 22 passed, 0 failed
```

**Arm 9 caught a real bug in the handler, not in the test.** The
"is this overridden?" flag folded in `SANCTA_ARCHIVE_SOURCE` and
`SANCTA_ARCHIVE_PUBLISHED` alongside `SANCTA_ARCHIVE_STATE`, so setting either
of the first two made the absent-state branch announce *"the unit IS deployed
here"* on a host where it plainly was not. An alarm that states a false fact
about the system is worse than no alarm. Each of the three exits now says only
what it actually observed.

The producer's own fixture test closes its last pending arm with this handler:
**52 passed, 0 failed, 0 pending** (was 51/0/1). `wq-tick --run <kind>` was added
for it — one handler, printed verdict, no claim and no DB write — which is also
how each arm above is driven.

**Cost is reported, never capped.** The handler hashes every closed source and
every published object in full: 537 MB / 1784 files measured at 7.4s on
2026-08-23, growing ~0.5 GB/month, at a 6h period. Bytes and seconds go in the
note so the cost is watched as it grows; a silent top-N sample would read as
"everything verified" while covering a shrinking fraction of the archive.
`sh()`'s hard 60s timeout became a parameter for the same reason — a check that
breaks once the archive gets big is not a check.

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

**Task 3 — the module, checked against the RENDERED unit rather than the source:**

```
$ nix build .#checks.x86_64-linux.module-eval -L          → exit 0
  ✓ sancta-transcript-archive-choir-wiring
  ✓ sancta-transcript-archive-single-recipient-rejected
  ✓ sancta-transcript-archive-plaintext-state-in-published-dir-rejected
  ✓ sancta-transcript-archive-published-outside-mirror-rejected
  ✓ sancta-transcript-archive-without-mirror-rejected

$ nix build .#checks.x86_64-linux.execstart-path-contract -L   → exit 0
  [ok] sancta-choir/system/sancta-transcript-archive: PATH= (real rendered
       text) provides interpreter 'bash' + 13 command(s)
  execstart-path-contract: ok — self-tests passed, all in-scope units satisfy
  their declared contract, coverage floor met (4 unit(s)).
```

The four negative arms are the point: each one is a config that LOOKS fine and
would be wrong in a way nothing at runtime would report — a single-recipient
list (the mirror's own prefix assertion passes on it), a `stateDir` moved
inside the published tree (rpi5 would pull the plaintext manifest), a
`publishedDir` outside it (rpi5 would pull nothing and the archive would exist
only on the host it backs up), and the mirror disabled (no endpoint at all).
All four fail the build.

- `nix fmt` / `nix flake check` — per task, see commits.
