{ inputs, lib, ... }:

# Personal settings (dotfiles) tracked in this repository
# =========================================================
# Hyprland, Noctalia, kitty, fish, starship and VS Code keep their settings in
# ~/.config, which a rebuild never touched. Now each of them lives in home/ in
# this repository, and home-manager links ~/.config/<name> to it.
#
# The links point at the live files in /etc/nixos/home (not read-only copies in
# the Nix store), so editing a config file, or a settings screen such as
# Noctalia's, works as before; the change just shows up in `git status`.
# Commit and push it like any other change.
#
# A name below is only linked once home/<name> is in git. To add your current
# settings the first time, run home/adopt.sh. Whatever was in ~/.config before
# is kept next to it as <name>.hm-backup.

let
  repo = "/etc/nixos"; # where this repository is checked out

  settings = [
    "hypr"
    "noctalia"
    "kitty"
    "fish"
    "starship.toml"
    "Code/User/settings.json"
    "Code/User/keybindings.json"
  ];

  tracked = builtins.filter (name: builtins.pathExists (../home + "/${name}")) settings;
in
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";

    users.haunted = { config, ... }: {
      home.stateVersion = "26.05";
      xdg.configFile = lib.genAttrs tracked (name: {
        source = config.lib.file.mkOutOfStoreSymlink "${repo}/home/${name}";
      });
    };
  };
}
