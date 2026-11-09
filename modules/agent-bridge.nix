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
      chown -R haunted:users /etc/nixos/.git 2>/dev/null || true
      ${pkgs.util-linux}/bin/runuser -u haunted -- ${pkgs.git}/bin/git -C /etc/nixos add -A 2>/dev/null || true
      echo "config commit: $(${pkgs.git}/bin/git -C /etc/nixos rev-parse --short HEAD 2>/dev/null) dirty=$(${pkgs.git}/bin/git -C /etc/nixos status --porcelain | wc -l)"
      /run/current-system/sw/bin/nixos-rebuild ${mode} --flake ${flakeRef}
      rc=$?
      if [ "$rc" -eq 0 ]; then
        ${pkgs.util-linux}/bin/runuser -u haunted -- ${pkgs.git}/bin/git -C /etc/nixos add -A 2>/dev/null || true
        if ! ${pkgs.util-linux}/bin/runuser -u haunted -- ${pkgs.git}/bin/git -C /etc/nixos diff --cached --quiet 2>/dev/null; then
          ${pkgs.util-linux}/bin/runuser -u haunted -- ${pkgs.git}/bin/git \
            -c user.name="haunted" -c user.email="haunted@X1" \
            -C /etc/nixos commit -m "nixos-rebuild ${mode}: $(date -Iseconds)" || true
        fi
      fi
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
      echo "--- vainfo (DRM renderD128)"
      LIBVA_DRIVER_NAME=iHD ${pkgs.libva-utils}/bin/vainfo --display drm --device /dev/dri/renderD128 2>&1
      echo "--- turbostat 10s + per-process IO rate over the same 10s"
      snap() { for p in /proc/[0-9]*; do
          w=$(${pkgs.gawk}/bin/awk '/^write_bytes/{print $2}' $p/io 2>/dev/null)
          [ -n "$w" ] && echo "''${p#/proc/} $w $(tr -d ' ' < $p/comm 2>/dev/null)"
        done | sort -k1,1; }
      snap > /tmp/agent-diag.io1
      ${pkgs.linuxPackages.turbostat}/bin/turbostat --quiet --Summary --show Busy%,Bzy_MHz,Avg_MHz,PkgWatt,CorWatt,GFXWatt,PkgTmp,GFX%rc6,Pkg%pc2,Pkg%pc6 --interval 10 --num_iterations 1 2>&1
      snap > /tmp/agent-diag.io2
      echo "--- top writers during sample (KiB/s)"
      join /tmp/agent-diag.io1 /tmp/agent-diag.io2 \
        | ${pkgs.gawk}/bin/awk '{d=($4-$2)/10240; if (d>0) printf "%9.1f KiB/s %s pid=%s\n", d, $3, $1}' \
        | sort -rn | head -15
      echo "--- top writers since process start (MiB)"
      ${pkgs.gawk}/bin/awk '{printf "%9d MiB %s pid=%s\n", $2/1048576, $3, $1}' /tmp/agent-diag.io2 | sort -rn | head -15
      rm -f /tmp/agent-diag.io1 /tmp/agent-diag.io2
      echo "--- btrfs device stats / commit"
      ${pkgs.btrfs-progs}/bin/btrfs device stats / 2>&1
      grep -E ' / | /home ' /proc/mounts
      echo "--- btrfs"
      ${pkgs.btrfs-progs}/bin/btrfs filesystem usage -T / 2>&1 | head -20
      echo "--- nvme smart"
      ${pkgs.nvme-cli}/bin/nvme smart-log /dev/nvme0 2>&1
      echo "--- wacom / usb / tablet kernel log"
      ${config.systemd.package}/bin/journalctl -b -k --no-pager -q | grep -E -i 'wacom|056a|5144|usb 1-10|tablet|hinge|xhci' | tail -60
      echo "--- journal errors this boot (last 60)"
      ${config.systemd.package}/bin/journalctl -b -p err --no-pager -q | grep -v 'Ignoring duplicate name' | tail -60
      echo "=== done $(date -Is) ==="
    } > "$out" 2>&1
  '';
  polkitVerdict =
    if config.services.nixcare.agentBridge.mode == "open" then "polkit.Result.YES"
    else if config.services.nixcare.agentBridge.mode == "auth" then "polkit.Result.AUTH_ADMIN_KEEP"
    else "polkit.Result.AUTH_ADMIN";
in
{
  systemd.services.nixos-apply-switch = mkApply "switch";
  systemd.services.nixos-apply-boot = mkApply "boot";

  systemd.services.agent-diag = {
    description = "Agent bridge: root-only diagnostics snapshot";
    restartIfChanged = false;
    path = with pkgs; [ coreutils gawk gnugrep procps util-linux ];
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
          return ${polkitVerdict};
        }
      }
    });
  '';

  # Let the user (and agents) read the full system journal. Takes effect on next login.
  users.users.haunted.extraGroups = [ "systemd-journal" ];
}
