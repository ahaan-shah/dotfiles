pragma Singleton

import QtQuick
import Quickshell.Io

// 1:1 port of scripts/powermenu.sh's option list + case dispatch — same
// four actions, same nerd-font glyphs baked into the label (rendered as-is
// by Finder's row Text, same as the original rofi listing did).
QtObject {
    id: root

    readonly property var items: [
        { label: "󰤄 Sleep",    key: "sleep" },
        { label: "󰐥 Shutdown", key: "shutdown" },
        { label: "󰜉 Reboot",   key: "reboot" },
        { label: "󰍃 Logout",   key: "logout" }
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
