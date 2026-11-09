{ config, pkgs, lib, ... }:

# Agent bridge
# ------------
# AI agents run inside sandboxes with NoNewPrivs=1, so sudo cannot work there.
# This module exposes a *fixed* set of root actions as systemd units which the
# user `haunted` may start without a password (polkit rule below):
#
#   systemctl start --no-block nixos-apply-switch.service  -> nixos-rebuild switch
#   systemctl start --no-block nixos-apply-boot.service    -> nixos-rebuild boot (never reboots)
#   systemctl start agent-diag.service                     -> root-only diagnostics snapshot
#
# Output: /var/lib/agent-bridge/{switch,boot,diag}.log (world-readable).
# Security note: this is effectively passwordless root for processes running as
# `haunted` (they can already edit /etc/nixos). Accepted by owner on 2026-11-09.
# Rollback: remove ./modules/agent-bridge.nix from hosts/X1.nix and rebuild.

let
  flakeRef = "/etc/nixos#X1";
  stateDir = "/var/lib/agent-bridge";

  applyScript = mode: pkgs.writeShellScript "nixos-apply-${mode}" ''
    set -uo pipefail
    log=${stateDir}/${mode}.log
    {
      echo "=== nixos-rebuild ${mode} started $(date -Is) ==="
      echo "config commit: $(${pkgs.git}/bin/git -C /etc/nixos rev-parse --short HEAD 2>/dev/null) dirty=$(${pkgs.git}/bin/git -C /etc/nixos status --porcelain | wc -l)"
      /run/current-system/sw/bin/nixos-rebuild ${mode} --flake ${flakeRef}
      rc=$?
      echo "=== finished $(date -Is) exit=$rc ==="
      exit $rc
    } > "$log" 2>&1
  '';

  mkApply = mode: {
    description = "Agent bridge: nixos-rebuild ${mode} (${flakeRef})";
    # Never part of a boot transaction; only started on request.
    restartIfChanged = false;
    stopIfChanged = false;
    path = with pkgs; [ git config.nix.package coreutils gnutar gzip xz ];
    environment.HOME = "/root";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = applyScript mode;
      StateDirectory = "agent-bridge";
      StateDirectoryMode = "0755";
      UMask = "0022";
    };
  };

  diagScript = pkgs.writeShellScript "agent-diag" ''
    set -u
    out=${stateDir}/diag.log
    {
      echo "=== agent-diag $(date -Is) ==="
      echo "--- RAPL energy counters (uJ)"
      for z in /sys/class/powercap/intel-rapl:*; do
        echo "$(cat $z/name 2>/dev/null) $(cat $z/energy_uj 2>/dev/null)"
      done
      echo "--- MSR power/thermal (msr-tools)"
      ${pkgs.kmod}/bin/modprobe msr 2>/dev/null
      echo "MSR_PKG_POWER_LIMIT 0x610: $(${pkgs.msr-tools}/bin/rdmsr -c 0x610 2>&1)"
      echo "IA32_TEMPERATURE_TARGET 0x1a2: $(${pkgs.msr-tools}/bin/rdmsr -c 0x1a2 2>&1)"
      echo "IA32_PACKAGE_THERM_STATUS 0x1b1: $(${pkgs.msr-tools}/bin/rdmsr -c 0x1b1 2>&1)"
      echo "MSR_CORE_PERF_LIMIT_REASONS 0x64f: $(${pkgs.msr-tools}/bin/rdmsr -c 0x64f 2>&1)"
      echo "--- turbostat 10s"
      ${config.boot.kernelPackages.turbostat}/bin/turbostat --quiet --show Busy%,Bzy_MHz,Avg_MHz,PkgWatt,CorWatt,GFXWatt,PkgTmp,GFX%rc6,Pkg%pc2,Pkg%pc3,Pkg%pc6,Pkg%pc8,Pkg%pc10 --interval 10 --num_iterations 1 2>&1
      echo "--- per-process IO since start (top 20 by write_bytes)"
      for p in /proc/[0-9]*; do
        w=$(awk '/^write_bytes/{print $2}' $p/io 2>/dev/null) || continue
        r=$(awk '/^read_bytes/{print $2}' $p/io 2>/dev/null)
        [ -n "$w" ] && echo "$((w/1048576)) MiB_w $((r/1048576)) MiB_r $(cat $p/comm 2>/dev/null) pid=''${p#/proc/}"
      done | sort -rn | head -20
      echo "--- btrfs"
      ${pkgs.btrfs-progs}/bin/btrfs filesystem usage -T / 2>&1 | head -20
      echo "--- nvme smart"
      ${pkgs.nvme-cli}/bin/nvme smart-log /dev/nvme0 2>&1
      echo "--- journal errors this boot (last 60)"
      ${config.systemd.package}/bin/journalctl -b -p err --no-pager -q | tail -60
      echo "=== done $(date -Is) ==="
    } > "$out" 2>&1
  '';
in
{
  systemd.services.nixos-apply-switch = mkApply "switch";
  systemd.services.nixos-apply-boot = mkApply "boot";

  systemd.services.agent-diag = {
    description = "Agent bridge: root-only diagnostics snapshot";
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = diagScript;
      StateDirectory = "agent-bridge";
      StateDirectoryMode = "0755";
      UMask = "0022";
    };
  };

  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          subject.user == "haunted") {
        var unit = action.lookup("unit");
        var verb = action.lookup("verb");
        var allowed = ["nixos-apply-switch.service",
                       "nixos-apply-boot.service",
                       "agent-diag.service"];
        if (allowed.indexOf(unit) >= 0 && (verb == "start" || verb == "restart")) {
          return polkit.Result.YES;
        }
      }
    });
  '';

  # Let the user (and agents) read the full system journal. Takes effect on next login.
  users.users.haunted.extraGroups = [ "systemd-journal" ];
}
