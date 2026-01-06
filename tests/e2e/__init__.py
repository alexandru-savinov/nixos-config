"""
E2E tests for Open-WebUI with real APIs (OpenRouter, Tavily).

Unlike the existing mock-based tests, these tests validate actual user workflows
against a live Open-WebUI deployment using real API integrations.

Target: https://rpi5.tail4249a9.ts.net (configurable via OPENWEBUI_BASE_URL)

Test scope:
- Model operations: list models, verify ZDR filtering, select different models
- Chat completions: send messages, streaming responses, multi-turn conversations
- Web search: Tavily RAG integration (when enabled)

Prerequisites:
- Open-WebUI running on target host
- Test user provisioned with API key (via agenix)
- Tailscale network access to target host
"""

__version__ = "0.1.0"
