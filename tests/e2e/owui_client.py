"""
Open-WebUI API client for E2E testing.

Follows patterns from openrouter_zdr_pipe.py for API interactions:
- requests library for HTTP calls
- Bearer token authentication
- Streaming response handling
- Error handling with clear messages

Target: https://rpi5.tail4249a9.ts.net (configurable)
"""

import json
import logging
from typing import Iterator, List, Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)

from .models import (
    ChatResponse,
    ChatChoice,
    Message,
    MessageRole,
    ModelInfo,
    SearchResponse,
    SearchResult,
    StreamChunk,
    StreamChoice,
    StreamDelta,
)


class OpenWebUIClient:
    """
    High-level client for Open-WebUI API operations.

    Provides methods for:
    - Model listing and selection
    - Chat completions (streaming and non-streaming)
    - Web search (Tavily RAG integration)

    Authentication via API key (Bearer token).
    """

    def __init__(
        self,
        base_url: str,
        api_key: str,
        default_timeout: int = 30,
        chat_timeout: int = 120,
    ):
        """
        Initialize Open-WebUI client.

        Args:
            base_url: Open-WebUI base URL (e.g., https://rpi5.tail4249a9.ts.net)
            api_key: User API key for authentication
            default_timeout: Default request timeout in seconds
            chat_timeout: Timeout for chat completion requests
        """
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.default_timeout = default_timeout
        self.chat_timeout = chat_timeout
        self.session = self._create_session()

    def _create_session(self) -> requests.Session:
        """Create requests session with retry strategy and auth headers."""
        session = requests.Session()

        # Retry strategy for transient failures
        retry_strategy = Retry(
            total=3,
            backoff_factor=0.5,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["GET", "POST"],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)

        # Set auth headers
        session.headers.update(
            {
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            }
        )

        return session

    def _request(
        self,
        method: str,
        path: str,
        json_data: Optional[dict] = None,
        timeout: Optional[int] = None,
        stream: bool = False,
    ) -> requests.Response:
        """
        Execute HTTP request with error handling.

        Args:
            method: HTTP method (GET, POST, etc.)
            path: API path (e.g., /api/models)
            json_data: JSON payload for POST requests
            timeout: Request timeout in seconds
            stream: Enable streaming response

        Returns:
            requests.Response object

        Raises:
            requests.HTTPError: For HTTP error responses
            requests.RequestException: For network errors
        """
        url = f"{self.base_url}{path}"
        timeout = timeout or self.default_timeout

        response = self.session.request(
            method=method,
            url=url,
            json=json_data,
            timeout=timeout,
            stream=stream,
        )

        if not stream:
            response.raise_for_status()

        return response

    # ========================================================================
    # Model Operations
    # ========================================================================

    def list_models(self) -> List[ModelInfo]:
        """
        List all available LLM models.

        Returns:
            List of ModelInfo objects

        Raises:
            requests.HTTPError: If request fails
        """
        response = self._request("GET", "/api/models")
        data = response.json()

        models = []
        for model_data in data.get("data", []):
            models.append(ModelInfo(**model_data))

        return models

    def get_zdr_models(self) -> List[ModelInfo]:
        """
        Get only ZDR-compliant models (those with ZDR/ prefix).

        Returns:
            List of ModelInfo objects with ZDR/ prefix in name
        """
        all_models = self.list_models()
        return [m for m in all_models if m.name.startswith("ZDR/")]

    # ========================================================================
    # Chat Completions
    # ========================================================================

    def create_chat(
        self,
        model: str,
        messages: List[dict],
        temperature: float = 0.7,
        max_tokens: Optional[int] = None,
    ) -> ChatResponse:
        """
        Create non-streaming chat completion.

        Args:
            model: Model ID (e.g., "anthropic/claude-3-sonnet")
            messages: List of message dicts with 'role' and 'content'
            temperature: Sampling temperature (0.0 to 2.0)
            max_tokens: Maximum tokens in response

        Returns:
            ChatResponse object

        Raises:
            requests.HTTPError: If request fails
        """
        payload = {
            "model": model,
            "messages": messages,
            "stream": False,
            "temperature": temperature,
        }

        if max_tokens:
            payload["max_tokens"] = max_tokens

        response = self._request(
            "POST",
            "/api/chat/completions",
            json_data=payload,
            timeout=self.chat_timeout,
        )

        data = response.json()

        # Parse response into ChatResponse model
        choices = []
        for choice_data in data.get("choices", []):
            message_data = choice_data.get("message", {})
            message = Message(
                role=MessageRole(message_data.get("role", "assistant")),
                content=message_data.get("content", ""),
            )
            choices.append(
                ChatChoice(
                    index=choice_data.get("index", 0),
                    message=message,
                    finish_reason=choice_data.get("finish_reason"),
                )
            )

        return ChatResponse(
            id=data.get("id", ""),
            object=data.get("object", "chat.completion"),
            created=data.get("created", 0),
            model=data.get("model", model),
            choices=choices,
        )

    def create_chat_stream(
        self,
        model: str,
        messages: List[dict],
        temperature: float = 0.7,
        max_tokens: Optional[int] = None,
    ) -> Iterator[StreamChunk]:
        """
        Create streaming chat completion.

        Follows SSE pattern from openrouter_zdr_pipe.py generate() function.

        Args:
            model: Model ID
            messages: List of message dicts
            temperature: Sampling temperature
            max_tokens: Maximum tokens in response

        Yields:
            StreamChunk objects for each SSE event

        Raises:
            requests.HTTPError: If request fails
        """
        payload = {
            "model": model,
            "messages": messages,
            "stream": True,
            "temperature": temperature,
        }

        if max_tokens:
            payload["max_tokens"] = max_tokens

        response = self._request(
            "POST",
            "/api/chat/completions",
            json_data=payload,
            timeout=self.chat_timeout,
            stream=True,
        )

        response.raise_for_status()

        malformed_count = 0  # Track malformed chunks to fail if too many

        for line in response.iter_lines():
            if not line:
                continue

            decoded = line.decode("utf-8")

            # Filter SSE comments (heartbeat/status lines starting with ':')
            if decoded.startswith(":"):
                continue

            # SSE format: "data: {json}"
            if decoded.startswith("data: "):
                data_str = decoded[6:]  # Remove "data: " prefix

                # Check for stream end marker
                if data_str.strip() == "[DONE]":
                    break

                try:
                    chunk_data = json.loads(data_str)

                    # Parse into StreamChunk model
                    choices = []
                    for choice_data in chunk_data.get("choices", []):
                        delta_data = choice_data.get("delta", {})
                        delta = StreamDelta(
                            role=delta_data.get("role"),
                            content=delta_data.get("content"),
                        )
                        choices.append(
                            StreamChoice(
                                index=choice_data.get("index", 0),
                                delta=delta,
                                finish_reason=choice_data.get("finish_reason"),
                            )
                        )

                    yield StreamChunk(
                        id=chunk_data.get("id", ""),
                        object=chunk_data.get("object", "chat.completion.chunk"),
                        created=chunk_data.get("created", 0),
                        model=chunk_data.get("model", model),
                        choices=choices,
                    )

                except json.JSONDecodeError as e:
                    malformed_count += 1
                    logger.error(
                        "Malformed SSE chunk (%d so far): %s... Error: %s",
                        malformed_count,
                        data_str[:100] if len(data_str) > 100 else data_str,
                        e,
                    )
                    if malformed_count > 5:
                        raise ValueError(
                            f"Too many malformed SSE chunks ({malformed_count}), aborting stream"
                        )
                    continue

    # ========================================================================
    # Web Search (RAG)
    # ========================================================================

    def web_search(self, query: str, max_results: int = 3) -> SearchResponse:
        """
        Perform web search via Tavily RAG integration.

        Requires tavilySearch.enable = true in Open-WebUI configuration.

        Args:
            query: Search query string
            max_results: Maximum number of results (1-10)

        Returns:
            SearchResponse with results

        Raises:
            requests.HTTPError: If request fails or Tavily not configured
        """
        # Open-WebUI 0.6+ uses /api/v1/retrieval/process/web/search
        # with 'queries' array (not 'query' string)
        payload = {
            "queries": [query],
        }

        response = self._request(
            "POST",
            "/api/v1/retrieval/process/web/search",
            json_data=payload,
            timeout=60,
        )

        data = response.json()

        # API returns 'items' with 'link'/'snippet', map to our model's 'url'/'content'
        results = []
        items = data.get("items", [])[:max_results]
        for item in items:
            results.append(SearchResult(
                title=item.get("title", ""),
                url=item.get("link", ""),
                content=item.get("snippet", ""),
            ))

        return SearchResponse(
            query=query,
            results=results,
        )

    # ========================================================================
    # Utility Methods
    # ========================================================================

    def health_check(self) -> bool:
        """
        Check if Open-WebUI is reachable and responding.

        Returns:
            True if healthy, False for expected failures (network, auth, server errors)

        Note:
            Catches network errors and HTTP errors. SSL certificate errors
            and other unexpected exceptions will propagate for visibility.
        """
        try:
            response = self._request("GET", "/api/models", timeout=10)
            return response.status_code == 200
        except requests.exceptions.ConnectionError:
            return False
        except requests.exceptions.Timeout:
            return False
        except requests.exceptions.HTTPError as e:
            # 401/403 = auth problem, 5xx = server problem - not healthy
            logger.warning("Health check failed with HTTP %s", e.response.status_code)
            return False

    def close(self) -> None:
        """Close underlying session."""
        self.session.close()

    def __enter__(self) -> "OpenWebUIClient":
        """Context manager entry."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        """Context manager exit."""
        self.close()
