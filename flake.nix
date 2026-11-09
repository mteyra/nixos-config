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
	
    antigravity-nix = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia/legacy-v4";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

    nixcare = {
      url = "github:mteyra/nixcare";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, noctalia, nix-cachyos-kernel, nixcare, ... }:
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
            ];
          }
        ];
      };
    };
}
