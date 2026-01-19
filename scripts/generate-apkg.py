#!/usr/bin/env python3
"""
Generate Anki APKG deck from JSON input.

Usage:
    echo '{"deckName": "Vocab", "cards": [{"word": "apple", "imageBase64": "..."}]}' | python generate-apkg.py

Input JSON format:
{
    "deckName": "Vocabulary",
    "cards": [
        {
            "word": "apple",
            "imageBase64": "iVBORw0KGgo...",  # Base64-encoded image
            "mimeType": "image/jpeg"           # Optional, defaults to image/jpeg
        }
    ]
}

Output: Base64-encoded APKG file to stdout
"""

import sys
import json
import base64
import tempfile
import os
import html
import random

import genanki


def generate_model_id():
    """Generate a stable model ID based on timestamp."""
    return random.randrange(1 << 30, 1 << 31)


def generate_deck_id():
    """Generate a stable deck ID based on timestamp."""
    return random.randrange(1 << 30, 1 << 31)


def create_vocabulary_model(model_id):
    """Create an Anki model for image-to-word vocabulary cards."""
    return genanki.Model(
        model_id,
        'Vocabulary (Image-to-Word)',
        fields=[
            {'name': 'Image'},
            {'name': 'Word'},
        ],
        templates=[
            {
                'name': 'Image to Word',
                'qfmt': '{{Image}}',
                'afmt': '{{FrontSide}}<hr id="answer"><div class="word">{{Word}}</div>',
            },
        ],
        css='''
.card {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    font-size: 24px;
    text-align: center;
    color: #333;
    background-color: #fafafa;
    padding: 20px;
}
.card img {
    max-width: 100%;
    max-height: 400px;
    border-radius: 8px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.1);
}
.word {
    font-size: 32px;
    font-weight: 600;
    color: #2563eb;
    margin-top: 16px;
}
'''
    )


def get_image_extension(mime_type):
    """Get file extension from MIME type."""
    mime_map = {
        'image/jpeg': 'jpg',
        'image/jpg': 'jpg',
        'image/png': 'png',
        'image/gif': 'gif',
        'image/webp': 'webp',
    }
    return mime_map.get(mime_type, 'jpg')


def main():
    # Read JSON from stdin
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(json.dumps({'success': False, 'error': f'Invalid JSON: {e}'}))
        sys.exit(1)

    deck_name = input_data.get('deckName', 'Vocabulary')
    cards_data = input_data.get('cards', [])

    if not cards_data:
        print(json.dumps({'success': False, 'error': 'No cards provided'}))
        sys.exit(1)

    # Create model and deck
    model_id = generate_model_id()
    deck_id = generate_deck_id()

    model = create_vocabulary_model(model_id)
    deck = genanki.Deck(deck_id, deck_name)

    # Temporary directory for media files
    media_files = []

    with tempfile.TemporaryDirectory() as tmpdir:
        valid_count = 0
        error_count = 0
        words = []

        for idx, card in enumerate(cards_data):
            word = card.get('word', '')
            image_base64 = card.get('imageBase64', '')
            mime_type = card.get('mimeType', 'image/jpeg')

            if not word or not image_base64:
                error_count += 1
                continue

            # Decode and save image to temp file
            try:
                image_data = base64.b64decode(image_base64)
                ext = get_image_extension(mime_type)
                image_filename = f'img_{idx}.{ext}'
                image_path = os.path.join(tmpdir, image_filename)

                with open(image_path, 'wb') as f:
                    f.write(image_data)

                media_files.append(image_path)
            except Exception as e:
                error_count += 1
                continue

            # Create note with image reference
            # HTML-escape the word to prevent XSS/rendering issues
            escaped_word = html.escape(word)
            image_field = f'<img src="{image_filename}">'

            note = genanki.Note(
                model=model,
                fields=[image_field, escaped_word]
            )
            deck.add_note(note)
            valid_count += 1
            words.append(word)

        if valid_count == 0:
            print(json.dumps({'success': False, 'error': 'No valid cards created'}))
            sys.exit(1)

        # Create package with media
        package = genanki.Package(deck)
        package.media_files = media_files

        # Write to temp file and read as base64
        output_path = os.path.join(tmpdir, 'output.apkg')
        package.write_to_file(output_path)

        with open(output_path, 'rb') as f:
            apkg_base64 = base64.b64encode(f.read()).decode('utf-8')

        # Output result as JSON
        result = {
            'success': True,
            'cardCount': valid_count,
            'failedCount': error_count,
            'words': words,
            'apkgBase64': apkg_base64,
            'apkgSizeBytes': len(base64.b64decode(apkg_base64))
        }
        print(json.dumps(result))


if __name__ == '__main__':
    main()
