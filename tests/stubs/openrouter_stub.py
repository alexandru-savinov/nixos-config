"""
Reusable Flask stub of the OpenRouter API for tests.

Implements the small subset of OpenRouter that this repo's tests need:

- GET  /api/v1/endpoints/zdr   — list of ZDR-compliant models
- GET  /v1/endpoints/zdr       — same (alternate prefix used by some clients)
- GET  /v1/models              — full model catalogue
- POST /v1/chat/completions    — echoes the prompt; records payload
- GET  /__last_payload         — introspection: last POST body received

The stub is used by:
- tests/e2e_test_openwebui_zdr.py (open-webui pipe e2e)
- tests/test_openclaw_zdr_proxy.py (zdr proxy unit tests)
- tests/openclaw-zdr-proxy.nix (nixosTest end-to-end)
"""

from __future__ import annotations

import json
from typing import Any

from flask import Flask, jsonify, request


DEFAULT_ZDR_MODELS: list[dict[str, Any]] = [
    {"name": "Venice | qwen/qwen3-coder:free", "model_name": "Qwen3 Coder (free)"},
    {"name": "Z.AI | z-ai/glm-4.5-air:free", "model_name": "GLM 4.5 Air (free)"},
    {
        "name": "Venice | qwen/qwen3-next-80b-a3b-instruct:free",
        "model_name": "Qwen3 Next 80B (free)",
    },
    {"name": "OpenAI | openrouter/gpt-4o-mini", "model_name": "GPT-4o Mini"},
    {"name": "OpenAI | openrouter/gpt-4o", "model_name": "GPT-4o"},
]


DEFAULT_ALL_MODELS: list[dict[str, Any]] = [
    {"id": "qwen/qwen3-coder:free", "name": "Qwen3 Coder (free)"},
    {"id": "z-ai/glm-4.5-air:free", "name": "GLM 4.5 Air (free)"},
    {"id": "qwen/qwen3-next-80b-a3b-instruct:free", "name": "Qwen3 Next 80B (free)"},
    {"id": "openrouter/gpt-4o-mini", "name": "GPT-4o Mini"},
    {"id": "openrouter/gpt-4o", "name": "GPT-4o"},
    {"id": "openrouter/gpt-4o-32k", "name": "GPT-4o 32k (NOT ZDR)"},
]


def _zdr_payload(zdr_models: list[dict[str, Any]]) -> dict[str, Any]:
    return {"data": list(zdr_models)}


def create_stub_openrouter(
    zdr_models: list[dict[str, Any]] | None = None,
    all_models: list[dict[str, Any]] | None = None,
) -> Flask:
    """Build a Flask app that mimics the OpenRouter API."""
    app = Flask(__name__)
    app.config["ZDR_MODELS"] = list(
        zdr_models if zdr_models is not None else DEFAULT_ZDR_MODELS
    )
    app.config["ALL_MODELS"] = list(
        all_models if all_models is not None else DEFAULT_ALL_MODELS
    )
    app.config["LAST_PAYLOAD"] = None

    def _zdr_response():
        return jsonify(_zdr_payload(app.config["ZDR_MODELS"]))

    # OpenRouter exposes /api/v1/endpoints/zdr; some test setups mount the stub
    # at a base that already includes /api so /v1/endpoints/zdr is also valid.
    app.add_url_rule("/api/v1/endpoints/zdr", "zdr_api_v1", _zdr_response)
    app.add_url_rule("/v1/endpoints/zdr", "zdr_v1", _zdr_response)

    @app.route("/v1/models")
    def models():
        return jsonify({"data": app.config["ALL_MODELS"]})

    @app.route("/v1/chat/completions", methods=["POST"])
    def chat():
        payload = request.get_json(silent=True) or {}
        app.config["LAST_PAYLOAD"] = payload
        prompt = payload.get("prompt") or (
            payload.get("messages", [{}])[-1].get("content") if payload.get("messages") else "no-prompt"
        )
        return jsonify(
            {
                "id": "chatcmpl-stub",
                "object": "chat.completion",
                "model": payload.get("model"),
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": f"stub-response: {prompt}"},
                        "finish_reason": "stop",
                    }
                ],
                "_request_metadata": {"provider": payload.get("provider", {})},
            }
        )

    @app.route("/__last_payload")
    def last_payload():
        body = app.config.get("LAST_PAYLOAD")
        return (json.dumps(body) if body is not None else "null"), 200, {"Content-Type": "application/json"}

    return app


if __name__ == "__main__":
    import os

    port = int(os.environ.get("PORT", "9999"))
    create_stub_openrouter().run(host="127.0.0.1", port=port)
