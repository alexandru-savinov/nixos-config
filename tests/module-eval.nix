# Module evaluation tests — verify NixOS modules evaluate correctly
# without needing to build derivations or spin up VMs.
#
# These tests catch:
#   - Import errors (typos, missing files)
#   - Type mismatches (wrong option types)
#   - Broken assertions (security checks, dependency validation)
#   - Incorrect mkIf conditional logic
#
# How it works:
#   Each test evaluates a minimal NixOS config that imports one module,
#   enables it with the minimum required options, and forces evaluation
#   of config.system.build.toplevel.drvPath. This resolves all module
#   system merging without actually building anything.
#
# Run: nix build .#checks.<system>.module-eval
#
# Called from flake.nix with: { pkgs, nixpkgs, self }

{ pkgs, nixpkgs, self }:

let
  system = pkgs.system;

  # Evaluate a NixOS config with the given modules and specialArgs.
  # Returns the fully-merged config attrset.
  evalConfig =
    { modules
    , specialArgs ? { }
    }:
    (nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit self; } // specialArgs;
      modules = [
        # Minimal base so the module system doesn't complain about
        # missing boot.loader / fileSystems / etc.
        ({ lib, ... }: {
          boot.loader.grub.enable = lib.mkDefault false;
          fileSystems."/" = lib.mkDefault { device = "/dev/sda1"; fsType = "ext4"; };
          system.stateVersion = lib.mkDefault "25.05";
          nixpkgs.hostPlatform = lib.mkDefault system;
        })
      ] ++ modules;
    }).config;

  # Force-evaluate a config down to its toplevel derivation path.
  # This triggers all assertions and option merging.
  forceEval = config:
    builtins.seq config.system.build.toplevel.drvPath true;

  # Check that evaluation succeeds (module is valid with given config).
  shouldEval = name: args:
    let
      config = evalConfig args;
      result = builtins.tryEval (forceEval config);
    in
    if result.success then true
    else builtins.throw "FAIL: ${name} — module should evaluate but threw an error";

  # Check that evaluation fails (assertion should fire for bad config).
  shouldFail = name: args:
    let
      config = evalConfig args;
      result = builtins.tryEval (forceEval config);
    in
    if !result.success then true
    else builtins.throw "FAIL: ${name} — expected assertion failure but evaluation succeeded";

  # ── Test definitions ──────────────────────────────────────────────

  tests = {

    # ── Qdrant ────────────────────────────────────────────────────
    qdrant-minimal = shouldEval "qdrant: minimal config" {
      modules = [
        ../modules/services/qdrant.nix
        {
          services.qdrant-tailscale.enable = true;
          services.qdrant-tailscale.tailscaleServe.enable = false;
        }
      ];
    };

    qdrant-on-disk = shouldEval "qdrant: on-disk storage" {
      modules = [
        ../modules/services/qdrant.nix
        {
          services.qdrant-tailscale.enable = true;
          services.qdrant-tailscale.storage.onDisk = true;
          services.qdrant-tailscale.tailscaleServe.enable = false;
        }
      ];
    };

    qdrant-disabled = shouldEval "qdrant: disabled" {
      modules = [
        ../modules/services/qdrant.nix
        { services.qdrant-tailscale.enable = false; }
      ];
    };

    # ── Gatus ─────────────────────────────────────────────────────
    gatus-minimal = shouldEval "gatus: minimal config" {
      modules = [
        ../modules/services/gatus.nix
        {
          services.gatus-tailscale.enable = true;
          services.gatus-tailscale.tailscaleServe.enable = false;
        }
      ];
    };

    gatus-with-endpoint = shouldEval "gatus: with endpoint" {
      modules = [
        ../modules/services/gatus.nix
        {
          services.gatus-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            endpoints = {
              test-health = {
                url = "http://127.0.0.1:8080/health";
                interval = "60s";
                conditions = [ "[STATUS] == 200" ];
              };
            };
          };
        }
      ];
    };

    gatus-with-suite = shouldEval "gatus: with suite" {
      modules = [
        ../modules/services/gatus.nix
        {
          services.gatus-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            suites = {
              test-suite = {
                description = "Test functional suite";
                endpoints = [
                  {
                    name = "step-1";
                    url = "http://127.0.0.1:8080/api/test";
                    conditions = [ "[STATUS] == 200" ];
                    store = { response_id = "[BODY].id"; };
                  }
                  {
                    name = "step-2";
                    url = "http://127.0.0.1:8080/api/test/[CONTEXT].response_id";
                    conditions = [ "[STATUS] == 200" ];
                  }
                ];
              };
            };
          };
        }
      ];
    };

    gatus-disabled = shouldEval "gatus: disabled" {
      modules = [
        ../modules/services/gatus.nix
        { services.gatus-tailscale.enable = false; }
      ];
    };

    # ── NixFrame ──────────────────────────────────────────────────
    nixframe-minimal = shouldEval "nixframe: minimal config" {
      modules = [
        ../modules/services/nixframe.nix
        { services.nixframe.enable = true; }
      ];
    };

    nixframe-with-weather = shouldEval "nixframe: with weather" {
      modules = [
        ../modules/services/nixframe.nix
        {
          services.nixframe = {
            enable = true;
            weather.enable = true;
          };
        }
      ];
    };

    nixframe-with-calendar = shouldEval "nixframe: with calendar" {
      modules = [
        ../modules/services/nixframe.nix
        {
          services.nixframe = {
            enable = true;
            calendar.enable = true;
            calendar.credentialsFile = "/run/secrets/caldav";
          };
        }
      ];
    };

    nixframe-disabled = shouldEval "nixframe: disabled" {
      modules = [
        ../modules/services/nixframe.nix
        { services.nixframe.enable = false; }
      ];
    };

    # ── Backup-pull ───────────────────────────────────────────────
    backup-pull-minimal = shouldEval "backup-pull: minimal config" {
      modules = [
        ../modules/services/backup-pull.nix
        {
          services.backup-pull = {
            enable = true;
            remoteHost = "test-host";
            remotePaths = [ "/var/lib/data" ];
            sshKeyFile = "/run/secrets/ssh-key";
            resticPasswordFile = "/run/secrets/restic-pw";
          };
        }
      ];
    };

    backup-pull-disabled = shouldEval "backup-pull: disabled" {
      modules = [
        ../modules/services/backup-pull.nix
        { services.backup-pull.enable = false; }
      ];
    };

    # ── n8n ───────────────────────────────────────────────────────
    n8n-minimal = shouldEval "n8n: minimal config" {
      modules = [
        ../modules/services/n8n.nix
        {
          services.n8n-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
          };
        }
      ];
    };

    n8n-with-encryption-key = shouldEval "n8n: with encryption key" {
      modules = [
        ../modules/services/n8n.nix
        {
          services.n8n-tailscale = {
            enable = true;
            encryptionKeyFile = "/run/secrets/n8n-encryption-key";
            tailscaleServe.enable = false;
          };
        }
      ];
    };

    n8n-nix-store-secret-rejected = shouldFail "n8n: nix-store secret rejected" {
      modules = [
        ../modules/services/n8n.nix
        {
          services.n8n-tailscale = {
            enable = true;
            encryptionKeyFile = "/nix/store/fake-hash-secret";
            tailscaleServe.enable = false;
          };
        }
      ];
    };

    n8n-disabled = shouldEval "n8n: disabled" {
      modules = [
        ../modules/services/n8n.nix
        { services.n8n-tailscale.enable = false; }
      ];
    };

    # ── Open-WebUI ────────────────────────────────────────────────
    open-webui-minimal = shouldEval "open-webui: minimal config" {
      modules = [
        ../modules/services/open-webui.nix
        {
          services.open-webui-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
          };
        }
      ];
      specialArgs = { pkgs-unstable = pkgs; };
    };

    open-webui-with-testing = shouldEval "open-webui: with testing enabled" {
      modules = [
        ../modules/services/open-webui.nix
        {
          services.open-webui-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            testing.enable = true;
            testing.apiKeyFile = "/run/secrets/e2e-key";
            secretKeyFile = "/run/secrets/webui-secret";
          };
        }
      ];
      specialArgs = { pkgs-unstable = pkgs; };
    };

    open-webui-testing-requires-secret-key = shouldFail "open-webui: testing without secretKeyFile" {
      modules = [
        ../modules/services/open-webui.nix
        {
          services.open-webui-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            testing.enable = true;
            testing.apiKeyFile = "/run/secrets/e2e-key";
            # secretKeyFile intentionally omitted — assertion should fire
          };
        }
      ];
      specialArgs = { pkgs-unstable = pkgs; };
    };

    open-webui-auto-memory-requires-memory = shouldFail "open-webui: autoMemory without memory" {
      modules = [
        ../modules/services/open-webui.nix
        {
          services.open-webui-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            autoMemory.enable = true;
            memory.enable = false;
          };
        }
      ];
      specialArgs = { pkgs-unstable = pkgs; };
    };

    open-webui-disabled = shouldEval "open-webui: disabled" {
      modules = [
        ../modules/services/open-webui.nix
        { services.open-webui-tailscale.enable = false; }
      ];
      specialArgs = { pkgs-unstable = pkgs; };
    };

    # ── OpenClaw ──────────────────────────────────────────────────
    openclaw-missing-claude-code = shouldFail "openclaw: missing claude-code input" {
      modules = [
        ../modules/services/openclaw.nix
        {
          services.openclaw = {
            enable = true;
            anthropicApiKeyFile = "/run/secrets/anthropic-key";
            githubTokenFile = "/run/secrets/github-token";
          };
        }
      ];
      # claude-code intentionally omitted — assertion should fire
      specialArgs = { claude-code = null; };
    };

    openclaw-nix-store-secret-rejected = shouldFail "openclaw: nix-store secret rejected" {
      modules = [
        ../modules/services/openclaw.nix
        {
          services.openclaw = {
            enable = true;
            anthropicApiKeyFile = "/nix/store/fake-hash-secret";
            githubTokenFile = "/run/secrets/github-token";
          };
        }
      ];
      # Provide a mock claude-code so the null-input assertion doesn't fire;
      # we're testing ONLY the /nix/store secret assertion here.
      specialArgs = { claude-code = { packages.${system}.default = pkgs.hello; }; };
    };

    openclaw-disabled = shouldEval "openclaw: disabled" {
      modules = [
        ../modules/services/openclaw.nix
        { services.openclaw.enable = false; }
      ];
      specialArgs = { claude-code = null; };
    };

    # ── NullClaw ──────────────────────────────────────────────────
    nullclaw-minimal = shouldEval "nullclaw: minimal config" {
      modules = [
        ../modules/services/nullclaw.nix
        {
          services.nullclaw = {
            enable = true;
            apiKeyFile = "/run/secrets/anthropic-key";
            # telegram.enable defaults to true, requiring botTokenFile;
            # disable it for the minimal-config test.
            telegram.enable = false;
          };
        }
      ];
      specialArgs = { pkgs-unstable = pkgs; };
    };

    nullclaw-nix-store-secret-rejected = shouldFail "nullclaw: nix-store api key rejected" {
      modules = [
        ../modules/services/nullclaw.nix
        {
          services.nullclaw = {
            enable = true;
            apiKeyFile = "/nix/store/fake-hash-key";
          };
        }
      ];
      specialArgs = { pkgs-unstable = pkgs; };
    };

    nullclaw-telegram-nix-store-rejected = shouldFail "nullclaw: nix-store telegram token rejected" {
      modules = [
        ../modules/services/nullclaw.nix
        {
          services.nullclaw = {
            enable = true;
            apiKeyFile = "/run/secrets/anthropic-key";
            telegram.enable = true;
            telegram.botTokenFile = "/nix/store/fake-hash-token";
            telegram.allowedUsers = [ "12345" ];
          };
        }
      ];
      specialArgs = { pkgs-unstable = pkgs; };
    };

    nullclaw-disabled = shouldEval "nullclaw: disabled" {
      modules = [
        ../modules/services/nullclaw.nix
        { services.nullclaw.enable = false; }
      ];
      specialArgs = { pkgs-unstable = pkgs; };
    };

    # ── UniFi MCP ─────────────────────────────────────────────────
    unifi-mcp-minimal = shouldEval "unifi-mcp: minimal config" {
      modules = [
        ../modules/services/unifi-mcp.nix
        {
          services.unifi-mcp = {
            enable = true;
            host = "192.168.1.1";
            passwordFile = "/run/secrets/unifi-password";
          };
        }
      ];
    };

    unifi-mcp-disabled = shouldEval "unifi-mcp: disabled" {
      modules = [
        ../modules/services/unifi-mcp.nix
        { services.unifi-mcp.enable = false; }
      ];
    };

    # ── Claude module ─────────────────────────────────────────────
    claude-missing-input = shouldFail "claude: missing claude-code input" {
      modules = [
        ../modules/services/claude.nix
        { customModules.claude.enable = true; }
      ];
      specialArgs = { claude-code = null; };
    };

    claude-disabled = shouldEval "claude: disabled" {
      modules = [
        ../modules/services/claude.nix
        { customModules.claude.enable = false; }
      ];
      specialArgs = { claude-code = null; };
    };

  };

  # ── Build the check derivation ──────────────────────────────────
  # Each test returns `true` on success or calls `builtins.throw` on
  # failure. Sequencing `builtins.deepSeq allResults` forces every test
  # to evaluate; a throw aborts immediately and `nix flake check` reports it.
  testNames = builtins.attrNames tests;
  testCount = builtins.length testNames;
  allResults = builtins.attrValues tests;

in
pkgs.runCommand "module-eval-tests"
{
  passthru = { inherit tests; };
}
  # deepSeq ensures all test thunks are forced before the builder runs.
  (builtins.deepSeq allResults ''
    echo "All ${toString testCount} module evaluation tests passed:"
    ${builtins.concatStringsSep "\n" (map (name: "echo '  ✓ ${name}'") testNames)}
    echo "${toString testNames}" > $out
  '')
