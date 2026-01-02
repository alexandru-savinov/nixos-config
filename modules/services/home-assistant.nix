# Home Assistant with Tailscale Access and Build-time Validation
#
# This module wraps the native NixOS Home Assistant service with:
# - Agenix secret management for API keys and passwords
# - Tailscale-only network access (no public internet exposure)
# - Localhost binding for defense-in-depth security
# - HTTPS via Tailscale Serve (automatic TLS certificates)
# - Build-time configuration validation using HA's check_config
#
# Usage in host configuration:
#   services.home-assistant-tailscale = {
#     enable = true;
#     config = {
#       homeassistant = { name = "Home"; };
#       automation = [{ id = "test"; alias = "Test"; trigger = {...}; action = {...}; }];
#     };
#     secrets = {
#       mqtt_password.file = config.age.secrets.mqtt-password.path;
#     };
#     tailscaleServe.enable = true;
#   };
#
# Access via Tailscale HTTPS: https://<hostname>.tail<hex>.ts.net:8123

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.home-assistant-tailscale;

  # Format for YAML generation
  format = pkgs.formats.yaml { };

  # Generate configuration.yaml from config option
  configWithHttp = cfg.config // {
    http = (cfg.config.http or { }) // {
      server_host = cfg.host;
      server_port = cfg.port;
    };
  };
  configYaml = format.generate "configuration.yaml" configWithHttp;

  # Post-process YAML to convert "!secret key" strings to proper YAML tags
  processedConfigYaml = pkgs.runCommand "configuration.yaml" { } ''
    ${pkgs.gnused}/bin/sed -E \
      -e "s/['\"]!secret ([^'\"]+)['\"]/!secret \1/g" \
      -e "s/['\"]!include ([^'\"]+)['\"]/!include \1/g" \
      -e "s/['\"]!include_dir_merge_named ([^'\"]+)['\"]/!include_dir_merge_named \1/g" \
      ${configYaml} > $out
  '';

  # Create a minimal config directory for validation
  # Note: Validation output is not persisted to avoid leaking config details to Nix store
  configCheckDir = pkgs.runCommand "hass-config-check" {
    nativeBuildInputs = [ pkgs.home-assistant ];
  } ''
    # Create temporary config directory (not in $out to avoid persisting secrets/paths)
    CONFIG_DIR=$(mktemp -d)
    cp ${processedConfigYaml} $CONFIG_DIR/configuration.yaml

    # Create placeholder secrets.yaml for validation
    cat > $CONFIG_DIR/secrets.yaml << 'EOF'
    # Placeholder secrets for build-time validation
    ${concatStringsSep "\n" (mapAttrsToList (name: _: "${name}: placeholder_value_for_validation") cfg.secrets)}
    EOF

    # Run Home Assistant config check
    # Note: This validates YAML structure and basic schema, not runtime connectivity
    echo "Validating Home Assistant configuration..."
    export HOME=$TMPDIR

    # Create minimal .storage directory to prevent warnings
    mkdir -p $CONFIG_DIR/.storage

    # Run config check - output goes to stderr only (not persisted)
    CHECK_OUTPUT=$(${pkgs.home-assistant}/bin/hass --script check_config -c $CONFIG_DIR 2>&1) || {
      echo "============================================"
      echo "Home Assistant configuration validation FAILED"
      echo "============================================"
      echo "$CHECK_OUTPUT"
      exit 1
    }

    # Check for ERROR in output (not just non-zero exit)
    if echo "$CHECK_OUTPUT" | grep -q "^ERROR"; then
      echo "============================================"
      echo "Configuration errors found:"
      echo "============================================"
      echo "$CHECK_OUTPUT" | grep "^ERROR"
      exit 1
    fi

    echo "Configuration validation passed"

    # Create minimal output (just a marker file, no sensitive data)
    mkdir -p $out
    echo "validated" > $out/status
  '';

