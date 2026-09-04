pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
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

    signal finished(bool ok)
    signal cancelled()

    function begin(t, why, cmd) {
        prompt.title = t
        prompt.reason = why
        prompt.command = cmd
        prompt.busy = false
        prompt.failed = false
        prompt.commandFailed = false
        field.text = ""
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
        prompt.busy = true
        prompt.failed = false
        prompt.commandFailed = false
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
                if (result === PamResult.Success) prompt._run()
                else                             prompt._reject()
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

    property var _authProc: Process {
        id: authProc
        running: false
        onExited: (code, status) => {
            prompt.busy = false
            if (code === 0) {
                prompt.finished(true)
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
    border.width: 1
    border.color: prompt.failed ? Theme.alpha(Theme.danger, 0.55) : Theme.line
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
                color: prompt.failed ? Theme.alpha(Theme.danger, 0.16)
                                     : Theme.alpha(Theme.accent, 0.20)
                Behavior on color { ColorAnimation { duration: 160 } }
                Text {
                    anchors.centerIn: parent
                    text: "󰌾"
                    color: prompt.failed ? Theme.danger : Theme.text
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
                    text: !prompt.failed ? "Administrator password"
                        : prompt.commandFailed ? "That did not work" : "Authentication failed"
                    color: prompt.failed ? Theme.danger : Theme.text
                    font.family: Theme.font
                    font.pixelSize: Theme.fsRow + 1
                    font.weight: Font.Medium
                }
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    visible: text.length > 0
                    text: !prompt.failed ? prompt.reason
                        : prompt.commandFailed ? "The password was accepted, but the command failed"
                        : "Try again, or press esc to cancel"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fsSub
                }
            }
        }

        // ── the field ─────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 42
            radius: 12
            color: Theme.alpha(Theme.col7, 0.07)
            border.width: 1
            border.color: field.activeFocus ? Theme.alpha(Theme.accent, 0.55) : Theme.hairline
            Behavior on border.color { ColorAnimation { duration: 140 } }

            // Dots rather than the field's own echo: the lock screen shows the
            // same feedback, and it keeps the caret out of a field whose
            // contents can never be read back.
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 7
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
