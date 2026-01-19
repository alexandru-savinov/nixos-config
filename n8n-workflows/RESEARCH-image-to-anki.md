# Research: Image to AnkiApp Deck n8n Workflow

## Overview

Build an n8n workflow that:
1. Receives a vocabulary infographic image via webhook
2. Uses AI vision to extract vocabulary items
3. Generates AI images for each vocabulary item
4. Creates an AnkiApp-compatible ZIP file with XML + images

## Requirements Confirmed

- **Input**: Webhook POST with `{ "imageUrl": "https://..." }`
- **Card structure**: AI-generated image (front) -> English word (back)
- **AI Provider**: OpenRouter with ZDR (Zero Data Retention)
- **Output**: Base64 ZIP download link in webhook response

---

## AnkiApp Deck Format

### File Structure
```
deck.zip
├── deck.xml
└── blobs/
    ├── <sha256hash1>.png
    ├── <sha256hash2>.png
    └── ...
```

### XML Schema
```xml
<deck name="Vocabulary Deck" tags="vocabulary,images">
  <fields>
    <img name="Image" sides="10"/>
    <text lang="en-US" name="Word" sides="01"/>
  </fields>
  <cards>
    <card tags="lesson1">
      <img name="Image" id="a3f5d2e9c8b7..."/>  <!-- SHA256 hex of blob -->
      <text name="Word">bed</text>
    </card>
    <!-- more cards -->
  </cards>
</deck>
```

### Key Details
- **sides attribute**: `"10"` = front only, `"01"` = back only, `"11"` = both
- **Media ID**: Base16 (hex) SHA256 hash of the blob file content
- **Blobs folder**: Files can have any filename, referenced by SHA256 hash

### Field Types Available
| Type | Tag | Key Attributes |
|------|-----|----------------|
| Text | `<text>` | `lang`, `sides` |
| Rich Text | `<rich-text>` | `lang` |
| Image | `<img>` | `id` (SHA256 hash) |
| Audio | `<audio>` | `id` (SHA256 hash) |
| Video | `<video>` | `id` (SHA256 hash) |
| TTS | `<tts>` | `lang`, `rate` |
| Markdown | `<markdown>` | - |
| Code | `<code>` | `lang` |

---

## OpenRouter API

### Existing Credentials
- Secret already exists: `openrouter-api-key.age`
- Used by Open-WebUI at: `https://openrouter.ai/api/v1`

### Vision API (Extract vocabulary from image)

**Endpoint**: `POST https://openrouter.ai/api/v1/chat/completions`

**Request Format** (example - actual implementation uses `anthropic/claude-sonnet-4` for ZDR):
```json
{
  "model": "anthropic/claude-sonnet-4",
  "max_tokens": 4096,
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "Extract all vocabulary items from this infographic..."
        },
        {
          "type": "image_url",
          "image_url": {
            "url": "https://example.com/image.png"
          }
        }
      ]
    }
  ],
  "zdr": true
}
```

**Image Input Options**:
- URL: `"url": "https://example.com/image.png"`
- Base64: `"url": "data:image/jpeg;base64,{base64_data}"`

### Image Generation API

**Endpoint**: Same `POST https://openrouter.ai/api/v1/chat/completions`

**Request Format**:
```json
{
  "model": "google/gemini-2.5-flash-image",
  "messages": [
    {
      "role": "user",
      "content": "Generate a simple, clean illustration of a bed for vocabulary learning"
    }
  ],
  "modalities": ["image", "text"],
  "zdr": true
}
```

**Response Format**:
```json
{
  "choices": [{
    "message": {
      "content": "...",
      "images": [{
        "image_url": {
          "url": "data:image/png;base64,..."
        }
      }]
    }
  }]
}
```

### Available Image Models (with pricing)
| Model | Price | Notes |
|-------|-------|-------|
| `google/gemini-2.5-flash-image-preview` | $0.30/M in, $2.50/M out | Recommended |
| `google/gemini-3-pro-image-preview` | $2/M in, $12/M out | Higher quality |
| `black-forest-labs/flux.2-pro` | $0.03/MP | Good quality |
| `bytedance-seed/seedream-4.5` | $0.04/image | Budget option |

