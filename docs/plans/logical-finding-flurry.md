# Plan: Write images/audio to disk during loop to prevent OOM

## Context

The `image-to-anki-worker` n8n workflow crashes with OOM (1GB peak + 338MB swap) when generating 40-card decks on the RPi5 (4GB RAM, `MemoryMax=1536M`). Root cause: base64 image and audio data (~200KB each × 40 cards) accumulates in memory through the loop iterations and n8n's aggregate nodes, overwhelming the n8n task runner.

## Approach

Write image/audio files to disk immediately in the Extract nodes. Pass only file paths through the loop. In Prepare APKG Input, read files back from disk when building the final JSON for `generate-apkg`.

This eliminates ~16MB of base64 data sitting in n8n's node memory across 40 loop iterations.

## Files to modify

- `n8n-workflows/image-to-anki-worker.json` — 5 Code nodes modified

## Step 1: Extract Image Data — write to disk

Currently keeps `imageBase64` in the item JSON. Change to:
- Write base64-decoded image bytes to `{jobDir}/img_{index}.bin`
- Store mimeType in `{jobDir}/img_{index}.meta`
- Return `imageFile` path instead of `imageBase64`
- Keep `imageHash` (small, needed for dedup)
- Set `imageBase64: null`

Key code change:
```js
const imgPath = require('path').join($('Initialize Job').first().json.jobDir, `img_${index}.bin`);
fs.writeFileSync(imgPath, bytes);
fs.writeFileSync(imgPath.replace('.bin', '.meta'), mimeType);
return [{ json: { index, word, description, imageFile: imgPath, imageHash: hash, mimeType, imageSizeBytes: bytes.length } }];
```

### Feedback: Verify Step 1
- Query the workflow JSON to confirm `imageBase64` is no longer in the Extract Image Data output
- Confirm `imageFile` path is present in the return value
- Confirm `fs.writeFileSync` writes the image bytes to disk

## Step 2: Handle Image Error — add imageFile: null

Currently sets `imageBase64: null`. Also set `imageFile: null` for consistency.

### Feedback: Verify Step 2
- Confirm Handle Image Error returns `imageFile: null` alongside `imageBase64: null`

## Step 3: Extract Audio Data — write to disk

Currently keeps `audioBase64` in the item JSON. Change to:
- Write base64-decoded audio bytes to `{jobDir}/audio_{index}.bin`
- Return `audioFile` path instead of `audioBase64`
- Set `audioBase64: null`

Key code change:
```js
const initData = $('Initialize Job').first().json;
const audioPath = require('path').join(initData.jobDir, `audio_${inputData.index}.bin`);
fs.writeFileSync(audioPath, Buffer.from(audioBase64, 'base64'));
return [{ json: { ...inputData, audioFile: audioPath, audioMimeType: mimeType, audioBase64: null } }];
```

### Feedback: Verify Step 3
- Confirm `audioBase64` is no longer in the Extract Audio Data output
- Confirm `audioFile` path is present
- Confirm audio bytes written to disk

## Step 4: No Audio Passthrough — set audioFile: null

Currently sets `audioBase64: null`. Change to set `audioFile: null` instead.

### Feedback: Verify Step 4
- Confirm No Audio Passthrough sets `audioFile: null`

## Step 5: Prepare APKG Input — read files from disk

Currently reads `imageBase64` and `audioBase64` from aggregated items. Change to:
- Read image from `imageFile` path → re-encode as base64
- Read audio from `audioFile` path → re-encode as base64
- One card at a time, so memory is bounded

Key code change:
```js
cards: valid.map(item => {
  let imageBase64 = null;
  if (item.imageFile) {
    try { imageBase64 = fs.readFileSync(item.imageFile).toString('base64'); }
    catch(e) { console.error(`Failed to read image for ${item.word}:`, e.message); }
  }
  let audioBase64 = null;
  if (item.audioFile) {
    try { audioBase64 = fs.readFileSync(item.audioFile).toString('base64'); }
    catch(e) { console.error(`Failed to read audio for ${item.word}:`, e.message); }
  }
  return { word: item.word, description: item.description || '', imageBase64, mimeType: item.mimeType || 'image/jpeg', audioBase64, audioMimeType: item.audioMimeType || 'audio/mpeg' };
})
```

### Feedback: Verify Step 5
- Confirm Prepare APKG Input reads from `imageFile`/`audioFile` paths
- Confirm it still outputs the same JSON structure for `generate-apkg.py`

## Step 6: Deploy and E2E test

### 6a: Commit and deploy
- Commit changes to `n8n-workflows/image-to-anki-worker.json`
- Run `sudo nixos-rebuild switch --flake .#rpi5-full`
- Verify n8n starts successfully

### Feedback: Verify Step 6a
- `systemctl is-active n8n` returns `active`
- `journalctl -u n8n --since "5 min ago" | grep -i error` shows no errors

### 6b: E2E test — trigger deck generation
- Extract the original "At the Beach" base64 image from execution 260950
- Trigger the workflow: `curl -X POST http://127.0.0.1:5678/webhook/image-to-anki -H "Content-Type: application/json" -d '...'`
- Poll status endpoint every 30s until complete or error

### Feedback: Verify Step 6b
- Status reaches `complete` or `partial` (not `error` or `crashed`)
- Check that image files exist on disk: `ls /var/lib/n8n/jobs/<jobId>/img_*.bin | wc -l` should be > 0
- Check that audio files exist on disk: `ls /var/lib/n8n/jobs/<jobId>/audio_*.bin | wc -l` should be > 0

### 6c: E2E test — verify memory stayed low
- Check n8n service memory during/after generation: `systemctl status n8n | grep Memory`
- Confirm no OOM or crash in logs: `journalctl -u n8n --since "10 min ago" | grep -iE "dump|abort|oom|kill"`

### Feedback: Verify Step 6c
- Memory usage should stay well under 1GB (target: <600MB)
- No crash/OOM messages in logs

### 6d: E2E test — verify APKG output
- Download the deck: `curl http://127.0.0.1:5678/webhook/anki-download?id=<deckId> -o /tmp/test.apkg`
- Verify file is non-empty and valid ZIP: `file /tmp/test.apkg`
- Check status response has `imageCardCount > 0` and `audioCardCount > 0`

### Feedback: Verify Step 6d
- APKG file exists and is valid
- Both images and audio present in the deck
- Word count matches expected 40

## What stays the same

- `generate-apkg.py` — unchanged, receives same JSON with base64
- `Aggregate All Items` / `Aggregate Audio Items` — unchanged, now aggregate lightweight items
- `Finalize Job` — unchanged
- Job cleanup timer already removes job dirs after 7 days (including temp files)
