import Quickshell
import Quickshell.Io
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

    // `qs -p ~/.config/lockscreen ipc call lock wake` — called by hypridle's
    // after_sleep_cmd, right after it turns DPMS back on.
    //
    // The lock raised by before_sleep_cmd is frozen by systemd ~100-200ms after
    // the compositor confirms it (see LockSurface.qml's instantIntro comment),
    // and it comes back from a hibernate in a state the surface cannot detect
    // from the inside: the clock reads the time the machine went down and the
    // password field takes no keystrokes, while fingerprint — a separate
    // process, not the surface — still works. Both clear the moment any real
    // input arrives, which is the tell: what is missing is the nudge, not the
    // machinery. So this delivers one, from the resume signal hypridle already
    // has, instead of guessing at it from a process that was not running.
    //
    // Only the FIRST lock after a resume is affected; every lock raised later
    // in the session is fine, so nothing here should run at any other time.
    IpcHandler {
        target: "lock"
        function wake(): void { lockContext.woke() }
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
