import Quickshell
import Quickshell.Wayland

// Quickshell replacement for hyprlock — see LockSurface.qml for the visual
// 1:1 port of hypr/hyprlock.conf and LockContext.qml for PAM/fingerprint
// auth. Structure follows Quickshell's own official lockscreen example
// (quickshell-examples/lockscreen) almost exactly: a shared LockContext plus
// a WlSessionLock whose surface component (one LockSurface per screen) is
// instantiated automatically for every connected monitor — matching
// hyprlock.conf's `monitor = ` (blank = all monitors) on every block.
//
// Run for real:  quickshell -c ~/.config/lockscreen   (see lockscreen-launch.sh)
// Run safely in a window instead of actually locking the session: test.qml.
ShellRoot {
    LockContext {
        id: lockContext

        onUnlocked: {
            // Unlock before quitting — per WlSessionLock's own docs, a
            // process that dies (or exits) while `locked` is still true
            // leaves the compositor showing a permanent solid-color lock
            // with nothing listening on the other end. This ordering is
            // the one thing here that must never be gotten backwards.
            lock.locked = false
            Qt.quit()
        }
    }

    WlSessionLock {
        id: lock
        locked: true

        WlSessionLockSurface {
            LockSurface {
                anchors.fill: parent
                context: lockContext
            }
        }
    }
}
