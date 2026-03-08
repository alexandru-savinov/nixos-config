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

{ lib, ... }:

{
  nixpkgs.overlays = [
    (final: prev:
      let
        isArm = prev.stdenv.isAarch64 && prev.stdenv.isLinux;
        disableChecks = drv: drv.overridePythonAttrs {
          pythonImportsCheck = [ ];
          doCheck = false;
          doInstallCheck = false;
        };
      in
      lib.optionalAttrs isArm {
        # Fix 1: Disable checks for Python packages that crash on ARM
        # deepdiff: polars transitive dep with jemalloc (4KB pages vs 16KB kernel)
        # chromadb: onnxruntime crashes on aarch64-linux
        python313Packages = prev.python313Packages.overrideScope (pyFinal: pyPrev: {
          deepdiff = disableChecks pyPrev.deepdiff;
          chromadb = disableChecks pyPrev.chromadb;
        });

        # Fix 2: Remove chromadb from open-webui on ARM (onnxruntime crash)
        open-webui = prev.open-webui.overridePythonAttrs (oldAttrs: {
          propagatedBuildInputs = builtins.filter
            (dep: (dep.pname or "") != "chromadb")
            (oldAttrs.propagatedBuildInputs or [ ]);

          pythonImportsCheck = builtins.filter
            (check: check != "chromadb")
            (oldAttrs.pythonImportsCheck or [ ]);

          meta = (oldAttrs.meta or { }) // {
            description = (oldAttrs.meta.description or "") + " (ARM: no chromadb)";
          };
        });
      }
    )
  ];
}
