{ pkgs, ... }:

# Laptop screen time on the iPhone home screen (MP8)
# ===================================================
# Every 15 minutes, `laptop-widget-push` (laptop-widget-push.py) sends today's
# active time and top 3 app names to the Cloudflare Worker of
# github.com/mteyra/laptop-widget, which the Scriptable widget reads.
# No window titles, URLs or sites leave the laptop.
#
# The token is read at run time from ~/.secrets/laptop-widget.token (chmod 600),
# so it is never in the Nix store or this repository. Until that file exists,
# the timer does nothing.
#
# Check:  systemctl --user list-timers laptop-widget-push
#         journalctl --user -u laptop-widget-push -n 20
#         laptop-widget-push --print      (shows what would be sent)

let
  push = pkgs.writers.writePython3Bin "laptop-widget-push" {
    flakeIgnore = [ "E501" ]; # long lines are fine
  } (builtins.readFile ./laptop-widget-push.py);

  environment = [
    "LAPTOP_REPORT=/run/current-system/sw/bin/laptop-report" # from nixcare
    "LAPTOP_WIDGET_URL=https://laptop-widget.mteyra.workers.dev/laptop"
  ];
in
{
  home-manager.users.haunted = {
    home.packages = [ push ];

    systemd.user.services.laptop-widget-push = {
      Unit = {
        Description = "Send today's laptop screen time to the iPhone widget";
        ConditionPathExists = "%h/.secrets/laptop-widget.token";
        # Right after waking up the Wi-Fi may not be back yet: retry a few times.
        StartLimitIntervalSec = "10min";
        StartLimitBurst = 4;
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${push}/bin/laptop-widget-push";
        Environment = environment;
        Restart = "on-failure";
        RestartSec = "1min";
      };
    };

    systemd.user.timers.laptop-widget-push = {
      Unit.Description = "Laptop widget every 15 min, catching up after sleep";
      Timer = {
        OnCalendar = "*:0/15";
        # Runs once right away if a time was missed while the laptop was off;
        # calendar times missed during suspend fire on resume anyway.
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
