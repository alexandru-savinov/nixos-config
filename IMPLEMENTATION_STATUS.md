# Issue #28: OpenRouter ZDR-Only Models Implementation Status

**Date:** 2025-12-19  
**Branch:** `feature/issue-28-openrouter-zdr-pipe`  
**Status:** ✅ Implementation Complete - Ready for Deployment Testing

## Summary

This implementation adds an Open WebUI pipe function that filters OpenRouter models to only show those with Zero Data Retention (ZDR) compliance. The feature is fully implemented with comprehensive tests and NixOS module integration.

## What Has Been Implemented

### 1. Core Pipe Function
- **File:** `modules/services/open-webui-functions/openrouter_zdr_pipe.py`
- **Features:**
  - Fetches ZDR model list from OpenRouter `/endpoints/zdr` endpoint
  - Caches ZDR list for 1 hour (configurable via `ZDR_CACHE_TTL` valve)
  - Filters model selector to only show ZDR-compliant models
  - Adds `provider.zdr: true` to all requests automatically
  - Supports both streaming and non-streaming responses
  - Model names prefixed with `ZDR/` for easy identification
  - Configurable via valves (API key, base URL, cache TTL, etc.)

### 2. Auto-Provisioning System
- **File:** `modules/services/open-webui-functions/provision.py`
- **Features:**
  - Idempotent provisioning - only updates if content changes
  - Uses content hash to detect changes
  - Connects directly to Open WebUI SQLite database
  - Extracts metadata from function docstring
  - Sets function as global and active by default
  - Waits for database to be available (max 30 retries)

### 3. NixOS Module Integration
- **File:** `modules/services/open-webui.nix`
- **Changes:**
  - Added `services.open-webui-tailscale.zdrModelsOnly.enable` option
  - New systemd service `open-webui-zdr-function.service`:
    - Type: oneshot
    - Runs after `open-webui.service`
    - Executes provisioning script automatically
  - Integrates with existing agenix secret management
  - OpenRouter API key already configured via `cfg.openai.apiKeyFile`

### 4. Comprehensive Test Suite

#### Unit Tests (`tests/test_openrouter_zdr_pipe.py`)
- ✅ `test_pipes_returns_only_zdr_models` - Verifies filtering works correctly
- ✅ `test_pipes_handles_missing_api_key` - Error handling for missing credentials
- ✅ `test_pipes_handles_no_zdr_models` - Handles empty ZDR list gracefully
- ✅ `test_pipe_proxies_request_with_zdr` - Verifies ZDR flag injection
- ✅ `test_pipe_streaming_response` - Tests SSE streaming mode
- ✅ `test_cache_mechanism` - Validates cache TTL behavior

**All 6 unit tests passing ✅**

#### End-to-End Test (`tests/e2e_test_openwebui_zdr.py`)
- ✅ Full integration test with Flask stub OpenRouter server
- ✅ Tests provisioning script against real SQLite database
- ✅ Validates entire flow: provision → fetch models → proxy requests
- ✅ Verifies `provider.zdr: true` flag is added to requests

**E2E test passing ✅**

### 5. Development Environment
- **File:** `shell.nix`
- **Added dependencies:**
  - `python3Packages.pytest` - Test framework
  - `python3Packages.flask` - E2E test stub server
  - `python3Packages.requests` - HTTP client
  - `python3Packages.pydantic` - Data validation

### 6. CI/CD Setup
- **File:** `.github/workflows/python-tests.yml`
- **Features:**
  - Runs on every push and PR
  - Tests on Python 3.11
  - Runs both unit and e2e tests
  - Uses Nix for reproducible environment

### 7. Documentation
- **File:** `modules/services/open-webui-functions/README.md`
- **Contents:**
  - Overview of the functions directory
  - Documentation for both the pipe and provisioner
  - Usage instructions
  - Configuration details

## File Structure

```
nixos-config/
├── modules/services/
│   ├── open-webui.nix                          # Modified: Added zdrModelsOnly option
│   └── open-webui-functions/                   # New directory
│       ├── openrouter_zdr_pipe.py              # Pipe function implementation
│       ├── provision.py                        # Auto-provisioning script
│       └── README.md                           # Documentation
├── tests/
│   ├── test_openrouter_zdr_pipe.py            # Unit tests
│   └── e2e_test_openwebui_zdr.py              # End-to-end test
├── shell.nix                                   # Modified: Added test dependencies
└── .github/workflows/
    └── python-tests.yml                        # New CI workflow
```

## How to Enable on a Host

Add to your host configuration (e.g., `hosts/sancta-choir/configuration.nix`):

```nix
services.open-webui-tailscale = {
  enable = true;
  zdrModelsOnly.enable = true;  # ← Enable ZDR-only mode
  
  # OpenRouter API key already configured via agenix
  openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;
};
```

Then rebuild:
```bash
nixos-rebuild switch --flake .#sancta-choir
```

## Testing Completed

### Local Test Results
```bash
$ nix-shell --run "pytest tests/test_openrouter_zdr_pipe.py tests/e2e_test_openwebui_zdr.py -v"

tests/test_openrouter_zdr_pipe.py::test_pipes_returns_only_zdr_models PASSED
tests/test_openrouter_zdr_pipe.py::test_pipes_handles_missing_api_key PASSED
tests/test_openrouter_zdr_pipe.py::test_pipes_handles_no_zdr_models PASSED
tests/test_openrouter_zdr_pipe.py::test_pipe_proxies_request_with_zdr PASSED
tests/test_openrouter_zdr_pipe.py::test_pipe_streaming_response PASSED
tests/test_openrouter_zdr_pipe.py::test_cache_mechanism PASSED
tests/e2e_test_openwebui_zdr.py::test_e2e_zdr_pipe PASSED

7 passed in 1.37s ✅
```

