"""
E2E test for Anki image compression pipeline.

Verifies that images in generated APKG decks are compressed to <= 512x512.
Requires a running n8n instance with the image-to-anki workflow active.

Configuration via environment variables:
- N8N_BASE_URL: n8n webhook base URL (default: https://rpi5.tail4249a9.ts.net:5678)

Run:
    pytest tests/e2e/test_anki_image_compression.py -v
"""

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


def _submit_deck(http, base_url, words):
    """Submit a vocabulary list and return the job response."""
    payload = json.dumps({"words": words}).encode("utf-8")
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
        if status == "completed":
            return data
        if status == "failed":
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
        """Submit a small vocab list and verify images in APKG are <= 512px."""
        # Submit job
        job = _submit_deck(http, n8n_base_url, ["cat", "dog"])

        # Handle both sync and async responses
        if "statusUrl" in job:
            status = _poll_status(http, job["statusUrl"])
            download_url = status.get("downloadUrl")
        else:
            download_url = job.get("downloadUrl")

        assert download_url, f"No download URL in response: {job}"

        # Download and inspect
        apkg_path = _download_apkg(http, download_url)
        try:
            dims = _get_image_dimensions_from_apkg(apkg_path)
            assert len(dims) > 0, "APKG should contain at least one image"

            for filename, (w, h) in dims:
                assert w <= 512, f"{filename}: width {w} > 512"
                assert h <= 512, f"{filename}: height {h} > 512"

            # APKG size sanity check (< 500KB for 2 cards)
            apkg_size = os.path.getsize(apkg_path)
            assert apkg_size < 500_000, f"APKG too large: {apkg_size} bytes"
        finally:
            os.unlink(apkg_path)