in
{
  options.services.home-assistant-tailscale = {
    enable = mkEnableOption "Home Assistant with Tailscale access";

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Host address for Home Assistant to listen on. Keep localhost for Tailscale Serve.";
    };

    port = mkOption {
      type = types.port;
      default = 8123;
      description = "Port for Home Assistant web interface.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/hass";
      description = "Directory for Home Assistant state (database, .storage, etc.).";
    };

    config = mkOption {
      type = types.nullOr types.attrs;
      default = null;
      example = literalExpression ''
        {
          homeassistant = {
            name = "Home";
            latitude = "!secret home_latitude";
            longitude = "!secret home_longitude";
            unit_system = "metric";
            time_zone = "Europe/Bucharest";
          };
          default_config = { };
          mqtt = {
            broker = "100.x.x.x";
            username = "homeassistant";
            password = "!secret mqtt_password";
          };
          automation = [
            {
              id = "motion_light";
              alias = "Motion Light";
              trigger = { platform = "state"; entity_id = "binary_sensor.motion"; to = "on"; };
              action = { service = "light.turn_on"; target.entity_id = "light.living_room"; };
            }
          ];
        }
      '';
      description = ''
        Home Assistant configuration as Nix attribute set.
        Equivalent to configuration.yaml.
        Use "!secret name" for values that should come from secrets.
        Set to null to manage configuration.yaml imperatively.
      '';
    };

    secrets = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          file = mkOption {
            type = types.path;
            description = "Path to file containing the secret value (e.g., agenix path).";
          };
        };
      });
      default = { };
      example = literalExpression ''
        {
          mqtt_password.file = config.age.secrets.mqtt-password.path;
          home_latitude.file = config.age.secrets.home-latitude.path;
        }
      '';
      description = ''
        Agenix secrets for Home Assistant.
        Referenced in config via "!secret <name>".
        Secrets are written to /var/lib/hass/secrets.yaml at runtime.
      '';
    };

    extraComponents = mkOption {
      type = types.listOf types.str;
      default = [
        "analytics"
        "google_translate"
        "met"
        "radio_browser"
        "shopping_list"
        "isal"
      ];
      example = [ "esphome" "mqtt" "zha" ];
      description = ''
        List of Home Assistant components/integrations to enable.
        Components are auto-discovered from config, but list any
        needed for onboarding or not auto-discovered here.
      '';
    };

    customComponents = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Custom Home Assistant components (HACS-style).";
    };

    customLovelaceModules = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Custom Lovelace UI modules.";
    };

    extraPackages = mkOption {
      type = types.functionTo (types.listOf types.package);
      default = ps: [ ];
      example = literalExpression "ps: with ps; [ gtts aiohttp-cors ]";
      description = "Additional Python packages for Home Assistant.";
    };

    validateConfig = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Validate configuration at build time using Home Assistant's check_config.
        Catches YAML errors, schema violations, and missing integrations.
        Adds to build time but prevents deployment of broken configs.
      '';
    };

    tailscaleServe = {
      enable = mkEnableOption "Tailscale Serve for HTTPS access" // {
        default = true;
      };

      httpsPort = mkOption {
        type = types.port;
        default = 8123;
        description = "HTTPS port for Tailscale Serve to expose.";
      };
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''
        {
          TZ = "Europe/Bucharest";
        }
      '';
      description = "Additional environment variables for Home Assistant.";
    };
  };

  config = mkIf cfg.enable {
    # Build-time validation (fails build if config is invalid)
    system.extraDependencies = mkIf (cfg.validateConfig && cfg.config != null) [
      configCheckDir
    ];

    # Native Home Assistant service
    services.home-assistant = {
      enable = true;
      openFirewall = false; # Access via Tailscale only

      configDir = cfg.stateDir;

      # Pass through declarative config if provided
      config = mkIf (cfg.config != null) configWithHttp;

      # Component dependencies
      extraComponents = cfg.extraComponents;
      customComponents = cfg.customComponents;
      customLovelaceModules = cfg.customLovelaceModules;
      extraPackages = cfg.extraPackages;
    };

    # Systemd service customizations
    systemd.services.home-assistant = mkMerge [
      {
        environment = cfg.extraEnvironment;
        serviceConfig = {
          # Security hardening
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          ReadWritePaths = [ cfg.stateDir ];
        };
      }

      # Secrets management
      (mkIf (cfg.secrets != { }) {
        preStart = mkBefore ''
          # Generate secrets.yaml from agenix files
          # Uses proper YAML quoting to handle special characters and newlines
          SECRETS_FILE="${cfg.stateDir}/secrets.yaml"
          echo "# Auto-generated secrets - do not edit" > "$SECRETS_FILE"

          ${concatStringsSep "\n" (mapAttrsToList (name: secretCfg: ''
            # Read secret, strip trailing newline, escape double quotes for YAML safety
            SECRET_VALUE=$(cat ${secretCfg.file} | tr -d '\n' | sed 's/"/\\"/g')
            printf '%s: "%s"\n' "${name}" "$SECRET_VALUE" >> "$SECRETS_FILE"
          '') cfg.secrets)}

          chmod 600 "$SECRETS_FILE"
          echo "Generated secrets.yaml with ${toString (length (attrNames cfg.secrets))} secrets"
        '';
      })
    ];

    # Tailscale Serve configuration for HTTPS access
    systemd.services.tailscale-serve-home-assistant = mkIf cfg.tailscaleServe.enable {
      description = "Configure Tailscale Serve for Home Assistant HTTPS access";
      after = [
        "network-online.target"
        "tailscaled.service"
        "home-assistant.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "tailscaled.service"
        "home-assistant.service"
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

        # Wait for Home Assistant to be listening (timeout: 120 seconds)
        # Home Assistant takes longer to start than other services
        timeout=120
        while ! ${pkgs.netcat}/bin/nc -z 127.0.0.1 ${toString cfg.port} 2>/dev/null; do
          timeout=$((timeout - 1))
          if [ $timeout -le 0 ]; then
            echo "ERROR: Home Assistant not listening on port ${toString cfg.port} after 120 seconds"
            exit 1
          fi
          sleep 1
        done

        # Check if serve is already configured for this port
        if ! ${pkgs.tailscale}/bin/tailscale serve status 2>/dev/null | grep -q "https:${toString cfg.tailscaleServe.httpsPort}"; then
          echo "Configuring Tailscale Serve for Home Assistant..."
          ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} http://127.0.0.1:${toString cfg.port}
        else
          echo "Tailscale Serve already configured for Home Assistant"
        fi
      '';

      preStop = ''
        echo "Removing Tailscale Serve configuration for Home Assistant..."
        ${pkgs.tailscale}/bin/tailscale serve --bg --https ${toString cfg.tailscaleServe.httpsPort} off || true
      '';
    };

    # Access Home Assistant via Tailscale HTTPS (requires tailscaleServe.enable = true):
    #   https://<hostname>.<tailnet>.ts.net:8123
    # Service binds to localhost only for security - no direct network access possible
  };
}
