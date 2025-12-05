{ config, pkgs, lib, ... }:

{
  # Enable nix-ld for running dynamically linked binaries
  # Required for: opencode, VS Code extensions, external language servers
  programs.nix-ld = {
    enable = true;

    # Common libraries needed by most dynamic binaries
    libraries = with pkgs; [
      # Core C libraries (keep both for libstdc++ and the glibc dynamic linker)
      stdenv.cc.cc.lib
      glibc

      # Compression
      zlib
      zstd

      # SSL/TLS
      openssl

      # Networking
      curl

      # System libraries commonly needed
      icu
      libunwind
      libuuid
      util-linux

      # For GUI apps (optional but useful)
      xorg.libX11
      xorg.libXcursor
      xorg.libXrandr
      xorg.libXi
    ];
  };
}
