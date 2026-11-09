{ config, pkgs, lib, ... }:

# Performance & hardware tuning for the ThinkPad X1 Yoga Gen 3 (i7-8650U, UHD 620).
# Evidence for every item is recorded in ~/Projects/system-audit/audit.md (Round 2).

let
  ppctl = "${config.services.power-profiles-daemon.package}/bin/powerprofilesctl";
in
{
  # ---------------------------------------------------------------------------
  # 1. Hardware video decode (VA-API). Before: no iHD/i965 driver in
  #    /run/opengl-driver -> all video was decoded on the CPU.
  #    UHD 620 decodes H.264, HEVC (8/10-bit), VP8, VP9 (8/10-bit). NOT AV1.
  # ---------------------------------------------------------------------------
  hardware.graphics.extraPackages = with pkgs; [ intel-media-driver ];
  hardware.graphics.extraPackages32 = with pkgs.pkgsi686Linux; [ intel-media-driver ];
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # Firefox (same browser as before, now via the NixOS module so prefs are declarative).
  # AV1 is disabled so YouTube & co. serve VP9/H.264, which the GPU decodes;
  # AV1 would otherwise be decoded in software on this 4-core CPU.
  # preferencesStatus = "default": you can still flip any of these in about:config.
  programs.firefox = {
    enable = true;
    preferencesStatus = "default";
    preferences = {
      "media.ffmpeg.vaapi.enabled" = true;
      "media.hardware-video-decoding.enabled" = true;
      "media.av1.enabled" = false;
      # Stop Firefox from writing 11+ GiB/day to Btrfs on NVMe (measured in diag.log):
      # cache HTTP assets in RAM (up to 512 MiB of 16 GiB) and checkpoint session every 60s instead of 15s.
      "browser.cache.disk.enable" = false;
      "browser.cache.memory.enable" = true;
      "browser.cache.memory.capacity" = 524288;
      "browser.sessionstore.interval" = 60000;
    };
  };

  # ---------------------------------------------------------------------------
  # 2. Memory: one compressed swap layer, tuned for zram.
  #    Before: CachyOS kernel enables zswap by default; it intercepted ~530 MiB
  #    while the 7.7 GiB zram device held ~20 KiB (double layering).
  #    Values follow the kernel/Fedora/Pop!_OS guidance for zram-only swap.
  # ---------------------------------------------------------------------------
  boot.kernelParams = [ "zswap.enabled=0" ];   # effective after next reboot
  fileSystems."/".options = [ "noatime" "compress=zstd:1" ];
  systemd.services.zswap-disable = {
    description = "Disable zswap and apply Btrfs noatime+zstd at runtime";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.util-linux ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      if [ -w /sys/module/zswap/parameters/enabled ]; then
        echo N > /sys/module/zswap/parameters/enabled
      fi
      if [ -w /sys/module/zswap/parameters/shrink ]; then
        echo 1 > /sys/module/zswap/parameters/shrink 2>/dev/null || true
      fi
      mount -o remount,noatime,compress=zstd:1 / 2>/dev/null || true
    '';
  };
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;              # zram is far cheaper than dropping page cache
    "vm.page-cluster" = 0;              # no swap readahead on zram
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;  # reclaim earlier, fewer allocation stalls
  };

  # ---------------------------------------------------------------------------
  # 3. Boot: systemd-boot menu waited the default 5 s (loader phase = 5.7 s).
  #    Press any key / hold Space during boot to get the menu & older generations.
  # ---------------------------------------------------------------------------
  boot.loader.timeout = 1;
  boot.loader.systemd-boot.configurationLimit = 20;  # caps /boot entries, deletes nothing

  # ---------------------------------------------------------------------------
  # 4. Battery: 78 % health at 282 cycles. Cap charge at 90 % (owner choice),
  #    resume charging below 85 %. thinkpad_acpi stores this in the EC.
  #    To charge to 100 % once:  echo 100 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
  # ---------------------------------------------------------------------------
  systemd.services.battery-charge-threshold = {
    description = "ThinkPad BAT0 charge thresholds (85-90 %)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      b=/sys/class/power_supply/BAT0
      [ -w $b/charge_control_end_threshold ] || exit 0
      echo 90 > $b/charge_control_end_threshold
      echo 85 > $b/charge_control_start_threshold
    '';
  };

  # ---------------------------------------------------------------------------
  # 5. Power profile & EPP follow the charger.
  #    Loop-3 telemetry discovery (`laptop-report`): setting PPD `performance`
  #    on AC forced EPP=`performance`, locking all 8 threads at 3.6-4.1 GHz even
  #    at 10 % CPU load and pushing package temp to 90-94 C at idle.
  #    Using PPD `balanced` + EPP=`balance_performance` on AC lets idle cores
  #    drop to 800 MHz / C-states (cool ~60-68 C) while still boosting active
  #    threads to 3.9-4.2 GHz (44 W PL2) immediately on demand.
  #    On battery: PPD `balanced` + EPP=`balance_power`.
  # ---------------------------------------------------------------------------
  systemd.services.power-profile-auto = {
    description = "Select power profile and Intel EPP from AC state";
    after = [ "power-profiles-daemon.service" ];
    wants = [ "power-profiles-daemon.service" ];
    wantedBy = [ "power-profiles-daemon.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      sleep 1
      ${ppctl} set balanced
      if [ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" = 1 ]; then
        epp=balance_performance
      else
        epp=balance_power
      fi
      for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [ -w "$f" ] && echo "$epp" > "$f"
      done
    '';
  };
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", KERNEL=="AC", ACTION=="change", RUN+="${config.systemd.package}/bin/systemctl --no-block start power-profile-auto.service"
  '';

  # ---------------------------------------------------------------------------
  # 6. Wi-Fi stability (Intel 8265): disable aggressive Wi-Fi powersave that
  #    caused missed beacons (Aug D-4) and GTK rekey timing glitches (R2-8).
  #    Also enable IIO sensor proxy for the X1 Yoga 360° hinge & accelerometer.
  # ---------------------------------------------------------------------------
  networking.networkmanager.wifi.powersave = false;
  hardware.sensor.iio.enable = true;

  # ---------------------------------------------------------------------------
  # 7. Diagnostic tools used by the audit loop and the telemetry collector.
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    libva-utils        # vainfo
    intel-gpu-tools    # intel_gpu_top
    config.boot.kernelPackages.turbostat
    powertop
    nvme-cli
    sysstat
    iotop-c
  ];
}
