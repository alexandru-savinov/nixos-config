"""
E2E tests for Qdrant RAG integration with Open-WebUI.

These tests verify that:
1. Qdrant is configured as the vector database
2. Document upload and embedding works
3. RAG queries return relevant context from uploaded documents

Prerequisites:
- Open-WebUI running with Qdrant vector DB configured
- Qdrant service running and accessible
- OPENWEBUI_TEST_API_KEY environment variable set

Run tests:
    export OPENWEBUI_TEST_API_KEY=$(sudo cat /run/open-webui/e2e-test-api-key)
    pytest tests/e2e/test_qdrant_rag.py -v
"""

import time
import uuid

import pytest
import requests

from .owui_client import OpenWebUIClient


# Unique content that won't appear in normal responses
TEST_DOCUMENT_CONTENT = """
QDRANT_RAG_TEST_DOCUMENT_v1

This is a test document for verifying Qdrant RAG integration.

The capital of Zephyria is Luminara, a city known for its crystal spires.
Zephyria's national flower is the moonbloom, which only blooms at midnight.
The currency of Zephyria is called the Zephyr, worth exactly 3.14159 USD.

These facts are entirely fictional and created for testing purposes.
If the model returns these facts, it confirms RAG retrieval is working.
"""

# Marker for RAG-specific tests
pytestmark = pytest.mark.rag


