#!/usr/bin/env python3
"""
Validate AnkiApp deck format.
Tests that generated ZIP files conform to AnkiApp import requirements.
"""

import base64
import hashlib
import re
import zipfile
import xml.etree.ElementTree as ET
from io import BytesIO
from pathlib import Path


def validate_ankiapp_zip(zip_base64: str) -> dict:
    """
    Validate a base64-encoded ZIP file against AnkiApp format requirements.

    Returns dict with:
        - valid: bool
        - errors: list of error messages
        - warnings: list of warning messages
        - stats: dict with card count, blob count, etc.
    """
    errors = []
    warnings = []
    stats = {}

    # Decode ZIP
    try:
        zip_bytes = base64.b64decode(zip_base64)
    except Exception as e:
        return {"valid": False, "errors": [f"Invalid base64: {e}"], "warnings": [], "stats": {}}

    # Open ZIP
    try:
        zf = zipfile.ZipFile(BytesIO(zip_bytes))
    except Exception as e:
        return {"valid": False, "errors": [f"Invalid ZIP: {e}"], "warnings": [], "stats": {}}

    # Check for deck.xml
    if "deck.xml" not in zf.namelist():
        errors.append("Missing deck.xml in ZIP root")
        return {"valid": False, "errors": errors, "warnings": warnings, "stats": stats}

    # Parse XML
    try:
        xml_content = zf.read("deck.xml")
        root = ET.fromstring(xml_content)
    except ET.ParseError as e:
        errors.append(f"Invalid XML: {e}")
        return {"valid": False, "errors": errors, "warnings": warnings, "stats": stats}

    # Validate root element
    if root.tag != "deck":
        errors.append(f"Root element must be 'deck', got '{root.tag}'")

    if "name" not in root.attrib:
        errors.append("Deck element missing required 'name' attribute")
    else:
        stats["deck_name"] = root.attrib["name"]

    # Validate fields section
    fields_elem = root.find("fields")
    if fields_elem is None:
        errors.append("Missing <fields> element")
    else:
        field_names = set()
        field_types = {}
        for field in fields_elem:
            if "name" not in field.attrib:
                errors.append(f"Field element <{field.tag}> missing 'name' attribute")
            else:
                field_names.add(field.attrib["name"])
                field_types[field.attrib["name"]] = field.tag
        stats["field_count"] = len(field_names)
        stats["field_names"] = list(field_names)
        stats["field_types"] = field_types

    # Validate cards section
    cards_elem = root.find("cards")
    if cards_elem is None:
        errors.append("Missing <cards> element")
    else:
        card_count = 0
        image_ids = set()

        for card in cards_elem.findall("card"):
            card_count += 1

            # Check that card fields reference defined field names
            for child in card:
                if "name" in child.attrib:
                    if fields_elem is not None and child.attrib["name"] not in field_names:
                        warnings.append(f"Card references undefined field: {child.attrib['name']}")

                # Collect image IDs
                if child.tag == "img":
                    if "id" not in child.attrib:
                        errors.append(f"Image field in card missing 'id' attribute")
                    else:
                        image_ids.add(child.attrib["id"])

        stats["card_count"] = card_count
        stats["image_ids"] = list(image_ids)

    # Validate blobs
    blob_files = [n for n in zf.namelist() if n.startswith("blobs/") and not n.endswith("/")]
    stats["blob_count"] = len(blob_files)

    # Verify each image ID has a corresponding blob
    blob_hashes = set()
    for blob_name in blob_files:
        # Extract hash from filename (blobs/HASH.ext)
        filename = blob_name.split("/")[-1]
        hash_part = filename.rsplit(".", 1)[0] if "." in filename else filename
        blob_hashes.add(hash_part)

        # Verify hash matches file content
        blob_data = zf.read(blob_name)
        actual_hash = hashlib.sha256(blob_data).hexdigest()
        if actual_hash != hash_part:
            errors.append(f"Blob {blob_name} hash mismatch: filename says {hash_part}, actual is {actual_hash}")

    # Check all image IDs have blobs
    missing_blobs = image_ids - blob_hashes
    if missing_blobs:
        errors.append(f"Cards reference missing blobs: {missing_blobs}")

    # Check for unused blobs (warning only)
    unused_blobs = blob_hashes - image_ids
    if unused_blobs:
        warnings.append(f"Unused blobs in archive: {unused_blobs}")

    zf.close()

    return {
        "valid": len(errors) == 0,
        "errors": errors,
        "warnings": warnings,
        "stats": stats
    }


