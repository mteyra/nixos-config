#!/usr/bin/env bash
# Copy your current settings from ~/.config into this repository (once), so
# home-manager can link them back and git tracks them. Safe to run again.
#
#   bash /etc/nixos/home/adopt.sh
#
# It only stages the files (git add). Nothing is committed or pushed until
# you've looked at the result, because this repository is public.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
home="$repo/home"

echo "Copying settings into $home:"
for name in hypr noctalia kitty fish starship.toml Code/User/settings.json Code/User/keybindings.json; do
  src="$HOME/.config/$name"
  if [ -L "$src" ]; then
    echo "  $name: already linked, skipped"
  elif [ ! -e "$src" ]; then
    echo "  $name: not on this computer, skipped"
  elif [ -e "$home/$name" ]; then
    echo "  $name: already in the repository, skipped"
  else
    mkdir -p "$(dirname "$home/$name")"
    cp -a "$src" "$home/$name"
    echo "  $name: copied"
  fi
done

# Re-stage from scratch, so removed secrets and newly ignored files drop out.
git -C "$repo" reset -q -- home
git -C "$repo" add home

echo
echo "Lines that look like a password, token or key (the repository is public):"
if git -C "$repo" diff --cached -U0 -- home ':!home/adopt.sh' ':!home/.gitignore' | grep -E '^\+' |
  grep -inE 'api[_-]?key|token|secret|passw|bearer|private[_-]?key'; then
  echo "  ^ Check these. Remove real secrets from the files in $home, then run this script again."
else
  echo "  none found"
fi

echo
echo "Files over 1 MB (wallpapers, caches) that probably don't belong in git:"
big=$(git -C "$repo" diff --cached --name-only -- home | while read -r f; do
  [ -f "$repo/$f" ] && [ "$(stat -c %s "$repo/$f")" -gt 1048576 ] && echo "  $f"
done || true)
echo "${big:-  none}"
[ -n "$big" ] && echo "  ^ To leave one out, add its path (relative to home/) to home/.gitignore, then run this script again."

echo
echo "Next:"
echo "  1. sudo nixos-rebuild switch --flake $repo#X1   (links ~/.config to these files)"
echo "  2. Check your desktop looks the same, then:"
echo "     cd $repo && git commit -m 'Track my personal settings' && git push"
