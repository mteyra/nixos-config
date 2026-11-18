# You are working on Marc's FAU cloud VM

Read this before changing anything. A repository's own `AGENTS.md` or `CLAUDE.md` adds to these rules and wins where they conflict, except for the rules about pushing and FAU's terms.

## Where you are

- An Ubuntu 26.04 virtual machine named `fau` in FAU's RRZE Compute Cloud, with 16 vCPUs, 32 GB RAM and a 200 GB disk.
- **No GPU and no screen.** GUI programs can't open here. Marc works from a NixOS laptop: over SSH and tmux, with VS Code Remote-SSH, and in his laptop's browser through port forwarding.
- **The VM is reachable only from inside FAU's network**, so Marc connects through eduVPN. You can't reach his laptop, and you must not build tunnels to it.
- Projects live in `~/projects/<repo>`. This rules file and the VM setup live in `~/nixos-config/vm/fau/` (repo `mteyra/nixos-config`).

## GitHub is the only safe copy

The VM isn't backed up, and access ends when Marc leaves FAU. Treat its disk as temporary.

- Every project is a git repository with a GitHub remote. If you start work in a folder that isn't one, ask Marc before creating the GitHub repository. Coursework and personal repositories are **private** by default.
- Commit in small, clear steps, and **push before you finish a task**, even when the work is incomplete. Use a branch if it isn't ready for the main branch.
- Before you say you're done, run `vmcheck`. It lists repositories under `~/projects` with uncommitted or unpushed work, and it has to come back clean.
- Never force-push, rewrite pushed history, or delete branches you didn't create.
- Commits are made as Marc; git is already configured for that. Don't add `Co-Authored-By` or other trailers.
- Never commit secrets (tokens, `.env` files, keys). Keep them in files listed in `.gitignore`.

## Working here

- Several agents work here (Claude Code, Codex, and VS Code's built-in assistants), sometimes in the same repository. Before starting, run `git status` and `git pull --rebase`, and never discard or overwrite changes you didn't make.
- You have `sudo`. `apt install` is fine for what a task needs; mention what you installed. Installed already: Node, Python with `uv` and `pipx`, `gh`, `ffmpeg`, `ripgrep`, `fd` (as `fdfind`), `jq`, `sqlite3`, `git-lfs`.
- **Python:** Ubuntu blocks system-wide `pip install`. Use a virtual environment per project (`python3 -m venv .venv && . .venv/bin/activate`), or `pipx` for command-line tools.
- **Long jobs** (test suites, renders, training) run inside tmux, because Marc's laptop may disconnect at any time.
- **Servers** (dev servers, Jupyter) listen on `localhost` only. Marc opens them through VS Code's port forwarding or `ssh -L`. Never open ports to the outside, change the cloud's security groups, or request public IPs.
- The laptop's own setup is not on this VM. Changes for the laptop go into `mteyra/nixos-config` and get pushed; Marc pulls and rebuilds there himself.

## FAU's terms

The VM is free because it's for study, teaching and Marc's own learning projects. Don't use it for commercial work, cryptocurrency, gaming, file sharing or anything that loads shared FAU resources unfairly. If a task looks like it crosses that line, stop and ask.
