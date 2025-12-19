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

    def _get_zdr_models(self) -> list[str]:
        """Fetch ZDR model list from OpenRouter API with caching."""
        now = time.time()
        if self._zdr_cache and (now - self._zdr_cache_time) < self.valves.ZDR_CACHE_TTL:
            return self._zdr_cache

        try:
            # Fetch ZDR endpoints from OpenRouter
            zdr_url = f"{self.valves.OPENROUTER_API_BASE_URL}/endpoints/zdr"
            headers = {
                "Authorization": f"Bearer {self._get_api_key()}",
                "Content-Type": "application/json",
            }

            response = requests.get(zdr_url, headers=headers, timeout=30)
            response.raise_for_status()

            data = response.json()
            zdr_models = [item["model"] for item in data.get("data", [])]

            self._zdr_cache = zdr_models
            self._zdr_cache_time = now

            return zdr_models

        except Exception as e:
            print(f"Error fetching ZDR models: {e}")
            # Return cached data if available, otherwise empty list
            return self._zdr_cache if self._zdr_cache is not None else []

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

        try:
            # Get ZDR model IDs
            zdr_model_ids = set(self._get_zdr_models())

            if not zdr_model_ids:
                return [
                    {
                        "id": "error",
                        "name": "No ZDR models found. Check API key and network connection.",
                    }
                ]

            # Fetch all available models from OpenRouter
            headers = {
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/alexandru-savinov/nixos-config",
                "X-Title": "nixos-config",
            }

            models_url = f"{self.valves.OPENROUTER_API_BASE_URL}/models"
            response = requests.get(models_url, headers=headers, timeout=30)
            response.raise_for_status()

            all_models = response.json().get("data", [])

            # Filter to only ZDR-compliant models
            zdr_models = [
                {
                    "id": model["id"],
                    "name": f"{self.valves.NAME_PREFIX}{model.get('name', model['id'])}",
                    "object": "model",
                    "created": model.get("created", int(time.time())),
                    "owned_by": model.get("owned_by", "openrouter"),
                }
                for model in all_models
                if model["id"] in zdr_model_ids
            ]

            # Sort by name for better UX
            zdr_models.sort(key=lambda x: x["name"])

            return (
                zdr_models
                if zdr_models
                else [
                    {
                        "id": "error",
                        "name": "No ZDR models available. Check OpenRouter ZDR endpoint.",
                    }
                ]
            )

        except requests.exceptions.RequestException as e:
            return [{"id": "error", "name": f"Network error: {str(e)}"}]
        except Exception as e:
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
                            yield line.decode("utf-8") + "\n"

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
