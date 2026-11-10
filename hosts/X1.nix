{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ../hardware-configuration.nix
    ./noctalia.nix
    ../modules/agent-bridge.nix
    ../modules/performance.nix
    ../modules/tablet-mode.nix
  ];

  services.nixcare = {
    enable = true;
    user = "haunted";
    flakePath = "/etc/nixos";
    hostName = "X1";
    clean.enable = true; # Keeps last 5 generations + last 14 days
    agentBridge.mode = "auth"; # Require password once per session (AUTH_ADMIN_KEEP)
  };

  nixpkgs.config.allowUnfree = true;
  
  nixpkgs.config.permittedInsecurePackages = [
    "electron-39.8.10"
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-bore;
  boot.kernelModules = [ "wacom" ];

  boot.kernelParams = [
    "quiet"
    "loglevel=3"
    "udev.log_level=3"
  ];

  # Identity / locale
  networking.hostName = "X1";
  time.timeZone = "Europe/Berlin";
  environment.etc."timezone".text = "Europe/Berlin\n";
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
  services.udisks2.enable = true;
  services.gvfs.enable = true;
  services.fprintd.enable = true;
  services.flatpak.enable = true;

  # Wacom touchscreen persistence & 360° hinge tablet-mode daemon are configured
  # in ../modules/tablet-mode.nix.

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
  security.rtkit.enable = true;
  programs.dconf.enable = true;
  programs.nix-ld.enable = true;

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
    NIXOS_OZONE_WL = "1";
    XCURSOR_THEME = "Bibata-Modern-Ice";
    XCURSOR_SIZE = "24";
    HYPRCURSOR_THEME = "Bibata-Modern-Ice";
    HYPRCURSOR_SIZE = "24";
  };

  environment.systemPackages = with pkgs; [
    # Core terminal tools
    vim
    neovim
    vscode
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
    jq
    zapzap
    libreoffice



    # Coding etc.
    (python3.withPackages (ps: with ps; [
      dbus-python
    ]))
    pixi
    uv
    gh
    jupyter

    # AI coding agents
    codex
    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity
    inputs.antigravity-nix.packages.${pkgs.stdenv.hostPlatform.system}.google-antigravity-cli
    google-chrome

    # Shell / prompt
    fish
    starship

    # Browser / terminal
    # firefox -> programs.firefox in modules/performance.nix
    kitty
    thunar
    thunar-archive-plugin
    tumbler
    logseq
    thunar-volman
    dosfstools
    exfatprogs
    ntfs3g
    
    # Hyprland tools
    rofi
    wl-clipboard
    grim
    slurp
    satty
    swappy
    hyprcursor
    libinput
    usbutils
    wev

    # Theme tooling
    papirus-icon-theme
    papirus-folders
    numix-icon-theme-circle
    tela-icon-theme
    bibata-cursors
    adw-gtk3
    orchis-theme
    colloid-gtk-theme
    nwg-look
    libsForQt5.qt5ct
    qt6Packages.qt6ct
    glib
    gsettings-desktop-schemas

    # GUI utilities
    gedit
    pavucontrol
    brightnessctl
    playerctl
    networkmanagerapplet
    wdisplays
    libnotify

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
    zoom-us

    pkgs.openvpn
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
