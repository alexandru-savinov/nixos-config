# ARM (aarch64-linux) compatibility fix for Open-WebUI
#
# Problem 1: jemalloc 16KB page size (RPi5 with kernel 6.12+)
# - Polars has jemalloc statically linked (compiled for 4KB pages)
# - RPi5 with kernel 6.12+ uses 16KB pages
# - jemalloc crashes with "Unsupported system page size" at runtime
# - Solution: Disable build-time checks for packages that import polars
#
# Problem 2: chromadb/onnxruntime crashes
# - onnxruntime crashes on aarch64-linux during import
# - Solution: Remove chromadb dependency (RAG requires external vector DB)
#
# Note: OpenBLAS works fine on ARM - the SIGBUS was from jemalloc, not BLAS.
#
# Impact:
# - RAG document embedding requires external vector DB (VECTOR_DB env var)
# - Document processing may crash at runtime if polars is invoked
# - Chat, web search, and API features work normally
#
# References:
# - https://github.com/jemalloc/jemalloc/issues/467 (16KB page support)
# - https://github.com/NixOS/nixpkgs/issues/312068 (ARM/aarch64 onnxruntime crash)

{ config, pkgs, lib, ... }:

{
  nixpkgs.overlays = [
    # Fix 1: Override Python packages that fail on ARM due to jemalloc/16KB pages
    # polars has jemalloc statically linked (compiled for 4KB pages)
    # deepdiff depends on polars, so its import check fails
    (final: prev:
      let
        isArm = prev.stdenv.isAarch64 && prev.stdenv.isLinux;
        python3Packages = prev.python313Packages;
      in lib.optionalAttrs isArm {
        python313Packages = python3Packages.overrideScope (pyFinal: pyPrev: {
          # Skip all checks for packages that use polars (jemalloc crash)
          # polars has jemalloc statically linked, compiled for 4KB pages
          deepdiff = pyPrev.deepdiff.overridePythonAttrs (oldAttrs: {
            pythonImportsCheck = [];
            doCheck = false;
            doInstallCheck = false;
          });

          # Skip all checks for chromadb (onnxruntime crash)
          chromadb = pyPrev.chromadb.overridePythonAttrs (oldAttrs: {
            pythonImportsCheck = [];
            doCheck = false;
            doInstallCheck = false;
          });
        });
      }
    )

    # Fix 2: Remove chromadb from open-webui on ARM (onnxruntime crashes)
    (final: prev:
      let isArm = prev.stdenv.isAarch64 && prev.stdenv.isLinux;
      in {
        open-webui = if isArm
          then prev.open-webui.overridePythonAttrs (oldAttrs: {
            # Remove chromadb from propagatedBuildInputs on ARM (onnxruntime crash)
            propagatedBuildInputs = builtins.filter
              (dep: (dep.pname or "") != "chromadb")
              (oldAttrs.propagatedBuildInputs or []);

            # Skip import check for chromadb
            pythonImportsCheck = builtins.filter
              (check: check != "chromadb")
              (oldAttrs.pythonImportsCheck or []);

            # Add metadata about the ARM fix
            meta = (oldAttrs.meta or {}) // {
              description = (oldAttrs.meta.description or "") + " (ARM: no chromadb)";
            };
          })
          else prev.open-webui;
      }
    )
  ];
}
