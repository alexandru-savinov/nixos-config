"""
Pytest fixtures for Open-WebUI E2E tests.

Configuration via environment variables:
- OPENWEBUI_BASE_URL: Target Open-WebUI instance (default: rpi5)
- OPENWEBUI_TEST_API_KEY: Test user API key (required, from agenix)
- OPENWEBUI_CHAT_TIMEOUT: Chat completion timeout in seconds (default: 120)

Run tests:
    export OPENWEBUI_TEST_API_KEY=$(sudo cat /run/agenix/e2e-test-api-key)
    pytest tests/e2e/ -v
"""

import os
from typing import Generator, List

import pytest

from .models import ModelInfo
from .owui_client import OpenWebUIClient


# ============================================================================
# Configuration
# ============================================================================


def get_base_url() -> str:
    """Get Open-WebUI base URL from environment."""
    return os.getenv(
        "OPENWEBUI_BASE_URL",
        "https://rpi5.tail4249a9.ts.net",  # Default to rpi5
    )


def get_api_key() -> str:
    """
    Get test API key from environment.

    This should be set from agenix secret:
        export OPENWEBUI_TEST_API_KEY=$(sudo cat /run/agenix/e2e-test-api-key)
    """
    key = os.getenv("OPENWEBUI_TEST_API_KEY")
    if not key:
        pytest.fail(
            "OPENWEBUI_TEST_API_KEY not set.\n"
            "Run: export OPENWEBUI_TEST_API_KEY=$(sudo cat /run/agenix/e2e-test-api-key)\n"
            "Or set it in your environment before running pytest."
        )
    return key


def get_chat_timeout() -> int:
    """Get chat timeout from environment."""
    return int(os.getenv("OPENWEBUI_CHAT_TIMEOUT", "120"))


# ============================================================================
# Client Fixtures
# ============================================================================


@pytest.fixture(scope="session")
def base_url() -> str:
    """Base URL for Open-WebUI instance."""
    return get_base_url()


@pytest.fixture(scope="session")
def api_key() -> str:
    """Test user API key."""
    return get_api_key()


@pytest.fixture(scope="session")
def client(base_url: str, api_key: str) -> Generator[OpenWebUIClient, None, None]:
    """
    Authenticated Open-WebUI client for the test session.

    Session-scoped to reuse connection across all tests.
    """
    client = OpenWebUIClient(
        base_url=base_url,
        api_key=api_key,
        default_timeout=30,
        chat_timeout=get_chat_timeout(),
    )

    # Verify connection before running tests
    if not client.health_check():
        pytest.fail(
            f"Cannot connect to Open-WebUI at {base_url}.\n"
            "Ensure the service is running and accessible via Tailscale."
        )

    yield client

    client.close()


# ============================================================================
# Model Fixtures
# ============================================================================


@pytest.fixture(scope="session")
def available_models(client: OpenWebUIClient) -> List[ModelInfo]:
    """
    All available models from Open-WebUI.

    Cached for session to avoid repeated API calls.
    """
    models = client.list_models()

    if not models:
        pytest.fail("No models available from Open-WebUI")

    return models


@pytest.fixture(scope="session")
def zdr_models(client: OpenWebUIClient) -> List[ModelInfo]:
    """
    ZDR-compliant models only (those with ZDR/ prefix).

    These are the models filtered by the ZDR pipe function.
    """
    models = client.get_zdr_models()

    if not models:
        pytest.skip(
            "No ZDR models available. "
            "Ensure zdrModelsOnly.enable = true in Open-WebUI configuration."
        )

    return models


@pytest.fixture
def test_model(zdr_models: List[ModelInfo]) -> str:
    """
    A single model ID for testing.

    Uses the first available ZDR model.
    """
    return zdr_models[0].id


@pytest.fixture
def alternate_model(zdr_models: List[ModelInfo]) -> str:
    """
    An alternate model ID for testing model selection.

    Uses second ZDR model if available, otherwise first.
    """
    if len(zdr_models) > 1:
        return zdr_models[1].id
    return zdr_models[0].id


# ============================================================================
# Test Data Fixtures
# ============================================================================


@pytest.fixture
def simple_message() -> list:
    """Simple test message for basic chat tests."""
    return [{"role": "user", "content": "Say 'Hello, E2E test!' and nothing else."}]


@pytest.fixture
def multi_turn_messages() -> list:
    """Messages for multi-turn conversation test."""
    return [
        {"role": "user", "content": "My favorite color is blue. Remember this."},
    ]


@pytest.fixture
def counting_message() -> list:
    """Message that generates multiple tokens for streaming tests."""
    return [{"role": "user", "content": "Count from 1 to 5, one number per line."}]


# ============================================================================
# Markers
# ============================================================================


def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line(
        "markers", "slow: marks tests as slow (deselect with '-m \"not slow\"')"
    )
    config.addinivalue_line(
        "markers", "search: marks tests that require Tavily search (deselect with '-m \"not search\"')"
    )
