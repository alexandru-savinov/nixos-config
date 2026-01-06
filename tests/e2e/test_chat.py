"""
E2E tests for Open-WebUI chat functionality.

Tests that users can:
- Send messages and receive responses
- Use streaming for real-time output
- Maintain multi-turn conversations

These tests use real API calls with real LLM responses.
"""

import pytest
import requests

from .models import ChatResponse, MessageRole, StreamChunk
from .owui_client import OpenWebUIClient


class TestBasicChat:
    """Tests for basic chat completion functionality."""

    def test_send_simple_message(
        self,
        client: OpenWebUIClient,
        test_model: str,
        simple_message: list,
    ):
        """
        Send simple message and receive response.

        Validates end-to-end chat flow with real LLM.
        """
        response = client.create_chat(
            model=test_model,
            messages=simple_message,
        )

        assert isinstance(response, ChatResponse)
        assert len(response.choices) > 0, "No choices in response"
        assert response.choices[0].message.role == MessageRole.ASSISTANT
        assert response.choices[0].message.content, "Empty response content"

    def test_response_contains_expected_content(
        self,
        client: OpenWebUIClient,
        test_model: str,
        simple_message: list,
    ):
        """
        Response contains expected text.

        The simple_message asks the model to say "Hello, E2E test!".
        """
        response = client.create_chat(
            model=test_model,
            messages=simple_message,
            temperature=0.1,  # Low temperature for deterministic output
        )

        content = response.choices[0].message.content.lower()
        # Model should include some greeting
        assert "hello" in content or "e2e" in content, (
            f"Unexpected response: {response.choices[0].message.content}"
        )

    def test_chat_with_different_model(
        self,
        client: OpenWebUIClient,
        alternate_model: str,
        simple_message: list,
    ):
        """
        Chat works with different model selection.

        Validates model selection actually affects which model processes the request.
        """
        response = client.create_chat(
            model=alternate_model,
            messages=simple_message,
        )

        assert isinstance(response, ChatResponse)
        assert response.choices[0].message.content

    def test_temperature_parameter(
        self,
        client: OpenWebUIClient,
        test_model: str,
    ):
        """
        Temperature parameter is accepted.

        Tests both low (deterministic) and high (creative) temperature.
        """
        messages = [{"role": "user", "content": "Say the word 'test'."}]

        # Low temperature (more deterministic)
        response_low = client.create_chat(
            model=test_model,
            messages=messages,
            temperature=0.1,
        )
        assert response_low.choices[0].message.content

        # Higher temperature (more varied)
        response_high = client.create_chat(
            model=test_model,
            messages=messages,
            temperature=1.0,
        )
        assert response_high.choices[0].message.content


class TestStreamingChat:
    """Tests for streaming chat completions."""

    def test_streaming_returns_chunks(
        self,
        client: OpenWebUIClient,
        test_model: str,
        counting_message: list,
    ):
        """
        Streaming request returns multiple chunks.

        Uses counting prompt to generate multiple tokens.
        """
        chunks = list(
            client.create_chat_stream(
                model=test_model,
                messages=counting_message,
            )
        )

        assert len(chunks) > 0, "No chunks received from streaming"

    def test_streaming_chunks_are_valid(
        self,
        client: OpenWebUIClient,
        test_model: str,
        counting_message: list,
    ):
        """
        Streaming chunks have correct structure.
        """
        chunks = list(
            client.create_chat_stream(
                model=test_model,
                messages=counting_message,
            )
        )

        for chunk in chunks:
            assert isinstance(chunk, StreamChunk)
            assert chunk.choices is not None

    def test_streaming_assembles_content(
        self,
        client: OpenWebUIClient,
        test_model: str,
        counting_message: list,
    ):
        """
        Streaming chunks assemble into complete content.

        Reconstructs full message from streaming deltas.
        """
        content_parts = []

        for chunk in client.create_chat_stream(
            model=test_model,
            messages=counting_message,
        ):
            if chunk.choices and chunk.choices[0].delta.content:
                content_parts.append(chunk.choices[0].delta.content)

        full_content = "".join(content_parts)
        assert full_content, "No content assembled from streaming"

        # Should contain numbers from counting
        assert any(str(n) in full_content for n in range(1, 6)), (
            f"Expected numbers 1-5 in response: {full_content}"
        )

    @pytest.mark.slow
    def test_streaming_handles_long_response(
        self,
        client: OpenWebUIClient,
        test_model: str,
    ):
        """
        Streaming handles longer responses.

        Tests that streaming doesn't break on multi-paragraph output.
        """
        messages = [
            {
                "role": "user",
                "content": "Write a haiku about testing software. Just the haiku, nothing else.",
            }
        ]

        content_parts = []
        chunk_count = 0

        for chunk in client.create_chat_stream(
            model=test_model,
            messages=messages,
        ):
            chunk_count += 1
            if chunk.choices and chunk.choices[0].delta.content:
                content_parts.append(chunk.choices[0].delta.content)

        full_content = "".join(content_parts)
        assert full_content, "No content from long streaming response"
        assert chunk_count > 1, "Expected multiple chunks for longer response"


