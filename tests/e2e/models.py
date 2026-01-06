"""
Pydantic models for Open-WebUI API entities.

These models provide type-safe representations of API request/response data,
following patterns from openrouter_zdr_pipe.py.
"""

from enum import Enum
from typing import List, Optional, Any
from pydantic import BaseModel, ConfigDict, Field


# ============================================================================
# Models & Model Operations
# ============================================================================


class ModelInfo(BaseModel):
    """LLM model information from /api/models endpoint."""

    model_config = ConfigDict(extra="allow")

    id: str
    name: str
    object: str = "model"
    owned_by: str = "openrouter"
    created: Optional[int] = None


# ============================================================================
# Chat Messages & Completions
# ============================================================================


class MessageRole(str, Enum):
    """Chat message roles."""

    SYSTEM = "system"
    USER = "user"
    ASSISTANT = "assistant"


class Message(BaseModel):
    """Single chat message."""

    model_config = ConfigDict(use_enum_values=True)

    role: MessageRole
    content: str


class ChatRequest(BaseModel):
    """Chat completion request payload."""

    model: str
    messages: List[Message]
    stream: bool = False
    temperature: float = Field(default=0.7, ge=0.0, le=2.0)
    max_tokens: Optional[int] = None


class ChatChoice(BaseModel):
    """Single completion choice in response."""

    model_config = ConfigDict(extra="allow")

    index: int = 0
    message: Message
    finish_reason: Optional[str] = None


class ChatUsage(BaseModel):
    """Token usage statistics."""

    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0


class ChatResponse(BaseModel):
    """Complete chat response."""

    model_config = ConfigDict(extra="allow")

    id: str = ""
    object: str = "chat.completion"
    created: int = 0
    model: str = ""
    choices: List[ChatChoice]
    usage: Optional[ChatUsage] = None


# ============================================================================
# Streaming Responses
# ============================================================================


class StreamDelta(BaseModel):
    """Streaming response delta."""

    model_config = ConfigDict(extra="allow")

    role: Optional[str] = None
    content: Optional[str] = None


class StreamChoice(BaseModel):
    """Single streaming choice."""

    model_config = ConfigDict(extra="allow")

    index: int = 0
    delta: StreamDelta
    finish_reason: Optional[str] = None


class StreamChunk(BaseModel):
    """Single SSE chunk in streaming response."""

    model_config = ConfigDict(extra="allow")

    id: str = ""
    object: str = "chat.completion.chunk"
    created: int = 0
    model: str = ""
    choices: List[StreamChoice]


# ============================================================================
# Web Search (RAG)
# ============================================================================


class SearchResult(BaseModel):
    """Single search result from Tavily."""

    model_config = ConfigDict(extra="allow")

    title: str
    url: str
    content: str
    score: Optional[float] = None


class SearchResponse(BaseModel):
    """Complete search response."""

    model_config = ConfigDict(extra="allow")

    query: str = ""
    results: List[SearchResult] = []


# ============================================================================
# Error Handling
# ============================================================================


class APIError(BaseModel):
    """Structured API error response."""

    model_config = ConfigDict(extra="allow")

    error: str = "unknown_error"
    message: str = ""
    status_code: int = 500
