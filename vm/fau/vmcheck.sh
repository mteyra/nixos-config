#!/usr/bin/env bash
# List git repositories under ~/projects (and ~/nixos-config) whose work isn't
# safely on GitHub: uncommitted changes, unpushed commits, or no upstream.
# Exit status 1 if anything needs attention. "vmcheck -q" prints nothing when clean.

quiet=false
[ "${1:-}" = "-q" ] && quiet=true

problems=()

for repo in "$HOME"/projects/*/ "$HOME"/nixos-config/; do
  [ -d "$repo" ] || continue
  name=$(basename "$repo")
  if [ ! -d "$repo/.git" ]; then
    problems+=("$name: not a git repository")
    continue
  fi
  changed=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
  [ "$changed" -gt 0 ] && problems+=("$name: $changed uncommitted change(s)")
  if git -C "$repo" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    ahead=$(git -C "$repo" rev-list --count '@{upstream}..HEAD' 2>/dev/null)
    [ "${ahead:-0}" -gt 0 ] && problems+=("$name: $ahead unpushed commit(s)")
  else
    problems+=("$name: branch $(git -C "$repo" branch --show-current) was never pushed")
  fi
done

if [ "${#problems[@]}" -gt 0 ]; then
  echo "Not yet on GitHub (only on this VM):"
  printf '  %s\n' "${problems[@]}"
  exit 1
fi
$quiet || echo "All projects are committed and pushed."
exit 0
