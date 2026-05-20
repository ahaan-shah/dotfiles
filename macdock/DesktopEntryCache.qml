pragma Singleton

import QtQuick
import Quickshell.Io

// Reads all .desktop files from standard locations once on startup.
// Exposes:
//   DesktopEntryCache.iconForClass(wmClass) -> "file:///path/to/icon" or ""
QtObject {
    id: root

    // Map of StartupWMClass.lowercase -> icon path
    property var _byWmClass: ({})
    // Map of app name.lowercase -> icon path (fallback)
    property var _byName: ({})

    function iconForClass(wmClass) {
        if (!wmClass || wmClass === "") return ""
        const lc = wmClass.toLowerCase()

        // 1. Exact StartupWMClass match
        if (root._byWmClass[lc]) return root._byWmClass[lc]

        // 2. Partial match — any key that contains or is contained by wmClass
        const keys = Object.keys(root._byWmClass)
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i]
            if (lc.includes(k) || k.includes(lc)) return root._byWmClass[k]
        }

        return ""
    }

    // ── Internal: run find + parse on startup ─────────────────────
    property string _buf: ""

    property var _proc: Process {
        id: findProc
        // Find all .desktop files in standard locations, print their content
        // separated by a sentinel line we can split on
        command: ["bash", "-c",
            "find /usr/share/applications ~/.local/share/applications " +
            "-name '*.desktop' 2>/dev/null | while read f; do " +
            "echo '---DESKTOP_FILE_START---'; cat \"$f\"; done"]
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._buf += data
        }
    }

    property var _conn: Connections {
        target: findProc
        function onRunningChanged() {
            if (findProc.running) return
            root._parse(root._buf)
        }
    }

    function _parse(raw) {
        const byWm   = {}
        const byName = {}

        const files = raw.split("---DESKTOP_FILE_START---")
        files.forEach(content => {
            if (!content.trim()) return

            let icon       = ""
            let wmClass    = ""
            let name       = ""

            content.split("\n").forEach(line => {
                const l = line.trim()
                if (l.startsWith("Icon="))            icon    = l.slice(5).trim()
                if (l.startsWith("StartupWMClass="))  wmClass = l.slice(15).trim()
                if (l.startsWith("Name=") && !name)   name    = l.slice(5).trim()
            })

            if (!icon) return

            // Resolve icon to a full path if it looks like a bare name
            const resolved = _resolveIconPath(icon)

            if (wmClass) byWm[wmClass.toLowerCase()]   = resolved
            if (name)    byName[name.toLowerCase()]    = resolved
        })

        root._byWmClass = byWm
        root._byName    = byName
    }

    function _resolveIconPath(icon) {
        // Already an absolute path
        if (icon.startsWith("/")) return "file://" + icon
        if (icon.startsWith("file://")) return icon

        // Bare icon name — Qt's image://icon provider handles these
        return "image://icon/" + icon
    }

    Component.onCompleted: {
        root._buf = ""
        findProc.running = true
    }
}
