# PentAGI — Autonomous AI-Powered Penetration Testing
#
# Deploys PentAGI (vxcontrol/pentagi) as Docker containers via NixOS oci-containers:
#   pentagi       — Go backend + React UI (port 8443)
#   pgvector      — PostgreSQL with vector extension
#   scraper       — Headless browser for web intelligence (port 3000)
#
# On-demand: enable = false by default. Flip to true, rebuild, run audit, flip back.
#
# Uses rootful Docker (not rootless Podman) because PentAGI requires Docker socket
# access to spawn tool containers (nmap, metasploit, sqlmap, etc.) and runs as root
# inside its container (upstream design). Security mitigated by on-demand lifecycle.
#
# Usage:
#   services.pentagi = {
#     enable = true;
#     anthropicApiKeyFile = config.age.secrets.anthropic-api-key-pentagi.path;
#     postgresPasswordFile = config.age.secrets.pentagi-postgres-password.path;
#     cookieSaltFile = config.age.secrets.pentagi-cookie-salt.path;
#   };

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.pentagi;

  # Scraper credentials (inter-container auth only, not externally exposed)
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
      description = "Path to file containing PostgreSQL password for pgvector (agenix). Must be URL-safe (no +/= chars).";
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
    assertions = map
      (name: {
        assertion = !(hasPrefix "/nix/store" (toString cfg.${name}));
        message = "services.pentagi.${name} must not point to /nix/store (world-readable).";
      }) [ "anthropicApiKeyFile" "postgresPasswordFile" "cookieSaltFile" ];

    # ── Docker ──────────────────────────────────────────────────────────
    virtualisation.docker.enable = true;

    # ── Directories ─────────────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d /var/lib/pentagi 0700 root root -"
      "d /var/lib/pentagi/data 0700 root root -"
      "d /var/lib/pentagi/pgdata 0700 root root -"
    ];

    # ── Docker network ──────────────────────────────────────────────────
    systemd.services.pentagi-network = {
      description = "Create PentAGI Docker network";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        ${pkgs.docker}/bin/docker network inspect pentagi-network >/dev/null 2>&1 || \
          ${pkgs.docker}/bin/docker network create pentagi-network
      '';

      preStop = ''
        ${pkgs.docker}/bin/docker network rm pentagi-network 2>/dev/null || true
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
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
      };

      script = ''
        PG_PASS=$(cat "${cfg.postgresPasswordFile}")
        ${pkgs.docker}/bin/docker rm -f pentagi-pgvector 2>/dev/null || true
        exec ${pkgs.docker}/bin/docker run --rm \
          --name pentagi-pgvector \
          --network pentagi-network \
          --hostname pgvector \
          -e POSTGRES_USER=postgres \
          -e "POSTGRES_PASSWORD=$PG_PASS" \
          -e POSTGRES_DB=pentagidb \
          -v /var/lib/pentagi/pgdata:/var/lib/postgresql/data \
          ${cfg.pgvectorImage}
      '';

      preStop = "${pkgs.docker}/bin/docker stop pentagi-pgvector 2>/dev/null || true";
    };

    # ── Scraper (headless browser) ──────────────────────────────────────
    systemd.services.pentagi-scraper = {
      description = "PentAGI scraper (headless browser)";
      after = [ "pentagi-network.service" ];
      requires = [ "pentagi-network.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
      };

      script = ''
        ${pkgs.docker}/bin/docker rm -f pentagi-scraper 2>/dev/null || true
        exec ${pkgs.docker}/bin/docker run --rm \
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

      preStop = "${pkgs.docker}/bin/docker stop pentagi-scraper 2>/dev/null || true";
    };

    # ── PentAGI main service ────────────────────────────────────────────
    systemd.services.pentagi = {
      description = "PentAGI autonomous pentesting platform";
      after = [
        "pentagi-pgvector.service"
        "pentagi-scraper.service"
      ];
      requires = [
        "pentagi-pgvector.service"
        "pentagi-scraper.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 180;
        TimeoutStopSec = 30;
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };

      script = ''
        PG_PASS=$(cat "${cfg.postgresPasswordFile}")
        ANTHROPIC_KEY=$(cat "${cfg.anthropicApiKeyFile}")
        COOKIE_SALT=$(cat "${cfg.cookieSaltFile}")

        ${pkgs.docker}/bin/docker rm -f pentagi 2>/dev/null || true

        # Wait for PostgreSQL to accept connections
        echo "Waiting for pgvector to be ready..."
        pg_timeout=60
        while ! ${pkgs.docker}/bin/docker exec pentagi-pgvector pg_isready -U postgres 2>/dev/null; do
          pg_timeout=$((pg_timeout - 1))
          if [ $pg_timeout -le 0 ]; then
            echo "ERROR: pgvector not ready after 60 seconds"
            exit 1
          fi
          sleep 1
        done
        echo "pgvector is ready"

        # PentAGI runs as root:root (upstream design) with Docker socket access
        # to spawn tool containers (nmap, metasploit, etc.)
        # DOCKER_NETWORK=host: tool containers get Tailscale access for audit targets
        exec ${pkgs.docker}/bin/docker run --rm \
          --name pentagi \
          --network pentagi-network \
          --hostname pentagi \
          -p 127.0.0.1:${toString cfg.listenPort}:8443 \
          -v /var/lib/pentagi/data:/opt/pentagi/data \
          -v /var/run/docker.sock:/var/run/docker.sock \
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

      preStop = "${pkgs.docker}/bin/docker stop pentagi 2>/dev/null || true";
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
        ts_timeout=60
        while ! ${pkgs.tailscale}/bin/tailscale status &>/dev/null; do
          ts_timeout=$((ts_timeout - 1))
          if [ $ts_timeout -le 0 ]; then
            echo "ERROR: tailscaled not ready after 60 seconds"
            exit 1
          fi
          sleep 1
        done

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
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.listenPort} http://127.0.0.1:${toString cfg.listenPort}
        fi
      '';

      preStop = ''
        ${pkgs.tailscale}/bin/tailscale serve --https ${toString cfg.listenPort} off || true
      '';
    };
  };
}
