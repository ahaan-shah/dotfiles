pragma Singleton

import QtQuick
import Quickshell.Io

// Reads ~/.cache/wal/colors.json and re-reads it live whenever wal regenerates.
// Usage: WalColors.background, WalColors.color0 … WalColors.color15
QtObject {
    id: root

    // Parsed color strings (hex, e.g. "#1a1b26"). Empty until file is loaded.
    property string background: "#1a1a1a"
    property string foreground: "#eeeeee"
    property string color0:  "#1a1a1a"
    property string color1:  "#2a2a2a"
    property string color2:  "#3a3a3a"
    property string color3:  "#4a4a4a"
    property string color4:  "#5a5a5a"
    property string color5:  "#6a6a6a"
    property string color6:  "#7a7a7a"
    property string color7:  "#8a8a8a"
    property string color8:  "#9a9a9a"
    property string color9:  "#aaaaaa"
    property string color10: "#bbbbbb"
    property string color11: "#cccccc"
    property string color12: "#dddddd"
    property string color13: "#eeeeee"
    property string color14: "#f0f0f0"
    property string color15: "#ffffff"

    readonly property string _colorsPath: "/home/" + _username + "/.cache/wal/colors.json"
    readonly property string _username: Qt.application.name === "" ? "ahaan" :
        _usernameProc.stdout || "ahaan"

    // ── Read the file ─────────────────────────────────────────────
    property string _buf: ""

    property var _readProc: Process {
        id: readProc
        command: ["bash", "-c", "cat ~/.cache/wal/colors.json"]
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._buf += data
        }
    }

    property var _readConn: Connections {
        target: readProc
        function onRunningChanged() {
            if (readProc.running) return
            if (root._buf.trim() !== "") {
                root._parse(root._buf)
            }
            root._buf = ""
        }
    }

    // ── Watch for changes via inotifywait ─────────────────────────
    // Blocks until colors.json is modified, then signals us to re-read.
    // We restart the watcher after each trigger so it loops indefinitely.
    property var _watchProc: Process {
        id: watchProc
        command: ["bash", "-c",
            "inotifywait -e close_write,moved_to --quiet ~/.cache/wal/colors.json 2>/dev/null"]
        running: false
    }

    property var _watchConn: Connections {
        target: watchProc
        function onRunningChanged() {
            if (watchProc.running) return
            // File changed — re-read then restart watcher
            root._buf = ""
            readProc.running = true
            // Restart watcher after a short delay so the file is fully written
            watchRestartTimer.restart()
        }
    }

    property var _watchRestartTimer: Timer {
        id: watchRestartTimer
        interval: 300
        repeat: false
        onTriggered: watchProc.running = true
    }

    // ── Parse colors.json ─────────────────────────────────────────
    function _parse(raw) {
        try {
            const j = JSON.parse(raw)
            const c = j.colors || {}
            const s = j.special || {}

            root.background = s.background || c.color0  || root.background
            root.foreground = s.foreground || c.color15 || root.foreground

            if (c.color0)  root.color0  = c.color0
            if (c.color1)  root.color1  = c.color1
            if (c.color2)  root.color2  = c.color2
            if (c.color3)  root.color3  = c.color3
            if (c.color4)  root.color4  = c.color4
            if (c.color5)  root.color5  = c.color5
            if (c.color6)  root.color6  = c.color6
            if (c.color7)  root.color7  = c.color7
            if (c.color8)  root.color8  = c.color8
            if (c.color9)  root.color9  = c.color9
            if (c.color10) root.color10 = c.color10
            if (c.color11) root.color11 = c.color11
            if (c.color12) root.color12 = c.color12
            if (c.color13) root.color13 = c.color13
            if (c.color14) root.color14 = c.color14
            if (c.color15) root.color15 = c.color15
        } catch (e) {
            console.warn("WalColors: failed to parse colors.json:", e)
        }
    }

    Component.onCompleted: {
        root._buf = ""
        readProc.running = true
        watchProc.running = true
    }
}