### ZDR (Zero Data Retention)
- Add `"zdr": true` to request body
- Ensures no data storage by provider
- May limit available models/endpoints

---

## n8n Implementation Details

### Binary Data Handling

**Get binary buffer**:
```javascript
let buffer = await this.helpers.getBinaryDataBuffer(0, 'data');
```

**Create binary from buffer** (using prepareBinaryData):
```javascript
const binaryData = await this.helpers.prepareBinaryData(buffer, 'filename.png');
return [{ json: {}, binary: { data: binaryData } }];
```

**Data structure with binary**:
```json
{
  "json": { "field": "value" },
  "binary": {
    "data": {
      "data": "base64...",
      "mimeType": "image/png",
      "fileExtension": "png",
      "fileName": "example.png"
    }
  }
}
```

### Compression Node (ZIP creation)

**Parameters**:
- `Input Binary Field(s)`: Comma-separated field names (e.g., "file1,file2")
- `Output Format`: "Zip" or "Gzip"
- `File Name`: Output archive name (e.g., "deck.zip")
- `Put Output File in Field`: Output field name

**Limitation**: n8n Compression node combines files into ZIP but doesn't support subdirectories (blobs/ folder).

### Alternative: Code Node for ZIP

Since AnkiApp needs `blobs/` subdirectory, may need to use Code node with a library like `jszip` or `archiver`. However, n8n Code node has limited npm access.

**Workaround options**:
1. Use flat structure if AnkiApp accepts it
2. Use external ZIP service
3. Check if blobs/ is strictly required (testing needed)

### Crypto Node (SHA256)

**Configuration**:
- Type: SHA256
- Encoding: HEX (required for AnkiApp - base16)
- Input: Binary file data or text
- Output: Hash string in specified field

### Convert to File Node

**Operations**:
- `toJson`: Convert JSON to JSON file
- Can specify custom filename with expressions

---

## Workflow Architecture

```
┌─────────────────────┐
│   Webhook Trigger   │ POST /image-to-anki
│   (receives URL)    │ Body: { "imageUrl": "..." }
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   HTTP Request      │ Fetch the vocabulary image
│   (get image)       │ Returns binary data
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   HTTP Request      │ POST to OpenRouter
│   (Vision API)      │ Model: gemini-2.0-flash-exp
│                     │ Extract: [{"word":"bed","desc":"..."},...]
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Code Node         │ Parse vision response
│   (Parse JSON)      │ Extract vocabulary array
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   SplitInBatches    │ Process each vocabulary item
│   (Loop items)      │ One at a time (rate limiting)
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   HTTP Request      │ POST to OpenRouter
│   (Image Gen API)   │ Model: gemini-2.5-flash-image
│                     │ modalities: ["image","text"]
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Code Node         │ Extract base64 image
│   (Extract Image)   │ Calculate SHA256 hash
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Merge             │ Collect all generated images
│   (Aggregate)       │ + hashes + words
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Code Node         │ Build deck.xml
│   (Build XML)       │ Structure cards with SHA256 refs
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Code Node         │ Create ZIP with XML + blobs
│   (Create ZIP)      │ Return as base64
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Respond to Webhook  │ Return base64 ZIP
│                     │ or download URL
└─────────────────────┘
```

---

## Node Configuration Templates

### 1. Webhook Trigger
```json
{
  "type": "n8n-nodes-base.webhook",
  "parameters": {
    "path": "image-to-anki",
    "httpMethod": "POST",
    "responseMode": "responseNode"
  }
}
```

### 2. Vision API Request
```json
{
  "type": "n8n-nodes-base.httpRequest",
  "parameters": {
    "method": "POST",
    "url": "https://openrouter.ai/api/v1/chat/completions",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "sendHeaders": true,
    "headerParameters": {
      "parameters": [
        { "name": "HTTP-Referer", "value": "https://sancta-choir.tail4249a9.ts.net" }
      ]
    },
    "sendBody": true,
    "bodyParameters": {
      "parameters": [
        { "name": "model", "value": "google/gemini-2.0-flash-exp:free" },
        { "name": "zdr", "value": "={{true}}" },
        { "name": "messages", "value": "={{ JSON.stringify([...]) }}" }
      ]
    }
  }
}
```

