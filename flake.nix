{
  description = "NixOS configurations for multiple machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager-unstable = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    tsidp = {
      url = "github:tailscale/tsidp";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    agenix = {
      url = "github:ryantm/agenix/0.15.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Raspberry Pi 5 support - provides proper kernel, firmware, and config.txt management
    # Archived but still functional and recommended for RPi5
    # See: https://github.com/nix-community/raspberry-pi-nix
    raspberry-pi-nix = {
      url = "github:nix-community/raspberry-pi-nix/v0.4.1";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, home-manager-unstable, vscode-server, tsidp, agenix, raspberry-pi-nix, ... }@inputs:
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
          };
          modules = [
            ./hosts/sancta-choir/configuration.nix
            home-manager.nixosModules.home-manager
            vscode-server.nixosModules.default
            tsidp.nixosModules.default
            agenix.nixosModules.default
            ({ pkgs, ... }: {
              environment.systemPackages = [
                agenix.packages.${pkgs.system}.default
              ];
            })
          ];
        };

        # Raspberry Pi 5 (aarch64)
        # Uses raspberry-pi-nix for proper Pi 5 kernel with RP1 SD controller support
        # Build SD image with: nix build .#images.rpi5-sd-image
        rpi5 = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            pkgs-unstable = import nixpkgs-unstable {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
            inherit self; # Pass self for accessing flake root
          };
          modules = [
            # raspberry-pi-nix provides proper Pi 5 kernel with RP1 drivers
            raspberry-pi-nix.nixosModules.raspberry-pi
            ./hosts/rpi5/configuration.nix
            home-manager.nixosModules.home-manager
            vscode-server.nixosModules.default
            agenix.nixosModules.default
            ({ pkgs, lib, ... }: {
              environment.systemPackages = [
                agenix.packages.${pkgs.system}.default
              ];
              # Configure for Raspberry Pi 5 (BCM2712)
              raspberry-pi-nix.board = "bcm2712";
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
