-- Hyprland configuration migrated from hyprland.conf for Hyprland 0.57+ (Lua engine)

---------------------
---- MY PROGRAMS ----
---------------------
local terminal    = "kitty"
local browser     = "firefox"
local fileManager = "thunar"
local menu        = "/home/haunted/.local/bin/noctalia-ipc launcher toggle"

------------------
---- MONITORS ----
------------------
hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = 1.0,
})

-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------
hl.env("XCURSOR_THEME", "Bibata-Modern-Ice")
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_THEME", "Bibata-Modern-Ice")
hl.env("HYPRCURSOR_SIZE", "24")

-------------------
---- AUTOSTART ----
-------------------
hl.on("hyprland.start", function()
    hl.exec_cmd("hyprctl setcursor Bibata-Modern-Ice 24")
    hl.exec_cmd("systemctl --user start noctalia-shell.service")
    hl.exec_cmd("nm-applet --indicator")
    hl.exec_cmd("blip --background --delay 5")
end)

---------------
---- INPUT ----
---------------
hl.config({
    input = {
        kb_layout = "de",

        touchpad = {
            natural_scroll = true,
            tap_to_click = true,
            tap_and_drag = true,
            disable_while_typing = true,
        },

        touchdevice = {
            enabled = true,
            output = "eDP-1",
        },

        tablet = {
            output = "eDP-1",
        },
    },

    cursor = {
        hide_on_touch = true,
        hide_on_tablet = true,
    },

    gestures = {
        workspace_swipe_touch = true,
        workspace_swipe_touch_invert = false,
        workspace_swipe_direction_lock = true,
        workspace_swipe_cancel_ratio = 0.35,
        workspace_swipe_distance = 280,
        workspace_swipe_min_speed_to_force = 20,
    },

    general = {
        gaps_in = 1.5,
        gaps_out = 2.7,
        border_size = 1,
        col = {
            active_border = "rgba(7dd3faff)",
            inactive_border = "rgba(1e293bcc)",
        },
    },

    decoration = {
        rounding = 5,
        active_opacity = 0.95,
        inactive_opacity = 0.90,

        blur = {
            enabled = true,
            size = 5,
            passes = 2,
            vibrancy = 0.15,
            xray = true,
            special = false,
            popups = false,
        },

        shadow = {
            enabled = true,
            range = 12,
            render_power = 3,
        },
    },

    animations = {
        enabled = true,
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo = true,
    },
})

hl.gesture({
    fingers = 3,
    direction = "horizontal",
    action = "workspace",
})

--------------------
---- ANIMATIONS ----
--------------------
hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1} } })

hl.animation({ leaf = "windows",    enabled = true, speed = 5, bezier = "easeOutQuint" })
hl.animation({ leaf = "border",     enabled = true, speed = 8, bezier = "default" })
hl.animation({ leaf = "fade",       enabled = true, speed = 5, bezier = "default" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "default" })

---------------------
---- KEYBINDINGS ----
---------------------
local mainMod = "SUPER"

-- Main binds
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + B",      hl.dsp.exec_cmd(browser))
hl.bind(mainMod .. " + D",      hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + C",      hl.dsp.exec_cmd("/home/haunted/.local/bin/noctalia-ipc controlCenter toggle"))
hl.bind(mainMod .. " + N",      hl.dsp.exec_cmd("/home/haunted/.local/bin/noctalia-ipc notifications toggleHistory"))
hl.bind(mainMod .. " + Q",      hl.dsp.window.close())
hl.bind(mainMod .. " + F",      hl.dsp.window.fullscreen())
hl.bind(mainMod .. " + V",      hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + M",      hl.dsp.exec_cmd("/home/haunted/.local/bin/noctalia-ipc sessionMenu toggle"))
hl.bind(mainMod .. " + SHIFT + M", hl.dsp.exit())
hl.bind(mainMod .. " + E",      hl.dsp.exec_cmd(fileManager))

-- Screenshots
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_cmd('grim -g "$(slurp)" - | swappy -f -'))

-- Workspaces
for i = 1, 9 do
    hl.bind(mainMod .. " + " .. i,             hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. i,     hl.dsp.window.move({ workspace = i }))
end

-- Switch workspace with Super + arrow keys
hl.bind(mainMod .. " + right", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + left",  hl.dsp.focus({ workspace = "e-1" }))

-- Floating / Mango-like workflow
hl.bind(mainMod .. " + Space", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + SHIFT + Space", hl.dsp.exec_cmd('hyprctl --batch "dispatch togglefloating; dispatch resizeactive exact 75% 75%; dispatch centerwindow"'))

-- Pseudo/tile behavior
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())

-- Groups / tabbed-ish behavior
hl.bind(mainMod .. " + G", hl.dsp.group.toggle())
hl.bind(mainMod .. " + Tab", hl.dsp.group.next())

-- Mouse floating controls
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Laptop function keys
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true, repeating = true })

hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl set 5%+"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%-"), { locked = true, repeating = true })

hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

-- IRISGUARD MANAGED SHORTCUTS BEGIN
do
    local irisguard_file = io.open("/home/haunted/.config/hypr/irisguard.lua", "r")
    if irisguard_file then
        irisguard_file:close()
        dofile("/home/haunted/.config/hypr/irisguard.lua")
    end
end
-- IRISGUARD MANAGED SHORTCUTS END