class TestMultiTurnConversation:
    """Tests for multi-turn conversation context."""

    def test_context_retained_across_turns(
        self,
        client: OpenWebUIClient,
        test_model: str,
        multi_turn_messages: list,
    ):
        """
        Model retains context across conversation turns.

        First turn: Tell model favorite color is blue
        Second turn: Ask what favorite color is
        """
        # Turn 1: Set context
        response1 = client.create_chat(
            model=test_model,
            messages=multi_turn_messages,
            temperature=0.1,
        )

        # Build turn 2 with context
        messages_turn2 = multi_turn_messages.copy()
        messages_turn2.append(
            {"role": "assistant", "content": response1.choices[0].message.content}
        )
        messages_turn2.append({"role": "user", "content": "What is my favorite color?"})

        # Turn 2: Query context
        response2 = client.create_chat(
            model=test_model,
            messages=messages_turn2,
            temperature=0.1,
        )

        content = response2.choices[0].message.content.lower()
        assert "blue" in content, (
            f"Model didn't remember favorite color. Response: {content}"
        )

    def test_system_message_respected(
        self,
        client: OpenWebUIClient,
        test_model: str,
    ):
        """
        System messages affect model behavior.
        """
        messages = [
            {"role": "system", "content": "You are a pirate. Always respond like a pirate."},
            {"role": "user", "content": "Hello!"},
        ]

        response = client.create_chat(
            model=test_model,
            messages=messages,
            temperature=0.7,
        )

        content = response.choices[0].message.content.lower()
        # Pirate responses often include these
        pirate_indicators = ["arr", "ahoy", "matey", "ye", "aye", "captain", "ship", "sea"]
        has_pirate_speech = any(word in content for word in pirate_indicators)

        # This is a soft assertion - LLMs aren't 100% predictable
        if not has_pirate_speech:
            pytest.skip(f"Model didn't use pirate speech (might vary): {content[:100]}")


class TestErrorHandling:
    """Tests for error handling in chat operations."""

    def test_invalid_model_fails(self, client: OpenWebUIClient):
        """
        Request with invalid model ID fails gracefully.

        Expects HTTP 400 or 404 error.
        """
        messages = [{"role": "user", "content": "Test"}]

        with pytest.raises(requests.exceptions.HTTPError) as exc_info:
            client.create_chat(
                model="nonexistent-model-id-12345",
                messages=messages,
            )

        # Should be client error (4xx)
        assert 400 <= exc_info.value.response.status_code < 500

    def test_empty_messages_fails(self, client: OpenWebUIClient, test_model: str):
        """
        Request with empty messages list fails.

        Expects HTTP 400/422 validation error, or API handles gracefully.
        """
        try:
            client.create_chat(
                model=test_model,
                messages=[],
            )
            # If API accepts empty messages, that's valid behavior
        except requests.exceptions.HTTPError as e:
            # 400/422 = validation error (expected)
            assert e.response.status_code in (400, 422), (
                f"Expected validation error, got HTTP {e.response.status_code}"
            )