### 3. Image Generation Request
```json
{
  "type": "n8n-nodes-base.httpRequest",
  "parameters": {
    "method": "POST",
    "url": "https://openrouter.ai/api/v1/chat/completions",
    "sendBody": true,
    "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify({ model: 'google/gemini-2.5-flash-image-preview', messages: [...], modalities: ['image', 'text'], zdr: true }) }}"
  }
}
```

---

## Credentials Setup (VERIFIED)

### OpenRouter API Headers (from official docs)
| Header | Required | Value | Purpose |
|--------|----------|-------|---------|
| `Authorization` | Yes | `Bearer <OPENROUTER_API_KEY>` | Authentication |
| `HTTP-Referer` | No | Your site URL | Rankings/attribution |
| `X-Title` | No | Your app name | Rankings/attribution |
| `Content-Type` | Yes | `application/json` | Request format |

### n8n HTTP Request Node Configuration
```json
{
  "authentication": "genericCredentialType",
  "genericAuthType": "httpHeaderAuth",
  "sendHeaders": true,
  "headerParameters": {
    "parameters": [
      { "name": "HTTP-Referer", "value": "https://rpi5.tail4249a9.ts.net" },
      { "name": "X-Title", "value": "Image-to-Anki" }
    ]
  }
}
```

### Create HTTP Header Auth Credential in n8n UI
1. Go to Settings > Credentials > Add Credential
2. Select "Header Auth"
3. **Name**: `OpenRouter API`
4. **Name** (header): `Authorization`
5. **Value**: `Bearer sk-or-v1-...` (from `openrouter-api-key.age`)

The API key is in agenix at `openrouter-api-key.age`.
Get it: `sudo cat /run/agenix/openrouter-api-key`

---

## Autonomous Testing Plan

### Test Environment (LOCAL - rpi5)
- **n8n instance**: `http://127.0.0.1:5678` (local) or `https://rpi5.tail4249a9.ts.net:5678` (Tailscale)
- **Webhook URL**: `http://127.0.0.1:5678/webhook/image-to-anki`
- **Test image**: Simple vocabulary image with 3-5 items (controlled input)
- **Existing workflows**: `example-webhook-handler` (inactive), `rpi5-system-health-check` (active)
- **Credentials**: None configured yet - need to add OpenRouter API key

### Phase 1: Pre-Deployment Validation (Local)

```bash
# 1.1 Validate workflow JSON syntax
jq empty n8n-workflows/image-to-anki.json && echo "JSON valid"

# 1.2 Validate required fields exist
jq -e '.id and .name and .nodes and .connections' n8n-workflows/image-to-anki.json

# 1.3 Validate node types are correct
jq -e '.nodes | map(.type) | contains(["n8n-nodes-base.webhook"])' n8n-workflows/image-to-anki.json
```

### Phase 2: Deployment Verification (Remote)

```bash
# 2.1 Check n8n service is running
ssh sancta-choir "systemctl is-active n8n"

# 2.2 Rebuild NixOS with new workflow (triggers n8n-workflow-sync)
# This happens automatically via workflowsDir config

# 2.3 Verify workflow imported (check n8n database)
ssh sancta-choir "sqlite3 /var/lib/n8n/.n8n/database.sqlite \"SELECT id, name, active FROM workflow_entity WHERE id='image-to-anki'\""

# 2.4 Verify workflow is active
ssh sancta-choir "sqlite3 /var/lib/n8n/.n8n/database.sqlite \"SELECT active FROM workflow_entity WHERE id='image-to-anki'\"" | grep -q 1
```

### Phase 3: Functional Tests (Remote via curl)

