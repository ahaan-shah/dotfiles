pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The three-way power profile picker behind SUPER+B.
//
// It goes through scripts/power-profile.sh rather than calling a daemon
// directly, because WHICH daemon answers is a property of the machine: asusd
// on this ASUS laptop, power-profiles-daemon elsewhere. Both write the same
// /sys/firmware/acpi/platform_profile, and running both is what made the
// profile appear to move on its own. The script owns that choice and speaks
// ppd's names in both directions, so `items` below did not change.
//
// Originally a 1:1 port of scripts/power_profiles.sh's `powerprofilesctl`
// picker. The original showed the active profile in the rofi prompt text
// ("Current: (balanced)"); here it's surfaced as a "current" subtitle on
// the matching row instead, since that's how Finder's row layout already
// marks state (see e.g. clipboard/app rows) — the prompt-string approach
// doesn't have an equivalent in Finder's single shared placeholder text.
QtObject {
    id: root

    // Beside the shell config, never a fixed path — the same rule (and the
    // same reasoning) as Settings.qml's scriptDir and the bar's sideScriptDir.
    // From ~/.config/shell that resolves to ~/.config/scripts; from the repo it
    // resolves to the repo's own scripts/, so a repo instance exercises the
    // repo's dispatcher with no deploy.
    readonly property string scriptDir: {
        var dir = String(Quickshell.shellDir || "").replace(/^file:\/\//, "")
        var cut = dir.lastIndexOf("/")
        return cut > 0 ? dir.substring(0, cut) + "/scripts"
                       : (Quickshell.env("HOME") || "") + "/.config/scripts"
    }

    readonly property var items: [
        { icon: "󰌪", label: "Power Saver", value: "power-saver" },
        { icon: "󰾅", label: "Balanced", value: "balanced" },
        { icon: "󰓅", label: "Performance", value: "performance" }
    ]

    property string current: ""   // "power-saver" | "balanced" | "performance"

    function refresh() {
        getProc.running = true
    }

    function set(value) {
        setProc.command = [root.scriptDir + "/power-profile.sh", "set", value]
        setProc.running = true
        // Optimistic update — avoids waiting on a second `get` round-trip
        // just to reflect a change we ourselves just made.
        root.current = value
    }

    property var getProc: Process {
        id: getProc
        command: [root.scriptDir + "/power-profile.sh", "get"]
        running: false
        stdout: StdioCollector {
            id: out
            onStreamFinished: root.current = out.text.trim()
        }
    }
    property var setProc: Process { id: setProc; running: false }

    Component.onCompleted: refresh()
}
