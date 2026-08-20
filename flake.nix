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
    # Open-WebUI OpenRouter cost tracking filter function.
    # Displays per-request cost (from OpenRouter's generation endpoint),
    # tokens, speed, and remaining credits in the message status area.
    owui-openrouter-stats = {
      url = "github:karamanliev/open-webui-openrouter-stats";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, vscode-server, agenix, nixos-raspberrypi, claude-code, claude-shared, owui-openrouter-stats, ... }@inputs:
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

      # hermesAgentPatched (the hermes-claw hash-patch overlay) was removed
      # 2026-08-20 with the host it existed solely to serve — see
      # docs/retired.md. Restore from git history if hermes-agent ever
      # returns to a live host.
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

        # sancta-claw, hermes-claw, zero-kuzea: retired 2026-08-20 — the
        # machines are destroyed (no tailnet response, gone for good). See
        # docs/retired.md for the record and the restore command.

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

          # Agenix recipient-drift + fail-open corruption guard (#448):
          # on-disk `-> ` stanza counts must match secrets.nix declarations,
          # and no .age payload may carry the empty-plaintext signature.
          secrets-recipient-guard = import ./tests/secrets-recipient-guard.nix { inherit pkgs; };

          # Workflow JSON sanity (#100): malformed JSON or a missing stable
          # `id` used to fail only at runtime during ExecStartPost import.
          n8n-workflows-valid = import ./tests/n8n-workflows-valid.nix { inherit pkgs; };

          # The review poster is the merge gate (#550): it turns findings into
          # threads that `required_conversation_resolution` blocks on. If it
          # silently stops posting, findings silently stop gating.
          claude-review-poster = import ./tests/claude-review-poster.nix { inherit pkgs; };

          # Heartbeat membrane-reflection guard (#519): runs the shared
          # trusted-context jq against fractional-second (…NNN Z) fixtures —
          # the real new Date().toISOString() form — and asserts the parsed
          # counts. Locks the fix so the module and this check can never drift.
          heartbeat-trusted-context = import ./tests/heartbeat-trusted-context.nix { inherit pkgs; };

          # Sancta membrane guard + relay invariants: failed turns retain the
          # cursor, successful turns commit once, and truncation never replays.
          sancta-membrane = import ./tests/sancta-membrane.nix { inherit pkgs; };

          # Doctrine guard branch coverage. Every case asserts a NON-ZERO exit
          # and the specific message: a guard that cannot be shown to fail is
          # the 2026-07-21 silent loss with better paperwork.
          sancta-doctrine-guard = import ./tests/sancta-doctrine-guard.nix { inherit pkgs; };

          # The gallery's tailnet bind probe, exercised against real sockets.
          # module-eval proves the unit is ordered after tailscaled; this proves
          # the probe tells "address not here yet" apart from every other
          # bind failure, which is the only part that can be silently wrong.
          sancta-gallery-bind-probe = import ./tests/sancta-gallery-bind-probe.nix { inherit pkgs; };

          # Store-reference existence for sancta unit scripts (2026-08-07, widened
          # 2026-08-19, narrowed 2026-08-20 when sancta-claw/hermes-claw/
          # zero-kuzea were retired — see docs/retired.md): dry-build was green
          # while `switch` failed 127 on `coreutils/bin/hostname` (hostname is
          # not in coreutils). `${pkg}/bin/X` is a string Nix never dereferences
          # until it RUNS — invisible to eval and build. This realises each
          # sancta unit's ExecStart scripts on the one remaining x86_64-linux
          # host (sancta-choir) and asserts every store path they reference
          # exists, catching that class in CI instead of at switch. rpi5/rpi5-full
          # (aarch64-linux) are named but not realised — no aarch64 builder here
          # or in CI; see tests/unit-script-refs.nix for the honest limit.
          unit-script-refs = import ./tests/unit-script-refs.nix {
            inherit pkgs nixpkgs self;
          };

          # Declared-contract check for the OTHER half of the same bug class:
          # ExecStart pointing OUTSIDE /nix/store entirely (e.g. a script on
          # the LUKS soul volume), where unit-script-refs.nix's realise-and-
          # grep approach cannot apply — there is no store derivation to
          # realise. sancta-statusline-refresh exited 127 on every tick (PR
          # #564) because its `path=` didn't include bash, its own shebang
          # interpreter. This is a pure eval-time check (no build sandbox can
          # read the soul-volume script — proven, see the file header) over a
          # committed, hand-written contract (tests/execstart-path-
          # contracts.nix); a runtime probe on sancta-choir (wq-tick, INDEX
          # repo, committed separately) verifies that contract still matches
          # the real script. Because it needs no realisation, unlike
          # unit-script-refs.nix, it evaluates all three hosts for real,
          # including both aarch64 ones this repo has no builder for.
          execstart-path-contract = import ./tests/execstart-path-contract.nix {
            inherit pkgs nixpkgs self;
          };

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
          sancta-doctrine-guard = import ./tests/sancta-doctrine-guard.nix { inherit pkgs; };
          sancta-gallery-bind-probe = import ./tests/sancta-gallery-bind-probe.nix { inherit pkgs; };
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
