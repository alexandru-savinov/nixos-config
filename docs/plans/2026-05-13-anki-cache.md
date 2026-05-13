# Cache generated images and audio for Anki deck workflow

## Overview

Add a filesystem-based cache to the image-to-anki-worker workflow so that previously generated images and audio are reused when the same word+prompt combination is requested again. This avoids redundant API calls to OpenRouter (images ~$0.04 each) and OpenAI (TTS), saving money and time.

**Cache key design:**
- **Images**: `SHA256("img-v1:" + word + ":" + description)` — both affect the image prompt
- **Audio**: `SHA256("tts-v1:" + word)` — TTS input is just the word

**Cache location**: `/var/lib/n8n/cache/` with `{hash}.bin` (binary data) and `{hash}.meta` (JSON: mimeType, word, createdAt)

**Cache lifetime**: 30 days via systemd timer

**Expected savings**: A 40-card deck costs ~$2-3. Second generation of the same deck = $0 + ~2 minutes (vs ~8 minutes).

## Context

- Workflow file: `n8n-workflows/image-to-anki-worker.json`
- NixOS module: `modules/services/n8n.nix` (cache dir + cleanup timer)
- Image generation: `google/gemini-2.5-flash-image` via OpenRouter, prompt = `"A single centered illustration of " + word + " (" + description + ") ..."`
- TTS generation: `tts-1-hd` / voice `nova` / mp3 via OpenAI, input = word only
- Disk offload (PR #438): images/audio already written to `{jobDir}/img_{index}.bin` and `audio_{index}.bin`

### Current connection flow (relevant sections)

```
IMAGE LOOP:
  Loop Over Items [done] → Aggregate All Items
  Loop Over Items [loop] → Update Progress → Generate Image
  Generate Image [ok]  → Extract Image Data → Wait (Rate Limit) → Loop Over Items
  Generate Image [err] → Handle Image Error  → Wait (Rate Limit) → Loop Over Items

AUDIO LOOP:
  TTS Loop [done] → Aggregate Audio Items
  TTS Loop [loop] → Update TTS Progress → Generate TTS
  Generate TTS [ok]  → Extract Audio Data → TTS Loop
  Generate TTS [err] → Handle TTS Error
```

### Data shape through image loop

Each item entering Update Progress:
```json
{ "jobId": "...", "jobDir": "/var/lib/n8n/jobs/...", "statusFile": "...",
  "index": 0, "word": "apple", "description": "red fruit", "totalItems": 40,
  "deckName": "...", "includeAudio": true, "mode": "vocabulary" }
```

Each item after Extract Image Data (going back to loop):
```json
{ "index": 0, "word": "apple", "description": "red fruit",
  "imageFile": "/var/lib/n8n/jobs/.../img_0.bin", "imageHash": "a3f5...",
  "mimeType": "image/png", "imageSizeBytes": 150000 }
```

### Data shape through audio loop

Each item entering Update TTS Progress:
```json
{ "index": 0, "word": "apple", "description": "red fruit",
  "imageFile": "...", "imageHash": "...", "mimeType": "...",
  "audioIndex": 0, "audioTotal": 40, "statusFile": "..." }
```

## Development Approach

- Complete each task fully before moving to the next
- Verification is via JSON inspection, `nix flake check`, and E2E testing
- The cache is entirely within n8n Code nodes using `fs` and `crypto` builtins

## Implementation Steps

### Task 1: Create cache directory and cleanup timer

Add `/var/lib/n8n/cache` directory creation and a 30-day cleanup timer.

**File: `modules/services/n8n.nix`**
- [x] Add `/var/lib/n8n/cache` to the directory creation loop in ExecStartPre (line ~505, alongside `anki-decks` and `jobs`)
- [x] Add `n8n-cleanup-cache` systemd timer (daily, `Persistent = true`)
- [x] Add `n8n-cleanup-cache` systemd service (oneshot, User=n8n, runs `find /var/lib/n8n/cache -type f -mtime +30 -delete`)
- [x] Model it after the existing `n8n-cleanup-jobs` timer/service (lines 790-814)

#### Verify
- [x] `nix eval .#nixosConfigurations.rpi5-full.config.systemd.services.n8n-cleanup-cache.script` contains `find` and `-mtime +30`
- [x] `nix flake check` passes
- [x] grep ExecStartPre output for `/var/lib/n8n/cache`

### Task 2: Add cache check + write for image generation

Add a "Check Image Cache" Code node between Update Progress and Generate Image. On cache hit, skip both Generate Image AND Wait (Rate Limit) — go directly back to Loop Over Items. On cache miss, proceed to Generate Image as before.

Also modify Extract Image Data to write to cache after successful generation.

**File: `n8n-workflows/image-to-anki-worker.json`**

**New node: "Check Image Cache"** (Code node, two outputs)
- [x] Compute cache key: `crypto.createHash('sha256').update('img-v1:' + item.word + ':' + item.description).digest('hex')`
- [x] Check if `/var/lib/n8n/cache/{key}.bin` exists using `fs.existsSync`
- [x] **Cache hit (output 0)**: copy `.bin` to `{jobDir}/img_{index}.bin`, read `.meta` for mimeType, compute imageHash from cached bytes, update status file with `"...word (cached)"`, return `{ index, word, description, imageFile, imageHash, mimeType, imageSizeBytes, cacheHit: true }`
- [x] **Cache miss (output 1)**: pass item through unchanged, return `{ ...item, cacheHit: false }`
- [x] Get `jobDir` and `statusFile` from the input item (they flow from Initialize Job through Parse Vocabulary JSON)
- [x] On cache hit, update status file phase to `"Generating image N/M: word (cached)"` — since Update Progress already ran, overwrite with cached indicator

**Modify: "Extract Image Data"** (existing Code node)
- [x] After writing to `{jobDir}/img_{index}.bin`, also write to `/var/lib/n8n/cache/{key}.bin`
- [x] Write `/var/lib/n8n/cache/{key}.meta` as JSON: `{ "word", "description", "mimeType", "createdAt" }`
- [x] Same cache key formula as Check Image Cache
- [x] Wrap cache writes in try/catch — must not break workflow
- [x] Add `cacheHit: false` to the return object

**Connection rewiring:**
- [x] Update Progress → Check Image Cache (was: Update Progress → Generate Image)
- [x] Check Image Cache [0: hit] → Loop Over Items (skip Generate Image + Wait entirely)
- [x] Check Image Cache [1: miss] → Generate Image (existing path continues)
- [x] Keep existing: Generate Image → Extract Image Data / Handle Image Error → Wait → Loop Over Items

#### Verify
- [x] Read Check Image Cache jsCode — confirm SHA256 key, fs.existsSync, copy to jobDir, status update
- [x] Read Extract Image Data jsCode — confirm cache write with try/catch
- [x] Verify connections: Update Progress → Check Image Cache, hit → Loop Over Items, miss → Generate Image
- [x] `node -e 'JSON.parse(require("fs").readFileSync("n8n-workflows/image-to-anki-worker.json"))'` passes
- [x] `nix flake check` passes

### Task 3: Add cache check + write for TTS generation

Same pattern as Task 2 but for the audio loop. Add "Check Audio Cache" between Update TTS Progress and Generate TTS.

**File: `n8n-workflows/image-to-anki-worker.json`**

**New node: "Check Audio Cache"** (Code node, two outputs)
- [x] Cache key: `crypto.createHash('sha256').update('tts-v1:' + item.word).digest('hex')` — audio only depends on word
- [x] Check `/var/lib/n8n/cache/{key}.bin` exists
- [x] **Cache hit (output 0)**: copy to `{jobDir}/audio_{index}.bin`, read `.meta` for mimeType, update status with "(cached)", return with `audioFile`, `audioMimeType`, `cacheHit: true`, `audioBase64: null`
- [x] **Cache miss (output 1)**: pass through with `cacheHit: false`
- [x] Use `audioIndex` (not `index`) for the audio file naming: `audio_{audioIndex}.bin`
- [x] Get `statusFile` from the input item

**Modify: "Extract Audio Data"** (existing Code node)
- [x] After writing `audio_{index}.bin` to jobDir, also write to `/var/lib/n8n/cache/{key}.bin`
- [x] Write `.meta` file: `{ "word", "mimeType", "createdAt" }`
- [x] Cache key: `SHA256("tts-v1:" + word)`
- [x] Wrap in try/catch
- [x] Add `cacheHit: false` to return

**Connection rewiring:**
- [x] Update TTS Progress → Check Audio Cache (was: → Generate TTS)
- [x] Check Audio Cache [0: hit] → TTS Loop (skip Generate TTS entirely)
- [x] Check Audio Cache [1: miss] → Generate TTS (existing path continues)
- [x] Keep existing: Generate TTS → Extract Audio Data / Handle TTS Error → TTS Loop

#### Verify
- [x] Read Check Audio Cache jsCode — confirm key uses only word, copies to correct audioIndex path
- [x] Read Extract Audio Data jsCode — confirm cache write
- [x] Verify connections: Update TTS Progress → Check Audio Cache, hit → TTS Loop, miss → Generate TTS
- [x] JSON validation passes
- [x] `nix flake check` passes

### Task 4: Add cache stats to final output

Show how many cache hits occurred in the final status response. Count from aggregated items.

**File: `n8n-workflows/image-to-anki-worker.json`**

**Modify: "Prepare APKG Input"**
- [ ] Count `imageCacheHits` from `items.filter(i => i.cacheHit === true).length` (image items)
- [ ] Pass `imageCacheHits` in the return JSON alongside existing `failedImageCount`, `words`, etc.

**Modify: "Finalize Job"**
- [ ] Read `imageCacheHits` and `audioCacheHits` from `initData` (Prepare APKG Input output)
- [ ] Add them to the final status JSON so the API response includes cache stats
- [ ] For `audioCacheHits`: need to count from the audio aggregated data — check if the audio items preserve `cacheHit` through Aggregate Audio Items

**Note on audioCacheHits**: The audio loop items flow through Aggregate Audio Items → Prepare APKG Input. Check if `cacheHit` field survives aggregation. If the Aggregate node uses `aggregateAllItemData`, it collects all fields. Verify and count `audioCacheHits` in Prepare APKG Input from the audio items (which come via a different input path — No Audio Passthrough or Aggregate Audio Items).

#### Verify
- [ ] Read Prepare APKG Input jsCode — confirm `imageCacheHits` count
- [ ] Read Finalize Job jsCode — confirm cache stats in output
- [ ] JSON validation passes

### Task 5: Handle Image Error — preserve cacheHit field

The Handle Image Error node returns items for failed image generations. These items need `cacheHit: false` for accurate counting.

**File: `n8n-workflows/image-to-anki-worker.json`**
- [ ] Add `cacheHit: false` to Handle Image Error return object

#### Verify
- [ ] Read Handle Image Error jsCode — confirm `cacheHit: false` present
- [ ] JSON validation passes

### Task 6: Deploy and E2E test

Deploy and run the workflow twice to verify caching. **Requires OpenRouter credits.**

- [ ] Deploy: `sudo nixos-rebuild switch --flake .#rpi5-full`
- [ ] Verify n8n starts and healthcheck passes
- [ ] Verify cache directory exists: `ls -la /var/lib/n8n/cache/`
- [ ] **First run**: trigger "At the Beach" deck, poll until complete
- [ ] Verify all items are cache misses (no "(cached)" in status during generation)
- [ ] Verify cache files created: `ls /var/lib/n8n/cache/*.bin | wc -l` should match word count
- [ ] Verify metadata files: `ls /var/lib/n8n/cache/*.meta | wc -l` should match `.bin` count
- [ ] Verify one `.meta` file content is valid JSON with word, mimeType, createdAt
- [ ] **Second run**: trigger same deck, poll until complete
- [ ] Verify second run shows "(cached)" in polling status for known words
- [ ] Verify final status has `imageCacheHits > 0` and `audioCacheHits > 0`
- [ ] Verify second run completes significantly faster than first (< 2 min vs ~8 min)
- [ ] Verify APKG file is valid and contains same number of cards as first run
- [ ] Verify no OOM: `journalctl -u n8n --since "15 min ago" | grep -iE "dump|abort|oom"` is empty
- [ ] Verify n8n is still running: `systemctl is-active n8n`

### Task 7: Update documentation

- [ ] Update `CLAUDE.md` Job Storage section: add cache directory, cache key design, TTL
- [ ] Update `CLAUDE.md` Disk Offload section: mention caching pattern and version prefix invalidation

## Technical Details

### Cache key computation
```javascript
const crypto = require('crypto');

// Image: word + description both affect the Gemini prompt
const imgKey = crypto.createHash('sha256')
  .update('img-v1:' + word + ':' + description)
  .digest('hex');

// Audio: TTS input is just the word (model=tts-1-hd, voice=nova, format=mp3 are fixed)
const ttsKey = crypto.createHash('sha256')
  .update('tts-v1:' + word)
  .digest('hex');
```

### Why version prefixes matter
- `img-v1` / `tts-v1` are baked into the cache key
- If we change the image prompt template, bump to `img-v2` → all old image cache keys become unreachable
- Old `img-v1` files expire naturally after 30 days
- Same for TTS model/voice changes → bump `tts-v2`

### Cache file layout
```
/var/lib/n8n/cache/
├── {sha256-hex}.bin    # raw binary (PNG/JPEG for images, MP3 for audio)
├── {sha256-hex}.meta   # JSON: {"word":"...","description":"...","mimeType":"...","createdAt":"..."}
└── ...
```

### Connection rewiring summary
```
BEFORE (image loop):
  Update Progress → Generate Image → [ok: Extract Image Data, err: Handle Image Error] → Wait → Loop

AFTER (image loop):
  Update Progress → Check Image Cache
    [hit]  → Loop Over Items  (skip API call + wait)
    [miss] → Generate Image → [ok: Extract Image Data, err: Handle Image Error] → Wait → Loop

BEFORE (audio loop):
  Update TTS Progress → Generate TTS → [ok: Extract Audio Data, err: Handle TTS Error] → TTS Loop

AFTER (audio loop):
  Update TTS Progress → Check Audio Cache
    [hit]  → TTS Loop  (skip API call)
    [miss] → Generate TTS → [ok: Extract Audio Data, err: Handle TTS Error] → TTS Loop
```

### Cache size estimate
- Image: ~150KB × 2 files (.bin + .meta) per word
- Audio: ~50KB × 2 files per word
- 200 unique words ≈ 40MB — negligible on 117GB disk
- 30-day TTL prevents unbounded growth

### Cache invalidation
- **Automatic**: 30-day TTL via `n8n-cleanup-cache` timer
- **Manual**: `sudo -u n8n rm /var/lib/n8n/cache/*`
- **Prompt change**: bump `img-v1` → `img-v2` in both Check Image Cache and Extract Image Data

## Post-Completion

- Monitor cache size: `du -sh /var/lib/n8n/cache/`
- Future: cache warming from word lists without image input
- Future: cache stats endpoint (how many cached, total size, hit rate)
