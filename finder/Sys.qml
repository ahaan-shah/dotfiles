pragma Singleton

import QtQuick
import Quickshell

// Small shared helpers that several finder singletons each used to carry their
// own copy of.
//
// `home` in particular replaces what used to be two separate
// `Process { command: ["bash", "-c", "echo -n $HOME"] }` spawns (FileSearch and
// ClipboardHistory each had one). Beyond being two subprocesses at every
// startup, they resolved *asynchronously*, so both singletons needed extra
// state to cope with a request arriving before $HOME was known - see the
// _pendingRefresh dance ClipboardHistory used to need. Quickshell.env is
// synchronous, so that whole class of race simply stops existing.
QtObject {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string cacheDir: root.home + "/.cache"

    // POSIX single-quote escaping, for the commands that genuinely need a
    // shell (a pipeline, a redirect). Was defined identically in four files.
    function quote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }
}
