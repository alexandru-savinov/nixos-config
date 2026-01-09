import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest
from flask import Flask, jsonify, request
from werkzeug.serving import make_server


# ----------------------------------------------------------------------
# Stub OpenRouter server
# ----------------------------------------------------------------------
def _find_free_port() -> int:
    """Return a free TCP port on localhost."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def create_stub_openrouter():
    """Create a Flask app that mimics the two OpenRouter endpoints we need."""
    app = Flask(__name__)

    # In‑memory data for the stub
    # ZDR endpoint returns {"name": "Provider | model-id", ...} format
    ZDR_MODELS = [
        {"name": "OpenAI | openrouter/gpt-4o-mini"},
        {"name": "OpenAI | openrouter/gpt-4o"},
    ]

    ALL_MODELS = [
        {"id": "openrouter/gpt-4o-mini", "name": "GPT‑4o Mini"},
        {"id": "openrouter/gpt-4o", "name": "GPT‑4o"},
        {"id": "openrouter/gpt-4o-32k", "name": "GPT‑4o 32k"},
    ]

    @app.route("/v1/endpoints/zdr")
    def zdr_endpoints():
        return jsonify({"data": ZDR_MODELS})

    @app.route("/v1/models")
    def models():
        return jsonify({"data": ALL_MODELS})

    @app.route("/v1/chat/completions", methods=["POST"])
    def chat():
        payload = request.get_json(silent=True) or {}
        # Echo back the prompt to make verification easy
        content = payload.get("prompt", "no-prompt")
        # Also include request metadata so tests can verify provider.zdr was set
        response = {
            "choices": [{"message": {"content": f"stub-response: {content}"}}],
            "_request_metadata": {
                "provider": payload.get("provider", {}),
            },
        }
        return jsonify(response)

    return app


class FlaskThread(threading.Thread):
    """Run a Flask app in a background thread."""

    def __init__(self, app, port):
        super().__init__(daemon=True)
        self.srv = make_server("127.0.0.1", port, app)
        self.ctx = app.app_context()
        self.ctx.push()

    def run(self):
        self.srv.serve_forever()

    def shutdown(self):
        self.srv.shutdown()


# ----------------------------------------------------------------------
# Helper to provision the pipe function into a temporary OpenWebUI DB
# ----------------------------------------------------------------------
def provision_pipe(db_path: Path, function_path: Path):
    """Run the provision.py script against a temporary DB."""
    provision_script = (
        Path(__file__).parent.parent
        / "modules"
        / "services"
        / "open-webui-functions"
        / "provision.py"
    )
    subprocess.check_call(
        [sys.executable, str(provision_script), str(db_path), str(function_path)],
        env=os.environ,
    )


# ----------------------------------------------------------------------
# The actual e2e test
# ----------------------------------------------------------------------
@pytest.fixture(scope="module")
def stub_openrouter():
    """Start the stub OpenRouter server for the duration of the module."""
    port = _find_free_port()
    app = create_stub_openrouter()
    server = FlaskThread(app, port)
    server.start()
    # Give the server a moment to start
    time.sleep(0.5)
    yield f"http://127.0.0.1:{port}"
    server.shutdown()


@pytest.fixture(scope="module")
def temp_openwebui_db():
    """Create a temporary SQLite DB that mimics OpenWebUI's schema."""
    with tempfile.TemporaryDirectory() as td:
        db_path = Path(td) / "webui.db"
        # Minimal schema required for the provisioner
        conn = sqlite3.connect(str(db_path))
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS function(
                id INTEGER PRIMARY KEY,
                name TEXT,
                content TEXT,
                type TEXT,
                description TEXT,
                is_active BOOLEAN,
                is_global BOOLEAN,
                meta TEXT,
                user_id INTEGER,
                updated_at INTEGER
            )
            """
        )
        conn.commit()
        conn.close()
        yield db_path


def test_e2e_zdr_pipe(stub_openrouter, temp_openwebui_db):
    """
    Full end‑to‑end test:

    1. Start stub OpenRouter.
    2. Provision the ZDR pipe function into a fresh OpenWebUI DB.
    3. Import the pipe implementation and point it at the stub server.
    4. Verify that `pipes()` returns only the ZDR models.
    5. Verify that a request through `pipe()` is correctly proxied and
       that the ZDR flag is added.
    """
    # ------------------------------------------------------------------
    # 1. Adjust environment so the pipe talks to the stub server
    # ------------------------------------------------------------------
    os.environ["OPENAI_API_BASE_URL"] = stub_openrouter
    os.environ["OPENAI_API_KEY"] = "dummy-key"

    # ------------------------------------------------------------------
    # 2. Provision the function
    # ------------------------------------------------------------------
    pipe_path = (
        Path(__file__).parent.parent
        / "modules"
        / "services"
        / "open-webui-functions"
        / "openrouter_zdr_pipe.py"
    )
    provision_pipe(temp_openwebui_db, pipe_path)

    # ------------------------------------------------------------------
    # 3. Import the pipe implementation (the file lives in the repo)
    # ------------------------------------------------------------------
    import importlib.util

    # Load the pipe implementation directly from the file (avoid relying on sys.path)
    spec = importlib.util.spec_from_file_location("openrouter_zdr_pipe", str(pipe_path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    Pipe = module.Pipe

    pipe = Pipe()
    # Ensure the pipe uses the stub base URL (overriding the default)
    # The stub has /v1 prefix to match OpenRouter's actual API structure
    pipe.valves.OPENROUTER_API_BASE_URL = f"{stub_openrouter}/v1"

    # ------------------------------------------------------------------
    # 4. Verify that only ZDR models are listed
    # ------------------------------------------------------------------
    models = pipe.pipes()
    assert isinstance(models, list)
    assert len(models) == 2, "Should return exactly the two ZDR models"
    returned_ids = {m["id"] for m in models}
    assert returned_ids == {"openrouter/gpt-4o-mini", "openrouter/gpt-4o"}
    for m in models:
        assert m["name"].startswith("ZDR/")

    # ------------------------------------------------------------------
    # 5. Verify that a request is proxied and ZDR flag is added
    # ------------------------------------------------------------------
    body = {
        "model": "openrouter/gpt-4o-mini",
        "prompt": "test‑prompt",
        "stream": False,
    }
    resp = pipe.pipe(body, __user__={})
    assert isinstance(resp, dict)
    # The stub returns the prompt back in the content field
    assert resp["choices"][0]["message"]["content"] == "stub-response: test‑prompt"
    # Verify that the ZDR flag was added to the request
    assert resp.get("_request_metadata", {}).get("provider", {}).get("zdr") is True

    # Also test with streaming to ensure it works in both modes
    body_stream = {
        "model": "openrouter/gpt-4o-mini",
        "prompt": "stream‑test",
        "stream": True,
    }
    gen = pipe.pipe(body_stream, __user__={})
    chunks = list(gen)
    # For streaming, we just verify it returns data (the pipe forwards SSE events)
    assert len(chunks) > 0
