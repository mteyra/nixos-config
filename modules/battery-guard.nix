{ pkgs, ... }:

# Low-battery warnings and a safe shutdown
# ========================================
# Before: no warning at all, and UPower's default last step was "hybrid sleep"
# at 2 %, which needs a swap disk. This laptop has only zram (no swap disk), so
# that step couldn't work and the battery simply ran flat mid-task.
#
# Now:
#   20 %  pop-up "Battery at 20 %"
#   10 %  urgent pop-up "Plug in now"
#    5 %  urgent pop-up "Shutting down soon"
#    4 %  UPower powers off cleanly (open files closed, no half-done updates)
#
# Pop-ups appear once per drop while discharging and reset when you plug in.
# Test a pop-up:  notify-send -u critical "Test" "Pop-ups work"

let
  battery = "/sys/class/power_supply/BAT0";

  batteryWarnings = pkgs.writeShellScript "battery-warnings" ''
    notify() { ${pkgs.libnotify}/bin/notify-send -a Battery -i battery-caution "$@"; }
    last=100
    while true; do
      level=$(cat ${battery}/capacity 2>/dev/null || echo 100)
      state=$(cat ${battery}/status 2>/dev/null || echo Unknown)
      if [ "$state" = Discharging ]; then
        if [ "$level" -le 5 ] && [ "$last" -gt 5 ]; then
          notify -u critical "Battery at $level %" "Shutting down soon. Plug in now to keep working."
        elif [ "$level" -le 10 ] && [ "$last" -gt 10 ]; then
          notify -u critical "Battery at $level %" "Plug in now. The laptop shuts down by itself at 4 %."
        elif [ "$level" -le 20 ] && [ "$last" -gt 20 ]; then
          notify -u normal "Battery at $level %" "Time to find a charger."
        fi
        last=$level
      else
        last=100
      fi
      sleep 60
    done
  '';
in
{
  services.upower = {
    enable = true;
    usePercentageForPolicy = true;
    percentageLow = 20;
    percentageCritical = 10;
    percentageAction = 4;
    criticalPowerAction = "PowerOff";
  };

  systemd.user.services.battery-warnings = {
    description = "Low-battery pop-ups at 20, 10 and 5 %";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = batteryWarnings;
      Restart = "always";
      RestartSec = 10;
    };
  };
}
