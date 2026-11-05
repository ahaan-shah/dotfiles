pragma Singleton

import QtQuick

// Whether the About sigil is up. A singleton so Settings (inside Launcher)
// can open a surface that lives beside it in shell.qml without a signal
// threaded through Launcher → Finder → Settings; the same reason JarvisState
// exists for the pill.
QtObject {
    property bool shown: false
    function open()   { shown = true }
    function close()  { shown = false }
    function toggle() { shown = !shown }
}
