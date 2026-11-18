{ pkgs, ... }:

# FAU remote machines: eduVPN client and SSH shortcuts
# ====================================================
#   fau          connect eduVPN if needed, then open (or reattach) the tmux
#                session "main" on the Compute Cloud VM
#   ssh fau      plain SSH to the VM, also connecting eduVPN if needed; this is
#                the host to use in VS Code Remote-SSH (alias: fau-cloud-compute)
#   fau-vpn      only make sure eduVPN is up and the VM answers; `fau-vpn off` disconnects
#   ssh cip      CS CIP pool, cip1e0 (i7-9700, 64 GB RAM, always on)
#   ssh gpu      CS CIP pool, cip4a0 (i7-8700, RTX 2080, always on)
#   ssh cipterm  CS CIP terminal server cipterm0
#
# eduVPN must have been set up once in the app (eduvpn-gui: FAU, Splittunnel);
# the scripts then reconnect that saved server (number 1) on their own.
#
# Your FAU username is deliberately not in this public repo. Add it once to
# ~/.ssh/config (read before this file, so its User wins):
#
#   Host cip gpu cipterm *.cip.cs.fau.de
#     User <your IdM username>
#
# CIP host list and SSH CA: https://wwwcip.cs.fau.de/documentation/services.en.html
# The VM's own setup and agent rules live in vm/fau/ in this repo.

let
  vmAddress = "172.17.67.63"; # RRZE Compute Cloud VM "fau", network FAU-Intern

  # fau-vpn [off]: make sure the VM answers on port 22, starting eduVPN first if
  # it doesn't; "fau-vpn off" disconnects. Messages go to stderr, because this
  # also runs inside ssh's ProxyCommand, where stdout is the SSH connection.
  #
  # The dorm network blocks eduVPN's UDP (WireGuard) mode, so this connects in
  # TCP mode (ProxyGuard). In that mode eduvpn-cli must keep running and waits
  # for a key press, so it runs in its own background session with an input
  # that never ends. Its log is in $XDG_RUNTIME_DIR/fau-vpn.log.
  fauVpn = pkgs.writeShellScriptBin "fau-vpn" ''
    cli=${pkgs.eduvpn-client}/bin/eduvpn-cli
    run="''${XDG_RUNTIME_DIR:-/tmp}/fau-vpn"

    reachable() { timeout 2 bash -c '</dev/tcp/${vmAddress}/22' 2>/dev/null; }
    # Is eduvpn-cli itself still alive? (It is the process whose ID is saved.)
    running() { [ -f "$run.pid" ] && kill -0 "$(cat "$run.pid")" 2>/dev/null; }
    stop() {
      if running; then
        kill -INT "$(cat "$run.pid")" 2>/dev/null # eduvpn-cli disconnects on Ctrl+C
        sleep 2
      fi
      # end the whole background group, including its "sleep infinity" input
      [ -f "$run.pid" ] && kill -- "-$(cat "$run.pid")" 2>/dev/null
      rm -f "$run.pid"
      # a session left over from the app or an earlier run
      if "$cli" status </dev/null 2>/dev/null | grep -q '^Connected to'; then
        "$cli" disconnect </dev/null >/dev/null 2>&1
      fi
    }

    if [ "''${1:-}" = off ]; then
      stop
      echo "eduVPN disconnected." >&2
      exit 0
    fi

    # One connection attempt at a time (VS Code opens several SSH sessions).
    exec 9>"$run.lock"
    ${pkgs.util-linux}/bin/flock 9

    reachable && exit 0

    echo "Connecting eduVPN (if a browser tab opens, log in there)..." >&2
    stop
    # setsid: its own session, so it survives the terminal or ssh that started it.
    # exec: eduvpn-cli takes over the started process, so $! is its ID.
    # shellcheck disable=SC2016
    ${pkgs.util-linux}/bin/setsid bash -c 'exec "$0" connect -n 1 --tcp < <(exec sleep infinity)' "$cli" \
      </dev/null >"$run.log" 2>&1 9>&- &
    echo $! >"$run.pid"

    for _ in $(seq 1 45); do
      if reachable; then
        echo "eduVPN connected." >&2
        exit 0
      fi
      running || break
      sleep 2
    done

    echo "Couldn't reach the FAU VM through eduVPN. Last eduVPN messages:" >&2
    grep -v 'level=DEBUG' "$run.log" | tail -n 5 >&2
    echo "If eduVPN did connect, check that the VM is running: https://cc.rrze.de" >&2
    exit 1
  '';

  # ProxyCommand for the VM: ensure the VPN, then hand ssh a plain TCP pipe.
  fauProxy = pkgs.writeShellScriptBin "fau-proxy" ''
    ${fauVpn}/bin/fau-vpn </dev/null >&2 || exit 1
    exec ${pkgs.socat}/bin/socat - "TCP:$1:$2"
  '';

  # One command: VPN, SSH, and the persistent tmux session "main".
  # TERM is set because the VM may not know kitty's terminal type.
  fau = pkgs.writeShellScriptBin "fau" ''
    ${fauVpn}/bin/fau-vpn || exit 1
    TERM=xterm-256color exec ssh -t fau tmux new -A -s main
  '';
in
{
  environment.systemPackages = [ pkgs.eduvpn-client fau fauVpn ];

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
    Host fau fau-cloud-compute
      HostName ${vmAddress}
      HostKeyAlias ${vmAddress}
      User ubuntu
      ProxyCommand ${fauProxy}/bin/fau-proxy %h %p
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
