hl.bind("SUPER + I", hl.dsp.exec_cmd("/home/haunted/.local/bin/irisguardctl panel"), { description = "IrisGuard panel: /home/haunted/.local/bin/irisguardctl" })
hl.bind("SUPER + SHIFT + I", hl.dsp.exec_cmd("/home/haunted/.local/bin/irisguardctl toggle"), { description = "IrisGuard toggle: /home/haunted/.local/bin/irisguardctl" })

hl.window_rule({
    name = "irisguard-panel",
    match = { class = "^irisguard$", xwayland = false },
    float = true,
    size = { 520, 680 },
    center = true,
})
