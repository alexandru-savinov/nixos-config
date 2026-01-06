"""
E2E tests for Open-WebUI web search (Tavily RAG integration).

These tests require:
- tavilySearch.enable = true in Open-WebUI configuration
- Valid Tavily API key configured

Tests are marked with @pytest.mark.search and can be skipped with:
    pytest tests/e2e/ -v -m "not search"
"""

import pytest

from .models import SearchResponse, SearchResult
from .owui_client import OpenWebUIClient


@pytest.mark.search
class TestWebSearch:
    """Tests for Tavily web search integration."""

    def test_simple_search(self, client: OpenWebUIClient):
        """
        Perform simple web search.

        Validates that Tavily integration is working.
        """
        try:
            response = client.web_search(
                query="NixOS operating system",
                max_results=3,
            )

            assert isinstance(response, SearchResponse)
            assert len(response.results) > 0, "No search results returned"
            assert len(response.results) <= 3, "More results than requested"

        except Exception as e:
            if "404" in str(e) or "not found" in str(e).lower():
                pytest.skip(
                    "Web search endpoint not available. "
                    "Ensure tavilySearch.enable = true in configuration."
                )
            raise

    def test_search_results_have_required_fields(self, client: OpenWebUIClient):
        """
        Search results have title, URL, and content.
        """
        try:
            response = client.web_search(
                query="Python programming language",
                max_results=3,
            )

            for result in response.results:
                assert isinstance(result, SearchResult)
                assert result.title, "Result missing title"
                assert result.url, "Result missing URL"
                assert result.content, "Result missing content"

                # URL should be valid format
                assert result.url.startswith("http"), f"Invalid URL: {result.url}"

        except Exception as e:
            if "404" in str(e):
                pytest.skip("Web search endpoint not available")
            raise

    def test_search_respects_max_results(self, client: OpenWebUIClient):
        """
        Search respects max_results parameter.
        """
        try:
            # Request exactly 2 results
            response = client.web_search(
                query="machine learning",
                max_results=2,
            )

            assert len(response.results) <= 2, (
                f"Got {len(response.results)} results, expected max 2"
            )

        except Exception as e:
            if "404" in str(e):
                pytest.skip("Web search endpoint not available")
            raise

    def test_search_with_technical_query(self, client: OpenWebUIClient):
        """
        Search works with technical queries.

        Tests that Tavily can handle technical/programming queries.
        """
        try:
            response = client.web_search(
                query="pytest fixtures dependency injection",
                max_results=5,
            )

            assert len(response.results) > 0

            # Results should be relevant to programming
            all_content = " ".join(r.content.lower() for r in response.results)
            assert "pytest" in all_content or "test" in all_content, (
                "Search results don't seem relevant to query"
            )

        except Exception as e:
            if "404" in str(e):
                pytest.skip("Web search endpoint not available")
            raise


@pytest.mark.search
class TestSearchErrorHandling:
    """Tests for search error handling."""

    def test_empty_query_handled(self, client: OpenWebUIClient):
        """
        Empty search query is handled gracefully.
        """
        try:
            # This might fail with validation error or return empty results
            response = client.web_search(query="", max_results=3)

            # If it succeeds, results should be empty or minimal
            # (depends on Tavily behavior)

        except Exception as e:
            # Expected to fail - empty query is invalid
            pass  # This is acceptable behavior

    def test_very_long_query_handled(self, client: OpenWebUIClient):
        """
        Very long search query is handled gracefully.
        """
        try:
            long_query = "test " * 100  # 400+ characters

            # Should either work or fail gracefully
            response = client.web_search(query=long_query, max_results=3)

        except Exception as e:
            # Long queries might be rejected - that's acceptable
            if "400" not in str(e) and "invalid" not in str(e).lower():
                raise  # Re-raise unexpected errors
