import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam

// Auth logic shared by every WlSessionLockSurface (one per screen) — mirrors
// hyprlock.conf's `auth { pam {...} fingerprint {...} }` block: password via
// PAM and fingerprint via fprintd run concurrently, either one unlocks.
//
// Password: originally pointed at /etc/pam.d/hyprlock (hyprlock.conf's own
// `auth.pam.module = hyprlock` target — pam_unix only, see that file's old
// comment "Fingerprint via Hyprlock (NOT PAM) happens separately"). That
// file is now GONE — confirmed via `pacman -Qo`/`pacman -Q hyprlock`: the
// hyprlock package has since been uninstalled, and it owned that pam.d
// file, so removing the package took it down too. PamContext logged
// `Cannot start ... because specified config file "/etc/pam.d/hyprlock" is
// not a file` and — because nothing checked start()'s return value at the
// time — just silently never called `completed` again, ever, for any
// future attempt: no unlock, no failure reset, field stuck disabled
// forever. That was the real bug behind "correct password doesn't unlock,
// only fingerprint does" and "wrong password doesn't reset".
//
// Fixed by pointing at `vlock`'s pam.d service instead (`/etc/pam.d/vlock`
// — plain pam_unix, no frills, and owned by the `kbd` package rather than
// anything specific to this lock screen's own toolchain, so it won't
// disappear the same way if hyprlock-adjacent packages get cleaned up
// further), PLUS defensively checking start()'s return value below so a
// missing/broken PAM service fails an attempt immediately instead of
// hanging forever the same way again.
//
// Fingerprint: hyprlock does this natively (outside PAM, per the comment
// above), which Quickshell has no equivalent binding for. `fprintd-verify`
// (confirmed installed and enrolled on this machine — `fprintd-list` shows
// device Egis Technology Match-on-Chip with a right-index-finger enrolled)
// is the standard CLI entry point to the same fprintd/libfprint backend
// hyprlock itself talks to over D-Bus, and is the well-established way
// non-PAM lockscreens (rofi/waylock-style setups) shell out to fprintd.
// Live-tested (`timeout 5 fprintd-verify`) to confirm the exact stdout line
// text parsed below ("Verify started!", "Verifying: <finger>"); the
// "Verify result: verify-match/-no-match (done)" line is documented fprintd
// behavior, not directly observed here (would've required an actual scan).
Scope {
    id: root

    signal unlocked()

    property string currentText: ""

    property bool _fpUnlocked: false

    // general.ignore_empty_input = true — Enter on an empty field is a no-op.
    // general.fail_timeout — there is no attempt cap: wrong password just
    // resets and lets you try again, indefinitely, same as fingerprint's
    // own indefinite retry loop below.
    //
    // A single long-lived PamContext, reused across every attempt (tried
    // first), was confirmed via direct probing (a standalone QML script
    // driving PamContext.start() in a loop, unrelated to the missing-file
    // bug fixed earlier) to reliably complete its 1st and 2nd `start()`
    // calls but then hang forever — no `completed` signal — on the 3rd. A
    // fresh PamContext created per attempt and destroyed right after it
    // completes sidesteps that entirely.
    //
    // The PAM round-trip itself (forking unix_chkpwd, running the
    // password through crypt()) takes a real, non-zero amount of time —
    // by design, since a slow hash is what makes brute-forcing expensive.
    // The old version gated the field on `unlockInProgress` (disabled
    // while waiting) so wrong-password recovery was only ever as fast as
    // that round-trip, and it also depended on refocusing the field
    // afterward. Now `currentText` is captured and cleared *immediately*
    // on submit, before PAM is even asked to start — so the pill resets
    // and the field is ready for the next attempt in the same tick Enter
    // is pressed, completely decoupled from how long verification takes in
    // the background. `unlockInProgress`/the field's `enabled` binding are
    // gone from LockSurface.qml for the same reason — there's nothing left
    // to disable.
    function tryUnlock() {
        if (root.currentText === "") return
        const attemptText = root.currentText
        root.currentText = ""
        const pam = pamComponent.createObject(root, {
            config: "vlock",
            _response: attemptText
        })
        pam.start()   // if this returns false (e.g. a broken/missing PAM
                       // service), the field's already clear and usable —
                       // nothing further needs to happen for that case.
    }

    Component {
        id: pamComponent
        PamContext {
            id: pam
            property string _response: ""

            onPamMessage: {
                if (this.responseRequired)
                    this.respond(this._response)
            }

            onCompleted: result => {
                if (result === PamResult.Success)
                    root.unlocked()
                // A wrong password needs no action here — currentText was
                // already cleared back in tryUnlock() the instant this
                // attempt was submitted.
                pam.destroy()
            }
        }
    }

    // ── Fingerprint (concurrent, independent of the password field) ────
    property var _fpProc: Process {
        id: fpProc
        running: false
        command: ["fprintd-verify"]
        stdout: SplitParser {
            onRead: line => root._onFpLine(line)
        }
        onExited: (code, status) => {
            if (root._fpUnlocked) return
            // Covers no-match, retry-scan, disconnected-device, and plain
            // errors alike — auth.fingerprint.retry_delay (250ms) later,
            // just try again. hyprlock retries fingerprint indefinitely
            // until the session is unlocked some other way, so we do too.
            fpRetryTimer.restart()
        }
    }

    // No visible status text for this (removed per explicit request — the
    // reference hyprlock photo shows no "Scanning..."/ready message either,
    // just the same blank pill fingerprint auth silently runs behind).
    function _onFpLine(line) {
        if (line.includes("Verify result:") &&
            line.includes("verify-match") && !line.includes("no-match")) {
            root._fpUnlocked = true
            root.unlocked()
        }
    }

    property var _fpRetryTimer: Timer {
        id: fpRetryTimer
        interval: 250
        repeat: false
        onTriggered: if (!root._fpUnlocked) fpProc.running = true
    }

    Component.onCompleted: fpProc.running = true
}
