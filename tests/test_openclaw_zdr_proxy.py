"""
Unit tests for the OpenClaw ZDR enforcement proxy.

The proxy module is at modules/services/openclaw-zdr-proxy/proxy.py
(non-package layout, so we load it via importlib).
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import socket
import sys
import threading
import time

import pytest
from werkzeug.serving import make_server

ROOT = pathlib.Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from stubs.openrouter_stub import create_stub_openrouter  # noqa: E402


def _load_proxy():
    module_path = (
        ROOT / "modules" / "services" / "openclaw-zdr-proxy" / "proxy.py"
    )
    spec = importlib.util.spec_from_file_location("openclaw_zdr_proxy", str(module_path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


proxy_mod = _load_proxy()


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _ServerThread(threading.Thread):
    def __init__(self, app, port: int):
        super().__init__(daemon=True)
        self.srv = make_server("127.0.0.1", port, app)

    def run(self):
        self.srv.serve_forever()

    def shutdown(self):
        self.srv.shutdown()


@pytest.fixture
def stub_server():
    port = _free_port()
    # Real OpenRouter `name` is "<provider> | <human-readable-model-name>";
    # the canonical id lives in `model_id`. Tests must mirror real shape so
    # the parser is exercised against the field it has to read in production.
    app = create_stub_openrouter(
        zdr_models=[
            {"name": "Venice | Qwen3 Coder", "model_id": "qwen/qwen3-coder:free"},
            {"name": "Z.AI | GLM 4.5 Air", "model_id": "z-ai/glm-4.5-air:free"},
        ],
    )
    server = _ServerThread(app, port)
    server.start()
    time.sleep(0.2)
    try:
        yield {"app": app, "url": f"http://127.0.0.1:{port}/v1"}
    finally:
        server.shutdown()


def test_parses_model_id_field():
    """Regression: the parser must read `model_id`, not derive it from `name`.

    Real OpenRouter `name` is "Venice | Qwen3 Coder" (provider | display
    name), so the older rsplit-on-' | ' parser cached the human-readable
    name and rejected every legitimate model. Production hit this on
    sancta-claw post-deploy: every chat completion 403'd with
    'model 'qwen/qwen3-coder:free' is not in the ZDR allow-list'.
    """
    payload = {
        "data": [
            {"name": "Venice | Qwen3 Coder", "model_id": "qwen/qwen3-coder:free"},
            {"name": "Z.AI | GLM 4.5 Air", "model_id": "z-ai/glm-4.5-air:free"},
            # Missing model_id, falls back to `id` (some shapes use this).
            {"name": "Other | Something", "id": "openrouter/something:free"},
            # Last-resort: only `name` available; rsplit on " | ".
            {"name": "Inline | inline/legacy:free"},
        ]
    }
    parsed = proxy_mod._parse_zdr_response(payload)
    assert "qwen/qwen3-coder:free" in parsed
    assert "z-ai/glm-4.5-air:free" in parsed
    assert "openrouter/something:free" in parsed
    assert "inline/legacy:free" in parsed
    # Human-readable display names must NOT leak into the allow-list.
    assert "Qwen3 Coder" not in parsed
    assert "GLM 4.5 Air" not in parsed


@pytest.fixture
def proxy_app(stub_server):
    """Build a proxy whose upstream is the stub server."""
    app = proxy_mod.create_app(
        upstream_url=stub_server["url"],
        cache_ttl=60,
        api_key_provider=lambda: "sk-test",
    )
    app.config["TESTING"] = True
    return app


def test_injects_zdr_true(proxy_app, stub_server):
    """Forwarded payload must carry provider.zdr=True and nothing extra.

    Earlier versions also injected `provider.allow = [...]` (the cached
    ZDR allow-list) as defense-in-depth. OpenRouter's request schema
    rejects unknown keys, so that injection broke every real chat
    completion with HTTP 400 (`Unrecognized key: "allow"`). The proxy
    enforces the allow-list client-side via the 403 branch instead;
    upstream injection is the boolean `zdr` flag only.
    """
    client = proxy_app.test_client()

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "qwen/qwen3-coder:free",
            "messages": [{"role": "user", "content": "hi"}],
        },
    )
    assert resp.status_code == 200, resp.data

    last = stub_server["app"].config["LAST_PAYLOAD"]
    assert last is not None, "stub did not record any upstream POST"
    assert last["provider"] == {"zdr": True}, (
        f"upstream provider must be exactly {{'zdr': True}}, got {last['provider']!r}"
    )


def test_rejects_non_zdr_model(proxy_app, stub_server):
    """A model that is not in the cached ZDR allow-list must 403."""
    client = proxy_app.test_client()

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "openrouter/gpt-4o-32k",
            "messages": [{"role": "user", "content": "x"}],
        },
    )
    assert resp.status_code == 403, resp.data
    body = resp.get_json()
    assert body["error"]["type"] == "zdr_blocked"
    # Stub must NOT have received any upstream POST for the rejected model.
    assert stub_server["app"].config["LAST_PAYLOAD"] is None


def test_healthz_fails_closed(monkeypatch):
    """When upstream refresh fails AND cache is older than 2*ttl, fail closed."""
    fake_now = {"t": 1_000_000.0}

    def now():
        return fake_now["t"]

    monkeypatch.setattr(proxy_mod, "_TIME_FN", now)

    fetch_calls: list[str] = []

    def successful_fetcher(upstream, api_key):
        fetch_calls.append("ok")
        return {"qwen/qwen3-coder:free"}

    def failing_fetcher(upstream, api_key):
        fetch_calls.append("fail")
        raise RuntimeError("upstream down")

    # First, populate the cache with one successful fetch.
    app = proxy_mod.create_app(
        upstream_url="http://upstream.invalid/v1",
        cache_ttl=60,
        api_key_provider=lambda: "sk-test",
        zdr_fetcher=successful_fetcher,
    )
    client = app.test_client()
    assert client.get("/healthz").status_code == 200
    assert fetch_calls == ["ok"]

    # Now swap in a failing fetcher and advance time past 2 * cache_ttl
    # (60s). Health must fail closed AND chat completions must 503.
    app.config["ZDR_FETCHER"] = failing_fetcher
    fake_now["t"] += 60 * 2 + 1  # > 2 * ttl since last success

    health = client.get("/healthz")
    assert health.status_code == 503, health.data

    chat = client.post(
        "/v1/chat/completions",
        json={
            "model": "qwen/qwen3-coder:free",
            "messages": [{"role": "user", "content": "hi"}],
        },
    )
    assert chat.status_code == 503, chat.data
    body = chat.get_json()
    assert "zdr allow-list unavailable" in body["error"]
    # And confirm the failing fetcher was invoked at least once during the
    # stale-cache refresh attempt.
    assert "fail" in fetch_calls
