pragma Singleton

import QtQuick
import Quickshell.Io

// 1:1 port of scripts/powermenu.sh's option list + case dispatch — same
// four actions. Icon glyphs are a separate field (not baked into the label
// string like the original rofi listing did) so Finder's icon tile can
// render them properly — these MDI codepoints are outside the BMP (need a
// UTF-16 surrogate pair), and Finder previously derived tile icons via
// title.charAt(0), which only grabs the lead surrogate and renders as a
// broken glyph ("?"). Rendering the full glyph string fixes that.
QtObject {
    id: root

    readonly property var items: [
        { icon: "󰤄", label: "Sleep",    key: "sleep" },
        { icon: "󰐥", label: "Shutdown", key: "shutdown" },
        { icon: "󰜉", label: "Reboot",   key: "reboot" },
        { icon: "󰍃", label: "Logout",   key: "logout" }
    ]

    function run(key) {
        switch (key) {
        case "sleep":
            // Matches powermenu.sh's Sleep case exactly, minus `pkill rofi`
            // (no equivalent needed — Finder just closes itself on activate).
            sleepProc.command = ["bash", "-c",
                "sleep 0.2; hypridle & disown; sleep 0.1; loginctl lock-session; sleep 0.2; systemctl suspend"]
            sleepProc.running = true
            break
        case "shutdown":
            runProc.command = ["systemctl", "poweroff"]
            runProc.running = true
            break
        case "reboot":
            runProc.command = ["systemctl", "reboot"]
            runProc.running = true
            break
        case "logout":
            runProc.command = ["bash", "-c",
                "if [ \"$XDG_CURRENT_DESKTOP\" = \"Hyprland\" ]; then " +
                "hyprctl dispatch 'hl.dsp.exit()'; " +
                "elif [ \"$DESKTOP_SESSION\" = \"plasma\" ]; then " +
                "qdbus org.kde.ksmserver /KSMServer logout 0 0 0; " +
                "else pkill -KILL -u \"$USER\"; fi"]
            runProc.running = true
            break
        }
    }

    property var runProc: Process { id: runProc; running: false }
    property var sleepProc: Process { id: sleepProc; running: false }
}
