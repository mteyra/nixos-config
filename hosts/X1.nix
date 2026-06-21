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
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-bore;
  boot.kernelModules = [ "wacom" ];

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

  # The internal X1 Yoga Wacom touch/pen sensor has dropped off USB after
  # suspend on this machine. Keep it out of runtime autosuspend when present.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="056a", ATTR{idProduct}=="5144", TEST=="power/control", ATTR{power/control}="on"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="056a", ATTR{idProduct}=="5144", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="-1"
  '';

  powerManagement.resumeCommands = ''
    for dev in /sys/bus/usb/devices/*; do
      [ -r "$dev/idVendor" ] || continue
      [ "$(cat "$dev/idVendor")" = "056a" ] || continue
      [ "$(cat "$dev/idProduct")" = "5144" ] || continue
      [ -w "$dev/power/control" ] && echo on > "$dev/power/control"
      [ -w "$dev/power/autosuspend_delay_ms" ] && echo -1 > "$dev/power/autosuspend_delay_ms"
    done
  '';

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
    neovim
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

    # Shell / prompt
    fish
    starship

    # Browser / terminal
    firefox
    kitty
    thunar
    thunar-archive-plugin
    tumbler

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
