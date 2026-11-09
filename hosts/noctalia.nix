{ pkgs, inputs, ... }:

{
  nix.settings.extra-substituters = [
    "https://noctalia.cachix.org"
    "https://cache.lantian.pub/lantian"
  ];

  nix.settings.extra-trusted-public-keys = [
    "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    "lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ="
  ];

  environment.systemPackages = [
    inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
