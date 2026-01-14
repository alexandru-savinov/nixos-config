"""
Auto Memory Filter for Open-WebUI

Automatically extracts and stores relevant information from user messages as memories.
Adapted for NixOS deployment with OpenRouter API support.

Based on: https://openwebui.com/f/prymz/auto_memory_filter
License: MIT (this adaptation)
"""

from pydantic import BaseModel, Field
from typing import Optional, List, Callable, Awaitable, Any, Dict, Tuple
import aiohttp
import sqlite3
import ast
import json
import time
import logging
import os
import traceback
import uuid
import asyncio

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("auto_memory_filter")

# Track import status for degraded mode detection
DIRECT_DB_MODE = False
DIRECT_DB_MODE_REASON = None

# Try both import paths to handle different OpenWebUI versions (v0.3+ vs earlier)
try:
    from open_webui.routers.memories import (
        add_memory,
        AddMemoryForm,
        query_memory,
        QueryMemoryForm,
        delete_memory_by_id,
    )
    from open_webui.routers.users import Users
except ImportError as e1:
    try:
        from open_webui.apps.webui.routers.memories import (
            add_memory,
            AddMemoryForm,
            query_memory,
            QueryMemoryForm,
            delete_memory_by_id,
        )
        from open_webui.apps.webui.models.users import Users
    except ImportError as e2:
        DIRECT_DB_MODE = True
        DIRECT_DB_MODE_REASON = f"v1 import: {e1}, v2 import: {e2}"
        logger.error(f"OpenWebUI API not available: {DIRECT_DB_MODE_REASON}")
        logger.error("Auto-memory will use direct database access (DEGRADED MODE)")
        logger.error("IMPACT: No deduplication, memories stored in SQLite only")
        add_memory = None
        query_memory = None
        delete_memory_by_id = None
        Users = None