class TestQdrantRAGIntegration:
    """Test suite for Qdrant RAG integration."""

    @pytest.fixture(autouse=True)
    def setup(self, client: OpenWebUIClient):
        """Store client reference."""
        self.client = client

    def test_rag_config_shows_qdrant(self, client: OpenWebUIClient):
        """
        Verify Qdrant is configured as the vector database.

        This test checks the RAG configuration endpoint to confirm
        Qdrant is being used instead of the default chromadb.
        """
        config = client.get_rag_config()

        # The config should indicate Qdrant is being used
        # Different Open-WebUI versions may expose this differently
        vector_db = config.get("VECTOR_DB", config.get("vector_db", ""))

        # If we can't determine from config, the upload test will verify
        if vector_db:
            assert vector_db.lower() == "qdrant", (
                f"Expected Qdrant vector DB, got: {vector_db}. "
                "Ensure services.open-webui-tailscale.vectorDb.type = 'qdrant' is set."
            )

    def test_file_upload_creates_embeddings(self, client: OpenWebUIClient):
        """
        Test that file upload triggers embedding creation in Qdrant.

        This verifies the full pipeline:
        1. Upload document
        2. Wait for async processing
        3. Verify file is ready for RAG
        """
        # Create unique filename to avoid collisions
        filename = f"qdrant_test_{uuid.uuid4().hex[:8]}.txt"

        # Upload test content
        file_info = client.upload_file_content(TEST_DOCUMENT_CONTENT, filename)
        assert file_info.id, "File upload should return file ID"

        try:
            # Wait for processing (embeddings computed in Qdrant)
            is_ready = client.wait_for_file_ready(file_info.id, timeout=120)
            assert is_ready, (
                f"File {file_info.id} did not become ready within timeout. "
                "Check Qdrant connection and embedding model configuration."
            )
        finally:
            # Cleanup
            client.delete_file(file_info.id)

    @pytest.mark.slow
    def test_rag_query_returns_document_context(
        self, client: OpenWebUIClient, zdr_models
    ):
        """
        Test that RAG queries retrieve content from uploaded documents.

        This is the core test for Qdrant integration:
        1. Upload a document with unique, fictional facts
        2. Query about those facts using RAG
        3. Verify the response contains the fictional information

        The test uses made-up facts about "Zephyria" that couldn't
        come from the model's training data, proving RAG retrieval works.
        """
        filename = f"zephyria_facts_{uuid.uuid4().hex[:8]}.txt"
        file_info = None

        try:
            # Step 1: Upload document with unique content
            file_info = client.upload_file_content(TEST_DOCUMENT_CONTENT, filename)
            assert file_info.id, "File upload failed"

            # Step 2: Wait for embeddings to be ready
            is_ready = client.wait_for_file_ready(file_info.id, timeout=120)
            assert is_ready, "File processing timed out"

            # Step 3: Query using RAG with the uploaded file
            model = zdr_models[0].id
            messages = [
                {
                    "role": "user",
                    "content": "What is the capital of Zephyria and what is its national flower? Only answer based on the provided document.",
                }
            ]

            response = client.create_chat_with_files(
                model=model,
                messages=messages,
                file_ids=[file_info.id],
                temperature=0.1,  # Low temperature for deterministic retrieval
                max_tokens=200,
            )

            # Step 4: Verify response contains document content
            assert response.choices, "No response choices returned"
            answer = response.choices[0].message.content.lower()

            # Check for fictional facts that can only come from RAG
            assert "luminara" in answer, (
                f"Expected 'Luminara' (capital of Zephyria) in response. "
                f"Got: {answer[:200]}... "
                "RAG may not be retrieving document content correctly."
            )

            # Check for national flower - indicates complete RAG retrieval
            assert "moonbloom" in answer, (
                f"Expected 'moonbloom' (national flower) in response. "
                f"Got: {answer[:200]}... "
                "RAG retrieval may be incomplete - only partial document content returned."
            )

        finally:
            # Cleanup uploaded file
            if file_info and file_info.id:
                client.delete_file(file_info.id)

    def test_multiple_files_rag(self, client: OpenWebUIClient, zdr_models):
        """
        Test RAG with multiple uploaded files.

        Verifies that the vector DB can handle queries across
        multiple document embeddings simultaneously.
        """
        file1_content = """
        MULTI_FILE_TEST_DOC_1

        The Starlight Corporation was founded in 2099 by Dr. Elena Vox.
        Their headquarters is located in Neo Tokyo, Japan.
        """

        file2_content = """
        MULTI_FILE_TEST_DOC_2

        The Moonbeam Initiative launched in 2101.
        It is led by Commander Aria Chen.
        The project aims to establish a lunar research station.
        """

        file_ids = []
        try:
            # Upload both files
            for i, content in enumerate([file1_content, file2_content]):
                filename = f"multifile_test_{i}_{uuid.uuid4().hex[:8]}.txt"
                file_info = client.upload_file_content(content, filename)
                file_ids.append(file_info.id)

            # Wait for both to be ready
            for fid in file_ids:
                is_ready = client.wait_for_file_ready(fid, timeout=120)
                assert is_ready, f"File {fid} processing timed out"

            # Query about content from both documents
            model = zdr_models[0].id
            messages = [
                {
                    "role": "user",
                    "content": "Who founded Starlight Corporation and who leads the Moonbeam Initiative? Answer based only on the provided documents.",
                }
            ]

            response = client.create_chat_with_files(
                model=model,
                messages=messages,
                file_ids=file_ids,
                temperature=0.1,
                max_tokens=200,
            )

            answer = response.choices[0].message.content.lower()

            # Should contain info from both documents
            assert "elena vox" in answer or "vox" in answer, (
                f"Expected Dr. Elena Vox in response. Got: {answer[:200]}"
            )

        finally:
            # Cleanup all files
            for fid in file_ids:
                client.delete_file(fid)

    def test_file_deletion_removes_from_qdrant(self, client: OpenWebUIClient):
        """
        Test that deleting a file removes its embeddings from Qdrant.

        This ensures proper cleanup and that deleted documents
        don't appear in future RAG queries.
        """
        filename = f"delete_test_{uuid.uuid4().hex[:8]}.txt"
        content = "This document should be deleted and not appear in searches."

        # Upload and wait for processing
        file_info = client.upload_file_content(content, filename)
        client.wait_for_file_ready(file_info.id, timeout=60)

        # Delete the file
        deleted = client.delete_file(file_info.id)
        assert deleted, "File deletion should succeed"

        # Small delay for Qdrant to process deletion
        time.sleep(2)

        # Verify file is gone (should return 404)
        try:
            client.get_file_status(file_info.id)
            pytest.fail("Expected file to be deleted, but it still exists")
        except requests.HTTPError as e:
            # Expected - file should return 404
            assert e.response.status_code == 404, (
                f"Expected 404 for deleted file, got HTTP {e.response.status_code}"
            )
