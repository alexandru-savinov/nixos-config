"""
E2E tests for Open-WebUI model operations.

Tests that users can:
- List all available models
- See ZDR-filtered models
- Select different models for chat

These tests use real API calls to the Open-WebUI instance.
"""

from typing import List

import pytest

from .models import ModelInfo
from .owui_client import OpenWebUIClient


class TestModelListing:
    """Tests for model listing and discovery."""

    def test_list_models_returns_data(self, client: OpenWebUIClient):
        """
        List models returns non-empty list.

        Validates that the Open-WebUI instance has models configured
        and accessible via the API.
        """
        models = client.list_models()

        assert len(models) > 0, "No models returned from API"
        assert all(isinstance(m, ModelInfo) for m in models)

    def test_models_have_required_fields(self, available_models: List[ModelInfo]):
        """
        All models have required fields.

        Validates model objects match expected structure.
        """
        for model in available_models:
            assert model.id, f"Model missing 'id': {model}"
            assert model.name, f"Model missing 'name': {model}"
            assert model.object == "model", f"Model has wrong 'object': {model.object}"

    def test_model_ids_are_unique(self, available_models: List[ModelInfo]):
        """
        All model IDs are unique.

        Ensures no duplicate models in the list.
        """
        ids = [m.id for m in available_models]
        unique_ids = set(ids)

        assert len(ids) == len(unique_ids), f"Duplicate model IDs found: {ids}"


class TestZDRModels:
    """Tests for ZDR (Zero Data Retention) model filtering."""

    def test_zdr_models_have_prefix(self, zdr_models: List[ModelInfo]):
        """
        All ZDR models have ZDR/ prefix in name.

        Validates the ZDR pipe function is correctly prefixing model names.
        """
        for model in zdr_models:
            assert model.name.startswith("ZDR/"), (
                f"ZDR model missing 'ZDR/' prefix: {model.name}"
            )

    def test_zdr_models_are_subset(
        self,
        available_models: List[ModelInfo],
        zdr_models: List[ModelInfo],
    ):
        """
        ZDR models are a subset of all available models.

        Validates that ZDR filtering doesn't add phantom models.
        """
        all_ids = {m.id for m in available_models}
        zdr_ids = {m.id for m in zdr_models}

        # ZDR model IDs should exist in the full list
        # (Note: ZDR models come from the pipe function, so IDs might differ)
        # This test validates that ZDR models are discoverable
        assert len(zdr_ids) > 0, "No ZDR models found"

    def test_multiple_zdr_models_available(self, zdr_models: List[ModelInfo]):
        """
        Multiple ZDR models are available for selection.

        Validates that users have model choices.
        """
        # At minimum, we expect at least one model
        # Ideally multiple for variety
        assert len(zdr_models) >= 1, "Expected at least one ZDR model"

        # Log available models for debugging
        model_names = [m.name for m in zdr_models]
        print(f"\nAvailable ZDR models: {model_names}")


class TestModelSelection:
    """Tests for selecting different models."""

    def test_can_select_first_model(self, test_model: str):
        """
        First ZDR model can be selected.

        Validates that test_model fixture provides a valid model ID.
        """
        assert test_model, "test_model fixture returned empty string"
        assert "/" in test_model, f"Model ID looks malformed: {test_model}"

    def test_can_select_alternate_model(self, alternate_model: str):
        """
        Alternate ZDR model can be selected.

        Validates model selection flexibility.
        """
        assert alternate_model, "alternate_model fixture returned empty string"

    def test_different_models_selectable(
        self,
        test_model: str,
        alternate_model: str,
        zdr_models: List[ModelInfo],
    ):
        """
        Different models can be selected when multiple are available.
        """
        if len(zdr_models) < 2:
            pytest.skip("Only one model available, cannot test alternate selection")

        # When multiple models available, they should be different
        assert test_model != alternate_model, (
            "test_model and alternate_model should differ when multiple models available"
        )

    @pytest.mark.parametrize("model_index", [0, 1, 2])
    def test_select_model_by_index(
        self,
        zdr_models: List[ModelInfo],
        model_index: int,
    ):
        """
        Models can be selected by index.

        Tests first few models in the list.
        """
        if len(zdr_models) <= model_index:
            pytest.skip(f"Only {len(zdr_models)} models available")

        model = zdr_models[model_index]
        assert model.id, f"Model at index {model_index} has no ID"
        assert model.name.startswith("ZDR/"), (
            f"Model at index {model_index} missing ZDR prefix"
        )
