import json
import os
import pathlib

# Import the pipe implementation
import sys
import time
from unittest import mock

import pytest

# Resolve the directory containing the pipe implementation (do not mutate sys.path)
module_dir = (
    pathlib.Path(__file__).resolve().parents[1]
    / "modules"
    / "services"
    / "open-webui-functions"
)
import importlib.util


def _load_pipe():
    module_path = (
        pathlib.Path(__file__).parents[1]
        / "modules"
        / "services"
        / "open-webui-functions"
        / "openrouter_zdr_pipe.py"
    )
    spec = importlib.util.spec_from_file_location(
        "openrouter_zdr_pipe", str(module_path)
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.Pipe


Pipe = _load_pipe()


@pytest.fixture
def pipe():
    """Return a fresh Pipe instance."""
    return Pipe()


@pytest.fixture
def mock_requests_get(monkeypatch):
    """Mock requests.get to return controlled responses."""

    def _mock_get(url, headers=None, timeout=None):
        # Determine which endpoint is being called
        if url.endswith("/endpoints/zdr"):
            # Return a list of ZDR-compliant models (format: "Provider | model-id")
            return mock.Mock(
                status_code=200,
                json=lambda: {
                    "data": [
                        {
                            "name": "OpenAI | openrouter/gpt-4o-mini",
                            "model_name": "GPT-4o Mini",
                        },
                        {
                            "name": "OpenAI | openrouter/gpt-4o",
                            "model_name": "GPT-4o",
                        },
                    ]
                },
            )
        elif url.endswith("/models"):
            # Return all available models
            return mock.Mock(
                status_code=200,
                json=lambda: {
                    "data": [
                        {"id": "openrouter/gpt-4o-mini", "name": "GPT-4o Mini"},
                        {"id": "openrouter/gpt-4o", "name": "GPT-4o"},
                        {"id": "openrouter/gpt-4o-32k", "name": "GPT-4o 32k"},
                    ]
                },
            )
        else:
            raise ValueError(f"Unexpected URL: {url}")

    monkeypatch.setattr("requests.get", _mock_get)
    return _mock_get


@pytest.fixture
def mock_requests_post(monkeypatch):
    """Mock requests.post for the pipe method."""

    def _mock_post(url, json=None, headers=None, stream=False, timeout=None):
        # Simulate a successful completion response
        if url.endswith("/chat/completions"):
            return mock.Mock(
                status_code=200,
                json=lambda: {"choices": [{"message": {"content": "Hello"}}]},
                raise_for_status=lambda: None,
                iter_lines=lambda: [b'{"choices":[{"message":{"content":"Hello"}}]}\n'],
            )
        raise ValueError(f"Unexpected POST URL: {url}")

    monkeypatch.setattr("requests.post", _mock_post)
    return _mock_post


def test_pipes_returns_only_zdr_models(pipe, mock_requests_get):
    """The pipes method should return only ZDR‑compliant models."""
    # Ensure API key is set
    pipe.valves.OPENROUTER_API_KEY = "dummy-key"

    models = pipe.pipes()
    # Should contain only the two ZDR models
    assert len(models) == 2
    ids = {m["id"] for m in models}
    assert ids == {"openrouter/gpt-4o-mini", "openrouter/gpt-4o"}
    # Names should be prefixed
    for m in models:
        assert m["name"].startswith("ZDR/")


def test_pipes_handles_missing_api_key(pipe):
    """If no API key is provided, an error model is returned."""
    pipe.valves.OPENROUTER_API_KEY = ""
    models = pipe.pipes()
    assert len(models) == 1
    assert models[0]["id"] == "error"


def test_pipes_handles_no_zdr_models(pipe, mock_requests_get):
    """If the ZDR endpoint returns no models, an error is returned."""

    # Override the mock to return empty list
    def _mock_get(url, headers=None, timeout=None):
        if url.endswith("/endpoints/zdr"):
            return mock.Mock(
                status_code=200,
                json=lambda: {"data": []},
            )
        return mock.Mock(status_code=200, json=lambda: {"data": []})

    monkeypatch = mock.patch("requests.get", _mock_get)
    monkeypatch.start()
    pipe.valves.OPENROUTER_API_KEY = "dummy-key"
    models = pipe.pipes()
    monkeypatch.stop()
    assert len(models) == 1
    assert models[0]["id"] == "error"


def test_pipe_proxies_request_with_zdr(pipe, mock_requests_post):
    """The pipe method should add provider.zdr=true and forward the request."""
    pipe.valves.OPENROUTER_API_KEY = "dummy-key"
    body = {
        "model": "openrouter/gpt-4o-mini",
        "prompt": "Say hi",
        "stream": False,
    }
    response = pipe.pipe(body, __user__={})
    # The mocked post returns a JSON dict
    assert isinstance(response, dict)
    assert response["choices"][0]["message"]["content"] == "Hello"


def test_pipe_streaming_response(pipe, mock_requests_post):
    """When stream=True, the pipe returns a generator yielding lines."""
    pipe.valves.OPENROUTER_API_KEY = "dummy-key"
    body = {
        "model": "openrouter/gpt-4o-mini",
        "prompt": "Say hi",
        "stream": True,
    }
    generator = pipe.pipe(body, __user__={})
    # The generator should yield a single line from the mocked response
    lines = list(generator)
    assert len(lines) == 1
    assert json.loads(lines[0])["choices"][0]["message"]["content"] == "Hello"


def test_cache_mechanism(pipe, mock_requests_get, monkeypatch):
    """The pipe should cache ZDR model list for the configured TTL."""
    pipe.valves.OPENROUTER_API_KEY = "dummy-key"
    pipe.valves.ZDR_CACHE_TTL = 3600

    # First call populates cache
    first_call = pipe.pipes()
    assert len(first_call) == 2
    assert {m["id"] for m in first_call} == {"openrouter/gpt-4o-mini", "openrouter/gpt-4o"}

    # Monkeypatch time to simulate time passage less than TTL
    original_time = time.time
    monkeypatch.setattr(time, "time", lambda: original_time() + 100)

    # Second call should return cached value, not trigger new request
    second_call = pipe.pipes()
    assert second_call == first_call

    # Simulate TTL expiry
    monkeypatch.setattr(time, "time", lambda: original_time() + 4000)
    # Next call should fetch again (mock will be called again)
    third_call = pipe.pipes()
    assert len(third_call) == 2
    assert {m["id"] for m in third_call} == {"openrouter/gpt-4o-mini", "openrouter/gpt-4o"}
