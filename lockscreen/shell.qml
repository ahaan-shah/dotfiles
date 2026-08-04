import Quickshell
import Quickshell.Wayland
import Quickshell.Io

// Quickshell replacement for hyprlock — see LockSurface.qml for the visual
// 1:1 port of hypr/hyprlock.conf and LockContext.qml for PAM/fingerprint
// auth. Structure follows Quickshell's own official lockscreen example
// (quickshell-examples/lockscreen) almost exactly: a shared LockContext plus
// a WlSessionLock whose surface component (one LockSurface per screen) is
// instantiated automatically for every connected monitor — matching
// hyprlock.conf's `monitor = ` (blank = all monitors) on every block.
//
// PERSISTENT process, like macdock/macswitcher/taskbar/finder — not spawned
// fresh per lock. It used to start with `locked: true` and Qt.quit() on
// unlock, cold-starting a brand new Quickshell process (QML compile,
// Wayland connect, wal-color/wallpaper load, PAM/fprintd setup) every single
// time a lock was needed. That start-up cost is exactly why waking from
// sleep showed the unlocked desktop, fully interactive, for 2-3 seconds
// before the lock surface finally appeared — suspend/resume completed well
// before the freshly-spawned process had gotten anywhere near calling
// lock(). Now the process is already warm and idle (locked: false) from
// session start, and lock_cmd just flips `lock.locked = true` over IPC —
// a protocol call, not a process spawn, so it's effectively instant.
//
// Run for real:  quickshell -c ~/.config/lockscreen   (see lockscreen-launch.sh,
// which now launches this once at session start and sends the IPC "lock"
// command on every actual lock instead of spawning a new instance).
// Run safely in a window instead of actually locking the session: test.qml.
ShellRoot {
    LockContext {
        id: lockContext
        active: lock.locked

        onUnlocked: {
            // Just drop the lock — do NOT Qt.quit() anymore, this process
            // stays resident so the next lock is instant too. (Still never
            // pkill this process while locked is true, for the same reason
            // as always: WlSessionLock's docs warn that killing it in that
            // state leaves the compositor permanently locked with nothing
            // left listening to unlock it.)
            lock.locked = false
        }
    }

    WlSessionLock {
        id: lock
        locked: false

        WlSessionLockSurface {
            LockSurface {
                anchors.fill: parent
                context: lockContext
            }
        }
    }

    IpcHandler {
        target: "lock"
        function engage(): void { lock.locked = true }
        function isLocked(): bool { return lock.locked }
    }
}