def create_sample_deck() -> str:
    """Create a sample AnkiApp deck for testing."""
    import struct

    # Sample image (1x1 red PNG)
    png_data = bytes([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  # PNG signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,  # IHDR chunk
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  # 1x1 image
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,  # IDAT chunk
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
        0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59,
        0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,  # IEND chunk
        0x44, 0xAE, 0x42, 0x60, 0x82
    ])

    image_hash = hashlib.sha256(png_data).hexdigest()

    # Create XML
    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<deck name="Test Vocabulary" tags="test,sample">
  <fields>
    <img name="Image" sides="10"/>
    <text lang="en-US" name="Word" sides="01"/>
  </fields>
  <cards>
    <card>
      <img name="Image" id="{image_hash}"/>
      <text name="Word">bed</text>
    </card>
  </cards>
</deck>
'''

    # Create ZIP manually (same as n8n code)
    def crc32(data):
        crc = 0xFFFFFFFF
        table = []
        for i in range(256):
            c = i
            for _ in range(8):
                c = (0xEDB88320 ^ (c >> 1)) if (c & 1) else (c >> 1)
            table.append(c)
        for byte in data:
            crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8)
        return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF

    files = [
        ("deck.xml", xml.encode("utf-8")),
        (f"blobs/{image_hash}.png", png_data)
    ]

    local_parts = []
    central_parts = []
    offset = 0

    for name, data in files:
        name_bytes = name.encode("utf-8")
        crc = crc32(data)

        # Local file header
        local_header = struct.pack(
            "<IHHHHHIIIHH",
            0x04034b50,  # signature
            20,          # version needed
            0,           # flags
            0,           # compression
            0,           # mod time
            0,           # mod date
            crc,         # crc32
            len(data),   # compressed size
            len(data),   # uncompressed size
            len(name_bytes),  # name length
            0            # extra length
        )
        local_parts.append(local_header + name_bytes + data)

        # Central directory header
        central_header = struct.pack(
            "<IHHHHHHIIIHHHHHII",
            0x02014b50,  # signature
            20,          # version made by
            20,          # version needed
            0,           # flags
            0,           # compression
            0,           # mod time
            0,           # mod date
            crc,         # crc32
            len(data),   # compressed size
            len(data),   # uncompressed size
            len(name_bytes),  # name length
            0,           # extra length
            0,           # comment length
            0,           # disk start
            0,           # internal attrs
            0,           # external attrs
            offset       # local header offset
        )
        central_parts.append(central_header + name_bytes)
        offset += len(local_header) + len(name_bytes) + len(data)

    local_data = b"".join(local_parts)
    central_data = b"".join(central_parts)

    # End of central directory
    end_record = struct.pack(
        "<IHHHHIIH",
        0x06054b50,      # signature
        0,               # disk number
        0,               # disk with central dir
        len(files),      # entries on disk
        len(files),      # total entries
        len(central_data),  # central dir size
        len(local_data),    # central dir offset
        0                # comment length
    )

    zip_data = local_data + central_data + end_record
    return base64.b64encode(zip_data).decode("ascii")


def test_sample_deck():
    """Test validation with a sample deck."""
    print("Creating sample deck...")
    sample_base64 = create_sample_deck()

    print(f"Sample ZIP size: {len(base64.b64decode(sample_base64))} bytes")

    print("\nValidating...")
    result = validate_ankiapp_zip(sample_base64)

    print(f"\nValid: {result['valid']}")
    print(f"Stats: {result['stats']}")

    if result['errors']:
        print(f"\nErrors:")
        for err in result['errors']:
            print(f"  - {err}")

    if result['warnings']:
        print(f"\nWarnings:")
        for warn in result['warnings']:
            print(f"  - {warn}")

    return result['valid']


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "--test":
        success = test_sample_deck()
        sys.exit(0 if success else 1)
    elif len(sys.argv) > 1:
        # Validate a file
        with open(sys.argv[1], "r") as f:
            content = f.read().strip()

        # Check if it's a JSON response with zipBase64 field
        if content.startswith("{"):
            import json
            data = json.loads(content)
            if "zipBase64" in data:
                content = data["zipBase64"]

        result = validate_ankiapp_zip(content)
        print(f"Valid: {result['valid']}")
        print(f"Stats: {result['stats']}")
        if result['errors']:
            print("Errors:", result['errors'])
        if result['warnings']:
            print("Warnings:", result['warnings'])
        sys.exit(0 if result['valid'] else 1)
    else:
        print("Usage: python test_ankiapp_format.py [--test | <base64_or_json_file>]")
        print("  --test: Run self-test with sample deck")
        print("  <file>: Validate base64 ZIP or JSON response file")
