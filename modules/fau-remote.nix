{ pkgs, ... }:

# FAU remote machines: eduVPN client and SSH shortcuts
# ====================================================
#   fau          open (or reattach) the tmux session "main" on the Compute Cloud VM
#   ssh fau      plain SSH to the VM (also the host name for VS Code Remote-SSH)
#   ssh cip      CS CIP pool, cip1e0 (i7-9700, 64 GB RAM, always on)
#   ssh gpu      CS CIP pool, cip4a0 (i7-8700, RTX 2080, always on)
#   ssh cipterm  CS CIP terminal server cipterm0
#
# Your FAU username is deliberately not in this public repo. Add it once to
# ~/.ssh/config (read before this file, so its User wins):
#
#   Host cip gpu cipterm *.cip.cs.fau.de
#     User <your IdM username>
#
# eduVPN (`eduvpn-gui`, search "FAU") is needed for machines on FAU's
# internal network, such as Compute Cloud VMs. Host list and SSH CA:
# https://wwwcip.cs.fau.de/documentation/services.en.html

let
  vmAddress = "172.17.67.63"; # RRZE Compute Cloud VM "fau", network FAU-Intern

  fau = pkgs.writeShellScriptBin "fau" ''
    if ! timeout 3 bash -c '</dev/tcp/${vmAddress}/22' 2>/dev/null; then
      echo "The FAU VM isn't reachable. Connect eduVPN first (run eduvpn-gui, choose Splittunnel)."
      exit 1
    fi
    exec ssh -t fau tmux new -A -s main
  '';
in
{
  environment.systemPackages = [ pkgs.eduvpn-client fau ];

  # Trust the CIP pool's SSH certificate authority, so CIP hosts are verified
  # without a "trust this host?" prompt on each new machine.
  programs.ssh.knownHosts.fau-cip-ca = {
    certAuthority = true;
    hostNames = [
      "*.cip.cs.fau.de"
      "faui0*.cs.fau.de"
      "ircbox.cs.fau.de"
      "gitlab.cs.fau.de"
    ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPmZxYAdJDYgQOrfht7VAeb5Kk/ZFldwTvA4H7jGyABx";
  };

  programs.ssh.extraConfig = ''
    Host fau
      HostName ${vmAddress}
      User ubuntu
      ConnectTimeout 5
      ServerAliveInterval 30

    Host cip
      HostName cip1e0.cip.cs.fau.de
    Host gpu
      HostName cip4a0.cip.cs.fau.de
    Host cipterm
      HostName cipterm0.cip.cs.fau.de

    # Survive flaky Wi-Fi; reuse one connection for 10 minutes.
    Host cip gpu cipterm *.cip.cs.fau.de
      ServerAliveInterval 30
      ControlMaster auto
      ControlPath ~/.ssh/cm-%r@%h:%p
      ControlPersist 10m
  '';
}
