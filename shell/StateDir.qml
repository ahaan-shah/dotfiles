pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// One inotify watch over ~/.local/state/hyprahaan, for everything in this shell
// that keeps state there.
//
// ── Why it exists ─────────────────────────────────────────────────────────
// Two components watch that directory: DockPins.qml, for the dock's pinned set,
// and Wallpaper.qml, for which image is up. Each spawned its own
// `bash -c inotifywait …` — and a Quickshell Process running a shell pipeline is
// TWO processes, the bash and the inotifywait it execs, so the pair cost four.
// Measured on the merged shell before this: two identical watchers on the same
// path, in the same process, woken by the same events.
//
// Separate instances could not have shared one. In one shell they can, and
// anything else that stores state there should use this rather than adding a
// third.
//
// ── Why the watch is on the DIRECTORY ─────────────────────────────────────
// Every writer here replaces its file with a temp-file `mv`, so a reader can
// never see half a write — and an inotify watch follows the INODE, so a watch
// on the file itself fires exactly once and then never again. Same trap and the
// same answer as UiConfig.qml's watch on ~/.config/scripts.
//
// Consumers connect to `changed` and re-read whatever they own. The signal
// deliberately says nothing about WHICH file moved: inotifywait is told to be
// quiet, the directory holds a handful of small files, and a re-read of one
// short file is cheaper than the plumbing to tell them apart.
QtObject {
    id: root

    readonly property string _home: Quickshell.env("HOME") || ""
    readonly property string dir:
        (Quickshell.env("XDG_STATE_HOME") || root._home + "/.local/state") + "/hyprahaan"

    // Fired after every close_write / moved_to / create in the directory.
    signal changed()

    // mkdir -p in the command rather than at startup: the directory does not
    // exist on a fresh machine until something first writes there, and
    // inotifywait on a missing path exits immediately, which would spin the
    // restart timer below for the life of the session.
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
            root.changed()
            restartTimer.restart()
        }
    }

    // inotifywait exits after one event, so the watch is re-armed each time. The
    // beat is what stops a tight respawn loop if the directory goes away.
    property var _restartTimer: Timer {
        id: restartTimer
        interval: 300
        repeat: false
        onTriggered: watchProc.running = true
    }

    Component.onCompleted: watchProc.running = true
}
