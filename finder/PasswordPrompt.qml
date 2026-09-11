pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell.Io
import Quickshell.Services.Pam

// The password box. Something in the settings menu needs root; the menu closes
// and this takes its place, rather than throwing a terminal on screen whose
// first line is a bare "[sudo] password for ahaan:" with no indication of what
// asked or why.
//
// Terminal work — update, install, remove — deliberately keeps its own prompt.
// Those open a terminal anyway because the output IS the point, and a password
// typed in the window that is about to show you what it did is coherent. This
// box is for the operations that have no terminal of their own.
//
// ── Why a wrong password is rejected before sudo ever sees it ────────────
// Handing every attempt straight to sudo made a typo take ~4.5s to come back,
// because sudo's stack is pam_faillock + pam_unix and it inserts its own delay
// after a failure — and each attempt also spent a faillock entry.
//
// The lock screen is instant on the same machine, and the reason is the PAM
// service: /etc/pam.d/vlock is plain pam_unix with no faillock and no frills.
// So this box validates against vlock exactly as LockContext does, and only
// once PAM says the password is RIGHT does it hand it to privileged-run.sh. A
// typo never reaches sudo, never waits on its delay and never touches faillock.
//
// A fresh PamContext per attempt, not one reused: LockContext.qml records that
// a long-lived one completes its 1st and 2nd start() and then hangs forever on
// the 3rd.
//
// ── And the field is never blocked while an attempt is in flight ─────────
// The remaining ~2s before a wrong password comes back is NOT the hash:
// measured, unix_chkpwd answers in 39ms. It is pam_unix's own pam_fail_delay,
// which exists to make guessing expensive and which vlock has as well — so the
// lock screen pays it too. The lock screen nevertheless feels instant, and
// LockContext.qml says exactly why: it clears the field the moment Enter is
// pressed and never disables it, so retyping is available in the same tick and
// is completely decoupled from how long verification takes.
//
// This does the same. There is no blocking "Authenticating…" state and nothing
// is ever disabled; the failure simply arrives when it arrives.
//
// ── And polkit's prompts land here too ───────────────────────────────────
// Everything polkit would have shown its own dialog for — mounting a disk, a
// systemd unit, anything run through pkexec — arrives as flow "polkit" from
// scripts/polkit-agent.py by way of PolkitLink.qml. It is the same box for the
// same reason the change-password flow is: this is the one place on this
// desktop that asks for a password, and lxqt-policykit-agent's Qt5 dialog
// (which answered these before) looked like nothing else here.
//
// The vlock pre-check matters even more there than it does for sudo. polkit
// authenticates through /usr/lib/pam.d/polkit-1, which includes system-auth —
// pam_faillock and pam_unix, exactly sudo's stack. Measured with the agent's
// own harness: one wrong password took 2.06s to come back and left one
// faillock entry against service `polkit-1`. So a typo is refused here, by
// vlock, and never reaches polkit at all.
//
// ── No fingerprint affordance here, and that is measured ─────────────────
// The lock screen offers one, so it would be reasonable to expect it. But
// fprintd there is called directly, next to PAM; sudo's PAM stack is what
// matters here and it does not include pam_fprintd — /etc/pam.d/sudo includes
// system-auth, whose auth chain is pam_faillock + pam_unix and nothing else.
// A fingerprint glyph on this box would be an offer the system cannot honour.
Rectangle {
    id: prompt

    property bool shown: false
    property string title: ""
    property string reason: ""
    property string command: ""      // passed to scripts/privileged-run.sh
    property bool busy: false
    property bool failed: false
    // A wrong password and a command that failed after a CORRECT password are
    // different things and deserve different words. privileged-run.sh exits 77
    // for the first and passes the command's own code through for the second.
    property bool commandFailed: false

    // ── flows ─────────────────────────────────────────────────────────────
    // "auth"   one password, verified, then handed to privileged-run.sh.
    // "passwd" three: current, new, confirm. Same box, same look — Ahaan asked
    //          for this to be the one authenticate-password design everywhere,
    //          so changing a password reuses it rather than growing a dialog of
    //          its own.
    // "verify" one password, verified, and then NOTHING is run. It exists for
    //          the operations that must run as this user rather than as root:
    //          enrolling a fingerprint is fprintd's `enroll` action, granted to
    //          the local active user, while the same call under sudo would be
    //          claiming another user's device (`setusername`, auth_admin_keep)
    //          and would be harder, not easier. The box proves who is asking;
    //          Settings.verified() decides what that unlocks.
    // "polkit" one password, verified, then handed to the polkit agent over
    //          PolkitLink rather than to a command. The box stays up until the
    //          agent says polkit accepted it too, because that answer comes
    //          from another process and can still be no.
    property string flow: "auth"
    property int stepIndex: 0
    property string _current: ""     // flow "passwd": the verified current one
    property string _newpw: ""       // flow "passwd": the new one, awaiting confirm

    readonly property var _passwdSteps: [
        { head: "Current password",     hint: "Confirm it is you before changing it" },
        { head: "New password",         hint: "" },
        { head: "Confirm new password", hint: "Type it once more" }
    ]

    signal finished(bool ok)
    signal cancelled()

    function begin(t, why, cmd) {
        prompt.flow = "auth"
        prompt.stepIndex = 0
        prompt.title = t
        prompt.reason = why
        prompt.command = cmd
        prompt._reset()
    }

    function beginVerify(why) {
        prompt.flow = "verify"
        prompt.stepIndex = 0
        prompt.title = ""
        prompt.reason = why
        prompt.command = ""
        prompt._reset()
    }

    // Whose password polkit wants, and whether that is the person sitting here.
    // auth_admin resolves through 50-default.rules to unix-group:wheel, which
    // is this user, so `polkitSelf` is true for everything this machine
    // actually asks — but an action that named someone else would authenticate
    // as them, and then neither the wording nor the vlock pre-check below can
    // pretend otherwise.
    property string polkitUser: ""
    property bool polkitSelf: true

    // The password, once verified, goes to the agent instead of to a command.
    signal polkitPassword(string pw)

    function beginPolkit(why, user, isSelf) {
        prompt.flow = "polkit"
        prompt.stepIndex = 0
        prompt.title = ""
        prompt.reason = why
        prompt.command = ""
        prompt.polkitUser = user
        prompt.polkitSelf = isSelf
        prompt._reset()
    }

    // The agent's verdict on a password this box has already accepted.
    function polkitFailed() {
        prompt.busy = false
        prompt._pending = ""
        // For our own password vlock has already said it is right, so a "no"
        // from polkit is not a typo and must not say "try again" — a locked
        // account (faillock, deny=20 here) or an expired one lands here. When
        // the identity is someone else there was nothing to pre-check against,
        // and then it IS a typo.
        prompt.commandFailed = prompt.polkitSelf
        prompt.failed = true
        shakeAnim.restart()
        field.forceActiveFocus()
    }

    function polkitAccepted() {
        prompt.busy = false
        prompt._pending = ""
        prompt.succeeded = true
        doneTimer.restart()
    }

    function beginChangePassword() {
        prompt.flow = "passwd"
        prompt.stepIndex = 0
        prompt.title = ""
        prompt.reason = ""
        prompt.command = ""
        prompt._current = ""
        prompt._newpw = ""
        prompt._reset()
    }

    function _reset() {
        prompt.succeeded = false
        prompt.busy = false
        prompt.failed = false
        prompt.commandFailed = false
        prompt.mismatch = false
        field.text = ""
    }

    readonly property bool alarm: prompt.failed || prompt.mismatch

    // Driven from `succeeded` rather than from each of the three places that
    // set it — polkit accepting, PAM accepting, and the command coming back —
    // so a fourth one cannot forget to play it.
    SequentialAnimation {
        id: okAnim
        NumberAnimation {
            target: okMark; property: "pop"; from: 0.35; to: 1
            duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.4
        }
        NumberAnimation {
            target: okMark; property: "prog"; from: 0; to: 1
            duration: 300; easing.type: Easing.OutCubic
        }
    }
    onSucceededChanged: {
        okAnim.stop()
        okMark.pop = 0.35
        okMark.prog = 0
        if (prompt.succeeded) okAnim.start()
    }

    // Held for a beat on success before the box goes. Authenticating used to
    // just fade out, which is indistinguishable from the box being dismissed —
    // there was nothing that said the password had been accepted.
    property bool succeeded: false

    // The confirm step disagreeing with the new password is neither an
    // authentication failure nor a command failure, and saying "Authentication
    // failed" there would be simply wrong.
    property bool mismatch: false

    // What the box says right now, for either flow.
    readonly property string headline: {
        if (prompt.succeeded)     return prompt.flow === "passwd" ? "Password changed" : "Authenticated"
        if (prompt.mismatch)      return "Passwords do not match"
        if (prompt.failed)        return prompt.commandFailed ? "That did not work" : "Authentication failed"
        if (prompt.flow === "passwd") return prompt._passwdSteps[prompt.stepIndex].head
        // A polkit action that wants somebody else's password says so. Every
        // action on this machine resolves to this user, so this is the branch
        // that never fires — and it is here so that the day one does not, the
        // box is not quietly asking for the wrong password.
        if (prompt.flow === "polkit" && !prompt.polkitSelf)
            return "Password for " + prompt.polkitUser
        // "Enter Password", not "Administrator password": the password this
        // box wants is Ahaan's own login password every time — PAM validates
        // it against the `vlock` service as this user, and privileged-run.sh
        // then hands that same password to sudo. Nothing here ever asks for a
        // separate root account, so naming one described a login that does not
        // exist on this machine.
        return "Enter Password"
    }
    readonly property string subline: {
        // Nothing under the headline on success: "Authenticated" and "Password
        // changed" already say it, and the notification carries the detail.
        if (prompt.succeeded)     return ""
        if (prompt.mismatch)      return "Type the new password again"
        if (prompt.failed)        return !prompt.commandFailed ? "Try again, or press esc to cancel"
                                : prompt.flow === "polkit" ? "The password was accepted here, but polkit refused it"
                                                           : "The password was accepted, but the command failed"
        if (prompt.flow === "passwd") return prompt._passwdSteps[prompt.stepIndex].hint
        return prompt.reason
    }
    function focusInput() { field.forceActiveFocus() }

    // Held only between PAM saying yes and the spawn that consumes it, then
    // cleared. The field itself is emptied the instant Enter is pressed.
    property string _pending: ""

    function submit() {
        // Deliberately NOT guarded on `busy`: a second attempt is allowed to
        // start while the first is still inside pam_fail_delay, which is the
        // whole point of not blocking. The later result wins.
        if (field.text.length === 0) return
        const attempt = field.text
        field.text = ""
        prompt.failed = false
        prompt.commandFailed = false
        prompt.mismatch = false

        if (prompt.flow === "passwd") {
            if (prompt.stepIndex === 1) {           // the new password
                prompt._newpw = attempt
                prompt.stepIndex = 2
                return
            }
            if (prompt.stepIndex === 2) {           // confirm it
                if (attempt !== prompt._newpw) {
                    prompt._newpw = ""
                    prompt.stepIndex = 1
                    prompt.mismatch = true
                    shakeAnim.restart()
                    field.forceActiveFocus()
                    return
                }
                prompt.busy = true
                prompt._runChangePassword()
                return
            }
        }

        if (prompt.flow === "polkit" && !prompt.polkitSelf) {
            // Someone else's password: vlock authenticates THIS user and would
            // reject it however right it is, so there is nothing to pre-check
            // with. It goes straight to the agent and polkit's own PAM stack
            // decides — the slow path, with faillock, which is the price of
            // being asked for a password that is not ours.
            prompt.busy = true
            prompt.polkitPassword(attempt)
            return
        }

        // Step 0 of any other flow: verify the password before anything else.
        prompt.busy = true
        prompt._pending = attempt
        const pam = pamComponent.createObject(prompt, { config: "vlock", _response: attempt })
        if (!pam.start()) prompt._reject()
    }

    function _reject() {
        prompt._pending = ""
        prompt.busy = false
        prompt.commandFailed = false
        prompt.failed = true
        shakeAnim.restart()
        field.forceActiveFocus()
    }

    property var _pamComponent: Component {
        id: pamComponent
        PamContext {
            property string _response: ""
            onPamMessage: if (this.responseRequired) this.respond(this._response)
            onCompleted: result => {
                if (result !== PamResult.Success) { prompt._reject(); this.destroy(); return }
                if (prompt.flow === "passwd") {
                    // Verified — keep it for chpasswd and move to the new one.
                    prompt._current = prompt._pending
                    prompt._pending = ""
                    prompt.busy = false
                    prompt.stepIndex = 1
                    field.forceActiveFocus()
                } else if (prompt.flow === "polkit") {
                    // Verified here; now polkit has to accept it as well.
                    // `busy` stays set — the box is genuinely waiting on
                    // another process — and polkitAccepted/polkitFailed is
                    // what clears it.
                    const pw = prompt._pending
                    prompt._pending = ""
                    prompt.polkitPassword(pw)
                } else if (prompt.flow === "verify") {
                    // Verified and done. No command, no sudo — the same
                    // "Authenticated" beat as flow "auth", and then finished()
                    // hands off to whatever asked.
                    prompt.busy = false
                    prompt._pending = ""
                    prompt.succeeded = true
                    doneTimer.restart()
                } else {
                    prompt._run()
                }
                this.destroy()
            }
        }
    }

    function _run() {
        // The command is an argument; the PASSWORD is not. argv is readable in
        // /proc by anything running as this user, so it goes over stdin — which
        // is the whole reason privileged-run.sh reads it that way.
        authProc.command = ["bash", "-c",
            "exec " + Sys.quote(Settings.scriptDir + "/privileged-run.sh") + " " + prompt.command]
        authProc.stdinEnabled = true
        authProc.running = true
        authProc.write(prompt._pending + "\n")
        authProc.stdinEnabled = false
        prompt._pending = ""
    }

    function _runChangePassword() {
        // Two lines on stdin, current then new — see change-password.sh. Same
        // reasoning as _run(): neither ever appears in argv.
        authProc.command = ["bash", "-c",
            "exec " + Sys.quote(Settings.scriptDir + "/change-password.sh")]
        authProc.stdinEnabled = true
        authProc.running = true
        authProc.write(prompt._current + "\n" + prompt._newpw + "\n")
        authProc.stdinEnabled = false
        prompt._current = ""
        prompt._newpw = ""
    }

    // Long enough to register, short enough not to be in the way.
    property var _doneTimer: Timer {
        id: doneTimer
        // 700 while success was a word and a tinted chip. The mark takes 540ms
        // to pop and then draw, and closing at 700 cut the stroke off partway.
        // 1000 lets it finish and be seen finished.
        interval: 1000
        repeat: false
        onTriggered: prompt.finished(true)
    }

    property var _authProc: Process {
        id: authProc
        running: false
        // These two collectors are not decoration — without them the box hangs
        // on "checking…" forever.
        //
        // A Quickshell Process hands its child a PIPE. With nothing reading the
        // far end, the child blocks the moment it has written a pipe buffer's
        // worth (64K) and never exits, so onExited never fires and `busy` is
        // never cleared. Hit with a command that rebuilt a Hyprland plugin and
        // printed steadily while it did — that particular caller is gone, but
        // any command here that is chatty enough will do it again. Same family
        // as the SIGPIPE rule: the child and the pipe have to be dealt with
        // deliberately, one way or the other.
        //
        // Collected rather than redirected to /dev/null, so stderr can say what
        // went wrong when a command fails.
        stdout: StdioCollector { id: authOut }
        stderr: StdioCollector { id: authErr }
        onExited: (code, status) => {
            prompt.busy = false
            if (code === 0) {
                if (prompt.flow === "passwd")
                    Settings.notify("Password changed", "Your login and sudo password is updated")
                prompt.succeeded = true
                doneTimer.restart()
                return
            }
            // Whatever the command complained about, so a failure is
            // diagnosable rather than just red.
            const why = String(authErr.text || "").trim()
            if (why !== "") console.warn("privileged command failed:", why)

            if (prompt.flow === "passwd") {
                // change-password.sh exits 77 only if the CURRENT password was
                // wrong, which PAM already ruled out — so in practice this is
                // chpasswd failing, and saying "try again" would be a lie.
                prompt.failed = true
                prompt.commandFailed = (code !== 77)
                prompt.stepIndex = 0
                prompt._current = ""
                prompt._newpw = ""
                shakeAnim.restart()
                field.forceActiveFocus()
                return
            }
            // Stay open either way — retyping is the obvious next move after a
            // wrong password, and closing would mean re-navigating the whole
            // menu to get back here.
            // PAM already vetted the password, so anything non-zero here is
            // the command failing — 77 (privileged-run's auth code) would mean
            // sudoers refused a password PAM accepted, which is still not a
            // typo and should not say "try again".
            prompt.failed = true
            prompt.commandFailed = true
            shakeAnim.restart()
            field.forceActiveFocus()
        }
    }

    // ── card ──────────────────────────────────────────────────────────────
    width: Theme.cardWidth
    implicitHeight: col.implicitHeight + Theme.pad * 2
    radius: Theme.cardRadius
    color: Theme.bg
    // Thicker while green: at 1px the success state was easy to miss entirely.
    border.width: prompt.succeeded ? 3 : Theme.cardBorder
    border.color: prompt.succeeded ? Theme.alpha(Theme.good, 0.85)
                : prompt.alarm ? Theme.alpha(Theme.danger, 0.55) : Theme.line
    Behavior on border.color { ColorAnimation { duration: 160 } }

    opacity: prompt.shown ? 1 : 0
    scale:   prompt.shown ? 1 : 0.97
    visible: opacity > 0.001
    Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
    Behavior on scale   { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

    // A wrong password should be felt, not just read.
    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: prompt; property: "anchors.horizontalCenterOffset"; to:  9; duration: 45 }
        NumberAnimation { target: prompt; property: "anchors.horizontalCenterOffset"; to: -8; duration: 70 }
        NumberAnimation { target: prompt; property: "anchors.horizontalCenterOffset"; to:  5; duration: 60 }
        NumberAnimation { target: prompt; property: "anchors.horizontalCenterOffset"; to:  0; duration: 55 }
    }

    MouseArea { anchors.fill: parent }   // swallow clicks; the scrim is behind

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: Theme.pad
        spacing: 14

        // ── who is asking, and what for ───────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Rectangle {
                implicitWidth: 38; implicitHeight: 38
                radius: 12
                color: prompt.succeeded ? Theme.alpha(Theme.good, 0.20)
                       : prompt.alarm ? Theme.alpha(Theme.danger, 0.16)
                       : Theme.alpha(Theme.accent, 0.20)
                Behavior on color { ColorAnimation { duration: 160 } }
                Text {
                    anchors.centerIn: parent
                    // Stays a lock, and goes green. It used to become a tick,
                    // which was the only success mark there was — now the field
                    // below draws one at four times the size, and two ticks in a
                    // 260px card is one of them saying nothing.
                    text: "󰌾"
                    color: prompt.succeeded ? Theme.good
                         : prompt.alarm ? Theme.danger : Theme.text
                    font.family: Theme.font
                    font.pixelSize: 18
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: prompt.headline
                    color: prompt.succeeded ? Theme.good
                         : prompt.alarm ? Theme.danger : Theme.text
                    font.family: Theme.font
                    font.pixelSize: Theme.fsRow + 1
                    font.weight: Font.Medium
                }
                Text {
                    Layout.fillWidth: true
                    // Two lines, not one. Every subline this box wrote itself
                    // fits on one — but polkit's do not: it supplies its own
                    // wording for the action, and "Authentication is required
                    // to run a program as another user" was cut at "as ano…"
                    // in the very first screenshot of this flow. The card
                    // grows by a line when it needs to and is unchanged
                    // otherwise.
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    visible: text.length > 0
                    text: prompt.subline
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fsSub
                }
            }
        }

        // ── the field ─────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            // FIXED. The mark is 52px in a 42px slot and simply overhangs it by
            // 5px top and bottom, into the column's own 14px spacing — nothing
            // clips here, and nothing else is drawn in that gap. Growing the
            // slot to enclose the mark instead meant the whole card resized on
            // success, which is a second animation nobody asked for on top of
            // the one that is the point.
            implicitHeight: 42
            radius: 12
            // The field disappears entirely rather than turning green: on
            // success there is nothing to type into, and a box drawn around a
            // confirmation mark frames it as an input that has been filled in.
            // What is left is the mark alone on the card.
            color: prompt.succeeded ? "transparent" : Theme.alpha(Theme.col7, 0.07)
            border.width: 1
            border.color: prompt.succeeded ? "transparent"
                        : field.activeFocus ? Theme.alpha(Theme.accent, 0.55) : Theme.hairline
            Behavior on color { ColorAnimation { duration: 200 } }
            Behavior on border.color { ColorAnimation { duration: 200 } }

            // ── the mark ──────────────────────────────────────────────────
            // A disc that pops, then a check that DRAWS itself inside it, in
            // that order — the shape of the thing iOS does when Face ID approves
            // a purchase, and the reason this is a sequence of two animations
            // rather than one fade.
            //
            // The stroke grows by MOVING ITS ENDPOINT, not by uncovering a
            // finished path with a dash pattern. The dash trick is the usual way
            // to do this and it silently does nothing here: Shape.CurveRenderer
            // ignores dashed strokes, so the check rendered complete on its
            // first frame and the animation was invisible. Falling back to the
            // geometry renderer would have got the dashes working and lost the
            // analytic antialiasing that makes a 5px diagonal stroke look drawn
            // rather than stepped — so the geometry animates instead, which
            // needs no renderer feature at all.
            //
            // `prog` walks 0..1 along the two segments end to end. While the
            // first is still growing the second is pinned to the first's tip and
            // has zero length: without that it would draw from the tip to the
            // corner and the short arm would appear complete instantly.
            Item {
                id: okMark
                anchors.centerIn: parent
                width: 52; height: 52
                visible: prompt.succeeded

                property real pop:  0.35   // disc scale
                property real prog: 0      // 0 undrawn -> 1 fully drawn

                // The check, in this item's own 64px coordinates.
                readonly property real ax: 14.5; readonly property real ay: 26.5
                readonly property real bx: 22.5; readonly property real by: 34.5
                readonly property real cx: 38.0; readonly property real cy: 18.0
                readonly property real s1: Math.hypot(bx - ax, by - ay)
                readonly property real s2: Math.hypot(cx - bx, cy - by)
                readonly property real t:  okMark.prog * (okMark.s1 + okMark.s2)
                readonly property real k1: Math.max(0, Math.min(1, okMark.t / okMark.s1))
                readonly property real k2: Math.max(0, Math.min(1, (okMark.t - okMark.s1) / okMark.s2))
                readonly property real e1x: okMark.ax + (okMark.bx - okMark.ax) * okMark.k1
                readonly property real e1y: okMark.ay + (okMark.by - okMark.ay) * okMark.k1
                readonly property real e2x: okMark.k1 < 1 ? okMark.e1x
                                          : okMark.bx + (okMark.cx - okMark.bx) * okMark.k2
                readonly property real e2y: okMark.k1 < 1 ? okMark.e1y
                                          : okMark.by + (okMark.cy - okMark.by) * okMark.k2

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Theme.good
                    scale: okMark.pop
                }

                Shape {
                    anchors.fill: parent
                    preferredRendererType: Shape.CurveRenderer
                    // Scaled with the disc, so the check is never hanging in
                    // space over a circle that has not finished arriving.
                    scale: okMark.pop
                    ShapePath {
                        strokeColor: Theme.bg
                        strokeWidth: 4.2
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        startX: okMark.ax; startY: okMark.ay
                        PathLine { x: okMark.e1x; y: okMark.e1y }
                        PathLine { x: okMark.e2x; y: okMark.e2y }
                    }
                }
            }

            // Dots rather than the field's own echo: the lock screen shows the
            // same feedback, and it keeps the caret out of a field whose
            // contents can never be read back.
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 7
                // The dots, the placeholder and the "checking…" note all clear
                // out together on success. This is the fix for the box that sat
                // there empty under the word "Authenticated": the field was
                // still a field, just with nothing in it.
                opacity: prompt.succeeded ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 120 } }
                Repeater {
                    model: dots.count
                    Rectangle {
                        width: 7; height: 7; radius: 3.5
                        color: Theme.alpha(Theme.text, 0.75)
                    }
                }
            }
            // An INT model, not a JS array. Qt grows and shrinks an integer
            // model by the difference; rebinding an array destroys and recreates
            // every delegate on each keystroke, which this repo has been bitten
            // by twice (notification popups, and the lock screen's own dots).
            QtObject { id: dots; property int count: 0 }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                visible: dots.count === 0
                opacity: prompt.succeeded ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 120 } }
                text: "Password"
                color: Theme.dimmer
                font.family: Theme.font
                font.pixelSize: Theme.fsInput
            }

            // Non-blocking, and off to one side: it reports that something is
            // happening without taking the field away from you.
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                visible: prompt.busy
                opacity: prompt.succeeded ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 120 } }
                text: "checking…"
                color: Theme.dimmer
                font.family: Theme.font
                font.pixelSize: Theme.fsSub
            }

            TextInput {
                id: field
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                echoMode: TextInput.Password
                // Nothing of the text is drawn — the dots above are the
                // feedback — so the glyphs and the caret are both invisible.
                color: "transparent"
                cursorDelegate: Item {}
                font.family: Theme.font
                font.pixelSize: Theme.fsInput
                onTextChanged: {
                    dots.count = Math.min(text.length, 32)
                    if (prompt.failed && text.length > 0) prompt.failed = false
                }
                onAccepted: prompt.submit()
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) { prompt.cancelled(); event.accepted = true }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.hairline }

        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            // Neither key does anything once it has been accepted.
            opacity: prompt.succeeded ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 140 } }
            Text {
                text: "↵ confirm"
                color: Theme.dimmer
                font.family: Theme.font
                font.pixelSize: Theme.fsHint
            }
            Item { Layout.fillWidth: true }
            Text {
                text: "esc cancel"
                color: Theme.dimmer
                font.family: Theme.font
                font.pixelSize: Theme.fsHint
            }
        }
    }
}
