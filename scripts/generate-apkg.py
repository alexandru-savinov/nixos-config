#!/usr/bin/env python3
"""
Generate Anki APKG deck from JSON input.

Usage:
    echo '{"deckName": "Vocab", "cards": [{"word": "apple", "description": "A red fruit"}]}' | python generate-apkg.py

Input JSON format:
{
    "deckName": "Vocabulary",
    "cards": [
        {
            "word": "apple",
            "description": "A red fruit",          # Required for text-only cards
            "imageBase64": "iVBORw0KGgo...",       # Optional: if present, creates image card
            "mimeType": "image/jpeg",              # Optional, defaults to image/jpeg
            "audioBase64": "//uQxAAA...",          # Optional: MP3 pronunciation audio
            "audioMimeType": "audio/mpeg"          # Optional, defaults to audio/mpeg
        }
    ]
}

Card types:
- With imageBase64: Shows image on front, word on back (with optional audio)
- Without imageBase64: Shows word on front, description on back (text-only, with optional audio)

Audio: If audioBase64 is present, audio auto-plays when the card back is revealed.

Output: JSON with deck info (use download endpoint to get APKG file)
"""

import sys
import json
import base64
import tempfile
import os
import html
import random
import time

import genanki


def generate_model_id():
    """Generate a stable model ID based on timestamp."""
    return random.randrange(1 << 30, 1 << 31)


def generate_deck_id():
    """Generate a stable deck ID based on timestamp."""
    return random.randrange(1 << 30, 1 << 31)


