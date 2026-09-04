pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The user's chosen UI font, icon theme and default apps, read live out of
// ~/.config/scripts/ui.conf — the file scripts/ui-prefs.sh writes, which is
// what finder's settings menu drives.
//
// ── Why this file exists four times ───────────────────────────────────────
// taskbar, macshell, finder and lockscreen are four SEPARATE Quickshell
// configs with four separate QML import roots, so there is no shared directory
// a singleton could live in. WalColors.qml is duplicated for exactly the same
// reason and for exactly as long. The four copies must stay identical; the only
// thing that legitimately differs between them is nothing at all.
//
// ── Why a file rather than an IPC push ────────────────────────────────────
// The shells start and stop independently (SUPER+K restarts all three
// persistent ones; the lockscreen is spawned per lock). A push would only reach
// whoever happened to be running. A file plus a watch means a shell that starts
// ten minutes later still comes up with the right font.
//
// Every default below is exactly what this repo hardcoded before ui.conf
// existed, so a machine with no ui.conf renders identically to one that never
// had a settings menu — a missing preference must never produce a blank UI.
QtObject {
    id: root

    readonly property string dir: (Quickshell.env("HOME") || "") + "/.config/scripts"

    property string fontFamily: "JetBrainsMono Nerd Font Propo"
    property string iconTheme:  "Papirus-Dark"
    property string gtkTheme:   ""
    property string browser:    "zen-browser"
    property string terminal:   "kitty"
    property string editor:     "vim"

    property string _buf: ""

    property var _readProc: Process {
        id: readProc
        command: ["bash", "-c", "cat '" + root.dir + "/ui.conf' 2>/dev/null"]
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
            root._parse(root._buf)
            root._buf = ""
        }
    }

    // The DIRECTORY, not the file. ui-prefs.sh writes to a temp file and mv's it
    // into place, because all four shells would otherwise read a half-written
    // ui.conf. That rename replaces the inode — and an inotify watch follows the
    // INODE, so a watch on ui.conf itself fires once and then never again.
    // Watching the containing directory survives the rename. (Same trap
    // WalColors avoids by watching a file pywal rewrites in place rather than
    // renames.)
    property var _watchProc: Process {
        id: watchProc
        command: ["bash", "-c",
            "inotifywait -e close_write,moved_to,create --quiet '" + root.dir + "' 2>/dev/null"]
        running: false
    }

    property var _watchConn: Connections {
        target: watchProc
        function onRunningChanged() {
            if (watchProc.running) return
            root._buf = ""
            readProc.running = true
            watchRestartTimer.restart()
        }
    }

    property var _watchRestartTimer: Timer {
        id: watchRestartTimer
        interval: 300
        repeat: false
        onTriggered: watchProc.running = true
    }

    function _parse(raw) {
        // KEY="value", the same shape hardware.env uses and parsed the same way
        // hyprland.lua parses that: by pattern. The file is never sourced or
        // eval'd, so a stray line in it cannot execute anything.
        const want = {
            "UI_FONT":          "fontFamily",
            "ICON_THEME":       "iconTheme",
            "GTK_THEME":        "gtkTheme",
            "DEFAULT_BROWSER":  "browser",
            "DEFAULT_TERMINAL": "terminal",
            "DEFAULT_EDITOR":   "editor"
        }
        const lines = String(raw).split("\n")
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*"(.*)"\s*$/)
            if (!m) continue
            const prop = want[m[1]]
            // An empty value is treated as absent rather than as "no font",
            // which would render every label invisible.
            if (prop && m[2] !== "") root[prop] = m[2]
        }
    }

    Component.onCompleted: {
        root._buf = ""
        readProc.running = true
        watchProc.running = true
    }
}
