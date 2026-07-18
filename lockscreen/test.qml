import QtQuick
import Quickshell

// Safe local testing: a normal floating window instead of a real
// WlSessionLock, so mistakes here can't leave the real session lock
// screened-out with nothing listening. Run with: quickshell -c . -p test.qml
// (or quickshell --path <this dir> -p test.qml).
ShellRoot {
    LockContext {
        id: lockContext
        onUnlocked: Qt.quit()
    }

    FloatingWindow {
        implicitWidth: 1440
        implicitHeight: 810
        LockSurface {
            anchors.fill: parent
            context: lockContext
        }
    }

    Connections {
        target: Quickshell
        function onLastWindowClosed() { Qt.quit() }
    }
}
