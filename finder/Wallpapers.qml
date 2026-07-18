pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// 1:1 port of scripts/set_wallpaper.sh's selection half (listing
// ~/Pictures/wallpapers, same directory, same flat file listing). The
// apply pipeline itself (pywal, hyprpaper restart, cava gradient sync,
// swayosd restart, hyprctl reload) lives in apply-wallpaper.sh alongside
// this file — it's a long shell pipeline with a lot of independent side
// effects, not worth reimplementing inline in QML piece by piece.
//
// One deliberate change from the original script: apply-wallpaper.sh drops
// its walker-restart calls (`update-walker-theme.sh`,
// `gapplication quit dev.quoteme.Walker`, `walker --gapplication-service`).
// Walker is already fully replaced by finder/ project-wide (see
// CLAUDE.md's `finder/` section) — those calls would just silently no-op
// against a binary/service nothing runs anymore, the same "broken call
// nobody notices because nothing crashes" class of bug this project has
// already hit (and fixed) elsewhere with stale hyprctl syntax.
QtObject {
    id: root

    readonly property string dir: "/home/ahaan/Pictures/wallpapers"
    property var wallpapers: []   // [{name, path}]

    function refresh() {
        listProc.running = true
    }

    property var listProc: Process {
        id: listProc
        command: ["bash", "-c", "ls -1 " + root.dir + " 2>/dev/null"]
        running: false
        stdout: StdioCollector {
            id: out
            onStreamFinished: {
                const lines = out.text.split("\n").map(l => l.trim()).filter(l => l.length > 0)
                root.wallpapers = lines.map(name => ({ name, path: root.dir + "/" + name }))
            }
        }
    }

    function search(query, limit) {
        const n = limit || 50
        if (!query) return root.wallpapers.slice(0, n)
        const q = query.toLowerCase()
        return root.wallpapers.filter(w => w.name.toLowerCase().includes(q)).slice(0, n)
    }

    function apply(path) {
        applyProc.command = [Quickshell.shellPath("apply-wallpaper.sh"), path]
        applyProc.running = true
    }

    property var applyProc: Process { id: applyProc; running: false }

    Component.onCompleted: refresh()
}
