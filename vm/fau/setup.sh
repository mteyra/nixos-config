#!/usr/bin/env bash
# One-time setup for the FAU Compute Cloud VM (Ubuntu). Safe to run again.
#
#   gh repo clone mteyra/nixos-config ~/nixos-config && bash ~/nixos-config/vm/fau/setup.sh
#
# Afterwards, `cd ~/nixos-config && git pull` updates the agent rules too,
# because the files below are links into this folder.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Packages"
sudo apt-get update -qq
sudo apt-get install -y -qq tmux git build-essential nodejs npm gh ffmpeg \
  python3-venv python3-pip pipx kitty-terminfo >/dev/null

echo "== Git: commit as Marc, push over HTTPS with the GitHub CLI login"
git config --global user.name 'HAUNTED (Marc)'
git config --global user.email '70148727+mteyra@users.noreply.github.com'
git config --global init.defaultBranch main
git config --global push.autoSetupRemote true
gh auth status >/dev/null 2>&1 && gh auth setup-git || echo "   (run 'gh auth login' first, then run this script again)"

echo "== Projects folder"
mkdir -p "$HOME/projects"
for d in "$HOME"/*/; do
  name=$(basename "$d")
  case "$name" in projects|nixos-config|snap) continue ;; esac
  if [ -d "$d/.git" ] && [ ! -e "$HOME/projects/$name" ]; then
    mv "$d" "$HOME/projects/" && echo "   moved ~/$name to ~/projects/$name"
  fi
done

echo "== Agent rules (one file, linked where each agent looks)"
link() { mkdir -p "$(dirname "$1")"; ln -sfn "$here/AGENTS.md" "$1"; echo "   $1"; }
link "$HOME/.claude/CLAUDE.md"
link "$HOME/.codex/AGENTS.md"
link "$HOME/.gemini/GEMINI.md"
link "$HOME/projects/AGENTS.md"

echo "== vmcheck command, and a warning at login when work isn't pushed"
mkdir -p "$HOME/.local/bin"
ln -sfn "$here/vmcheck.sh" "$HOME/.local/bin/vmcheck"
chmod +x "$here/vmcheck.sh"
marker='# fau-vm setup'
if ! grep -qF "$marker" "$HOME/.bashrc"; then
  cat >>"$HOME/.bashrc" <<'EOF'

# fau-vm setup (from ~/nixos-config/vm/fau/setup.sh)
export PATH="$HOME/.local/bin:$PATH"
case "$-" in *i*) vmcheck -q || true ;; esac
EOF
fi

echo
echo "Done. Projects go in ~/projects; run 'vmcheck' to see what isn't on GitHub yet."