```bash
# 3.1 Test webhook responds (should fail gracefully without valid input)
curl -s -X POST https://sancta-choir.tail4249a9.ts.net:5678/webhook/image-to-anki \
  -H "Content-Type: application/json" \
  -d '{}' | jq -e '.error'

# 3.2 Test with minimal valid input (simple test image)
TEST_IMAGE="https://example.com/simple-vocab-3items.png"
RESPONSE=$(curl -s -X POST https://sancta-choir.tail4249a9.ts.net:5678/webhook/image-to-anki \
  -H "Content-Type: application/json" \
  -d "{\"imageUrl\": \"$TEST_IMAGE\"}")

# 3.3 Validate response structure
echo "$RESPONSE" | jq -e '.success and .zipBase64'
```

### Phase 4: Output Validation (Decode and verify ZIP)

```bash
# 4.1 Extract base64 ZIP from response
echo "$RESPONSE" | jq -r '.zipBase64' | base64 -d > /tmp/test-deck.zip

# 4.2 Verify ZIP structure
unzip -l /tmp/test-deck.zip | grep -E "(deck.xml|blobs/)"

# 4.3 Extract and validate XML
unzip -p /tmp/test-deck.zip deck.xml > /tmp/deck.xml
xmllint --noout /tmp/deck.xml && echo "XML valid"

# 4.4 Verify XML has expected structure
grep -q '<deck' /tmp/deck.xml && \
grep -q '<fields>' /tmp/deck.xml && \
grep -q '<cards>' /tmp/deck.xml && \
echo "XML structure valid"

# 4.5 Verify SHA256 hashes match blob files
# Extract image IDs from XML
IMAGE_IDS=$(grep -oP 'id="[a-f0-9]+"' /tmp/deck.xml | cut -d'"' -f2)
for ID in $IMAGE_IDS; do
  # Verify blob file exists (with or without blobs/ prefix)
  unzip -l /tmp/test-deck.zip | grep -q "$ID" && echo "Blob $ID found"
done

# 4.6 Verify blob SHA256 matches ID
unzip -d /tmp/deck-extract /tmp/test-deck.zip
for BLOB in /tmp/deck-extract/blobs/*; do
  HASH=$(sha256sum "$BLOB" | cut -d' ' -f1)
  BASENAME=$(basename "$BLOB" | cut -d'.' -f1)
  [ "$HASH" = "$BASENAME" ] && echo "Hash verified: $BASENAME"
done
```

### Phase 5: End-to-End Test with Real Image

```bash
# 5.1 Test with the actual vocabulary infographic type
REAL_IMAGE="https://mrmrsenglish.com/wp-content/uploads/2024/01/Household-Items-Names.png"
E2E_RESPONSE=$(curl -s -X POST https://sancta-choir.tail4249a9.ts.net:5678/webhook/image-to-anki \
  -H "Content-Type: application/json" \
  -d "{\"imageUrl\": \"$REAL_IMAGE\"}" \
  --max-time 300)  # 5 min timeout for image generation

# 5.2 Validate success
echo "$E2E_RESPONSE" | jq -e '.success == true'

# 5.3 Count cards generated (should be > 10 for household items)
echo "$E2E_RESPONSE" | jq -r '.zipBase64' | base64 -d > /tmp/e2e-deck.zip
CARD_COUNT=$(unzip -p /tmp/e2e-deck.zip deck.xml | grep -c '<card')
[ "$CARD_COUNT" -gt 10 ] && echo "E2E test passed: $CARD_COUNT cards generated"
```

### Automated Test Script Location

Create pytest test at `tests/test_n8n_image_to_anki.py`:

```python
import pytest
import requests
import base64
import zipfile
import hashlib
import xml.etree.ElementTree as ET
from io import BytesIO

N8N_BASE = "https://sancta-choir.tail4249a9.ts.net:5678"
WEBHOOK_URL = f"{N8N_BASE}/webhook/image-to-anki"
TEST_IMAGE = "https://example.com/simple-vocab.png"  # Need hosted test image

class TestImageToAnkiWorkflow:

    @pytest.fixture
    def workflow_response(self):
        """Call webhook and get response"""
        resp = requests.post(
            WEBHOOK_URL,
            json={"imageUrl": TEST_IMAGE},
            timeout=300
        )
        return resp.json()

    def test_webhook_returns_success(self, workflow_response):
        assert workflow_response.get("success") == True

    def test_response_contains_zip(self, workflow_response):
        assert "zipBase64" in workflow_response
        # Verify it's valid base64
        base64.b64decode(workflow_response["zipBase64"])

    def test_zip_contains_xml(self, workflow_response):
        zip_bytes = base64.b64decode(workflow_response["zipBase64"])
        with zipfile.ZipFile(BytesIO(zip_bytes)) as zf:
            assert "deck.xml" in zf.namelist()

    def test_xml_has_valid_structure(self, workflow_response):
        zip_bytes = base64.b64decode(workflow_response["zipBase64"])
        with zipfile.ZipFile(BytesIO(zip_bytes)) as zf:
            xml_content = zf.read("deck.xml")
            root = ET.fromstring(xml_content)
            assert root.tag == "deck"
            assert root.find("fields") is not None
            assert root.find("cards") is not None

    def test_blob_hashes_match(self, workflow_response):
        zip_bytes = base64.b64decode(workflow_response["zipBase64"])
        with zipfile.ZipFile(BytesIO(zip_bytes)) as zf:
            # Get all blob files
            blob_files = [n for n in zf.namelist() if n.startswith("blobs/")]
            for blob_name in blob_files:
                blob_data = zf.read(blob_name)
                actual_hash = hashlib.sha256(blob_data).hexdigest()
                # Filename should be the hash
                expected_hash = blob_name.split("/")[-1].split(".")[0]
                assert actual_hash == expected_hash, f"Hash mismatch for {blob_name}"

    def test_cards_reference_existing_blobs(self, workflow_response):
        zip_bytes = base64.b64decode(workflow_response["zipBase64"])
        with zipfile.ZipFile(BytesIO(zip_bytes)) as zf:
            xml_content = zf.read("deck.xml")
            root = ET.fromstring(xml_content)
            blob_files = [n.split("/")[-1].split(".")[0] for n in zf.namelist() if "blobs" in n]

            for card in root.findall(".//card"):
                img = card.find("img")
                if img is not None:
                    img_id = img.get("id")
                    assert img_id in blob_files, f"Card references missing blob: {img_id}"
```

### Test Execution Order

1. **Local**: Run JSON validation (instant)
2. **Deploy**: Push to branch, deploy via nixos-rebuild
3. **Verify**: Check workflow imported correctly
4. **Smoke**: Quick webhook ping test
5. **Functional**: Full flow with test image
6. **E2E**: Real vocabulary image test

### Success Criteria

| Test | Pass Criteria |
|------|---------------|
| JSON valid | `jq empty` exits 0 |
| Workflow imported | Found in SQLite with active=1 |
| Webhook responds | HTTP 200 with JSON body |
| ZIP structure | Contains deck.xml + blobs/ |
| XML valid | Parses without errors |
| Hash verification | All blob hashes match filenames |
| Card count | > 0 cards generated |
| E2E test | > 10 cards from household image |

### Test Image Requirements

Need a simple, controlled test image:
- 3-5 clearly labeled vocabulary items
- Clean background, distinct items
- Hosted at accessible URL

Options:
1. Create and host on GitHub (raw URL)
2. Use a known simple vocabulary image
3. Base64 encode small test image in test fixture

---

## Open Questions / Risks

1. **ZIP subdirectory**: Does AnkiApp strictly require `blobs/` folder or accept flat ZIP?
2. **Rate limiting**: OpenRouter may rate-limit image generation (need delays)
3. **Image size**: Generated images may need resizing for mobile
4. **Error handling**: What if vision fails to extract items?
5. **Credential injection**: How to pass OpenRouter key to n8n at runtime?

---

## Implementation Blockers & Dependencies

### Blocker 1: n8n Credential Configuration

The workflow needs an HTTP Header Auth credential configured in n8n with the OpenRouter API key. Options:

**Option A: Manual UI Setup** (simplest)
1. Access n8n UI at `https://sancta-choir.tail4249a9.ts.net:5678`
2. Go to Settings > Credentials > Add Credential
3. Select "Header Auth"
4. Name: `OpenRouter API`
5. Header Name: `Authorization`
6. Header Value: `Bearer <key from openrouter-api-key.age>`

