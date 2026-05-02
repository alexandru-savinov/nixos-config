"""
OpenClaw ZDR enforcement proxy.

A Flask sidecar that sits between OpenClaw and OpenRouter. Every request:

1. Has its `model` field validated against a fail-closed allow-list fetched
   from `${UPSTREAM}/endpoints/zdr` (cached, lazy refresh).
2. Has `provider.zdr = true` injected (matches the open-webui pipe pattern).
   This is the only field needed for upstream ZDR enforcement; OpenRouter's
   request schema rejects unknown keys, so the proxy does NOT inject
   `provider.allow` — the model allow-list is enforced client-side via the
   403 path above, not by stuffing it into the upstream payload.

Fail-closed semantics: if the upstream allow-list refresh fails AND the
existing cache is older than `2 * cacheTtl` seconds, the proxy returns 503
for everything — including chat completions and `/healthz` — rather than
serving requests against a potentially stale list.

Configuration via environment variables (read at import time):

- OPENROUTER_API_KEY              — bearer token (required at runtime)
- OPENCLAW_ZDR_PROXY_PORT         — listen port (default 5780, used by main)
- OPENCLAW_ZDR_UPSTREAM            — upstream base URL (default OpenRouter)
- OPENCLAW_ZDR_CACHE_TTL           — allow-list cache TTL seconds (default 3600)
"""

from __future__ import annotations

import logging
import os
import threading
import time
from typing import Any, Callable, Iterable

import requests
from flask import Flask, Response, jsonify, request, stream_with_context

logger = logging.getLogger("openclaw-zdr-proxy")

DEFAULT_UPSTREAM = "https://openrouter.ai/api/v1"
DEFAULT_CACHE_TTL = 3600
DEFAULT_PORT = 5780

# Indirection for tests to advance time via monkeypatch.
_TIME_FN: Callable[[], float] = time.time


class AllowListCache:
    """Holds the ZDR model allow-list and last successful refresh time."""

    def __init__(self, ttl: int) -> None:
        self.ttl = ttl
        self._lock = threading.Lock()
        self._models: set[str] = set()
        self._last_success: float | None = None

    @property
    def models(self) -> set[str]:
        with self._lock:
            return set(self._models)

    @property
    def last_success(self) -> float | None:
        with self._lock:
            return self._last_success

    def is_fresh(self, now: float) -> bool:
        """True if cache was successfully refreshed within ttl."""
        with self._lock:
            return (
                self._last_success is not None
                and (now - self._last_success) < self.ttl
            )

    def is_usable(self, now: float) -> bool:
        """True if cache exists and is within 2*ttl of last success.

        Outside this window we fail closed.
        """
        with self._lock:
            return (
                self._last_success is not None
                and (now - self._last_success) < (2 * self.ttl)
            )

    def update(self, models: Iterable[str], now: float) -> None:
        with self._lock:
            self._models = set(models)
            self._last_success = now


def _parse_zdr_response(payload: dict[str, Any]) -> set[str]:
    """Extract model IDs from the OpenRouter `/endpoints/zdr` response."""
    data = payload.get("data") or []
    if not isinstance(data, list):
        return set()

    # `/api/v1/endpoints/zdr` returns one entry per provider+model+quant combo;
    # the canonical model identifier is `model_id` ("qwen/qwen3-coder:free"),
    # which is what OpenClaw / OpenRouter clients send in the request body.
    # The previous parser tried to derive the id from `name` (e.g. "Together
    # | deepseek/...") via rsplit on " | ", which only works when the right
    # half happens to be the model_id. For Venice, Z.AI and several others
    # the right half is the human-readable `model_name` ("Qwen3 Coder"), so
    # the cache silently filled with names that no inbound request would
    # ever match — the proxy then 403'd every legitimate ZDR-allowed model.
    # Fix: read `model_id` directly. Keep `id` (some shapes use it) and the
    # `name`-rsplit path as last-resort fallbacks for forward compatibility.
    out: set[str] = set()
    for item in data:
        if not isinstance(item, dict):
            continue
        model_id = item.get("model_id")
        if isinstance(model_id, str) and model_id:
            out.add(model_id)
            continue
        item_id = item.get("id")
        if isinstance(item_id, str) and item_id:
            out.add(item_id)
            continue
        name = item.get("name") or ""
        if name:
            parts = name.rsplit(" | ", 1)
            fallback = parts[1] if len(parts) > 1 else name
            if fallback:
                out.add(fallback)
    return out


def _fetch_zdr_models(upstream: str, api_key: str, timeout: float = 30.0) -> set[str]:
    url = f"{upstream.rstrip('/')}/endpoints/zdr"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/alexandru-savinov/nixos-config",
        "X-Title": "openclaw-zdr-proxy",
    }
    response = requests.get(url, headers=headers, timeout=timeout)
    response.raise_for_status()
    return _parse_zdr_response(response.json())


def _refresh_allow_list(app: Flask) -> bool:
    """Try to refresh the cache. Return True on success."""
    cache: AllowListCache = app.config["ALLOW_LIST_CACHE"]
    upstream: str = app.config["UPSTREAM_URL"]
    api_key = app.config["API_KEY_PROVIDER"]()
    if not api_key:
        logger.error("OPENROUTER_API_KEY is empty; cannot refresh ZDR allow-list")
        return False
    fetcher: Callable[[str, str], set[str]] = app.config["ZDR_FETCHER"]
    try:
        models = fetcher(upstream, api_key)
    except Exception as exc:
        logger.warning("ZDR allow-list refresh failed: %s", exc)
        return False

    cache.update(models, _TIME_FN())
    logger.info("Refreshed ZDR allow-list: %d models", len(models))
    return True


