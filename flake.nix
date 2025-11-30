{
  description = "A NixOS module that runs Dokploy (a self-hosted PaaS) using declarative systemd units";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    {
      nixosModules = {
        default = import ./nix-dokploy.nix;
        dokploy = import ./nix-dokploy.nix;
      };

      # For backwards compatibility
      nixosModule = self.nixosModules.default;
    }
    // flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            statix
            deadnix
            alejandra
          ];
        };
        formatter = pkgs.alejandra;
      }
    );
}
