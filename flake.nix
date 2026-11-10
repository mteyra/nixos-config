{
  description = "haunted@X1 snowy Finley-style NixOS Hyprland Noctalia setup";

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://noctalia.cachix.org"
      "https://cache.lantian.pub/lantian"
    ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
      "lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-prev.url = "github:NixOS/nixpkgs/567a49d1913ce81ac6e9582e3553dd90a955875f";

    antigravity-nix = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia/legacy-v4";
      inputs.nixpkgs.follows = "nixpkgs-prev";
    };

    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

    nixcare = {
      url = "github:mteyra/nixcare";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-prev, noctalia, nix-cachyos-kernel, nixcare, ... }:
    {
      nixosConfigurations.X1 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/X1.nix
          nixcare.nixosModules.default

          {
            nixpkgs.overlays = [
              nix-cachyos-kernel.overlays.pinned
              (final: prev: {
                codex = inputs.nixpkgs-prev.legacyPackages.${prev.stdenv.hostPlatform.system}.codex;
                pixi = inputs.nixpkgs-prev.legacyPackages.${prev.stdenv.hostPlatform.system}.pixi;
              })
            ];
          }
        ];
      };
    };
}
