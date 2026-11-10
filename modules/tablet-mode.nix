{ config, lib, pkgs, ... }:

# ThinkPad X1 Yoga Gen 3 — Touchscreen Persistence & 360° Tablet-Mode Daemon
# ==========================================================================
# Fixes two hardware-specific issues on the ThinkPad X1 Yoga 3rd Gen (20LGS0GG00):
#
# 1. Wacom Touchscreen & Pen (056a:5144 on xHCI port usb1-port10 / ACPI HS10)
#    dropping off USB after lid close or S3 deep suspend:
#    - Root cause (found in journalctl kernel logs):
#      a) On the X1 Yoga Gen 3, the BIOS ACPI _UPC table erroneously declares
#         usb1-port10 (HS10) as `connect_type = not used`, and its port-level
#         runtime PM (`usb1-port10/power/control`) defaults to `auto`.
#      b) When the lid closes, the ThinkPad EC cuts power to the display panel's
#         Wacom digitizer (`usb 1-10: USB disconnect`). If the laptop then
#         suspends to S3 (`deep`) while the lid is closed (e.g., when unplugging
#         a dock) and later wakes when the lid opens, Linux's default
#         `button.lid_init_state=method` does not force an explicit ACPI `_LID`
#         open evaluation, leaving the EC digitizer rail powered off, or
#         failing warm USB resume without `USB_QUIRK_RESET_RESUME`.
#    - Fixes:
#      * `button.lid_init_state=open`: forces ACPI `_LID` open state notification
#        on every resume so the EC restores power to the Wacom panel rail.
#      * `usbcore.quirks=056a:5144:k`: enables `USB_QUIRK_RESET_RESUME` for the
#        Wacom sensor so xHCI always performs a reset-resume.
#      * Port-level udev rules on `usb1-port10` (`power/control="on"`,
#        `quirks="00000006"` for `NO_AUTOSUSPEND | FAST_RECONNECT`) in addition
#        to device-level rules on `056a:5144`.
#      * Resume & lid-open recovery script that re-enables port10 and re-binds
#        the `wacom` kernel driver if needed.
#
# 2. 360° Hinge / Tent / Tablet Mode Automatic Keyboard, Touchpad & TrackPoint
#    Disable (`tablet-hinge-guard.service` + `tablet-mode-toggle` CLI):
#    - Root cause: The 360° hinge angle is reported by the Intel Integrated
#      Sensor Hub (`hid_sensor_custom_intel_hinge`) at
#      `/sys/bus/iio/devices/iio:device*/in_angl0_raw` (0..360 degrees), while
#      `thinkpad_acpi/hotkey_tablet_mode` stays 0 on Linux.
#    - Fix: A lightweight user daemon polls the IIO hinge angle sensor (and
#      `hotkey_tablet_mode`) every 250ms and uses Hyprland's IPC
#      (`hyprctl --batch`) to disable `at-translated-set-2-keyboard`,
#      `synps/2-synaptics-touchpad`, and `tpps/2-elan-trackpoint` whenever
#      `hinge_angle >= 190°` (tent/stand/tablet mode), and re-enables them when
#      folded back to laptop mode (`1° <= hinge_angle <= 175°`).

