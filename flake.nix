{
  description = "NixOS configurations for multiple machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix/0.15.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Raspberry Pi 5 support - provides kernel 6.12.34, firmware, and config.txt management
    # Uses nvmd/nixos-raspberrypi which has the same kernel as the pre-built SD image
    # Cache: nixos-raspberrypi.cachix.org
    # See: https://github.com/nvmd/nixos-raspberrypi
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
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, vscode-server, agenix, disko, nixos-raspberrypi, claude-code, ... }@inputs:
    let
      # Systems that can run our scripts and packages
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Helper function to generate an attribute set for each system
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Import nixpkgs for each system
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
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

        # Claude Code package
        # Requires claude-code flake input passed via specialArgs.
        # Example:
        #   inputs.claude-code.url = "github:sadjow/claude-code-nix";
        #   specialArgs = { inherit claude-code; };
        # Enable with: customModules.claude.enable = true;
        claude = ./modules/services/claude.nix;

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
            pkgs-unstable = import nixpkgs-unstable {
              system = "x86_64-linux";
              config.allowUnfree = true;
            };
            inherit self; # Pass self for accessing flake root
            inherit claude-code; # Pass claude-code flake
          };
          modules = [
            ./hosts/sancta-choir/configuration.nix
            home-manager.nixosModules.home-manager
            vscode-server.nixosModules.default
            agenix.nixosModules.default
            ({ pkgs, ... }: {
              environment.systemPackages = [
                agenix.packages.${pkgs.system}.default
              ];
            })
          ];
        };

        # x86_64 VPS server - Dedicated OpenClaw host (Official npm package)
        sancta-claw = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            pkgs-unstable = import nixpkgs-unstable {
              system = "x86_64-linux";
              config.allowUnfree = true;
            };
            inherit self;
            inherit claude-code;
          };
          modules = [
            ./hosts/sancta-claw/configuration.nix
            disko.nixosModules.disko
            home-manager.nixosModules.home-manager
            agenix.nixosModules.default
            ({ pkgs, ... }: {
              environment.systemPackages = [
                agenix.packages.${pkgs.system}.default
              ];
            })
          ];
        };

        # x86_64 VPS server - Dedicated NullClaw bot (Zero_kuzea)
        zero-kuzea = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit self;
          };
          modules = [
            ./hosts/zero-kuzea/configuration.nix
            disko.nixosModules.disko
            agenix.nixosModules.default
            ({ pkgs, ... }: {
              environment.systemPackages = [
                agenix.packages.${pkgs.system}.default
              ];
            })
          ];
        };

        # Raspberry Pi 5 (aarch64) - Minimal config for SD image builds
        # Uses nvmd/nixos-raspberrypi for kernel 6.12.34 (same as pre-built SD image)
        # Cache: nixos-raspberrypi.cachix.org
        # Build SD image with: nix build .#images.rpi5-sd-image
        rpi5 = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = {
            inherit nixos-raspberrypi; # Required by nixos-raspberrypi.lib.nixosSystem
            pkgs-unstable = import nixpkgs-unstable {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
            inherit self; # Pass self for accessing flake root
            inherit claude-code; # Pass claude-code flake
          };
          modules = [
            # nixos-raspberrypi modules for RPi5 with kernel 6.12.34
            nixos-raspberrypi.nixosModules.raspberry-pi-5.base
            ./hosts/rpi5/configuration.nix
            home-manager.nixosModules.home-manager
            vscode-server.nixosModules.default
            agenix.nixosModules.default
            ({ pkgs, ... }: {
              environment.systemPackages = [
                agenix.packages.${pkgs.system}.default
              ];
            })
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
            inherit nixos-raspberrypi;
            pkgs-unstable = import nixpkgs-unstable {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
            inherit self;
            inherit claude-code;
          };
          modules = [
            nixos-raspberrypi.nixosModules.raspberry-pi-5.base
            ./hosts/rpi5-full/configuration.nix
            home-manager.nixosModules.home-manager
            vscode-server.nixosModules.default
            agenix.nixosModules.default
            ({ pkgs, ... }: {
              environment.systemPackages = [
                agenix.packages.${pkgs.system}.default
              ];
            })
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
