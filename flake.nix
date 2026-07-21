{
  description = "NixOS configurations for multiple machines";

  inputs = {
    # Upgraded from nixos-25.05 to fix CVE-2025-68613 (n8n RCE, CVSS 9.9)
    # nixos-25.05 has n8n 1.91.3 (vulnerable); nixos-25.11 has n8n 1.123.23 (patched)
    # Also resolves Home Manager version mismatch (#264): nixos-raspberrypi
    # already uses nixpkgs 25.11, so this aligns all hosts.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      # Unpinned from 0.15.0: that tag uses substituteAll, removed in nixpkgs 25.11.
      # Main branch uses replaceVars. Pin to next release when available.
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Raspberry Pi 5 support - provides kernel 6.12.34, firmware, and config.txt management
    # Uses nvmd/nixos-raspberrypi which has the same kernel as the pre-built SD image
    # Cache: nixos-raspberrypi.cachix.org
    # See: https://github.com/nvmd/nixos-raspberrypi
    #
    # INTENTIONALLY no `inputs.nixpkgs.follows = "nixpkgs"` (#182): the
    # nixos-raspberrypi binary cache (kernel, firmware) is built against ITS
    # pinned nixpkgs. Following our nixpkgs would change the kernel derivation
    # hash and force multi-hour from-source kernel builds on the 4GB Pi.
    # Consequence: rpi5/rpi5-full track nixos-raspberrypi's nixpkgs pin while
    # the other hosts track the root `nixpkgs` input — both on the same
    # nixos-25.11 branch since the 25.11 upgrade, but at slightly different
    # revisions (days apart). Keep both fresh with `nix flake update`.
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi";
    };
    # Declarative disk partitioning
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Claude Code - auto-updated hourly from npm
    # See: https://github.com/sadjow/claude-code-nix
    claude-code = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    # User-level Claude Code config (skills, agents, slash commands, HM module).
    # Public repo, no auth needed.
    claude-shared = {
      url = "github:alexandru-savinov/claude-shared";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.claude-code.follows = "claude-code";
    };
    kuzea-workspace = {
      url = "github:alexandru-savinov/kuzea-workspace";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Open-WebUI OpenRouter cost tracking filter function.
    # Displays per-request cost (from OpenRouter's generation endpoint),
    # tokens, speed, and remaining credits in the message status area.
    owui-openrouter-stats = {
      url = "github:karamanliev/open-webui-openrouter-stats";
      flake = false;
    };
    # Hermes Agent (Nous Research) — AI agent framework with NixOS module.
    # Container mode: uv2nix-built binary bind-mounted into Ubuntu, writable layer.
    # Pinned to v0.16.0 release commit (3c231eb, 2026-06-05). v0.16 ships
    # locales/ in $out/share/hermes-agent/ and sets HERMES_BUNDLED_LOCALES
    # in the wrapper, fixing /status etc. rendering as raw i18n keys
    # (gateway.status.header, …). Earlier releases (incl. v0.14.0 /
    # v2026.5.16) ship the locales as setuptools data-files, which the
    # uv2nix venv places where agent.i18n._locales_dir() does NOT look —
    # so /status was returning literal key strings to Telegram before
    # this upgrade. Upstream nix/lib.nix on 3c231eb pins a stale
    # npmDepsHash for hermes-tui; we patch it in `outputs` via
    # runCommand+callPackage (see `hermesAgentPatched` below) so the fix
    # stays in git, not /tmp. Drop the overlay once upstream's
    # auto-fix-lockfiles CI catches up.
    hermes-agent = {
      url = "github:NousResearch/hermes-agent/3c231eb3979ab9c57d5cd6d02f1d577a3b718b43";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, vscode-server, agenix, disko, nixos-raspberrypi, claude-code, claude-shared, kuzea-workspace, owui-openrouter-stats, hermes-agent, ... }@inputs:
    let
      # Systems that can run our scripts and packages
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Helper function to generate an attribute set for each system
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Import nixpkgs for each system
      # allowUnfree needed for open-webui (changed to "Open WebUI License" in 25.11)
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; config.allowUnfree = true; });

      # Import unstable nixpkgs per architecture (shared across host configs)
      pkgs-unstable-x86 = import nixpkgs-unstable {
        system = "x86_64-linux";
        config.allowUnfree = true;
      };
      pkgs-unstable-aarch64 = import nixpkgs-unstable {
        system = "aarch64-linux";
        config.allowUnfree = true;
      };

      # Agenix CLI package module (shared across all hosts)
      agenixModule = { pkgs, ... }: {
        environment.systemPackages = [
          agenix.packages.${pkgs.system}.default
        ];
      };

      # Patched hermes-agent package: upstream v0.16.0 nix/lib.nix pins an
      # npmDepsHash for hermes-tui that is stale (FOD hash mismatch breaks
      # the build). We materialize the upstream source, bump the hash in
      # place via substituteInPlace, then call the upstream build recipe
      # directly via callPackage (avoids getFlake — which pure-eval rejects
      # on store paths). The recipe's inputs (uv2nix, pyproject-nix, etc.)
      # are re-used from hermes-agent's own flake inputs.
      # Remove this overlay once upstream's auto-fix-lockfiles CI catches up.
      hermesAgentPatched = system:
        let
          pkgs = nixpkgsFor.${system};
          # Patcher runs on target arch (x86_64 for hermes-claw): native on
          # GitHub CI runners; on rpi5 (aarch64) the nixos-rebuild
          # `--build-host root@hermes-claw` flag delegates the IFD build
          # over SSH-ng. If you ever `nix eval` this output directly on
          # rpi5 without --builders, add hermes-claw to nix.buildMachines.
          patchedSrc = pkgs.runCommand "hermes-agent-patched-src" { } ''
            cp -r ${hermes-agent} $out
            chmod -R +w $out
            substituteInPlace $out/nix/lib.nix \
              --replace-fail \
                'sha256-cY+gM1FnTBjmld/uqt7RsqRtW9uQGs8LGokCcxu7bjQ=' \
                'sha256-hgnqcpKRPztHhDEpwC7HJrALuJp9wsrV4+GJ6t6HI2c='
          '';
        in
        pkgs.callPackage "${patchedSrc}/nix/hermes-agent.nix" {
          inherit (hermes-agent.inputs) uv2nix pyproject-nix pyproject-build-systems;
          npm-lockfile-fix = hermes-agent.inputs.npm-lockfile-fix.packages.${system}.default;
          rev = null;
        };
    in
    {
      # Formatter for `nix fmt`
      formatter = forAllSystems (system: nixpkgsFor.${system}.nixpkgs-fmt);

      # Exportable NixOS modules for use in external flakes
      # Usage in external flake:
      #   inputs.nixos-config.url = "github:alexandru-savinov/nixos-config";
      #   modules = [ nixos-config.nixosModules.dev-tools ];
      nixosModules = {
        # Common base configuration (SSH, zram, flakes, /bin/bash shim)
        common = ./hosts/common.nix;

        # Claude Code package + user-level config via claude-shared flake.
        # Requires both `claude-code` and `claude-shared` flake inputs passed
        # via specialArgs. Enable with:
        #   customModules.claudeShared = { enable = true; users = [ "nixos" ]; };
        claudeShared = ./modules/services/claude-shared.nix;

        # Dynamic binary support (nix-ld for running non-Nix binaries)
        nix-ld = ./modules/system/nix-ld.nix;

        # Development tools package set (editors, dev tools, nix tooling)
        # Optional: Pass pkgs-unstable via specialArgs for latest github-copilot-cli
        # Example:
        #   specialArgs = { pkgs-unstable = import nixpkgs-unstable { system = "..."; }; };
        # Enable with: customModules.dev-tools.enable = true;
        dev-tools = ./modules/system/dev-tools.nix;
      };

      # NixOS system configurations
      nixosConfigurations = {
        # x86_64 VPS server
        sancta-choir = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            pkgs-unstable = pkgs-unstable-x86;
            inherit self claude-code claude-shared owui-openrouter-stats;
          };
          modules = [
            ./hosts/sancta-choir/configuration.nix
            home-manager.nixosModules.home-manager
            vscode-server.nixosModules.default
            agenix.nixosModules.default
            agenixModule
          ];
        };

        # x86_64 VPS server - Dedicated OpenClaw host (Official npm package)
        sancta-claw = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            pkgs-unstable = pkgs-unstable-x86;
            kuzea-ws = kuzea-workspace.packages.x86_64-linux;
            inherit self claude-code;
          };
          modules = [
            ./hosts/sancta-claw/configuration.nix
            disko.nixosModules.disko
            home-manager.nixosModules.home-manager
            agenix.nixosModules.default
            agenixModule
          ];
        };

        # x86_64 VPS server - Dedicated Hermes Agent host (Nous Research, container mode)
        hermes-claw = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            pkgs-unstable = pkgs-unstable-x86;
            inherit self;
          };
          modules = [
            ./hosts/hermes-claw/configuration.nix
            disko.nixosModules.disko
            home-manager.nixosModules.home-manager
            agenix.nixosModules.default
            agenixModule
            hermes-agent.nixosModules.default
            # Override default package with our patched hermes-tui hash.
            { services.hermes-agent.package = hermesAgentPatched "x86_64-linux"; }
          ];
        };

        # x86_64 VPS server - Dedicated NullClaw bot (Zero_kuzea)
        zero-kuzea = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            pkgs-unstable = import nixpkgs-unstable { system = "x86_64-linux"; };
            inherit self;
          };
          modules = [
            ./hosts/zero-kuzea/configuration.nix
            disko.nixosModules.disko
            agenix.nixosModules.default
            agenixModule
          ];
        };

        # Raspberry Pi 5 (aarch64) - Minimal config for SD image builds
        # Uses nvmd/nixos-raspberrypi for kernel 6.12.34 (same as pre-built SD image)
        # Cache: nixos-raspberrypi.cachix.org
        # Build SD image with: nix build .#images.rpi5-sd-image
        rpi5 = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = {
            inherit nixos-raspberrypi self claude-code claude-shared;
            pkgs-unstable = pkgs-unstable-aarch64;
          };
          modules = [
            nixos-raspberrypi.nixosModules.raspberry-pi-5.base
            ./hosts/rpi5/configuration.nix
            home-manager.nixosModules.home-manager
            vscode-server.nixosModules.default
            agenix.nixosModules.default
            agenixModule
          ];
        };

        # Raspberry Pi 5 (aarch64) - Full config with all services
        # IMPORTANT: Only build this NATIVELY on the RPi5, not via QEMU emulation
        # chromadb/Open-WebUI fail under QEMU - use rpi5 config for SD image builds
        #
        # After first boot with minimal SD image, rebuild natively:
        #   sudo nixos-rebuild switch --flake github:user/nixos-config#rpi5-full
        rpi5-full = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = {
            inherit nixos-raspberrypi self claude-code claude-shared;
            pkgs-unstable = pkgs-unstable-aarch64;
          };
          modules = [
            nixos-raspberrypi.nixosModules.raspberry-pi-5.base
            ./hosts/rpi5-full/configuration.nix
            home-manager.nixosModules.home-manager
            vscode-server.nixosModules.default
            agenix.nixosModules.default
            agenixModule
          ];
        };
      };

      # SD Image for Raspberry Pi 5
      # Build with: nix build .#rpi5-sd-image
      images = {
        rpi5-sd-image = self.nixosConfigurations.rpi5.config.system.build.sdImage;
      };

      # Packages - scripts that can be built and run
      packages = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          # Default package (what runs with `nix run github:user/repo`)
          default = self.packages.${system}.install;

          # Ralphex — orchestrates Claude Code agents through plan files.
          # See pkgs/ralphex.nix; install via environment.systemPackages.
          ralphex = pkgs.callPackage ./pkgs/ralphex.nix { };

          # Declarative n8n VM test (#42). A package (not a check) so plain
          # `nix flake check` stays light — see the note in the checks
          # section. CI builds it in the "Build x86_64 Configs" job; run
          # locally with: nix build .#n8n-declarative-test
          n8n-declarative-test = import ./tests/n8n-declarative.nix { inherit pkgs self; };

          # Fresh system installation script
          install = pkgs.writeShellApplication {
            name = "nixos-install";
            runtimeInputs = with pkgs; [
              git
              nixos-rebuild
              coreutils
            ];
            text = builtins.readFile ./scripts/install.sh;
          };

          # Deployment script for updates
          deploy = pkgs.writeShellApplication {
            name = "nixos-deploy";
            runtimeInputs = with pkgs; [
              git
              nixos-rebuild
              coreutils
              gnugrep
              gnused
            ];
            text = builtins.readFile ./scripts/deploy.sh;
          };

          # Bootstrap script for remote infection
          bootstrap = pkgs.writeShellApplication {
            name = "nixos-bootstrap";
            runtimeInputs = with pkgs; [
              curl
              git
              coreutils
            ];
            text = builtins.readFile ./scripts/bootstrap.sh;
          };
        });

      # Checks - run with `nix flake check`
      # x86_64-linux only: CI runs `nix flake check --all-systems` on x86_64
      # runners without aarch64 builders. Module eval tests are architecture-
      # independent (they test option merging, not package builds).
      checks.x86_64-linux =
        let
          pkgs = nixpkgsFor.x86_64-linux;
        in
        {
          # Module evaluation tests — verify all service modules evaluate
          # correctly with minimal config, and that assertions fire for
          # invalid inputs (e.g. secrets in /nix/store).
          module-eval = import ./tests/module-eval.nix {
            inherit pkgs nixpkgs self;
          };

          # End-to-end ZDR proxy test: boots a VM with the proxy + a stub
          # OpenRouter, verifies provider.zdr=true is injected on the wire
          # and non-ZDR models are rejected before reaching the upstream.
          openclaw-zdr-proxy = pkgs.testers.nixosTest (import ./tests/openclaw-zdr-proxy.nix { inherit pkgs; });

          # Agenix recipient-drift + fail-open corruption guard (#448):
          # on-disk `-> ` stanza counts must match secrets.nix declarations,
          # and no .age payload may carry the empty-plaintext signature.
          secrets-recipient-guard = import ./tests/secrets-recipient-guard.nix { inherit pkgs; };

          # Workflow JSON sanity (#100): malformed JSON or a missing stable
          # `id` used to fail only at runtime during ExecStartPost import.
          n8n-workflows-valid = import ./tests/n8n-workflows-valid.nix { inherit pkgs; };

          # Heartbeat membrane-reflection guard (#519): runs the shared
          # trusted-context jq against fractional-second (…NNN Z) fixtures —
          # the real new Date().toISOString() form — and asserts the parsed
          # counts. Locks the fix so the module and this check can never drift.
          heartbeat-trusted-context = import ./tests/heartbeat-trusted-context.nix { inherit pkgs; };

          # Sancta membrane guard + relay invariants: failed turns retain the
          # cursor, successful turns commit once, and truncation never replays.
          sancta-membrane = import ./tests/sancta-membrane.nix { inherit pkgs; };

          # NOTE: the declarative n8n VM test (#42) deliberately lives under
          # packages.<system>.n8n-declarative-test, NOT here. `nix flake
          # check` builds every check inside the resource-constrained
          # "Check Flake & Formatting" CI job — adding the n8n source build
          # (unfree, never binary-cached) plus a second KVM VM there killed
          # the runner with a shutdown signal. CI runs the test as an
          # explicit step in the "Build x86_64 Configs" job instead, which
          # frees ~30GB disk first and runs nothing concurrently.
        };

      # aarch64-linux checks: only the architecture-independent, cheap
      # guards that are also meaningful on the actual deploy
      # host. `heartbeat-trusted-context` is re-exposed here (same fixture,
      # same shared .jq — no drift) so the guard for the tick, which runs
      # on rpi5-full (aarch64), can be built NATIVELY on the Pi without
      # x86_64 emulation. CI still exercises it on the x86_64 runner.
      checks.aarch64-linux =
        let
          pkgs = nixpkgsFor.aarch64-linux;
        in
        {
          heartbeat-trusted-context = import ./tests/heartbeat-trusted-context.nix { inherit pkgs; };
          sancta-membrane = import ./tests/sancta-membrane.nix { inherit pkgs; };
        };

      # Apps - makes packages runnable with `nix run`
      apps = forAllSystems (system: {
        # Default app (what runs with `nix run github:user/repo`)
        default = self.apps.${system}.install;

        # Fresh installation
        install = {
          type = "app";
          program = "${self.packages.${system}.install}/bin/nixos-install";
        };

        # Deployment/updates
        deploy = {
          type = "app";
          program = "${self.packages.${system}.deploy}/bin/nixos-deploy";
        };

        # Bootstrap for remote systems
        bootstrap = {
          type = "app";
          program = "${self.packages.${system}.bootstrap}/bin/nixos-bootstrap";
        };
      });
    };
}
