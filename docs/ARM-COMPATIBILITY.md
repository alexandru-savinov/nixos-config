# ARM (aarch64-linux) Compatibility Guide

## Open-WebUI on Raspberry Pi 5

### Problem Summary

Open-WebUI crashes immediately on startup with SIGBUS (signal 31/SYS) on aarch64-linux platforms like Raspberry Pi 5.

### Root Cause Analysis

The crash is caused by a dependency chain issue:

1. **chromadb** → requires **onnxruntime** for vector embeddings
2. **onnxruntime** → has memory alignment bugs on ARM architecture
3. Crash occurs during numpy/BLAS initialization in onnxruntime
4. SIGBUS indicates memory alignment violation (unaligned memory access)

**Evidence:**
- Stack trace shows crash in `libblas.so.3` and `_multiarray_umath.cpython-313-aarch64-linux-gnu.so`
- Same configuration works perfectly on x86_64 (sancta-choir)
- nixpkgs maintainers disabled chromadb tests on aarch64-linux due to this issue
- References: [NixOS/nixpkgs#312068](https://github.com/NixOS/nixpkgs/issues/312068), [NixOS/nixpkgs#392640](https://github.com/NixOS/nixpkgs/issues/392640)

### Solution

We override the `open-webui` package on aarch64-linux to remove the chromadb dependency entirely.

**Implementation:** `/root/nixos-config/modules/system/open-webui-arm-fix.nix`

```nix
nixpkgs.overlays = [
  (final: prev: {
    open-webui = if pkgs.stdenv.isAarch64 && pkgs.stdenv.isLinux
      then prev.open-webui.overridePythonAttrs (oldAttrs: {
        # Remove chromadb from dependencies
        propagatedBuildInputs = builtins.filter
          (dep: dep.pname or "" != "chromadb")
          (oldAttrs.propagatedBuildInputs or []);
        # Skip chromadb import checks
        pythonImportsCheck = builtins.filter
          (check: check != "chromadb")
          (oldAttrs.pythonImportsCheck or []);
      })
      else prev.open-webui;
  })
];
```

### Impact & Workarounds

#### What Still Works ✅

- Chat interface and LLM conversations
- OpenRouter model access (GPT-4, Claude, etc.)
- Web search via Tavily API
- Voice features (TTS/STT via OpenAI)
- User authentication
- All UI features

#### What Doesn't Work ❌

- **Document upload for RAG** (requires vector database)
- **Local document embedding** (requires chromadb)

#### Workaround Options

If you need document RAG features, you have two options:

##### Option 1: External Vector Database (Recommended)

Set up a separate vector database service and configure Open-WebUI to use it:

**Qdrant (Fast, Recommended):**
```nix
services.open-webui-tailscale.extraEnvironment = {
  VECTOR_DB = "qdrant";
  QDRANT_URI = "http://localhost:6333";
  QDRANT_API_KEY = "your-api-key";  # Optional
};
```

**PostgreSQL + pgvector (Reliable):**
```nix
services.open-webui-tailscale.extraEnvironment = {
  VECTOR_DB = "pgvector";
  DATABASE_URL = "postgresql://user:pass@localhost/openwebui";
};
```

**Other supported options:**
- `milvus` - High performance, good for large datasets
- `opensearch` - Enterprise-grade search and analytics
- `pinecone` - Managed cloud service

See [Open-WebUI Environment Configuration](https://docs.openwebui.com/getting-started/env-configuration/) for details.

##### Option 2: Use x86_64 System

Deploy Open-WebUI on an x86_64 machine (like sancta-choir VPS) where chromadb works natively.

### Configuration Example

```nix
{
  imports = [
    # ARM compatibility fix - removes chromadb on aarch64-linux
    ../../modules/system/open-webui-arm-fix.nix
  ];

  services.open-webui-tailscale = {
    enable = true;

    # Basic features work without chromadb
    tavilySearch.enable = true;
    voice.enable = true;

    # Disable document RAG or configure external vector DB
    extraEnvironment = {
      ENABLE_RAG_LOCAL_WEB_FETCH = "False";

      # Or enable with external vector DB:
      # VECTOR_DB = "qdrant";
      # QDRANT_URI = "http://localhost:6333";
    };
  };
}
```

### Current Status

- ✅ Open-WebUI runs successfully on Raspberry Pi 5
- ✅ All core features work (chat, models, search, voice)
- ⚠️  Document RAG requires external vector DB setup
- 🔄 Monitoring upstream for onnxruntime ARM fixes

### Future Improvements

This workaround will be needed until one of the following happens:

1. **onnxruntime** fixes ARM alignment issues
2. **chromadb** provides ARM-compatible alternative to onnxruntime
3. **nixpkgs** provides platform-specific chromadb builds
4. **open-webui** makes chromadb a truly optional dependency

### Testing

The fix has been validated with:
- ✅ `nix flake check` passes
- ✅ Configuration builds successfully
- ✅ Service starts without SIGBUS crash
- ✅ Works on both x86_64 and aarch64-linux

### Related Issues

- [NixOS/nixpkgs#312068](https://github.com/NixOS/nixpkgs/issues/312068) - chromadb build failure on aarch64-linux
- [NixOS/nixpkgs#392640](https://github.com/NixOS/nixpkgs/issues/392640) - chromadb dependency for open-webui
- [NixOS/nixpkgs#374254](https://github.com/NixOS/nixpkgs/issues/374254) - open-webui fails on aarch64-darwin
- [microsoft/onnxruntime#9368](https://github.com/microsoft/onnxruntime/issues/9368) - SIGBUS on 32-bit ARM
- [open-webui/open-webui#9651](https://github.com/open-webui/open-webui/issues/9651) - ARM64 crash/infinite loop

### Contributing

If you find a better solution or onnxruntime gets fixed on ARM, please:

1. Update `/root/nixos-config/modules/system/open-webui-arm-fix.nix`
2. Update this documentation
3. Submit a PR to share the improvement

---

Last Updated: 2026-01-03
Status: Active workaround in production
