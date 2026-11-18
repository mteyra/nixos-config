# Manual setup: what a rebuild doesn't bring back

`nixos-rebuild` recreates everything in this repository: packages, services, the desktop, the kernel and the `fau` commands. This file lists what lives **outside** it (logins, keys, personal settings, accounts) and how to set each one up again on a new computer.

When you set something up by hand, add a line here.

## New computer, in order

### 1. NixOS and this repository

1. Install NixOS, then clone this repository to `/etc/nixos`:
   ```sh
   sudo git clone https://github.com/mteyra/nixos-config /etc/nixos
   ```
2. Replace `hardware-configuration.nix` with the new machine's own: `sudo nixos-generate-config --show-hardware-config > /etc/nixos/hardware-configuration.nix`.
3. Rebuild: `sudo nixos-rebuild switch --flake /etc/nixos#X1`. When it asks about `extra-substituters` and `extra-trusted-public-keys`, answer `y`, including "permanently mark as trusted". Otherwise Nix compiles the kernel and shell itself, which takes hours.

### 2. Personal settings

Hyprland, Noctalia, kitty, fish, starship and VS Code settings live in `home/` in this repository. The rebuild in step 1 links `~/.config` to them (`modules/home.nix`), so they come back by themselves.

To add them the first time (or after a new app's settings appear), run `bash /etc/nixos/home/adopt.sh`, follow what it prints, rebuild, then commit and push. When you change a setting later, it shows up in `git status`; commit it like any other change.

Not in the repository:

| What | How to bring it back |
| --- | --- |
| Firefox (bookmarks, logins, extensions) | sign in to Firefox Sync, or copy `~/.mozilla/` |
| Flatpak apps | on the old computer run `flatpak list --app --columns=application`, then `flatpak install flathub <id>` for each |
| Anything else in `~/.config` | run `ls ~/.config` on the old computer and copy what you need |

### 3. SSH key and GitHub

1. Make a key: `ssh-keygen -t ed25519` (press Enter at each question).
2. Log in to GitHub: `gh auth login` (GitHub.com, HTTPS, log in with a web browser).

### 4. FAU: VPN, CIP pool, cloud VM

- **eduVPN:** open `eduvpn-gui` once, search "Erlangen", choose the FAU entry under *Institute Access*, log in, and pick **Splittunnel (FAU)**. After that, `fau` and `ssh fau` connect it by themselves. Ignore the keyring warning ("Ignore warning and run client").
- **CIP pool:** your account lives at https://account.cip.cs.fau.de. Add your IdM username to `~/.ssh/config` (see `modules/fau-remote.nix`), then run `ssh-copy-id cip` for password-free logins.
- **Cloud VM:** the VM only accepts SSH keys it already knows, so a new key must be added from a computer that can still log in:
  ```sh
  ssh-copy-id -i ~/.ssh/new_key.pub fau
  ```
  Also import the new key at https://cc.rrze.de under Compute → Key Pairs, so new VMs get it. If no computer can log in anymore, the VM's web console won't help (Ubuntu cloud images have no password login): build a new VM (below), delete the old instance (its disk stays, since it isn't deleted with the instance), then attach the old disk to the new VM under Volumes → Manage Attachments and copy your files off.

### 5. VS Code

1. On the laptop, install **Remote - SSH** (Microsoft).
2. `Ctrl+Shift+P` → **Remote-SSH: Connect to Host…** → `fau`.
3. In that window, install **Python** and **Jupyter** (Microsoft). They install on the VM.

### 6. Logins for the AI agents

| Agent | On the laptop | On the VM |
| --- | --- | --- |
| Claude Code | `claude`, follow the link | the same |
| Codex | `codex`, sign in with ChatGPT | `codex login --device-auth` (enable "device code login" in ChatGPT → Settings → Security first) |
| GitHub CLI | `gh auth login` | the same |

### 7. Fitbit data (Google Health)

`modules/health.nix` installs Google's `ghealth` tool and a timer that saves your Fitbit data to `~/.local/share/health/` at 08:00 and 20:00. It needs a one-time connection to your Google account, and nothing here costs money.

1. **Create a project:** https://console.cloud.google.com → project picker → **New project** (any name, e.g. `health`). Don't add a billing account or card; if anything asks for one, stop.
2. **Turn on the API:** APIs & Services → Library → search **Google Health API** → **Enable**.
3. **Consent screen:** Google Auth Platform → **Get started**. User type **External**, your email as contact. Under **Audience**, add your own Gmail as a test user, then click **Publish app**. Published, your login lasts; left in "Testing", it expires every 7 days.
4. **Login client:** Google Auth Platform → **Clients** → **Create client** → type **Desktop app** → create, then **download the JSON**.
5. **Connect:** `ghealth setup --client-secret ~/Downloads/client_secret_*.json`. Choose the **read-only** scopes. In the browser, Google warns that the app isn't verified: that's your own app, so click **Advanced → Go to … (unsafe)** and allow.
6. **Check it works:** `ghealth data steps daily-rollup --from yesterday --to today`
7. **Fetch your history once:** `health-sync --since 2026-01-01` (use the day you started wearing the Air). After that the timer keeps it current; `systemctl --user list-timers health-sync` shows the next run.

Your login is kept in `~/.config/ghealth/`, which is not part of this repository. If it ever expires, you get a pop-up; run `ghealth auth login`.

## Rebuilding the cloud VM from scratch

If the VM is deleted, or your access ends and starts again, build a new one at https://cc.rrze.de:

1. **Compute → Key Pairs → Import Public Key:** paste `~/.ssh/id_ed25519.pub`, name it `x1`.
2. **Network → Security Groups:** create a group `ssh` with the rule "SSH".
3. **Compute → Instances → Launch Instance:**
   - Image: newest Ubuntu LTS (not Minimal)
   - Volume: 200 GB, "Delete Volume on Instance Delete" set to No
   - Flavor: `SCS-16V-32`
   - Network: `FAU-Intern`
   - Security groups: `ssh` and `default`
   - Key pair: `x1`
4. Put the new IP address into `vmAddress` in `modules/fau-remote.nix`, then rebuild.
5. On the VM (`fau`): `gh auth login`, then
   ```sh
   gh repo clone mteyra/nixos-config ~/nixos-config && bash ~/nixos-config/vm/fau/setup.sh
   ```
   Then log in to `claude` and `codex` (see above).

Anything that was only on the VM and not pushed to GitHub is gone at that point. That's why `vmcheck` exists.