## Next Steps for Deployment

### 1. Deploy to Test Host
```bash
# On your local machine
git push origin feature/issue-28-openrouter-zdr-pipe

# On sancta-choir (or test host)
cd /etc/nixos/nixos-config
git fetch
git checkout feature/issue-28-openrouter-zdr-pipe
nixos-rebuild switch --flake .#sancta-choir
```

### 2. Verify Deployment
After deployment, verify:

1. **Check systemd service ran successfully:**
   ```bash
   systemctl status open-webui-zdr-function.service
   journalctl -u open-webui-zdr-function.service
   ```
   
   Expected output:
   ```
   INFO - Provisioning function: OpenRouter ZDR-Only Models
   INFO - Connected to database: /var/lib/open-webui/data/webui.db
   INFO - Function OpenRouter ZDR-Only Models does not exist, creating...
   INFO - Inserted new function: OpenRouter ZDR-Only Models
   INFO - Function provisioning completed successfully
   ```

2. **Check database directly:**
   ```bash
   sqlite3 /var/lib/open-webui/data/webui.db \
     "SELECT name, type, is_active, is_global FROM function WHERE name LIKE '%ZDR%';"
   ```
   
   Expected output:
   ```
   OpenRouter ZDR-Only Models|pipe|1|1
   ```

3. **Access Open WebUI:**
   - Navigate to your Open WebUI instance
   - Go to Admin Settings → Functions
   - Verify "OpenRouter ZDR-Only Models" appears and is active
   - In a chat, click model selector
   - Verify only `ZDR/` prefixed models appear

4. **Test a chat request:**
   - Select a ZDR model (e.g., `ZDR/GPT-4o Mini`)
   - Send a message
   - Verify response works correctly
   - Check OpenRouter dashboard to confirm ZDR flag was applied

### 3. Monitor for Issues

Check logs if anything doesn't work:
```bash
# Open WebUI logs
journalctl -u open-webui.service -f

# Provisioner logs
journalctl -u open-webui-zdr-function.service

# Check if API key is accessible
sudo cat /run/secrets/openrouter-api-key  # Should show your key
```

### 4. Common Troubleshooting

**Issue: Function not appearing in UI**
- Check provisioner service status: `systemctl status open-webui-zdr-function`
- Verify database permissions: `ls -l /var/lib/open-webui/data/webui.db`
- Check provisioner logs: `journalctl -u open-webui-zdr-function`

**Issue: "API Key not provided" error in model selector**
- Verify secret file exists: `ls -l /run/secrets/openrouter-api-key`
- Check Open WebUI can read it: `systemctl show open-webui.service -p EnvironmentFile`
- Restart Open WebUI: `systemctl restart open-webui.service`

**Issue: No ZDR models showing**
- Check network connectivity from server to OpenRouter
- Test API manually: `curl -H "Authorization: Bearer $(cat /run/secrets/openrouter-api-key)" https://openrouter.ai/api/v1/endpoints/zdr`
- Check Open WebUI logs for errors

## Future Enhancements (Optional)

These are not required for Issue #28 but could be added later:

1. **Admin API Provisioning:** Replace direct SQLite writes with Open WebUI's admin HTTP API (safer against schema changes)

2. **Model Metadata Cache:** Cache the full models list alongside ZDR list to reduce API calls

3. **Monitoring:** Add Prometheus metrics for cache hits/misses, API errors, etc.

4. **UI Configuration:** Allow users to toggle ZDR enforcement per-chat rather than globally

5. **Multi-Provider Support:** Extend to support other providers with data retention policies

6. **Audit Logging:** Log all requests with ZDR flag for compliance tracking

## Files Modified/Created Summary

### New Files (8)
- `modules/services/open-webui-functions/openrouter_zdr_pipe.py` (235 lines)
- `modules/services/open-webui-functions/provision.py` (287 lines)
- `modules/services/open-webui-functions/README.md` (73 lines)
- `tests/test_openrouter_zdr_pipe.py` (218 lines)
- `tests/e2e_test_openwebui_zdr.py` (228 lines)
- `.github/workflows/python-tests.yml` (45 lines)
- `CLAUDE.md` (conversation context)
- `IMPLEMENTATION_STATUS.md` (this file)

### Modified Files (3)
- `modules/services/open-webui.nix` (+13 lines for zdrModelsOnly option and systemd service)
- `shell.nix` (+4 lines for Python test dependencies)
- `flake.nix` (minor updates if any)

### Total Lines of Code Added
- Production code: ~595 lines
- Test code: ~446 lines
- Documentation: ~150 lines
- **Total: ~1,191 lines**

## Sign-off

**Implementation:** ✅ Complete  
**Unit Tests:** ✅ 6/6 passing  
**E2E Tests:** ✅ 1/1 passing  
**Documentation:** ✅ Complete  
**CI/CD:** ✅ Configured  
**Ready for:** 🚀 Deployment Testing

**Next Action Required:** Deploy to test host and verify real-world functionality with actual OpenRouter API.

---

*Generated by Claude Code Assistant on 2025-12-19*
