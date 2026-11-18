#!/usr/bin/env bash
# Setup for the FAU Compute Cloud VM (Ubuntu). Safe to run again, and the way
# to apply changes after an update:
#
#   gh repo clone mteyra/nixos-config ~/nixos-config && bash ~/nixos-config/vm/fau/setup.sh
#   cd ~/nixos-config && git pull && bash vm/fau/setup.sh     # later updates
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"

echo "== Packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  tmux git git-lfs build-essential curl unzip zip \
  nodejs npm python3-venv python3-pip python3-dev pipx \
  gh ffmpeg sqlite3 ripgrep fd-find jq tree htop btop \
  kitty-terminfo >/dev/null

echo "== Coding agents and tools (installed once, then they update themselves)"
install_once() { # command, name, installer URL, shell
  if command -v "$1" >/dev/null 2>&1; then
    echo "   $2: already installed"
  else
    echo "   $2: installing"
    curl -fsSL "$3" | "$4" >/dev/null || echo "   $2: install failed; run this script again later"
  fi
}
install_once claude "Claude Code" https://claude.ai/install.sh bash
install_once codex "Codex" https://chatgpt.com/codex/install.sh sh
install_once uv "uv (Python projects)" https://astral.sh/uv/install.sh sh

echo "== Git: commit as Marc, push over HTTPS with the GitHub CLI login"
git config --global user.name 'HAUNTED (Marc)'
git config --global user.email '70148727+mteyra@users.noreply.github.com'
git config --global init.defaultBranch main
git config --global push.autoSetupRemote true
git lfs install --skip-repo >/dev/null
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

echo "== Agent rules (one file, placed where each agent looks)"
link() { mkdir -p "$(dirname "$1")"; ln -sfn "$here/AGENTS.md" "$1"; echo "   $1"; }
link "$HOME/.claude/CLAUDE.md"   # Claude Code
link "$HOME/.codex/AGENTS.md"    # Codex
link "$HOME/projects/AGENTS.md"  # any agent that looks in parent folders

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
echo "Done. Agents: claude, codex. Projects go in ~/projects;"
echo "run 'vmcheck' to see what isn't on GitHub yet."
