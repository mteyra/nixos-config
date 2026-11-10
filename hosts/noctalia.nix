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

  # Supervised user service for Noctalia shell & launcher daemon.
  # Automatically restarts if Wayland disconnects or after system sleep/resume.
  systemd.user.services.noctalia-shell = {
    description = "Noctalia Desktop Shell & Launcher Daemon";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/noctalia-shell";
      Restart = "always";
      RestartSec = 2;
    };
  };
}
