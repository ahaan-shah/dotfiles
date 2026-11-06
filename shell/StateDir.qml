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

    // Fired shortly after any close_write / moved_to / create in the directory.
    signal changed()

    // ── One long-lived watcher, not one per event ─────────────────────────
    // This used to be `inotifywait` without -m: exit on the first event, re-read,
    // re-arm 300 ms later. Every writer here does temp file then `mv`, so the
    // FIRST event of every write is the temp file's create, and the event that
    // carries the new contents arrives inside the dead window. Consumers re-read
    // the old value and nothing ever told them again. That was the wallpaper that
    // needed choosing twice (Ahaan, 2026-11-06; "often"): the second pick found
    // the path the first had already written. It also left dune on screen under
    // colours pywal had derived from frequency.png, since palette.sh reads the
    // file directly and the shell had not.
    //
    // -m keeps one watch armed for the shell's life, so there is no window. `exec`
    // makes the Process's child the inotifywait itself, not a bash holding it, so
    // stopping the Process cannot orphan it. mkdir -p stays in the command: on a
    // fresh machine the directory may not exist yet and inotifywait would exit at
    // once, spinning the restart timer below.
    property var _watchProc: Process {
        id: watchProc
        command: ["bash", "-c",
            "mkdir -p '" + root.dir + "'; " +
            "exec inotifywait -m -e close_write,moved_to,create --quiet '" + root.dir + "' 2>/dev/null"]
        running: false
        stdout: SplitParser { onRead: debounce.restart() }
    }

    // One write is three events (create, close_write, moved_to), and consumers
    // re-read a file each time, so a burst becomes one signal. Restarted on each
    // event, so it fires after the LAST: a read can no longer land before the mv.
    property var _debounce: Timer {
        id: debounce
        interval: 60
        repeat: false
        onTriggered: root.changed()
    }

    // Only reached if inotifywait dies. Anything written while it was down has no
    // event coming, so the restart re-reads once it is armed again. The beat is
    // what stops a tight respawn loop if the directory goes away.
    property var _watchConn: Connections {
        target: watchProc
        function onRunningChanged() {
            if (watchProc.running) debounce.restart()
            else restartTimer.restart()
        }
    }

    property var _restartTimer: Timer {
        id: restartTimer
        interval: 300
        repeat: false
        onTriggered: watchProc.running = true
    }

    Component.onCompleted: watchProc.running = true
}
