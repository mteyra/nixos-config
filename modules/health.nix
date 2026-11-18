{ pkgs, lib, ... }:

# Fitbit (Google Health) data on this laptop
# ==========================================
# `ghealth` is Google's official command-line tool for the Google Health API,
# which replaced the Fitbit Web API (turned off on 2 November 2026).
# `health-sync` (health-sync.py) uses it to save the data as JSON files in
# ~/.local/share/health/<type>/<day>.json, for the agentic secretary.
#
# One-time setup, with your Google account: `ghealth setup` (see MANUAL-SETUP.md).
# Until that is done, the timer below does nothing.
# Your login stays in ~/.config/ghealth/ and is never part of this repository.

let
  # Pinned to the commit that was built and tested (all 5 test packages pass).
  ghealth = pkgs.buildGoModule {
    pname = "ghealth";
    version = "0.1.0-unstable-2026-07-09";
    src = pkgs.fetchFromGitHub {
      owner = "Google-Health-API";
      repo = "google-health-cli";
      rev = "9cf02743d9ca051500b7c1c181eb88a9ae8988a5";
      hash = "sha256-InH3mYQT1TuyNKzvXKiD7XmKG08a8CODUbj6EhLdJJE=";
    };
    vendorHash = "sha256-rXAoAIis/4bhzDVswVfqpWdwFN72UOGKxUcA1fbCcAo=";
    ldflags = [ "-s" "-w" "-X ghealth/internal/version.GitCommit=9cf0274" ];
    meta = {
      description = "Command-line tool for the Google Health API (Fitbit and Pixel Watch data)";
      homepage = "https://github.com/Google-Health-API/google-health-cli";
      license = lib.licenses.asl20;
      mainProgram = "ghealth";
    };
  };

  healthSync = pkgs.writers.writePython3Bin "health-sync" {
    flakeIgnore = [ "E501" ]; # long lines are fine
  } (builtins.readFile ./health-sync.py);
in
{
  environment.systemPackages = [ ghealth healthSync ];

  systemd.user.services.health-sync = {
    description = "Save recent Fitbit (Google Health) data to ~/.local/share/health";
    unitConfig.ConditionPathExists = "%h/.config/ghealth/credentials.json";
    path = [ pkgs.libnotify ];
    environment.GHEALTH = "${ghealth}/bin/ghealth";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${healthSync}/bin/health-sync";
    };
  };

  systemd.user.timers.health-sync = {
    description = "Save Fitbit data twice a day, catching up after the laptop was off";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 08,20:00:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}