class Filter:
    """
    Auto Memory Filter - Extracts and stores user information as memories.

    This filter analyzes user messages during conversations and automatically
    extracts valuable information to store as long-term memories in the database.
    When OpenWebUI's memory API is available, memories are also indexed in the
    vector database for semantic retrieval. In direct DB mode (fallback),
    memories are stored in SQLite only.
    """

    class Valves(BaseModel):
        """Configuration options for the Auto Memory Filter."""

        openai_api_url: str = Field(
            default="https://openrouter.ai/api/v1",
            description="OpenAI-compatible API endpoint for memory extraction LLM",
        )
        model: str = Field(
            default="openai/gpt-4o-mini",
            description="Model to use for memory extraction (should be fast and cheap)",
        )
        api_key: str = Field(
            default="",
            description="API key for the LLM endpoint",
        )
        related_memories_n: int = Field(
            default=5,
            description="Number of related memories to consider when updating",
        )
        related_memories_dist: float = Field(
            default=0.75,
            description="Distance threshold for related memories (0.0-1.0; memories below threshold are considered duplicates)",
        )
        auto_save_user: bool = Field(
            default=True,
            description="Automatically extract and save info from user messages",
        )
        direct_db_path: str = Field(
            default="/var/lib/open-webui/data/webui.db",
            description="Path to Open-WebUI SQLite database (overridden by NixOS provisioning)",
        )
        enabled: bool = Field(
            default=True,
            description="Enable/disable automatic memory extraction",
        )

    class UserValves(BaseModel):
        """Per-user settings."""

        show_status: bool = Field(
            default=True,
            description="Show status messages when memories are saved",
        )
        enabled: bool = Field(
            default=True,
            description="Enable memory saving for this user",
        )

    def __init__(self):
        self.valves = self.Valves()
        self._warned_direct_mode = False
        self._test_db_connection()

    def _test_db_connection(self):
        """Test database connectivity on startup."""
        try:
            if os.path.exists(self.valves.direct_db_path):
                with sqlite3.connect(self.valves.direct_db_path) as conn:
                    cursor = conn.cursor()
                    cursor.execute(
                        "SELECT name FROM sqlite_master WHERE type='table' AND name='memory'"
                    )
                    result = cursor.fetchone()
                    if result:
                        logger.info(f"Database connected: {self.valves.direct_db_path}")
                    else:
                        logger.warning("Database exists but 'memory' table not found")
            else:
                logger.warning(f"Database not found: {self.valves.direct_db_path}")
        except sqlite3.Error as e:
            logger.error(f"Database connection test failed: {e}")

    def inlet(
        self,
        body: dict,
        __event_emitter__: Callable[[Any], Awaitable[None]],
        user: Optional[dict] = None,
        request: Optional[Any] = None,
    ) -> dict:
        """Process incoming messages (no-op for this filter)."""
        return body

    async def outlet(
        self,
        body: dict,
        __event_emitter__: Callable[[Any], Awaitable[None]],
        user: Optional[dict] = None,
        request: Optional[Any] = None,
    ) -> dict:
        """Process outgoing messages and extract memories from user input."""
        if not self.valves.enabled:
            return body

        # Warn user about degraded mode once per session
        if DIRECT_DB_MODE and not self._warned_direct_mode and __event_emitter__:
            self._warned_direct_mode = True
            try:
                await __event_emitter__({
                    "type": "status",
                    "data": {
                        "description": "Auto-memory: running in direct DB mode (limited functionality)",
                        "done": True
                    }
                })
            except Exception:
                pass  # Don't fail if event emitter fails

        logger.debug(f"Outlet processing: {list(body.keys() if body else [])}")

        # Handle chat completion events (no user/request context)
        is_chat_completed = (
            (not user or not request)
            and body
            and "chat_id" in body
            and "messages" in body
        )

        if is_chat_completed:
            chat_id = body.get("chat_id")
            messages = body.get("messages", [])
            if messages:
                # Wrap in error-handling task to prevent silent failures
                asyncio.create_task(
                    self._safe_process_completed_chat(chat_id, messages)
                )
            return body

        # Normal processing with user context
        if not user or not body:
            return body

        messages = body.get("messages", [])
        if not messages:
            return body

        # Check user preferences
        user_settings = user.get("valves", {})
        if not user_settings.get("enabled", True):
            return body

        # Process user message for memories
        if len(messages) >= 2 and self.valves.auto_save_user:
            user_message = messages[-2]
            if user_message.get("role") == "user":
                try:
                    if Users:
                        user_obj = Users.get_user_by_id(user["id"])
                    else:
                        user_obj = None

                    memories = await self.identify_memories(
                        user_message.get("content", "")
                    )

                    if self._is_valid_memory_list(memories):
                        success, saved, failed = await self.process_memories(
                            memories, user_obj, request, user.get("id")
                        )

                        if user_settings.get("show_status", True) and __event_emitter__:
                            if success:
                                status_msg = f"Saved {saved} memory/memories"
                            elif saved > 0:
                                status_msg = f"Saved {saved}/{saved+failed} memories (some failed)"
                            else:
                                status_msg = "Memory extraction found nothing to save"
                            await __event_emitter__({
                                "type": "status",
                                "data": {"description": status_msg, "done": True}
                            })
                except Exception as e:
                    logger.error(f"Error processing user message: {e}")
                    logger.error(traceback.format_exc())

        return body

    def _is_valid_memory_list(self, memories: str) -> bool:
        """Check if the response is a valid non-empty Python list of strings."""
        if not (memories.startswith("[") and memories.endswith("]")):
            return False

        try:
            parsed = ast.literal_eval(memories)
            if not isinstance(parsed, list):
                return False
            if not parsed:  # Empty list
                return False
            if not all(isinstance(item, str) for item in parsed):
                logger.warning(f"Memory list contains non-string items: {memories[:100]}")
                return False
            return True
        except (SyntaxError, ValueError) as e:
            logger.debug(f"Invalid memory list format: {e}")
            return False

    async def _safe_process_completed_chat(self, chat_id: str, messages: list):
        """Wrapper to catch and log exceptions from background task."""
        try:
            await self._process_completed_chat(chat_id, messages)
        except Exception as e:
            logger.error(f"Background task failed for chat {chat_id}: {e}")
            logger.error(traceback.format_exc())

    async def _process_completed_chat(self, chat_id: str, messages: list):
        """Process a completed chat using direct database access."""
        # Brief delay to ensure chat record is committed to SQLite
        await asyncio.sleep(1)

        user_id, error = await self._get_user_id_for_chat(chat_id)
        if error:
            logger.error(f"Failed to get user ID for chat {chat_id}: {error}")
            return
        if not user_id:
            logger.debug(f"No user ID found for chat {chat_id} (chat may not exist)")
            return

        if self.valves.auto_save_user and len(messages) >= 2:
            for msg in reversed(messages):
                if msg.get("role") == "user":
                    await self._process_user_message_direct(msg, user_id)
                    break

    async def _process_user_message_direct(self, message: dict, user_id: str):
        """Extract and save memories directly to database."""
        content = message.get("content", "")
        if not content:
            return

        try:
            memories = await self.identify_memories(content)
            if not self._is_valid_memory_list(memories):
                return

            memory_list = ast.literal_eval(memories)
            for memory in memory_list:
                if isinstance(memory, str):
                    await self._save_memory_to_db(user_id, memory)

        except (SyntaxError, ValueError) as e:
            logger.error(f"Failed to parse memory list: {e}")
        except Exception as e:
            logger.error(f"Error in direct memory processing: {e}")
            logger.error(traceback.format_exc())

    async def _get_user_id_for_chat(self, chat_id: str) -> Tuple[Optional[str], Optional[str]]:
        """Look up user ID for a chat from the database.

        Returns:
            tuple: (user_id, error_message). If error_message is set, user_id is None.
        """
        try:
            with sqlite3.connect(self.valves.direct_db_path) as conn:
                cursor = conn.cursor()
                cursor.execute("SELECT user_id FROM chat WHERE id = ?", (chat_id,))
                result = cursor.fetchone()
                if result:
                    return result[0], None
                else:
                    return None, None  # Chat not found (not an error)
        except sqlite3.Error as e:
            return None, f"Database error: {e}"

    async def _save_memory_to_db(self, user_id: str, content: str) -> bool:
        """Save a memory directly to the SQLite database."""
        try:
            with sqlite3.connect(self.valves.direct_db_path) as conn:
                cursor = conn.cursor()

                memory_id = str(uuid.uuid4())
                current_time = int(time.time())

                cursor.execute(
                    "INSERT INTO memory (id, user_id, content, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                    (memory_id, user_id, content, current_time, current_time),
                )
                conn.commit()

                logger.info(f"Memory saved for user {user_id[:8]}... (id={memory_id[:8]})")
                return True
        except sqlite3.IntegrityError as e:
            logger.warning(f"Memory constraint violation (may already exist): {e}")
            return False
        except sqlite3.OperationalError as e:
            logger.error(f"Database operational error: {e}")
            logger.error("HINT: Database may be locked, disk full, or filesystem read-only")
            return False
        except sqlite3.Error as e:
            logger.error(f"Database error saving memory: {e}")
            return False

    async def identify_memories(self, input_text: str) -> str:
        """Use LLM to extract memorable facts from user input."""
        system_prompt = """You will be provided with text from a user. Analyze it to identify information worth remembering long-term about the user. Do not include short-term information like the current query.

Extract useful information and output it as a Python list of strings. Include full context in each item. If no useful information exists, respond with an empty list: []

Do not provide commentary - only the Python list.

Useful information includes:
- Preferences, habits, goals, interests
- Personal/professional facts (job, hobbies, location)
- Relationships, views on topics
- Explicit "remember this" requests (these override short-term exclusion)

Examples:
Input: "I love hiking and explore new trails on weekends."
Output: ["User enjoys hiking", "User explores trails on weekends"]

Input: "My favorite cuisine is Japanese, especially sushi."
Output: ["User's favorite cuisine is Japanese", "User especially likes sushi"]

Input: "Remember that I'm learning Spanish."
Output: ["User is learning Spanish"]

Input: "What's the weather like?"
Output: []

Input: "Please remember our meeting is Friday at 10 AM."
Output: ["Meeting scheduled for Friday at 10 AM"]"""

        return await self._query_llm(system_prompt, input_text)

    async def _query_llm(self, system_prompt: str, user_message: str) -> str:
        """Query the configured LLM endpoint."""
        url = f"{self.valves.openai_api_url}/chat/completions"
        headers = {"Content-Type": "application/json"}

        if self.valves.api_key:
            headers["Authorization"] = f"Bearer {self.valves.api_key}"

        payload = {
            "model": self.valves.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_message},
            ],
            "temperature": 0.1,
            "max_tokens": 500,
        }

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(url, headers=headers, json=payload, timeout=30) as response:
                    if response.status == 401:
                        logger.error(f"LLM authentication failed (401) - check API key for {self.valves.model}")
                        return "[]"
                    elif response.status == 429:
                        logger.error(f"LLM rate limited (429) - too many requests to {self.valves.model}")
                        return "[]"
                    elif response.status >= 400:
                        logger.error(f"LLM request failed with status {response.status} for {self.valves.model}")
                        return "[]"

                    data = await response.json()

                    # Validate response structure
                    if "choices" not in data or not data["choices"]:
                        logger.error(f"LLM returned unexpected response (no choices): {str(data)[:200]}")
                        return "[]"

                    return data["choices"][0]["message"]["content"]

        except aiohttp.ClientError as e:
            logger.error(f"LLM network error for {self.valves.model}: {e}")
            return "[]"
        except asyncio.TimeoutError:
            logger.error(f"LLM request timed out after 30s for {self.valves.model}")
            return "[]"
        except KeyError as e:
            logger.error(f"LLM response missing expected field: {e}")
            return "[]"
        except Exception as e:
            logger.error(f"Unexpected error querying LLM {self.valves.model}: {e}")
            logger.error(traceback.format_exc())
            return "[]"

    async def process_memories(
        self,
        memories: str,
        user: Any,
        request: Any,
        user_id: Optional[str] = None,
    ) -> Tuple[bool, int, int]:
        """Process and store extracted memories.

        Returns:
            tuple: (overall_success, saved_count, failed_count)
        """
        try:
            memory_list = ast.literal_eval(memories)
        except (SyntaxError, ValueError) as e:
            logger.error(f"Failed to parse memory list from LLM: {memories[:100]}...")
            return False, 0, 0

        if not isinstance(memory_list, list):
            logger.error(f"LLM returned non-list type: {type(memory_list)}")
            return False, 0, 0

        saved = 0
        failed = 0

        for memory in memory_list:
            if not isinstance(memory, str):
                logger.warning(f"Skipping non-string memory: {type(memory)}")
                failed += 1
                continue

            try:
                # If we have OpenWebUI API access, use it (includes vector storage)
                if add_memory and user and request:
                    success = await self._store_memory_with_api(memory, user, request)
                # Otherwise use direct DB access (SQLite only, no vector)
                elif user_id:
                    success = await self._save_memory_to_db(user_id, memory)
                else:
                    logger.error("No storage method available (no API access and no user_id)")
                    return False, saved, len(memory_list) - saved

                if success:
                    saved += 1
                else:
                    failed += 1
            except Exception as e:
                logger.error(f"Failed to save memory '{memory[:50]}...': {e}")
                failed += 1

        return failed == 0, saved, failed

    async def _store_memory_with_api(self, memory: str, user: Any, request: Any) -> bool:
        """Store memory using OpenWebUI's internal API."""
        try:
            # Check for similar existing memories
            if query_memory:
                related = await query_memory(
                    request=request,
                    form_data=QueryMemoryForm(
                        content=memory,
                        k=self.valves.related_memories_n,
                    ),
                    user=user,
                )

                # Filter by distance threshold
                if related:
                    related_list = list(related)
                    if len(related_list) >= 4:
                        distances = related_list[3][1][0] if related_list[3][1] else []
                        if any(d < self.valves.related_memories_dist for d in distances):
                            logger.info("Similar memory exists, skipping")
                            return True

            # Add new memory
            if add_memory:
                await add_memory(
                    request=request,
                    form_data=AddMemoryForm(content=memory),
                    user=user,
                )
                logger.info(f"Memory stored via API: {memory[:50]}...")
                return True

        except (TypeError, AttributeError, IndexError) as e:
            logger.error(f"OpenWebUI API structure mismatch (possible version issue): {e}")
            logger.error(f"Memory content: {memory[:100]}...")
        except Exception as e:
            logger.error(f"Error storing memory via API: {e}")
            logger.error(f"Memory: {memory[:100]}...")
            logger.error(traceback.format_exc())

        return False
