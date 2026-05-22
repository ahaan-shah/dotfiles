pragma Singleton

import QtQuick
import Quickshell.Io

// Reuses all the icon resolution logic learned from the dock.
QtObject {
    id: root

    property var _byWmClass: ({})
    property var _byName:    ({})

    readonly property var _aliases: ({
        "org.gnome.diskutility": "gnome-disks",
        "org.gnome.nautilus":    "org.gnome.Nautilus",
        "org.gnome.calendar":    "org.gnome.Calendar",
        "org.gnome.calculator":  "org.gnome.Calculator",
        "org.gnome.clocks":      "org.gnome.Clocks",
        "org.gnome.texteditor":  "org.gnome.TextEditor",
        "org.gnome.maps":        "org.gnome.Maps",
        "org.gnome.weather":     "org.gnome.Weather"
    })

    function iconForClass(wmClass) {
        if (!wmClass || wmClass === "") return ""
        const lc = wmClass.toLowerCase()

        if (root._aliases[lc]) return "image://icon/" + root._aliases[lc]
        if (root._byWmClass[lc]) return root._byWmClass[lc]

        const dots = lc.split(".")
        if (dots.length > 1) {
            for (let i = dots.length - 1; i >= 0; i--) {
                if (dots[i] && root._byWmClass[dots[i]])
                    return root._byWmClass[dots[i]]
            }
        }

        const keys = Object.keys(root._byWmClass)
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i]
            if (k.length < 4) continue
            if (lc.includes(k) || k.includes(lc)) return root._byWmClass[k]
        }

        if (root._byName[lc]) return root._byName[lc]
        return ""
    }

    function resolveForWindow(w) {
        const cls = w.class ?? ""

        // 1. Desktop entry cache
        let icon = iconForClass(cls)
        if (icon !== "") return icon

        // 2. Browser webapp stripping
        const browserPrefixes = ["brave-", "chrome-", "chromium-", "msedge-", "firefox-"]
        const genericSegments = new Set(["app", "www", "web", "mail", "m", "go", "get"])
        for (const p of browserPrefixes) {
            if (cls.startsWith(p)) {
                let s = cls.slice(p.length)
                s = s.replace(/__.*$/, "").replace(/[-_]+default$/i, "").toLowerCase()
                for (const part of s.split(".")) {
                    if (part && part.length >= 3 && !genericSegments.has(part))
                        return "image://icon/" + part
                }
            }
        }

        // 3. Reverse-domain last segment
        const segs = cls.split(".")
        if (segs.length > 1) return "image://icon/" + segs[segs.length - 1].toLowerCase()

        return cls ? "image://icon/" + cls : ""
    }

    property string _buf: ""

    property var _proc: Process {
        id: findProc
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
            _parse(root._buf)
            root._buf = ""
        }
    }

    function _parse(raw) {
        const byWm = {}
        const byName = {}
        const genericSegments = new Set(["app", "www", "web", "mail", "m", "go", "get"])
        const browserPrefixes = ["brave-", "chrome-", "chromium-", "msedge-", "firefox-"]

        raw.split("---DESKTOP_FILE_START---").forEach(block => {
            if (!block.trim()) return
            let icon = "", wmClass = "", name = "", exec = ""
            block.split("\n").forEach(line => {
                const l = line.trim()
                if (l.startsWith("Icon=")           && !icon)    icon    = l.slice(5).trim()
                if (l.startsWith("StartupWMClass=") && !wmClass) wmClass = l.slice(15).trim()
                if (l.startsWith("Name=")           && !name)    name    = l.slice(5).trim()
                if (l.startsWith("Exec=")           && !exec)    exec    = l.slice(5).trim()
            })
            if (!icon) return
            const resolved = icon.startsWith("/") ? "file://" + icon : "image://icon/" + icon
            if (wmClass) byWm[wmClass.toLowerCase()] = resolved
            byWm[icon.toLowerCase()] = resolved
            const iconDots = icon.split(".")
            if (iconDots.length > 1) {
                const last = iconDots[iconDots.length - 1].toLowerCase()
                if (last.length >= 3) byWm[last] = resolved
            }
            for (const p of browserPrefixes) {
                if (icon.toLowerCase().startsWith(p)) {
                    let s = icon.slice(p.length).replace(/__.*$/, "").replace(/[-_]+default$/i, "").toLowerCase()
                    for (const part of s.split(".")) {
                        if (part && part.length >= 3 && !genericSegments.has(part)) {
                            byWm[part] = resolved; break
                        }
                    }
                }
            }
            if (exec) {
                const base = exec.split(" ")[0].split("/").pop().toLowerCase()
                if (base && base.length >= 3) byWm[base] = resolved
            }
            if (name) byName[name.toLowerCase()] = resolved
        })
        root._byWmClass = byWm
        root._byName    = byName
    }

    Component.onCompleted: {
        root._buf = ""
        findProc.running = true
    }
}
