"""
E2E test for Anki image compression pipeline.

Verifies that images in generated APKG decks are compressed to <= 512x512.
Requires a running n8n instance with the image-to-anki workflow active.

Configuration via environment variables:
- N8N_BASE_URL: n8n webhook base URL (default: https://rpi5.tail4249a9.ts.net:5678)

Run:
    pytest tests/e2e/test_anki_image_compression.py -v
"""

import base64
import json
import os
import tempfile
import time
import zipfile

import pytest
import urllib3

# Suppress InsecureRequestWarning for Tailscale self-signed certs
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

N8N_BASE_URL = os.getenv("N8N_BASE_URL", "https://rpi5.tail4249a9.ts.net:5678")
WEBHOOK_PATH = "/webhook/image-to-anki"
STATUS_TIMEOUT = 300  # 5 minutes max for image generation


@pytest.fixture(scope="module")
def http():
    """HTTP client with retry logic."""
    return urllib3.PoolManager(
        cert_reqs="CERT_NONE",
        retries=urllib3.Retry(total=3, backoff_factor=1),
    )


@pytest.fixture(scope="module")
def n8n_base_url():
    return N8N_BASE_URL


def _make_vocab_image(words):
    """Create a simple PNG image with vocabulary words and return base64 string."""
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (400, 40 * len(words) + 20), "white")
    draw = ImageDraw.Draw(img)
    for i, word in enumerate(words):
        draw.text((20, 20 + i * 40), word, fill="black")
    from io import BytesIO
    buf = BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def _submit_deck(http, base_url, words):
    """Create a vocab image from words and submit it to the pipeline."""
    image_b64 = _make_vocab_image(words)
    payload = json.dumps({
        "imageData": image_b64,
        "deckName": "E2E Compression Test",
    }).encode("utf-8")
    resp = http.request(
        "POST",
        f"{base_url}{WEBHOOK_PATH}",
        body=payload,
        headers={"Content-Type": "application/json"},
    )
    assert resp.status in (200, 202), f"Submit failed: HTTP {resp.status} - {resp.data.decode()}"
    return json.loads(resp.data.decode())


def _poll_status(http, status_url, timeout=STATUS_TIMEOUT):
    """Poll job status URL until completion or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        resp = http.request("GET", status_url)
        if resp.status != 200:
            time.sleep(5)
            continue
        data = json.loads(resp.data.decode())
        status = data.get("status", "")
        if status in ("complete", "completed"):
            return data
        if status in ("error", "failed"):
            pytest.fail(f"Job failed: {data.get('error', 'unknown')}")
        time.sleep(5)
    pytest.fail(f"Job did not complete within {timeout}s")


def _download_apkg(http, download_url):
    """Download APKG file and return path to temp file."""
    resp = http.request("GET", download_url)
    assert resp.status == 200, f"Download failed: HTTP {resp.status}"
    tmp = tempfile.NamedTemporaryFile(suffix=".apkg", delete=False)
    tmp.write(resp.data)
    tmp.close()
    return tmp.name


def _get_image_dimensions_from_apkg(apkg_path):
    """Extract all image dimensions from an APKG file."""
    from PIL import Image
    from io import BytesIO

    dims = []
    with zipfile.ZipFile(apkg_path, "r") as zf:
        media_json = json.loads(zf.read("media"))
        for idx, filename in media_json.items():
            if filename.startswith("img_"):
                img_data = zf.read(idx)
                img = Image.open(BytesIO(img_data))
                dims.append((filename, img.size))
    return dims


@pytest.mark.slow
class TestAnkiImageCompression:
    """E2E tests for image compression in the Anki generation pipeline."""

    def test_generated_images_are_compressed(self, http, n8n_base_url):
        """Submit a vocab image and verify images in APKG are <= 512px."""
        # Submit job with a simple vocab image
        job = _submit_deck(http, n8n_base_url, [
            "cat - a small furry animal",
            "sun - the star in our sky",
        ])

        # Handle both sync and async responses
        if "statusUrl" in job:
            # statusUrl may be relative (http://127.0.0.1:...) — use as-is
            status = _poll_status(http, job["statusUrl"])
            download_url = status.get("downloadUrl")
        else:
            download_url = job.get("downloadUrl")

        assert download_url, f"No download URL in response: {job}"

        # downloadUrl is a relative path like /webhook/anki-download?id=...
        if download_url.startswith("/"):
            download_url = n8n_base_url + download_url

        # Download and inspect
        apkg_path = _download_apkg(http, download_url)
        try:
            dims = _get_image_dimensions_from_apkg(apkg_path)
            assert len(dims) > 0, "APKG should contain at least one image"

            for filename, (w, h) in dims:
                assert w <= 512, f"{filename}: width {w} > 512"
                assert h <= 512, f"{filename}: height {h} > 512"
        finally:
            os.unlink(apkg_path)
