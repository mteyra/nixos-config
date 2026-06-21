{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ../hardware-configuration.nix
    ./noctalia.nix
  ];

  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Identity / locale
  networking.hostName = "X1";
  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "de";
  services.xserver.xkb.layout = "de";

  # Network / laptop basics
  networking.networkmanager.enable = true;
  services.resolved.enable = true;

  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  services.fwupd.enable = true;
  services.thermald.enable = true;
  services.upower.enable = true;
  services.power-profiles-daemon.enable = true;
  services.libinput.enable = true;

  zramSwap = {
    enable = true;
    memoryPercent = 50;
    priority = 100;
    algorithm = "zstd";
  };

  # Graphics / audio
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  security.polkit.enable = true;
  programs.dconf.enable = true;

  # Minimal ASCII/TUI login manager
  services.displayManager.ly.enable = true;

  # Hyprland
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-gtk
    ];
  };

  # Shell / prompt
  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      starship init fish | source
    '';
  };

  users.users.haunted = {
    isNormalUser = true;
    description = "haunted";
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "audio"
      "input"
    ];
  };

  # Gaming basics
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
  };

  environment.sessionVariables = {
    XCURSOR_THEME = "Bibata-Modern-Ice";
    XCURSOR_SIZE = "24";
    HYPRCURSOR_THEME = "Bibata-Modern-Ice";
    HYPRCURSOR_SIZE = "24";
  };

  environment.systemPackages = with pkgs; [
    # Core terminal tools
    vim
    nano
    wget
    curl
    git
    tree
    unzip
    file-roller
    fastfetch
    btop
    bat
    eza
    fd
    ripgrep
    fzf

    # Shell / prompt
    fish
    starship

    # Browser / terminal
    firefox
    kitty
    thunar
    xfce.thunar-archive-plugin
    xfce.tumbler

    # Hyprland tools
    rofi
    wl-clipboard
    grim
    slurp
    satty
    swappy
    hyprcursor

    # Theme tooling
    papirus-icon-theme
    numix-icon-theme-circle
    bibata-cursors
    adw-gtk3
    nwg-look
    libsForQt5.qt5ct
    qt6Packages.qt6ct
    glib

    # GUI utilities
    gedit
    pavucontrol
    brightnessctl
    playerctl
    networkmanagerapplet

    # Finley-ish fun/monitoring
    cava
    cmatrix

    # Media / creator
    vlc
    ffmpeg-full
    obs-studio
    kdePackages.kdenlive

    # Social / gaming
    vesktop
    protonplus
  ];

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    spleen
    inter
    fira-sans
    font-awesome
    noto-fonts
    noto-fonts-color-emoji
  ];

  system.stateVersion = "26.05";
}
