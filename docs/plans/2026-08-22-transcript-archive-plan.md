Append-only encrypted transcript archive: closed sessions become age-encrypted time-keyed objects on choir, pulled to rpi5 by the existing mirror transport, guarded by a manifest check that can lose.

## Context
Design doc: `docs/plans/2026-08-22-transcript-archive-design.md` (read it FIRST — the shape, the guards, and the scope fences are all there). Source of truth for transcripts: `/var/lib/sancta/.claude/projects/**/*.jsonl` (530 MB, growing ~0.5 GB/month). Producer model to imitate: `modules/services/sancta-soul-mirror.nix` (dual age recipients, build-time recipient assertion) and `modules/services/sancta-statusline-refresh.nix` (unit hardening pattern, ReadWritePaths lesson: WAL/shm, ExecStart↔PATH contract). The soul-side script lives in the SOUL repo (`/var/lib/sancta/.claude/index/bin/`), the unit in nixos-config; tests in `tests/module-eval.nix` + a script-level fixture test.

## Tasks

### Task 1: Verify the transport end-to-end before building anything
- [ ] From repo alone, document where choir publishes ciphertext (`services.sancta-soul-mirror.localDir` = `/var/lib/sancta/soul-mirror`) and how rpi5's rrsync endpoint anchors it (hosts/rpi5-full/soul-mirror-pull.nix; endpoint definition on the choir side — find it and quote it)
- [ ] Decide and write down in the design doc: archive dir placement UNDER the published dir (preferred; zero rpi5 changes) vs second endpoint — justify with the actual rrsync constraint found above
- [ ] Record the open external fact (rpi5 vault freshness probe is at the human's hand) as a checklist item in the PR body — do NOT block the build on it, but the PR must NAME it

### Task 2: The archiver script (soul repo)
- [ ] Write `index/bin/transcript-archive`: scan closed sessions (mtime > 48h), diff vs `MANIFEST.jsonl`, age-encrypt each new/changed object to `soul-archive/YYYY/MM/<project>--<session>.jsonl.age` under the published dir, append manifest row `{ts,key,session,sha256_plain,sha256_cipher,bytes_plain,bytes_cipher,src_mtime}`, atomic tmp+rename per object, manifest row written only AFTER its object lands
- [ ] Idempotence: second run with no new closed sessions produces zero writes (prove it in the fixture test)
- [ ] Regenerate `soul-archive/INDEX.md` from the manifest (derived view, never hand-edited)
- [ ] Fixture test script `index/tests/transcript-archive-test.sh` (or .mjs): fake closed session → object + manifest + INDEX asserted; rerun → zero new; corrupt manifest copy → the check from Task 4 FAILS (negative arm)
- [ ] Commit to the soul index repo (post-commit hook pushes to the local bare mirror — expected)

### Task 3: The nixos module + timer
- [ ] `modules/services/sancta-transcript-archive.nix`: oneshot unit + daily timer (`Persistent=true`), User=sancta, `ExecStartPre test -x`, `flock -n` wrapper, ReadWritePaths ONLY the archive dir, source dir read-only, PATH enumerated from what the script actually calls (read the script, list the binaries), build-time assertion that age recipients are real (copy the soul-mirror assertion pattern)
- [ ] Wire into hosts/sancta-choir/configuration.nix
- [ ] Extend the ExecStart↔PATH contract manifest (tests/unit-script-refs.nix or the contract file the execstart-contract-check reads) with the new unit
- [ ] tests/module-eval.nix: wiring checks (paths, PATH contract, timer Persistent, flock present) with a negative arm where the existing pattern has one
- [ ] `nix build .#checks.x86_64-linux.module-eval -L` passes; `nixos-rebuild dry-build --flake .#sancta-choir` and both rpi5 hosts clean

### Task 4: The guard
- [ ] Add `archive-check` handler to `/var/lib/sancta/.claude/index/bin/wq-tick`: any closed session >72h missing from manifest → alarm; manifest older than 8 days → alarm; healthy → one-line ok
- [ ] Add `transcript-archive` producer row to `producers.json` (absent-guard) with max-age 8d
- [ ] Enqueue the periodic task in the wq queue (period 6h) — follow the pattern of existing handlers
- [ ] Prove the negative arm live: corrupted manifest copy → handler exits nonzero (paste output in the PR body)

## Constraints
- NEVER delete, move, or rewrite source transcripts. Read-only on `projects/`.
- No new keys, no secrets in any output or chat: only PUBLIC age recipients in nix.
- Nothing leaves the tailnet; no third-party leg in v1.
- Do not touch rpi5's pull mechanics in v1 (repairing the pull key, if the human's probe shows the vault empty, is a SEPARATE his-hand task already documented in the mirror module).
- Never push main; worktree + PR; merge is the human's word. Follow `nix fmt` before committing nix files.
- Archive placement must keep rrsync confinement intact — no endpoint widening beyond the published directory.
