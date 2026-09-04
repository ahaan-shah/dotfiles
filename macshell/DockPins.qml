pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "."

// The dock's pinned-app store: which apps stay in the dock when they are not
// running, and in what order.
//
// ── Why this exists ───────────────────────────────────────────────────────
// The pinned set used to BE DockModel.qml — eleven ListElements naming this
// machine's apps, compiled into the shell. Anyone else running these dotfiles
// got a dock full of icons for software they had never installed, and had to
// edit QML and restart the shell to change it. The pinned set is a preference,
// so it lives in a file now and DockModel.qml is only the first-run seed.
//
// ── Where the file is, and why not ~/.config ──────────────────────────────
// ~/.local/state/hyprahaan/dock-pins.json, beside the nightlight temperature
// and the agent usage records, for the two reasons those are there:
//   * backup_configs.sh mirrors ~/.config/macshell into a PUBLIC repo. A pin
//     list is this machine's apps, not the desktop's design.
//   * a deploy copies files INTO ~/.config/macshell. State kept there would be
//     clobbered by exactly the copy that ships a dock update.
// It is also why the path is built from $HOME rather than Quickshell.shellDir:
// a repo-path instance run for testing must read and write the same store the
// live shell does, not a second one beside itself.
//
// ── The shape ─────────────────────────────────────────────────────────────
//   { "version": 1, "pins": [ {name, icon, command, windowClass, separator} ] }
// Array order IS dock order. `icon` takes the same three shapes DockModel.qml
// documents (theme name / "~/…" / "/…") plus already-resolved "file://" and
// "image://icon/" URLs, which is what a pin created from a running window with
// no .desktop entry ends up carrying; Dock.qml's _resolveDockIcon() handles
// all five.
QtObject {
    id: root

    // Ordered pin records. Dock.qml is the only writer, via setPins().
    property var pins: []

    // Flips once the store has actually been read. Same race the other
    // singletons here document: the cat Process is async, and a _rebuild()
    // that ran before it landed would draw an empty pinned block.
    property bool ready: false

    readonly property string _home: Quickshell.env("HOME") || ""
    readonly property string dir:
        (Quickshell.env("XDG_STATE_HOME") || root._home + "/.local/state") + "/hyprahaan"
    readonly property string path: root.dir + "/dock-pins.json"

    // The seed for a machine that has never had this file: whatever
    // DockModel.qml lists. Instantiated here rather than in Dock.qml so the
    // defaults are read exactly once, at the one moment they matter.
    property var _defaults: DockModel { id: defaultsModel }

    // ── Public API ────────────────────────────────────────────────
    function keyFor(pin, index) {
        // A pin's identity is its window class, lowercased — the same key the
        // dock uses for a running window, which is what lets a right-click pin
        // an open app without its icon changing slots. Separators have no
        // class, so they fall back to their position in the list.
        if (pin && pin.windowClass && pin.windowClass !== "")
            return String(pin.windowClass).toLowerCase()
        return "separator:" + index
    }

    // Replace the whole list, in dock order, and persist it. Callers pass the
    // full array rather than a pin/unpin delta on purpose: the store's order is
    // the dock's order, and only the dock knows what that currently is.
    function setPins(list) {
        const clean = []
        for (let i = 0; i < list.length; i++) {
            const p = root._norm(list[i])
            if (p) clean.push(p)
        }
        root.pins = clean
        root._write()
    }

    function _norm(p) {
        if (!p) return null
        const sep = p.separator === true
        const cls = p.windowClass ? String(p.windowClass) : ""
        // An entry that is neither a separator nor tied to a window class can
        // never be matched, launched or unpinned — dropping it here keeps a
        // hand-edited file from producing a permanently stuck icon.
        if (!sep && cls === "") return null
        return {
            name:        p.name    ? String(p.name)    : cls,
            icon:        p.icon    ? String(p.icon)    : "",
            command:     p.command ? String(p.command) : "",
            windowClass: cls,
            separator:   sep
        }
    }

    function _seed() {
        const out = []
        for (let i = 0; i < defaultsModel.count; i++) {
            const e = defaultsModel.get(i)
            out.push({
                name:        e.name,
                icon:        e.icon,
                command:     e.command,
                windowClass: e.windowClass,
                separator:   e.separator === true
            })
        }
        return out
    }

    // ── Read ──────────────────────────────────────────────────────
    property string _buf: ""

    property var _readProc: Process {
        id: readProc
        command: ["bash", "-c", "cat '" + root.path + "' 2>/dev/null"]
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
            const raw = root._buf
            root._buf = ""

            if (raw.trim() === "") {
                // No file yet — first run on this machine. Seed it from
                // DockModel.qml and write it out, so the file exists from the
                // first launch and is there to be hand-edited.
                root.pins = root._seed()
                root.ready = true
                root._write()
                return
            }

            try {
                const obj  = JSON.parse(raw)
                const list = Array.isArray(obj) ? obj : (obj.pins || [])
                const clean = []
                for (let i = 0; i < list.length; i++) {
                    const p = root._norm(list[i])
                    if (p) clean.push(p)
                }
                root.pins = clean
            } catch (e) {
                // Unparseable. Fall back to the defaults IN MEMORY only — the
                // broken file is left exactly as it is, because overwriting it
                // here would destroy a hand-edit that just has a typo in it.
                root.pins = root._seed()
            }
            root.ready = true
        }
    }

    // ── Write ─────────────────────────────────────────────────────
    // Atomic, for the same reason ui-prefs.sh writes atomically: the watch
    // below (and a second macshell instance) would otherwise read a partial
    // file. The JSON is passed as an ARGUMENT, never interpolated into the
    // script text — an app name with a quote in it cannot become shell syntax.
    property bool _pendingWrite: false

    property var _writeProc: Process {
        id: writeProc
        command: ["true"]
        running: false
    }

    property var _writeConn: Connections {
        target: writeProc
        function onRunningChanged() {
            if (writeProc.running) return
            if (!root._pendingWrite) return
            root._pendingWrite = false
            root._write()
        }
    }

    function _write() {
        if (writeProc.running) {
            // `running = true` is a no-op while already running, so a second
            // pin landing mid-write would otherwise be silently dropped.
            root._pendingWrite = true
            return
        }
        const payload = JSON.stringify({ version: 1, pins: root.pins }, null, 2)
        writeProc.command = ["bash", "-c",
            'mkdir -p "$1" && printf \'%s\\n\' "$3" > "$2.tmp" && mv -f "$2.tmp" "$2"',
            "dock-pins", root.dir, root.path, payload]
        writeProc.running = true
    }

    // ── Watch ─────────────────────────────────────────────────────
    // The DIRECTORY, not the file — _write() mv's a temp file into place and an
    // inotify watch follows the inode, so a watch on dock-pins.json itself
    // fires once and never again. Same trap, and the same answer, as
    // UiConfig.qml's watch on ~/.config/scripts.
    //
    // This exists so the file can be edited by hand, and so two macshell
    // instances (the live one and a repo-path one under test) converge instead
    // of overwriting each other blind. Re-reading our own write is harmless:
    // reads assign `pins`, only setPins() writes, so there is no loop.
    property var _watchProc: Process {
        id: watchProc
        command: ["bash", "-c",
            "mkdir -p '" + root.dir + "'; " +
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

    Component.onCompleted: {
        root._buf = ""
        readProc.running  = true
        watchProc.running = true
    }
}