def create_image_model(model_id):
    """Create an Anki model for image-to-word vocabulary cards with optional audio."""
    return genanki.Model(
        model_id,
        'Vocabulary (Image-to-Word)',
        fields=[
            {'name': 'Image'},
            {'name': 'Word'},
            {'name': 'Audio'},  # [sound:audio_0.mp3] - auto-plays on card reveal
        ],
        templates=[
            {
                'name': 'Image to Word',
                'qfmt': '{{Image}}',
                'afmt': '{{FrontSide}}<hr id="answer"><div class="word">{{Word}}</div>{{Audio}}',
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


def create_text_model(model_id):
    """Create an Anki model for text-only vocabulary cards with optional audio."""
    return genanki.Model(
        model_id,
        'Vocabulary (Text-Only)',
        fields=[
            {'name': 'Word'},
            {'name': 'Description'},
            {'name': 'Audio'},  # [sound:audio_0.mp3] - auto-plays on card reveal
        ],
        templates=[
            {
                'name': 'Word to Description',
                'qfmt': '<div class="word">{{Word}}</div>',
                'afmt': '{{FrontSide}}<hr id="answer"><div class="description">{{Description}}</div>{{Audio}}',
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
.word {
    font-size: 36px;
    font-weight: 700;
    color: #1e40af;
    margin: 20px 0;
}
.description {
    font-size: 24px;
    font-weight: 400;
    color: #374151;
    line-height: 1.5;
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


def get_audio_extension(mime_type):
    """Get file extension from audio MIME type."""
    mime_map = {
        'audio/mpeg': 'mp3',
        'audio/mp3': 'mp3',
        'audio/wav': 'wav',
        'audio/ogg': 'ogg',
        'audio/webm': 'webm',
        'audio/aac': 'aac',
    }
    return mime_map.get(mime_type, 'mp3')


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

    # Create models and deck
    image_model_id = generate_model_id()
    text_model_id = generate_model_id()
    deck_id = generate_deck_id()

    image_model = create_image_model(image_model_id)
    text_model = create_text_model(text_model_id)
    deck = genanki.Deck(deck_id, deck_name)

    # Temporary directory for media files
    media_files = []

    with tempfile.TemporaryDirectory() as tmpdir:
        image_card_count = 0
        text_card_count = 0
        audio_card_count = 0
        audio_failed_count = 0
        error_count = 0
        words = []

        for idx, card in enumerate(cards_data):
            word = card.get('word', '')
            description = card.get('description', '')
            image_base64 = card.get('imageBase64', '')
            mime_type = card.get('mimeType', 'image/jpeg')
            audio_base64 = card.get('audioBase64', '')
            audio_mime_type = card.get('audioMimeType', 'audio/mpeg')

            if not word:
                error_count += 1
                continue

            # HTML-escape to prevent XSS/rendering issues
            escaped_word = html.escape(word)
            escaped_description = html.escape(description) if description else ''

            # Process audio if present (used by both image and text cards)
            audio_field = ''
            if audio_base64:
                try:
                    audio_data = base64.b64decode(audio_base64)
                    audio_ext = get_audio_extension(audio_mime_type)
                    audio_filename = f'audio_{idx}.{audio_ext}'
                    audio_path = os.path.join(tmpdir, audio_filename)

                    with open(audio_path, 'wb') as f:
                        f.write(audio_data)

                    media_files.append(audio_path)
                    audio_field = f'[sound:{audio_filename}]'
                    audio_card_count += 1
                except Exception as e:
                    # Log audio failure for debugging, continue without audio
                    print(f"WARNING: Audio processing failed for card {idx} ({word}): {e}", file=sys.stderr)
                    audio_field = ''
                    audio_failed_count += 1

            # Card with image: use image model (image on front, word on back)
            if image_base64:
                try:
                    image_data = base64.b64decode(image_base64)
                    ext = get_image_extension(mime_type)
                    image_filename = f'img_{idx}.{ext}'
                    image_path = os.path.join(tmpdir, image_filename)

                    with open(image_path, 'wb') as f:
                        f.write(image_data)

                    media_files.append(image_path)
                    image_field = f'<img src="{image_filename}">'

                    note = genanki.Note(
                        model=image_model,
                        fields=[image_field, escaped_word, audio_field]
                    )
                    deck.add_note(note)
                    image_card_count += 1
                    words.append(word)
                except Exception as e:
                    # Log image failure, fall back to text card if possible
                    print(f"WARNING: Image processing failed for card {idx} ({word}): {e}", file=sys.stderr)
                    if escaped_description:
                        note = genanki.Note(
                            model=text_model,
                            fields=[escaped_word, escaped_description, audio_field]
                        )
                        deck.add_note(note)
                        text_card_count += 1
                        words.append(word)
                    else:
                        error_count += 1
                    continue

            # Card without image: use text model (word on front, description on back)
            elif escaped_description:
                note = genanki.Note(
                    model=text_model,
                    fields=[escaped_word, escaped_description, audio_field]
                )
                deck.add_note(note)
                text_card_count += 1
                words.append(word)

            # No image and no description: skip
            else:
                error_count += 1
                continue

        valid_count = image_card_count + text_card_count

        if valid_count == 0:
            print(json.dumps({'success': False, 'error': 'No valid cards created'}))
            sys.exit(1)

        # Create package with media
        package = genanki.Package(deck)
        package.media_files = media_files

        # Write APKG to persistent temp directory for download
        # Use UUID for unique filename to avoid collisions
        import uuid
        apkg_dir = '/var/lib/n8n/anki-decks'
        os.makedirs(apkg_dir, exist_ok=True)

        # Cleanup: delete files older than 1 hour to prevent accumulation
        cutoff_time = time.time() - 3600  # 1 hour ago
        for old_file in os.listdir(apkg_dir):
            old_path = os.path.join(apkg_dir, old_file)
            if os.path.isfile(old_path) and os.path.getmtime(old_path) < cutoff_time:
                try:
                    os.remove(old_path)
                except OSError as e:
                    print(f"WARNING: Failed to cleanup old file {old_path}: {e}", file=sys.stderr)

        deck_id = str(uuid.uuid4())[:8]
        output_filename = f'{deck_id}.apkg'
        output_path = os.path.join(apkg_dir, output_filename)
        package.write_to_file(output_path)

        apkg_size = os.path.getsize(output_path)

        # Output result as JSON (no base64 - use download endpoint instead)
        result = {
            'success': True,
            'cardCount': valid_count,
            'imageCardCount': image_card_count,
            'textCardCount': text_card_count,
            'audioCardCount': audio_card_count,
            'audioFailedCount': audio_failed_count,
            'failedCount': error_count,
            'words': words,
            'deckId': deck_id,
            'apkgPath': output_path,
            'apkgSizeBytes': apkg_size
        }
        print(json.dumps(result))


if __name__ == '__main__':
    main()