let
  hyprctl = "${config.programs.hyprland.package}/bin/hyprctl";
  notifySend = "${pkgs.libnotify}/bin/notify-send";

  enableInternalInputsScript = pkgs.writeShellScript "enable-internal-inputs" ''
    uid="$(id -u)"
    for d in /run/user/"$uid"/hypr/*; do
      [ -S "$d/.socket.sock" ] || continue
      sig="$(basename "$d")"
      ${hyprctl} --instance "$sig" --batch "\
        keyword device[at-translated-set-2-keyboard]:enabled true ; \
        keyword device[synps/2-synaptics-touchpad]:enabled true ; \
        keyword device[tpps/2-elan-trackpoint]:enabled true" >/dev/null 2>&1 || true
    done
  '';

  wacomRecoverScript = pkgs.writeShellScript "wacom-touch-recover" ''
    set -u
    port="/sys/bus/usb/devices/usb1/1-0:1.0/usb1-port10"
    if [ -d "$port" ]; then
      [ -w "$port/power/control" ] && echo on > "$port/power/control" 2>/dev/null || true
      [ -w "$port/quirks" ] && echo 00000006 > "$port/quirks" 2>/dev/null || true
      [ -w "$port/disable" ] && [ "$(cat "$port/disable" 2>/dev/null)" = "1" ] && echo 0 > "$port/disable" 2>/dev/null || true
    fi

    # Helper to check if Wacom 056a:5144 is present on USB bus
    check_wacom() {
      for dev in /sys/bus/usb/devices/*; do
        [ -r "$dev/idVendor" ] || continue
        if [ "$(cat "$dev/idVendor" 2>/dev/null)" = "056a" ] && [ "$(cat "$dev/idProduct" 2>/dev/null)" = "5144" ]; then
          [ -w "$dev/power/control" ] && echo on > "$dev/power/control" 2>/dev/null || true
          [ -w "$dev/power/autosuspend_delay_ms" ] && echo -1 > "$dev/power/autosuspend_delay_ms" 2>/dev/null || true
          return 0
        fi
      done
      return 1
    }

    if check_wacom; then
      ${pkgs.kmod}/bin/modprobe wacom 2>/dev/null || true
      exit 0
    fi

    # If lid is open and Wacom 056a:5144 is missing after lid close / S3 sleep,
    # invoke the ThinkPad X1 Yoga Gen 3 EC lid-open ACPI query (\_SB.PCI0.LPCB.EC._Q2A)
    # to re-enable the 3.3V Wacom digitizer power rail.
    lid_state="$(cat /proc/acpi/button/lid/LID/state 2>/dev/null || true)"
    if echo "$lid_state" | grep -q "open"; then
      if [ ! -e /proc/acpi/call ]; then
        ${pkgs.kmod}/bin/modprobe acpi_call 2>/dev/null || true
      fi
      if [ ! -e /proc/acpi/call ] && [ "$(uname -r)" = "7.1.1-cachyos" ]; then
        ${pkgs.kmod}/bin/insmod /nix/store/36z6mi6yxin9cgd59n5c2qxsifa2q8bg-acpi-call-1.2.2-7.1.1/lib/modules/7.1.1-cachyos/misc/acpi_call.ko 2>/dev/null || true
      fi
      if [ -w /proc/acpi/call ]; then
        echo '\_SB.PCI0.LPCB.EC._Q2A' > /proc/acpi/call 2>/dev/null || true
        sleep 1.5
      fi

      if ! check_wacom && [ -w "$port/disable" ]; then
        echo 1 > "$port/disable" 2>/dev/null || true
        sleep 0.5
        echo 0 > "$port/disable" 2>/dev/null || true
        sleep 1
        check_wacom || true
      fi
    fi

    ${pkgs.kmod}/bin/modprobe wacom 2>/dev/null || true
  '';

  wacomLidWatchdogScript = pkgs.writeShellScript "wacom-lid-watchdog" ''
    set -u
    while true; do
      if [ ! -e /sys/bus/usb/devices/1-10 ]; then
        lid_state="$(cat /proc/acpi/button/lid/LID/state 2>/dev/null || true)"
        if echo "$lid_state" | grep -q "open"; then
          ${wacomRecoverScript} || true
          sleep 12
        fi
      fi
      sleep 3
    done
  '';

  tabletHingeDaemonPy = pkgs.writeText "tablet-hinge-daemon.py" ''
    #!/usr/bin/env python3
    import glob
    import os
    import subprocess
    import time

    DEVICES = [
        "at-translated-set-2-keyboard",
        "synps/2-synaptics-touchpad",
        "tpps/2-elan-trackpoint",
    ]

    TABLET_ENTER_DEG = 190
    LAPTOP_ENTER_DEG = 175
    POLL_INTERVAL_SEC = 0.25
    OVERRIDE_FILE = f"/run/user/{os.getuid()}/tablet-mode-override"
    STATE_FILE = f"/run/user/{os.getuid()}/tablet-mode-state"


    def find_hinge_angle_path():
        for dev in sorted(glob.glob("/sys/bus/iio/devices/iio:device*")):
            try:
                with open(os.path.join(dev, "name"), "r") as f:
                    name = f.read().strip()
                if name == "hinge":
                    candidate = os.path.join(dev, "in_angl0_raw")
                    if os.path.exists(candidate):
                        return candidate
            except OSError:
                continue
        return None


    def read_int(path):
        if not path:
            return None
        try:
            with open(path, "r") as f:
                return int(f.read().strip())
        except (OSError, ValueError):
            return None


    def read_override():
        try:
            with open(OVERRIDE_FILE, "r") as f:
                val = f.read().strip().lower()
                if val in ("tablet", "laptop"):
                    return val
        except OSError:
            pass
        return "auto"


    def write_state(mode, angle, override):
        try:
            with open(STATE_FILE, "w") as f:
                f.write(f"mode={mode}\nangle={angle}\noverride={override}\n")
        except OSError:
            pass


    def find_hypr_instances():
        uid = os.getuid()
        instances = []
        for d in sorted(glob.glob(f"/run/user/{uid}/hypr/*")):
            if os.path.exists(os.path.join(d, ".socket.sock")):
                instances.append(os.path.basename(d))
        return instances


    def set_inputs_enabled(enabled: bool):
        val = "true" if enabled else "false"
        batch_cmd = " ; ".join(
            f"keyword device[{dev}]:enabled {val}" for dev in DEVICES
        )
        instances = find_hypr_instances()
        if not instances:
            env_sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
            if env_sig:
                instances = [env_sig]
        if not instances:
            return False
        ok = False
        for sig in instances:
            try:
                res = subprocess.run(
                    ["${hyprctl}", "--instance", sig, "--batch", batch_cmd],
                    capture_output=True,
                    text=True,
                    timeout=3,
                )
                if res.returncode == 0:
                    ok = True
            except Exception:
                continue
        return ok


    def notify(title, body):
        try:
            subprocess.Popen(
                [
                    "${notifySend}",
                    "-a",
                    "ThinkPad Yoga Hinge",
                    "-u",
                    "low",
                    "-t",
                    "2500",
                    "-h",
                    "string:x-canonical-private-synchronous:tablet-mode",
                    title,
                    body,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            pass


    def main():
        hinge_path = find_hinge_angle_path()
        tp_tablet_path = "/sys/devices/platform/thinkpad_acpi/hotkey_tablet_mode"
        current_mode = None  # "laptop" or "tablet"
        last_enforce = 0.0

        while True:
            if not hinge_path or not os.path.exists(hinge_path):
                hinge_path = find_hinge_angle_path()

            angle = read_int(hinge_path)
            tp_tablet = read_int(tp_tablet_path)
            override = read_override()

            desired_mode = current_mode
            if override == "tablet":
                desired_mode = "tablet"
            elif override == "laptop":
                desired_mode = "laptop"
            else:
                if tp_tablet == 1 or (angle is not None and angle >= TABLET_ENTER_DEG):
                    desired_mode = "tablet"
                elif angle is not None and 1 <= angle <= LAPTOP_ENTER_DEG and tp_tablet != 1:
                    desired_mode = "laptop"
                elif current_mode is None:
                    desired_mode = "laptop"

            now = time.monotonic()
            # Apply immediately on transition, or re-enforce every 30s in case Hyprland reloaded config
            if desired_mode != current_mode or (now - last_enforce >= 30.0):
                enabled = desired_mode != "tablet"
                if set_inputs_enabled(enabled):
                    last_enforce = now
                    if desired_mode != current_mode and current_mode is not None:
                        deg_str = f"{angle}°" if angle is not None else "sensor"
                        if desired_mode == "tablet":
                            notify(
                                f"Tablet Mode ({deg_str})",
                                "Internal keyboard, touchpad & TrackPoint disabled",
                            )
                        else:
                            notify(
                                f"Laptop Mode ({deg_str})",
                                "Internal keyboard, touchpad & TrackPoint enabled",
                            )
                    current_mode = desired_mode
                    write_state(current_mode, angle, override)

            time.sleep(POLL_INTERVAL_SEC)


    if __name__ == "__main__":
        main()
  '';

  tabletModeToggleCli = pkgs.writeScriptBin "tablet-mode-toggle" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    uid="$(id -u)"
    override_file="/run/user/$uid/tablet-mode-override"
    state_file="/run/user/$uid/tablet-mode-state"

    cmd="''${1:-status}"
    case "$cmd" in
      on|tablet)
        echo "tablet" > "$override_file"
        echo "Forced Tablet Mode (internal keyboard, touchpad & TrackPoint disabled)."
        ;;
      off|laptop)
        echo "laptop" > "$override_file"
        echo "Forced Laptop Mode (internal keyboard, touchpad & TrackPoint enabled)."
        ;;
      auto)
        rm -f "$override_file"
        echo "Returned to Automatic 360° Hinge Mode."
        ;;
      status)
        for d in /sys/bus/iio/devices/iio:device*; do
          if [ "$(cat "$d/name" 2>/dev/null)" = "hinge" ]; then
            echo "Live Hinge Angle (in_angl0_raw): $(cat "$d/in_angl0_raw" 2>/dev/null)°"
            echo "Live Screen Angle (in_angl1_raw): $(cat "$d/in_angl1_raw" 2>/dev/null)°"
            echo "Live Base Angle (in_angl2_raw):   $(cat "$d/in_angl2_raw" 2>/dev/null)°"
          fi
        done
        if [ -f "$state_file" ]; then
          cat "$state_file"
        fi
        ;;
      *)
        echo "Usage: tablet-mode-toggle [status|auto|on|off]"
        exit 1
        ;;
    esac
  '';
in
{
  # 1. Kernel parameters & acpi_call module for ThinkPad X1 Yoga Gen 3 EC _Q2A digitizer wake
  boot.kernelParams = [
    "button.lid_init_state=open"
    "usbcore.quirks=056a:5144:k"
  ];
  boot.extraModulePackages = [ config.boot.kernelPackages.acpi_call ];
  boot.kernelModules = [ "acpi_call" ];

  # 2. Udev rules for both the parent xHCI root hub port (usb1-port10) and the Wacom device (056a:5144)
  services.udev.extraRules = ''
    # Keep xHCI root hub port 10 (ACPI HS10 -> Wacom digitizer) permanently powered and fast-reconnecting
    ACTION=="add|change", SUBSYSTEM=="usb", KERNEL=="usb1-port10", TEST=="power/control", ATTR{power/control}="on"
    ACTION=="add|change", SUBSYSTEM=="usb", KERNEL=="usb1-port10", TEST=="quirks", ATTR{quirks}="00000006"

    # Keep Wacom Pen and multitouch sensor (056a:5144) out of USB runtime autosuspend
    ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="056a", ATTR{idProduct}=="5144", TEST=="power/control", ATTR{power/control}="on"
    ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="056a", ATTR{idProduct}=="5144", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="-1"
  '';

  # 3. Boot & post-resume enforcement for ThinkPad X1 Yoga Gen 3 Wacom touchscreen (\_SB.PCI0.LPCB.EC._Q2A)
  systemd.services.wacom-touch-recover = {
    description = "Ensure ThinkPad X1 Yoga Wacom touchscreen port (usb1-port10) and EC _Q2A rail are active";
    after = [
      "multi-user.target"
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];
    wantedBy = [
      "multi-user.target"
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = wacomRecoverScript;
    };
  };

  # 3b. Lid-open watchdog (handles docked lid close/open where suspend.target does not fire)
  systemd.services.wacom-lid-watchdog = {
    description = "Watch ThinkPad X1 Yoga lid state and wake Wacom digitizer if missing when lid is open";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = wacomLidWatchdogScript;
      Restart = "always";
      RestartSec = 5;
    };
  };

  # 4. User daemon for 360° Hinge -> Tablet Mode input auto-disable in Hyprland
  systemd.user.services.tablet-hinge-guard = {
    description = "ThinkPad X1 Yoga 360-degree hinge auto-disable for internal keyboard/touchpad/TrackPoint";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 -u ${tabletHingeDaemonPy}";
      ExecStopPost = enableInternalInputsScript;
      Restart = "always";
      RestartSec = 2;
    };
  };

  # 5. CLI helper (`tablet-mode-toggle status|auto|on|off`)
  environment.systemPackages = [
    tabletModeToggleCli
  ];
}
