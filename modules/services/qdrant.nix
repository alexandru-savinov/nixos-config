# Qdrant Vector Database with Tailscale Integration
#
# Wraps the native NixOS services.qdrant with:
# - Tailscale Serve for HTTPS access
# - On-disk storage configuration for low memory (RPi5)
# - Localhost binding for security
#
# Usage:
#   services.qdrant-tailscale = {
#     enable = true;
#     storage.onDisk = true;  # Recommended for RPi5
#     tailscaleServe.enable = true;
#   };
#
# Access: https://<hostname>.<tailnet>.ts.net:6333
#
# References:
# - https://qdrant.tech/documentation/guides/configuration/
# - https://mynixos.com/options/services.qdrant

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.qdrant-tailscale;
in
{
  options.services.qdrant-tailscale = {
    enable = mkEnableOption "Qdrant vector database with Tailscale access";

    port = mkOption {
      type = types.port;
      default = 6333;
      description = "HTTP port for Qdrant REST API.";
    };

    grpcPort = mkOption {
      type = types.port;
      default = 6334;
      description = "gRPC port for high-performance operations.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host address for Qdrant to bind to. Keep localhost for Tailscale Serve.";
    };

    storage = {
      onDisk = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable on-disk (mmap) storage for vectors.
          Recommended for memory-constrained devices like RPi5.
          Trades some query speed for significantly lower RAM usage.
        '';
      };

      path = mkOption {
        type = types.path;
        default = "/var/lib/qdrant/storage";
        description = "Path to store Qdrant data.";
      };

      snapshotsPath = mkOption {
        type = types.path;
        default = "/var/lib/qdrant/snapshots";
        description = "Path to store Qdrant snapshots.";
      };
    };

    performance = {
      maxWorkers = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Maximum number of worker threads.
          0 = auto-detect based on CPU cores.
          Set to lower value on resource-constrained devices.
        '';
      };
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve for HTTPS access";

      httpsPort = mkOption {
        type = types.port;
        default = 6333;
        description = "HTTPS port for Tailscale Serve to expose.";
      };
    };

    extraSettings = mkOption {
      type = types.attrs;
      default = { };
      description = ''
        Additional Qdrant settings merged with defaults.
        See: https://qdrant.tech/documentation/guides/configuration/
      '';
    };
  };

  config = mkIf cfg.enable {
    # Enable native NixOS Qdrant service
    services.qdrant = {
      enable = true;
      settings = mkMerge [
        {
          # Service binding
          service = {
            host = cfg.host;
            http_port = cfg.port;
            grpc_port = cfg.grpcPort;
            max_workers = cfg.performance.maxWorkers;
          };

          # Storage configuration
          storage = {
            storage_path = cfg.storage.path;
            snapshots_path = cfg.storage.snapshotsPath;

            # On-disk mode uses mmap for vectors (lower RAM, slightly slower)
            on_disk_payload = cfg.storage.onDisk;
          };

          # HNSW index on disk (critical for low memory)
          hnsw_index = {
            on_disk = cfg.storage.onDisk;
          };

          # Disable telemetry
          telemetry_disabled = true;
        }
        cfg.extraSettings
      ];
    };

    # Tailscale Serve configuration for HTTPS access
    systemd.services.tailscale-serve-qdrant = mkIf cfg.tailscaleServe.enable {
      description = "Configure Tailscale Serve for Qdrant HTTPS access";
      after = [
        "network-online.target"
        "tailscaled.service"
        "qdrant.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "qdrant.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Wait for tailscaled to be ready (timeout: 60 seconds)
        timeout=60
        while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: tailscaled not ready after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        # Wait for Qdrant to be listening (timeout: 60 seconds)
        timeout=60
        while ! ${pkgs.netcat}/bin/nc -z ${cfg.host} ${toString cfg.port} 2>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: Qdrant not listening on port ${toString cfg.port} after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        # Check if serve is already configured for this port
        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${toString cfg.tailscaleServe.httpsPort}"; then
          echo "Configuring Tailscale Serve for Qdrant..."
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://${cfg.host}:${toString cfg.port}
        else
          echo "Tailscale Serve already configured for Qdrant"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for Qdrant..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };

    # Service binds to localhost only - accessible via Tailscale Serve (HTTPS)
    # Access Qdrant via:
    #   REST API: https://<hostname>.<tailnet>.ts.net:6333
    #   Web UI:   https://<hostname>.<tailnet>.ts.net:6333/dashboard
  };
}
