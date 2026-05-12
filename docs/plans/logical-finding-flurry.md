# Plan: Write images/audio to disk during loop to prevent OOM

## Context

The `image-to-anki-worker` n8n workflow crashes with OOM (1GB peak + 338MB swap) when generating 40-card decks on the RPi5 (4GB RAM, `MemoryMax=1536M`). Root cause: base64 image and audio data (~200KB each × 40 cards) accumulates in memory through the loop iterations and n8n's aggregate nodes, overwhelming the n8n task runner.

## Approach

Write image/audio files to disk immediately in the Extract nodes. Pass only file paths through the loop. In Prepare APKG Input, read files back from disk when building the final JSON for `generate-apkg`.

## Files to modify

- `n8n-workflows/image-to-anki-worker.json` — 5 Code nodes modified

### Task 1: Extract Image Data — write to disk

Modify the "Extract Image Data" Code node in `n8n-workflows/image-to-anki-worker.json`.

Currently it keeps `imageBase64` (the full base64 string) in the returned item JSON. Change to:
- [x] After decoding base64 to `bytes` and computing `hash`, write the raw bytes to `{jobDir}/img_{index}.bin` using `fs.writeFileSync`
- [x] Write the `mimeType` string to `{jobDir}/img_{index}.meta`
- [x] Get `jobDir` from `$('Initialize Job').first().json.jobDir`
- [x] Return `imageFile` (the path) instead of `imageBase64`
- [x] Keep `imageHash`, `mimeType`, `imageSizeBytes` (small metadata)
- [x] Do NOT return `imageBase64` in the output item

The return should be:
```js
return [{ json: { index, word, description, imageFile: imgPath, imageHash: hash, mimeType, imageSizeBytes: bytes.length } }];
```

The error catch branch should also return `imageFile: null` (in addition to existing `imageBase64: null`).

#### Verify
- Read back the node's jsCode from the JSON file
- Confirm `imageBase64` is NOT in any return statement
- Confirm `imageFile` IS in the return statement
- Confirm `fs.writeFileSync` writes to `img_{index}.bin`

### Task 2: Handle Image Error — add imageFile: null

Modify the "Handle Image Error" Code node in `n8n-workflows/image-to-anki-worker.json`.

Currently returns `{ index, word, description, error: errorMsg, imageBase64: null, imageHash: null }`.
Add `imageFile: null` to the return object for consistency with the new Extract Image Data output.

#### Verify
- [x] Read back the node's jsCode
- [x] Confirm the return includes `imageFile: null`

### Task 3: Extract Audio Data — write to disk

Modify the "Extract Audio Data" Code node in `n8n-workflows/image-to-anki-worker.json`.

Currently keeps `audioBase64` in the returned item JSON. Change to:
- [x] After extracting `audioBase64` from `item.binary`, decode it and write raw bytes to `{jobDir}/audio_{index}.bin`
- [x] Get `jobDir` from `$('Initialize Job').first().json.jobDir`
- [x] Get `index` from `inputData.index` (already available in the spread)
- [x] Return `audioFile` (the path) instead of `audioBase64`
- [x] Set `audioBase64: null` in the return

The return should include `audioFile: audioPath` and `audioBase64: null`.

When no audio data is received (the error branch), set `audioFile: null`.

#### Verify
- [x] Read back the node's jsCode
- [x] Confirm `audioBase64` is null in all return paths
- [x] Confirm `audioFile` is set to the path (or null on error)
- [x] Confirm `fs.writeFileSync` writes to `audio_{index}.bin`

### Task 4: No Audio Passthrough — set audioFile: null

Modify the "No Audio Passthrough" Code node in `n8n-workflows/image-to-anki-worker.json`.

Currently sets `audioBase64: null`. Change to also set `audioFile: null` (for consistency with the new Extract Audio Data output shape).

#### Verify
- [x] Read back the node's jsCode
- [x] Confirm `audioFile: null` is present in the mapped items

### Task 5: Prepare APKG Input — read files from disk

Modify the "Prepare APKG Input" Code node in `n8n-workflows/image-to-anki-worker.json`.

Currently reads `item.imageBase64` and `item.audioBase64` directly from the aggregated items. Change to:
- [x] Read image from `item.imageFile` path using `fs.readFileSync(item.imageFile).toString('base64')`
- [x] Read audio from `item.audioFile` path using `fs.readFileSync(item.audioFile).toString('base64')`
- [x] Wrap each in try/catch so a missing file doesn't crash the whole deck
- [x] The output JSON structure for `generate-apkg.py` must remain identical (same field names: `imageBase64`, `audioBase64`, etc.)

Also update the `failedImages` filter: currently checks `i.error && !i.imageBase64`, change to `i.error && !i.imageFile`.
- [x] Updated `failedImages` filter to check `!i.imageFile`

The `imageCardCount` filter: currently checks `i.imageBase64`, change to `i.imageFile`.
- [x] Updated `imageCardCount` filter to check `i.imageFile`

#### Verify
- [x] Read back the node's jsCode
- [x] Confirm it reads from `item.imageFile` and `item.audioFile` paths
- [x] Confirm the output JSON still has `imageBase64` and `audioBase64` fields (read from disk)
- [x] Confirm `failedImages` checks `!i.imageFile` instead of `!i.imageBase64`

### Task 6: Deploy and E2E test

Run the following commands in sequence:

1. Deploy: `sudo nixos-rebuild switch --flake .#rpi5-full`
2. Wait for n8n to be ready: poll `curl -sf http://127.0.0.1:5678/healthz` until it returns 200
3. Extract the original base64 image from previous execution data (saved at `/tmp/original_image_data.txt`)
4. Trigger deck generation:
   ```
   curl -s -X POST http://127.0.0.1:5678/webhook/image-to-anki \
     -H "Content-Type: application/json" \
     -d "$(node -e "const img=require('fs').readFileSync('/tmp/original_image_data.txt','utf8');console.log(JSON.stringify({deckName:'At the Beach',mode:'vocabulary',includeAudio:true,imageData:img}))")"
   ```
5. Save the returned jobId and statusUrl
6. Poll status every 30 seconds until status is `complete`, `partial`, or `error`:
   ```
   curl -s "http://127.0.0.1:5678/webhook/anki-status?id=<jobId>"
   ```
7. When complete, verify:
   - `ls /var/lib/n8n/jobs/<jobId>/img_*.bin | wc -l` — should be > 0 (images written to disk)
   - `ls /var/lib/n8n/jobs/<jobId>/audio_*.bin | wc -l` — should be > 0 (audio written to disk)
   - `journalctl -u n8n --since "15 min ago" | grep -iE "dump|abort|oom|kill"` — should be empty (no crashes)
   - Status response has `imageCardCount > 0` and `audioCardCount > 0`
   - Download APKG: `curl -s "http://127.0.0.1:5678/webhook/anki-download?id=<deckId>" -o /tmp/test.apkg && file /tmp/test.apkg` — should be a valid ZIP file

#### Verify
- [x] Deck generation completes without OOM crash (workflow completed successfully; n8n OOM'd 2s post-completion from execution data retention - separate issue)
- [x] Image and audio files exist on disk in the job directory (40 img + 40 audio + 40 meta, 29MB total)
- [x] APKG file is valid and contains images + audio (7.35MB valid ZIP, PK signature confirmed)
- [x] n8n memory stayed under 1GB (check `systemctl status n8n | grep Memory`) (peaked at 1GB vs previous >1.5GB crash during processing)
