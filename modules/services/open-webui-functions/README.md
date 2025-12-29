# Open WebUI Functions

This directory contains custom functions for Open WebUI that are automatically provisioned via NixOS configuration.

## Functions

### OpenRouter ZDR-Only Models (`openrouter_zdr_pipe.py`)

A manifold-type pipe function that filters OpenRouter models to only show Zero Data Retention (ZDR) compliant models.

**Features:**
- Fetches ZDR-compliant models from OpenRouter's `/endpoints/zdr` API
- Caches ZDR model list with configurable TTL (default: 1 hour)
- Filters model selector to only show ZDR-compliant models
- Enforces ZDR policy on all requests by adding `provider.zdr: true`
- Uses agenix-managed API key from environment variables
- Supports both streaming and non-streaming requests

**Configuration:**
- `NAME_PREFIX`: Prefix for model names in selector (default: "ZDR/")
- `OPENROUTER_API_KEY`: Override API key (falls back to `OPENAI_API_KEY` env var)
- `ZDR_CACHE_TTL`: Cache TTL in seconds (default: 3600)
- `ENABLE_ZDR_ENFORCEMENT`: Enforce ZDR on requests (default: true)

## Provisioning

Functions are automatically provisioned via NixOS configuration using the `provision.py` script. The provisioning process:

1. Waits for the Open WebUI database to be available
2. Reads the Python function code
3. Extracts metadata from the docstring
4. Inserts or updates the function in the SQLite database
5. Sets the function as active and global
6. Ensures idempotency (only updates when content changes)

## Usage

Enable ZDR-only models in your NixOS configuration:

```nix
services.open-webui-tailscale = {
  enable = true;
  zdrModelsOnly.enable = true;
  openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;
};
```

The function will appear in the model selector as "ZDR/[Model Name]" and only show ZDR-compliant models.