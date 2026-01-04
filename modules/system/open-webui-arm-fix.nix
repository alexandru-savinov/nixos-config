# ARM (aarch64-linux) compatibility fix for Open-WebUI
#
# Root Cause:
# - chromadb dependency requires onnxruntime
# - onnxruntime crashes on aarch64-linux during import (logger initialization + CPU detection)
# - nixpkgs disables chromadb import checks on aarch64-linux but still builds it
# - The package builds but crashes at runtime when onnxruntime is imported
#
# Solution:
# - Override open-webui package to make chromadb optional on aarch64-linux
# - Use alternative vector database (Qdrant, pgvector, etc.) instead
# - Chromadb is only needed for RAG document embedding/vector storage
#
# Impact:
# - RAG document embedding/retrieval requires external vector DB (VECTOR_DB env var)
# - Chat, web search, and other non-embedding features work normally
# - Recommended alternatives:
#   - pgvector: officially maintained by Open-WebUI team
#   - Qdrant: community-maintained, fast performance
#
# References:
# - https://github.com/NixOS/nixpkgs/issues/312068 (ARM/aarch64 onnxruntime crash)
# - https://docs.openwebui.com/getting-started/env-configuration/

{ config, pkgs, lib, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      # Override open-webui to work without chromadb on aarch64-linux
      open-webui = if pkgs.stdenv.isAarch64 && pkgs.stdenv.isLinux
        then prev.open-webui.overridePythonAttrs (oldAttrs: {
          # Remove chromadb from propagatedBuildInputs on aarch64-linux
          propagatedBuildInputs = builtins.filter
            (dep: dep.pname or "" != "chromadb")
            (oldAttrs.propagatedBuildInputs or []);

          # Skip import check for chromadb on aarch64-linux
          pythonImportsCheck = builtins.filter
            (check: check != "chromadb")
            (oldAttrs.pythonImportsCheck or []);

          # Add metadata about the ARM fix
          meta = (oldAttrs.meta or {}) // {
            description = (oldAttrs.meta.description or "") + " (ARM build without chromadb - use external vector DB)";
          };
        })
        else prev.open-webui;
    })
  ];
}