**Option B: n8n Credentials File** (declarative)
Configure `credentialsFile` in NixOS n8n module:
```nix
services.n8n-tailscale.credentialsFile = config.age.secrets.n8n-credentials.path;
```
With secret JSON:
```json
{
  "httpHeaderAuth": {
    "name": "Authorization",
    "value": "Bearer sk-or-v1-..."
  }
}
```

**Recommendation**: Start with Option A for testing, migrate to Option B for production.

### Blocker 2: Test Image Hosting

Need a stable, accessible test image URL. Options:
1. Use existing public image (mrmrsenglish.com) - risk of 404
2. Host in this repo's docs/ folder (GitHub raw URL)
3. Create minimal SVG test image inline

**Decision**: Create simple test image and host in repo.

### Blocker 3: Tailscale Access for Testing

Tests require Tailscale connectivity to reach n8n:
- Local machine must be on Tailnet
- Or use SSH tunnel: `ssh -L 5678:localhost:5678 sancta-choir`

### Blocker 4: n8n Code Node Limitations

The Code node runs in a sandboxed environment:
- Limited npm packages (no `jszip`, `archiver`)
- Must use built-in Node.js APIs only
- `zlib` available for gzip, but not for ZIP with directories

**Workaround for blobs/ subdirectory**:
Research shows ZIP format allows directory entries. Can manually construct ZIP with:
```javascript
// ZIP file format: local file headers + central directory
// Directory entries have trailing slash in filename
// e.g., "blobs/" as a directory entry, then "blobs/hash.png" as file
```

Will need to implement minimal ZIP creation in Code node or test if AnkiApp accepts flat structure.

---

## Implementation Sequence

### Step 1: Create Minimal Test Workflow
Start with simplified flow to validate each component:
1. Webhook -> Respond (verify webhook works)
2. Add HTTP Request to OpenRouter (verify auth)
3. Add vision extraction (verify JSON parsing)
4. Add single image generation (verify image output)
5. Add XML generation (verify format)
6. Add ZIP creation (verify structure)

### Step 2: Configure Credentials
Before testing API calls:
1. SSH to sancta-choir
2. Get API key: `sudo cat /run/agenix/openrouter-api-key`
3. Configure in n8n UI

### Step 3: Incremental Testing
Test each node addition before proceeding:
```bash
# After each change, trigger webhook and check response
curl -X POST https://sancta-choir.tail4249a9.ts.net:5678/webhook-test/image-to-anki \
  -H "Content-Type: application/json" \
  -d '{"imageUrl": "https://..."}'
```

### Step 4: Full Integration
Once all nodes work individually:
1. Connect full flow
2. Test with simple image (3 items)
3. Test with complex image (20+ items)
4. Measure execution time and optimize

### Step 5: Deployment & Pytest
1. Commit workflow JSON
2. Deploy via nixos-rebuild
3. Run pytest suite
4. Fix any failures
5. Document final configuration

---

---

## Implementation Status (2026-01-19) - OPTIMIZED ✅

### Summary

**The workflow is functional, tested, and optimized for ARM.** Key achievements:
- Receives vocabulary infographic URL via webhook
- Extracts vocabulary using Claude Sonnet 4 vision
- Generates AI images using Gemini 2.5 Flash Image
- Builds AnkiApp-compatible ZIP with deck.xml + blobs/
- Returns `success:true` with card count and base64 ZIP
- **17x performance improvement** on ARM (RPi5) via native Node.js APIs

### Completed

1. **Workflow Structure**: Complete 14-node workflow with:
   - Webhook trigger with input validation
   - Vision API call (Claude Sonnet 4 for ZDR compatibility)
   - JSON parsing with markdown block removal and specific error handling
   - Loop over vocabulary items with rate limiting
   - Image generation (Gemini 2.5 Flash Image)
   - **Node.js crypto SHA256** (requires `NODE_FUNCTION_ALLOW_BUILTIN=crypto`)
   - **Node.js Buffer for base64** (fast native implementation)
   - **Optimized ZIP file creation** with Node.js Buffer API
   - AnkiApp XML deck generation
   - Webhook response with base64 ZIP

