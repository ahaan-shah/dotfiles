pragma Singleton

import QtQuick
import Quickshell.Io

// Parses .desktop files once at startup and exposes a fuzzy-searchable app list.
// Launching goes through `gio launch <path>` rather than hand-parsing Exec=,
// since gio already handles %U/%f field-code substitution, Terminal=true
// wrapping, and StartupNotify the way a real app launcher would.
QtObject {
    id: root

    property var apps: []   // [{name, comment, icon, iconPath, path}]

    property string _buf: ""

    property var _proc: Process {
        id: findProc
        command: ["bash", "-c",
            "find /usr/share/applications ~/.local/share/applications " +
            "-name '*.desktop' 2>/dev/null | while read f; do " +
            "echo '---DESKTOP_FILE_START---'; echo \"PATH=$f\"; cat \"$f\"; done"]
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
            root._buf = ""
        }
    }

    function _parse(raw) {
        const files = raw.split("---DESKTOP_FILE_START---")
        const list = []
        files.forEach(block => {
            if (!block.trim()) return

            let path = "", name = "", comment = "", icon = "", noDisplay = false, inDesktopEntry = false

            block.split("\n").forEach(line => {
                const l = line.trim()
                if (l.startsWith("PATH=")) { path = l.slice(5); return }
                if (l === "[Desktop Entry]") { inDesktopEntry = true; return }
                if (l.startsWith("[") && l !== "[Desktop Entry]") { inDesktopEntry = false; return }
                if (!inDesktopEntry) return
                if (l.startsWith("Name=") && !name)          name = l.slice(5).trim()
                if (l.startsWith("Comment=") && !comment)    comment = l.slice(8).trim()
                if (l.startsWith("Icon=") && !icon)          icon = l.slice(5).trim()
                if (l.startsWith("NoDisplay=true"))          noDisplay = true
            })

            if (!name || noDisplay || !path) return
            // Avahi's discovery tool and hwloc's lstopo viewer are system
            // utilities the user never wants surfaced in finder at all.
            if (/avahi/i.test(name) || /avahi/i.test(path)) return
            if (/lstopo/i.test(name) || /lstopo/i.test(path)) return

            let iconPath = ""
            if (icon.startsWith("/"))            iconPath = "file://" + icon
            else if (icon)                        iconPath = "image://icon/" + icon

            list.push({ name, comment, icon, iconPath, path })
        })

        // De-dupe by name, keep first occurrence (local overrides system since
        // ~/.local/share/applications is listed second in `find` args above,
        // but find's actual traversal order can vary — sort so local wins by
        // re-ordering: entries whose path includes the home dir go first).
        list.sort((a, b) => {
            const aLocal = a.path.includes("/.local/share/") ? 0 : 1
            const bLocal = b.path.includes("/.local/share/") ? 0 : 1
            return aLocal - bLocal
        })
        const byName = {}
        const deduped = []
        list.forEach(a => {
            const key = a.name.toLowerCase()
            if (byName[key]) return
            byName[key] = true
            deduped.push(a)
        })
        deduped.sort((a, b) => a.name.localeCompare(b.name))
        root.apps = deduped
    }

    // ── Fuzzy-ish search: case-insensitive substring on name, then comment ──
    function search(query, limit) {
        if (!query) return []
        const q = query.toLowerCase()
        const nameHits = []
        const commentHits = []
        for (const a of root.apps) {
            const n = a.name.toLowerCase()
            if (n.includes(q)) {
                nameHits.push(a)
                continue
            }
            if (a.comment && a.comment.toLowerCase().includes(q)) {
                commentHits.push(a)
            }
        }
        // Prefix matches on name rank above pure substring matches
        nameHits.sort((a, b) => {
            const an = a.name.toLowerCase(), bn = b.name.toLowerCase()
            const ap = an.startsWith(q) ? 0 : 1
            const bp = bn.startsWith(q) ? 0 : 1
            if (ap !== bp) return ap - bp
            return an.localeCompare(bn)
        })
        return nameHits.concat(commentHits).slice(0, limit || 8)
    }

    function launch(app) {
        launchProc.command = ["gio", "launch", app.path]
        launchProc.running = true
    }

    property var launchProc: Process { id: launchProc; running: false }

    Component.onCompleted: {
        root._buf = ""
        findProc.running = true
    }
}
