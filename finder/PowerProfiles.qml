pragma Singleton

import QtQuick
import Quickshell.Io

// 1:1 port of scripts/power_profiles.sh's three-way `powerprofilesctl`
// picker. The original showed the active profile in the rofi prompt text
// ("Current: (balanced)"); here it's surfaced as a "current" subtitle on
// the matching row instead, since that's how Finder's row layout already
// marks state (see e.g. clipboard/app rows) — the prompt-string approach
// doesn't have an equivalent in Finder's single shared placeholder text.
QtObject {
    id: root

    readonly property var items: [
        { label: "Power Saver", value: "power-saver" },
        { label: "Balanced", value: "balanced" },
        { label: "Performance", value: "performance" }
    ]

    property string current: ""   // "power-saver" | "balanced" | "performance"

    function refresh() {
        getProc.running = true
    }

    function set(value) {
        setProc.command = ["powerprofilesctl", "set", value]
        setProc.running = true
        // Optimistic update — avoids waiting on a second `get` round-trip
        // just to reflect a change we ourselves just made.
        root.current = value
    }

    property var getProc: Process {
        id: getProc
        command: ["powerprofilesctl", "get"]
        running: false
        stdout: StdioCollector {
            id: out
            onStreamFinished: root.current = out.text.trim()
        }
    }
    property var setProc: Process { id: setProc; running: false }

    Component.onCompleted: refresh()
}
