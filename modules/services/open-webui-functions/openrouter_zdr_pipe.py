"""
title: OpenRouter ZDR-Only Models
author: nixos-config
version: 0.1.0
description: Only shows OpenRouter models with Zero Data Retention policy
"""

import json
import os
import time
from typing import Generator, Iterator, Optional, Union

import requests
from pydantic import BaseModel, Field


class Pipe:
    class Valves(BaseModel):
        NAME_PREFIX: str = Field(
            default="ZDR/",
            description="Prefix for model names in the selector.",
        )
        OPENROUTER_API_BASE_URL: str = Field(
            default="https://openrouter.ai/api/v1",
            description="OpenRouter API base URL.",
        )
        OPENROUTER_API_KEY: str = Field(
            default="",
            description="OpenRouter API key. Falls back to OPENAI_API_KEY env var.",
        )
        ZDR_CACHE_TTL: int = Field(
            default=3600,
            description="How long to cache the ZDR model list (seconds).",
        )
        ENABLE_ZDR_ENFORCEMENT: bool = Field(
            default=True,
            description="Enforce ZDR policy on all requests by adding provider.zdr=true",
        )

    def __init__(self):
        self.type = "manifold"
        self.valves = self.Valves()
        self._zdr_cache = None
        self._zdr_cache_time = 0

    def _get_api_key(self) -> str:
        """Get API key from valves or environment variable."""
        if self.valves.OPENROUTER_API_KEY:
            return self.valves.OPENROUTER_API_KEY
        # Fall back to the global OPENAI_API_KEY (set by agenix)
        return os.environ.get("OPENAI_API_KEY", "")

    def pipes(self) -> list[dict]:
        """Return only ZDR-compliant models."""
        api_key = self._get_api_key()
        if not api_key:
            return [
                {
                    "id": "error",
                    "name": "API Key not provided. Configure OPENROUTER_API_KEY valve or set OPENAI_API_KEY environment variable.",
                }
            ]

        # Check cache first
        now = time.time()
        if self._zdr_cache and (now - self._zdr_cache_time) < self.valves.ZDR_CACHE_TTL:
            return self._zdr_cache

        try:
            # Fetch ZDR endpoints directly
            zdr_url = f"{self.valves.OPENROUTER_API_BASE_URL}/endpoints/zdr"
            headers = {
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            }
            response = requests.get(zdr_url, headers=headers, timeout=30)
            response.raise_for_status()

            zdr_data = response.json().get("data", [])

            # Build model list directly from ZDR endpoint
            # Deduplicate by model ID (same model may have multiple providers)
            seen_ids = set()
            zdr_models = []

            for item in zdr_data:
                # Extract model ID from "Provider | model-id" format
                name_parts = item["name"].split(" | ")
                model_id = name_parts[1] if len(name_parts) > 1 else item["name"]

                if model_id not in seen_ids:
                    seen_ids.add(model_id)
                    zdr_models.append(
                        {
                            "id": model_id,
                            "name": f"{self.valves.NAME_PREFIX}{item.get('model_name', model_id)}",
                            "object": "model",
                            "created": int(time.time()),
                            "owned_by": "openrouter",
                        }
                    )

            zdr_models.sort(key=lambda x: x["name"])

            # Cache the result
            result = (
                zdr_models
                if zdr_models
                else [
                    {
                        "id": "error",
                        "name": "No ZDR models found",
                    }
                ]
            )
            self._zdr_cache = result
            self._zdr_cache_time = now

            return result

        except requests.exceptions.RequestException as e:
            # Return cached data on error if available
            if self._zdr_cache:
                return self._zdr_cache
            return [{"id": "error", "name": f"Network error: {str(e)}"}]
        except Exception as e:
            # Return cached data on error if available
            if self._zdr_cache:
                return self._zdr_cache
            return [{"id": "error", "name": f"Error loading ZDR models: {str(e)}"}]

    def pipe(self, body: dict, __user__: dict) -> Union[str, Generator, Iterator]:
        """Proxy requests to OpenRouter with ZDR enforcement."""
        api_key = self._get_api_key()
        if not api_key:
            return "Error: API key not configured. Set OPENROUTER_API_KEY valve or OPENAI_API_KEY environment variable."

        # Extract model ID, removing any pipe prefix
        model_id = body.get("model", "")
        if "." in model_id:
            model_id = model_id[model_id.find(".") + 1 :]

        # Prepare headers for OpenRouter API
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/alexandru-savinov/nixos-config",
            "X-Title": "nixos-config",
        }

        # Prepare payload with ZDR enforcement
        payload = {
            **body,
            "model": model_id,
        }

        # Add ZDR enforcement if enabled
        if self.valves.ENABLE_ZDR_ENFORCEMENT:
            payload["provider"] = {**body.get("provider", {}), "zdr": True}

        try:
            # Make request to OpenRouter API
            chat_url = f"{self.valves.OPENROUTER_API_BASE_URL}/chat/completions"

            if body.get("stream", False):
                # Handle streaming requests
                response = requests.post(
                    url=chat_url,
                    json=payload,
                    headers=headers,
                    stream=True,
                    timeout=300,
                )
                response.raise_for_status()

                def generate():
                    for line in response.iter_lines():
                        if line:
                            decoded = line.decode("utf-8")
                            # Filter out SSE comments (lines starting with ':')
                            # These are status messages like ": OPENROUTER PROCESSING"
                            if decoded.startswith(":"):
                                continue
                            yield decoded + "\n"

                return generate()
            else:
                # Handle non-streaming requests
                response = requests.post(
                    url=chat_url,
                    json=payload,
                    headers=headers,
                    timeout=300,
                )
                response.raise_for_status()
                return response.json()

        except requests.exceptions.Timeout:
            return "Error: Request timed out. Please try again."
        except requests.exceptions.RequestException as e:
            return f"Error: Network request failed - {str(e)}"
        except Exception as e:
            return f"Error: {str(e)}"

    def cleanup(self) -> None:
        """Cleanup resources."""
        self._zdr_cache = None
        self._zdr_cache_time = 0
