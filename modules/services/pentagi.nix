# PentAGI — Autonomous AI-Powered Penetration Testing
#
# Deploys PentAGI (vxcontrol/pentagi) as Podman rootless containers:
#   pentagi       — Go backend + React UI (port 8443)
#   pgvector      — PostgreSQL with vector extension
#   scraper       — Headless browser for web intelligence (port 3000, rootless)
#
# On-demand: enable = false by default. Flip to true, rebuild, run audit, flip back.
#
# Usage:
#   services.pentagi = {
#     enable = true;
#     anthropicApiKeyFile = config.age.secrets.anthropic-api-key.path;
#     postgresPasswordFile = config.age.secrets.pentagi-postgres-password.path;
#   };

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.pentagi;

  pentagiUid = 989;
  pentagiGid = 989;

  podman = "${pkgs.podman}/bin/podman";

  # Scraper credentials (non-secret, used for inter-container auth)
  scraperUser = "pentagi";
  scraperPass = "scraper-local";
in
{
  options.services.pentagi = {
    enable = mkEnableOption "PentAGI autonomous pentesting (on-demand)";

    anthropicApiKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing Anthropic API key (agenix).";
    };

    postgresPasswordFile = mkOption {
      type = types.path;
      description = "Path to file containing PostgreSQL password for pgvector (agenix).";
    };

    cookieSaltFile = mkOption {
      type = types.path;
      description = "Path to file containing cookie signing salt (agenix). Must be stable across restarts.";
    };

    listenPort = mkOption {
      type = types.port;
      default = 8443;
      description = "Port for PentAGI web UI (bound to 127.0.0.1).";
    };

    image = mkOption {
      type = types.str;
      default = "docker.io/vxcontrol/pentagi:latest";
      description = "PentAGI container image.";
    };

    pgvectorImage = mkOption {
      type = types.str;
      default = "docker.io/vxcontrol/pgvector:latest";
      description = "pgvector container image.";
    };

    scraperImage = mkOption {
      type = types.str;
      default = "docker.io/vxcontrol/scraper:latest";
      description = "Scraper container image.";
    };
  };

  config = mkIf cfg.enable {
    # ── Assertions ──────────────────────────────────────────────────────
    assertions = [
      {
        assertion = !(hasPrefix "/nix/store" (toString cfg.anthropicApiKeyFile));
        message = "services.pentagi.anthropicApiKeyFile must not point to /nix/store (world-readable).";
      }
      {
        assertion = !(hasPrefix "/nix/store" (toString cfg.postgresPasswordFile));
        message = "services.pentagi.postgresPasswordFile must not point to /nix/store (world-readable).";
      }
      {
        assertion = !(hasPrefix "/nix/store" (toString cfg.cookieSaltFile));
        message = "services.pentagi.cookieSaltFile must not point to /nix/store (world-readable).";
      }
    ];

    # ── Podman ──────────────────────────────────────────────────────────
    # Rootless Podman — no system-wide Docker socket needed.
    # PentAGI uses the per-user Podman socket at /run/user/<uid>/podman/podman.sock.
    virtualisation.podman.enable = true;

    # ── User ────────────────────────────────────────────────────────────
    users.users.pentagi = {
      isSystemUser = true;
      uid = pentagiUid;
      group = "pentagi";
      home = "/var/lib/pentagi";
      createHome = true;
      shell = pkgs.bash;
      # subuid/subgid ranges required for rootless Podman
      subUidRanges = [{ startUid = 100000; count = 65536; }];
      subGidRanges = [{ startGid = 100000; count = 65536; }];
      # Podman rootless needs lingering for user systemd session
      linger = true;
    };

    users.groups.pentagi = {
      gid = pentagiGid;
    };

    # ── Directories ─────────────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d /var/lib/pentagi 0700 pentagi pentagi -"
      "d /var/lib/pentagi/data 0700 pentagi pentagi -"
      "d /var/lib/pentagi/pgdata 0700 pentagi pentagi -"
    ];

    # ── Podman network setup ───────────────────────────────────────────
    systemd.services.pentagi-network = {
      description = "Create PentAGI Podman network";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "pentagi";
        Group = "pentagi";
      };

      script = ''
        if ! ${podman} network exists pentagi-network 2>/dev/null; then
          ${podman} network create pentagi-network
          echo "Created pentagi-network"
        else
          echo "pentagi-network already exists"
        fi
      '';

      preStop = ''
        ${podman} network rm pentagi-network 2>/dev/null || true
      '';
    };

    # ── pgvector (PostgreSQL) ───────────────────────────────────────────
    systemd.services.pentagi-pgvector = {
      description = "PentAGI pgvector (PostgreSQL)";
      after = [ "pentagi-network.service" ];
      requires = [ "pentagi-network.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "pentagi";
        Group = "pentagi";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        NoNewPrivileges = true;
      };

      script = ''
        PG_PASS=$(cat "${cfg.postgresPasswordFile}")

        # Remove stale container if exists
        ${podman} rm -f pentagi-pgvector 2>/dev/null || true

        exec ${podman} run --rm \
          --name pentagi-pgvector \
          --network pentagi-network \
          --hostname pgvector \
          -e POSTGRES_USER=postgres \
          -e "POSTGRES_PASSWORD=$PG_PASS" \
          -e POSTGRES_DB=pentagidb \
          -v /var/lib/pentagi/pgdata:/var/lib/postgresql/data:Z \
          ${cfg.pgvectorImage}
      '';

      preStop = ''
        ${podman} stop pentagi-pgvector 2>/dev/null || true
      '';
    };

    # ── Scraper (headless browser) ──────────────────────────────────────
    systemd.services.pentagi-scraper = {
      description = "PentAGI scraper (headless browser)";
      after = [ "pentagi-network.service" ];
      requires = [ "pentagi-network.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "pentagi";
        Group = "pentagi";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        NoNewPrivileges = true;
      };

      script = ''
        # Remove stale container if exists
        ${podman} rm -f pentagi-scraper 2>/dev/null || true

        exec ${podman} run --rm \
          --name pentagi-scraper \
          --network pentagi-network \
          --hostname scraper \
          --shm-size=2g \
          -e MAX_CONCURRENT_SESSIONS=10 \
          -e "USERNAME=${scraperUser}" \
          -e "PASSWORD=${scraperPass}" \
          -e PORT=3000 \
          --expose 3000/tcp \
          ${cfg.scraperImage}
      '';

      preStop = ''
        ${podman} stop pentagi-scraper 2>/dev/null || true
      '';
    };

    # ── PentAGI main service ────────────────────────────────────────────
    systemd.services.pentagi = {
      description = "PentAGI autonomous pentesting platform";
      after = [
        "pentagi-pgvector.service"
        "pentagi-scraper.service"
        "network-online.target"
      ];
      requires = [
        "pentagi-pgvector.service"
        "pentagi-scraper.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "pentagi";
        Group = "pentagi";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 180;
        TimeoutStopSec = 30;
        NoNewPrivileges = true;
        # Memory limit for pentagi main container process
        MemoryMax = "4G";
      };

      script = ''
        PG_PASS=$(cat "${cfg.postgresPasswordFile}")
        ANTHROPIC_KEY=$(cat "${cfg.anthropicApiKeyFile}")
        COOKIE_SALT=$(cat "${cfg.cookieSaltFile}")

        # Remove stale container if exists
        ${podman} rm -f pentagi 2>/dev/null || true

        # Podman rootless socket path
        PODMAN_SOCK="/run/user/$(id -u)/podman/podman.sock"

        exec ${podman} run --rm \
          --name pentagi \
          --network pentagi-network \
          --hostname pentagi \
          -p 127.0.0.1:${toString cfg.listenPort}:8443 \
          -v /var/lib/pentagi/data:/opt/pentagi/data:Z \
          -v "$PODMAN_SOCK":/var/run/docker.sock:Z \
          -e "ANTHROPIC_API_KEY=$ANTHROPIC_KEY" \
          -e "DATABASE_URL=postgres://postgres:$PG_PASS@pentagi-pgvector:5432/pentagidb?sslmode=disable" \
          -e "SCRAPER_PRIVATE_URL=http://${scraperUser}:${scraperPass}@pentagi-scraper:3000/" \
          -e "SERVER_PORT=8443" \
          -e "SERVER_HOST=0.0.0.0" \
          -e "SERVER_USE_SSL=false" \
          -e "PUBLIC_URL=https://localhost:${toString cfg.listenPort}" \
          -e "DOCKER_INSIDE=true" \
          -e "DOCKER_HOST=unix:///var/run/docker.sock" \
          -e "DOCKER_NETWORK=host" \
          -e "DOCKER_NET_ADMIN=false" \
          -e "DOCKER_PUBLIC_IP=0.0.0.0" \
          -e "DUCKDUCKGO_ENABLED=true" \
          -e "SPLOITUS_ENABLED=true" \
          -e "COOKIE_SIGNING_SALT=$COOKIE_SALT" \
          ${cfg.image}
      '';

      preStop = ''
        ${podman} stop pentagi 2>/dev/null || true
      '';
    };

    # ── Tailscale Serve ─────────────────────────────────────────────────
    systemd.services.pentagi-tailscale-serve = {
      description = "Tailscale Serve for PentAGI UI";
      after = [
        "network-online.target"
        "tailscaled.service"
        "pentagi.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "pentagi.service"
      ];
      wantedBy = [ "multi-user.target" ];
      partOf = [ "pentagi.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 150;
        NoNewPrivileges = true;
      };

      script = ''
        # Wait for tailscaled to be ready
        ts_timeout=60
        while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
          ts_timeout=$((ts_timeout - 1))
          if [ $ts_timeout -le 0 ]; then
            echo "ERROR: tailscaled not ready after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        # Wait for PentAGI to be listening
        port_timeout=60
        while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 ${toString cfg.listenPort} 2>/dev/null; do
          port_timeout=$((port_timeout - 1))
          if [ $port_timeout -le 0 ]; then
            echo "ERROR: PentAGI not listening on port ${toString cfg.listenPort} after 60 seconds"
            exit 1
          fi
          sleep 1
        done

        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${toString cfg.listenPort}"; then
          echo "Configuring Tailscale Serve for PentAGI..."
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.listenPort} http://127.0.0.1:${toString cfg.listenPort}
        else
          echo "Tailscale Serve already configured for PentAGI"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for PentAGI..."
        ${pkgs.tailscale}/bin/tailscale serve --https ${toString cfg.listenPort} off || true
      '';
    };
  };
}
