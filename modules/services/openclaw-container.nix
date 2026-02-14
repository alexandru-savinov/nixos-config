# OpenClaw Container Module
# Runs OpenClaw in a systemd-nspawn container with network isolation

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.openclaw-container;

  # Container configuration (inner NixOS system)
  containerConfig = { config, pkgs, ... }: {
    imports = [
      ./openclaw.nix
    ];

    boot.isContainer = true;

    # Networking inside container
    networking = {
      useHostResolvConf = false;
      nameservers = [ "1.1.1.1" "8.8.8.8" ];
    };

    # OpenClaw service (reuse existing module)
    services.openclaw = {
      enable = true;
      anthropicApiKeyFile = "/run/secrets/anthropic-api-key";
      githubTokenFile = "/run/secrets/github-token";
      repoUrl = cfg.repoUrl;
      repoBranch = cfg.repoBranch;
      model = cfg.model;
      maxTurns = cfg.maxTurns;
      maxBudgetUsd = cfg.maxBudgetUsd;
      # Disable per-UID network restriction (handled at container level)
      networkRestriction.enable = false;
    };

    # Container-level network restrictions (nftables whitelist)
    networking.nftables = {
      enable = true;
      tables.openclaw-container-filter = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority 0; policy drop;

            # Allow loopback
            oifname "lo" accept

            # Allow established/related connections
            ct state established,related accept

            # Allow DNS to public resolvers
            ip daddr { 1.1.1.1, 8.8.8.8 } tcp dport 53 accept
            ip daddr { 1.1.1.1, 8.8.8.8 } udp dport 53 accept

            # Allow HTTPS to Anthropic API (AWS regions)
            ip daddr { 54.185.0.0/16, 35.165.0.0/16 } tcp dport 443 accept
            ip daddr { 160.79.104.0/23 } tcp dport 443 accept
            ip6 daddr { 2607:6bc0::/48 } tcp dport 443 accept

            # Allow HTTPS + SSH to GitHub
            ip daddr { 140.82.112.0/20 } tcp dport { 22, 443 } accept

            # Log and drop everything else
            log prefix "openclaw-blocked: " drop
          }
        '';
      };
    };

    system.stateVersion = "24.11";
  };

in
{
  options.services.openclaw-container = {
    enable = mkEnableOption "OpenClaw in systemd-nspawn container";

    anthropicApiKeyFile = mkOption {
      type = types.path;
      description = "Path to Anthropic API key file (on host)";
    };

    githubTokenFile = mkOption {
      type = types.path;
      description = "Path to GitHub token file (on host)";
    };

    repoUrl = mkOption {
      type = types.str;
      description = "Git repository URL for OpenClaw to work on";
    };

    repoBranch = mkOption {
      type = types.str;
      default = "main";
      description = "Git branch to use";
    };

    model = mkOption {
      type = types.enum [ "opus" "sonnet" "haiku" ];
      default = "sonnet";
      description = "Claude model to use";
    };

    maxTurns = mkOption {
      type = types.int;
      default = 50;
      description = "Maximum conversation turns per task";
    };

    maxBudgetUsd = mkOption {
      type = types.float;
      default = 5.0;
      description = "Maximum budget in USD per task";
    };
  };

  config = mkIf cfg.enable {
    # Create systemd-nspawn container
    containers.openclaw = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = "cnt-openclaw";
      localAddress = "192.168.84.2/24";

      bindMounts = {
        # Repository (read-only)
        "/var/lib/openclaw" = {
          hostPath = "/var/lib/openclaw";
          isReadOnly = true;
        };
        # Results directory (read-write)
        "/var/lib/openclaw/results" = {
          hostPath = "/var/lib/openclaw/results";
          isReadOnly = false;
        };
        # Secrets (read-only)
        "/run/secrets" = {
          hostPath = "/run/secrets-openclaw";
          isReadOnly = true;
        };
      };

      config = containerConfig;
    };

    # Host networking configuration
    networking.bridges.cnt-openclaw.interfaces = [];
    networking.interfaces.cnt-openclaw.ipv4.addresses = [{
      address = "192.168.84.1";
      prefixLength = 24;
    }];

    # NAT for container internet access
    networking.nat = {
      enable = true;
      internalInterfaces = [ "cnt-openclaw" ];
      externalInterface = "eth0";
    };

    # Secret staging service (runs before container starts)
    systemd.services.openclaw-secrets-stage = {
      description = "Stage OpenClaw container secrets";
      before = [ "container@openclaw.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail

        mkdir -p /run/secrets-openclaw
        chmod 700 /run/secrets-openclaw

        cp ${cfg.anthropicApiKeyFile} /run/secrets-openclaw/anthropic-api-key
        cp ${cfg.githubTokenFile} /run/secrets-openclaw/github-token

        chmod 400 /run/secrets-openclaw/*
      '';
    };

    # Create necessary directories on host
    systemd.tmpfiles.rules = [
      "d /var/lib/openclaw 0755 root root -"
      "d /var/lib/openclaw/inbox 0755 root root -"
      "d /var/lib/openclaw/results 0755 root root -"
      "d /run/secrets-openclaw 0700 root root -"
    ];
  };
}