2. **AnkiApp Format Validation**: Python validator at `tests/test_ankiapp_format.py`
   - Validates deck.xml structure (root element, fields, cards)
   - Verifies SHA256 hashes match blob filenames
   - Comprehensive error condition tests via pytest
   - Self-test passes with sample deck

3. **ZDR-Compatible Models**:
   - Vision: `anthropic/claude-sonnet-4` (paid, works with ZDR)
   - Image Gen: `google/gemini-2.5-flash-image` (paid, works with ZDR)

4. **Performance Optimization** (PR #135):
   - **Before**: 10+ minutes (pure JS SHA256 on ARM = 100% CPU)
   - **After**: ~34 seconds for same workflow
   - Solution: Enable `NODE_FUNCTION_ALLOW_BUILTIN=crypto` in n8n config
   - Code nodes use `crypto.createHash('sha256')` and `Buffer.from()`

5. **Robust Error Handling**:
   - Parse Vocabulary JSON: Specific error types (empty_response, invalid_format, json_parse, not_array, empty_array, invalid_item)
   - Extract Image Data: console.error logging for debugging
   - Build AnkiApp Deck: Try-catch wrapper prevents workflow crash
   - Partial success: Failed items included in response for transparency

### Known Limitations

1. **Execution Time**: Full workflow takes ~30-60 seconds per vocabulary image:
   - Vision API call (~10s)
   - Image generation per vocabulary item (~60-90s each, but batched)
   - Rate limiting delays (2s between items)

2. **API Key Configuration**:
   - Uses `$env.OPENROUTER_API_KEY` environment variable
   - Configured via `openrouterApiKeyFile` in NixOS module
   - `blockEnvAccessInCode = false` required for `$env` expressions

### Files in This PR

```
n8n-workflows/
├── image-to-anki.json           # Main workflow (uses $env.OPENROUTER_API_KEY)
├── RESEARCH-image-to-anki.md    # This document

hosts/rpi5-full/
└── configuration.nix            # NODE_FUNCTION_ALLOW_BUILTIN=crypto

tests/
└── test_ankiapp_format.py       # AnkiApp ZIP format validator (pytest)
```

### Deployment

The workflow is deployed via NixOS declarative configuration:

```nix
services.n8n-tailscale = {
  enable = true;
  workflowsDir = "${self}/n8n-workflows";
  openrouterApiKeyFile = config.age.secrets.openrouter-api-key.path;
  blockEnvAccessInCode = false;
  extraEnvironment = {
    NODE_FUNCTION_ALLOW_BUILTIN = "crypto";
  };
};
```

### Manual Testing Commands

```bash
# Validation test (should return error JSON)
curl -X POST http://127.0.0.1:5678/webhook/image-to-anki \
  -H "Content-Type: application/json" \
  -d '{}'

# Full test (replace with hosted vocabulary image)
curl -X POST http://127.0.0.1:5678/webhook/image-to-anki \
  -H "Content-Type: application/json" \
  -d '{"imageUrl":"https://example.com/vocab-image.png"}' \
  --max-time 300

# Validate output ZIP
python tests/test_ankiapp_format.py /tmp/anki-response.json
```

---

## Sources

- [AnkiApp Import Format](https://www.algoapp.ai/support/solutions/f7c77364/how-to-import-ankiapp-decks-zip-xml-/)
- [OpenRouter Image Generation](https://openrouter.ai/docs/guides/overview/multimodal/image-generation)
- [OpenRouter ZDR](https://openrouter.ai/docs/guides/features/zdr)
- [n8n Crypto Node](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.crypto/)
- [n8n Compression Node](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.compression/)
- [n8n Binary Data](https://docs.n8n.io/data/binary-data/)
- [n8n Code Node Binary Buffer](https://docs.n8n.io/code/cookbook/code-node/get-binary-data-buffer/)
- [How to hash by sha256 in n8n](https://community.n8n.io/t/how-to-hash-by-sha256/438)