def _ensure_allow_list(app: Flask) -> bool:
    """Refresh the cache if missing or stale. Returns True if cache is usable."""
    cache: AllowListCache = app.config["ALLOW_LIST_CACHE"]
    now = _TIME_FN()
    if cache.is_fresh(now):
        return True

    refreshed = _refresh_allow_list(app)
    if refreshed:
        return True

    return cache.is_usable(_TIME_FN())


def create_app(
    upstream_url: str | None = None,
    cache_ttl: int | None = None,
    api_key_provider: Callable[[], str] | None = None,
    zdr_fetcher: Callable[[str, str], set[str]] | None = None,
) -> Flask:
    """Build the Flask app. All side-effecting collaborators are injectable."""
    app = Flask(__name__)
    app.config["UPSTREAM_URL"] = upstream_url or os.environ.get(
        "OPENCLAW_ZDR_UPSTREAM", DEFAULT_UPSTREAM
    )
    ttl = cache_ttl if cache_ttl is not None else int(
        os.environ.get("OPENCLAW_ZDR_CACHE_TTL", str(DEFAULT_CACHE_TTL))
    )
    app.config["ALLOW_LIST_CACHE"] = AllowListCache(ttl=ttl)
    app.config["API_KEY_PROVIDER"] = api_key_provider or (
        lambda: os.environ.get("OPENROUTER_API_KEY", "")
    )
    app.config["ZDR_FETCHER"] = zdr_fetcher or _fetch_zdr_models

    @app.route("/healthz")
    def healthz():
        cache: AllowListCache = app.config["ALLOW_LIST_CACHE"]
        # Try a refresh if we have no successful fetch yet, but never on every
        # probe — health checks should not pummel the upstream.
        if cache.last_success is None:
            _refresh_allow_list(app)
        if cache.is_usable(_TIME_FN()):
            return jsonify({"status": "ok", "models": len(cache.models)}), 200
        return jsonify({"status": "fail-closed", "models": 0}), 503

    @app.route("/v1/models")
    def models_passthrough():
        if not _ensure_allow_list(app):
            return jsonify({"error": "zdr allow-list unavailable"}), 503
        cache: AllowListCache = app.config["ALLOW_LIST_CACHE"]
        now = int(_TIME_FN())
        return jsonify(
            {
                "object": "list",
                "data": [
                    {
                        "id": model_id,
                        "object": "model",
                        "created": now,
                        "owned_by": "openrouter",
                    }
                    for model_id in sorted(cache.models)
                ],
            }
        )

    @app.route("/v1/chat/completions", methods=["POST"])
    def chat_completions():
        if not _ensure_allow_list(app):
            return jsonify({"error": "zdr allow-list unavailable"}), 503

        body = request.get_json(silent=True) or {}
        model_id = body.get("model", "")
        if not isinstance(model_id, str) or not model_id:
            return jsonify({"error": "missing model"}), 400

        cache: AllowListCache = app.config["ALLOW_LIST_CACHE"]
        allow = cache.models
        if model_id not in allow:
            return (
                jsonify(
                    {
                        "error": {
                            "type": "zdr_blocked",
                            "message": f"model {model_id!r} is not in the ZDR allow-list",
                        }
                    }
                ),
                403,
            )

        api_key = app.config["API_KEY_PROVIDER"]()
        if not api_key:
            return jsonify({"error": "OPENROUTER_API_KEY not configured"}), 500

        upstream = app.config["UPSTREAM_URL"].rstrip("/")
        chat_url = f"{upstream}/chat/completions"

        # `body.get("provider", {})` returns None — not the default — when the
        # client explicitly sends `"provider": null`. `{**None}` raises
        # TypeError, so coalesce explicitly.
        provider_in = body.get("provider") or {}
        # ZDR enforcement on the upstream side is a single boolean: `zdr: true`
        # tells OpenRouter to route only to ZDR endpoints. The defense-in-depth
        # layer is the proxy's own client-side rejection above (the `model not
        # in allow_list -> 403` branch). Earlier versions also stuffed the full
        # allow-list into `provider.allow`, but OpenRouter's request schema
        # rejects unknown keys with HTTP 400 (`Unrecognized key: "allow"`),
        # which broke every chat completion. Keep the injection minimal.
        provider = {**provider_in, "zdr": True}
        payload = {**body, "provider": provider}

        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/alexandru-savinov/nixos-config",
            "X-Title": "openclaw-zdr-proxy",
        }

        stream = bool(body.get("stream"))
        try:
            upstream_resp = requests.post(
                url=chat_url,
                json=payload,
                headers=headers,
                stream=stream,
                timeout=300,
            )
        except requests.RequestException as exc:
            logger.error("upstream POST failed: %s", exc)
            return jsonify({"error": f"upstream error: {exc}"}), 502

        if stream:
            # Pass raw bytes through unchanged so SSE event delimiters
            # (blank lines per spec) and `: keep-alive` comments survive.
            # `iter_lines()` strips terminators and merges events.
            def generate():
                try:
                    for chunk in upstream_resp.iter_content(chunk_size=None):
                        if chunk:
                            yield chunk
                finally:
                    upstream_resp.close()

            return Response(
                stream_with_context(generate()),
                status=upstream_resp.status_code,
                mimetype=upstream_resp.headers.get("content-type", "text/event-stream"),
            )

        return Response(
            upstream_resp.content,
            status=upstream_resp.status_code,
            mimetype=upstream_resp.headers.get("content-type", "application/json"),
        )

    return app


# WSGI entry point used by gunicorn (`gunicorn proxy:app`).
app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("OPENCLAW_ZDR_PROXY_PORT", str(DEFAULT_PORT)))
    app.run(host="127.0.0.1", port=port)
