pragma ComponentBehavior: Bound

import QtQuick
// No QtQuick.Layouts and no QtQuick.Shapes any more. The box is four items
// anchored to each other rather than a ColumnLayout of six, and the Shape was
// the success check's animated stroke.
import Quickshell.Io
import Quickshell.Services.Pam

// The password box. Something in the settings menu needs root; the menu closes
// and this takes its place, rather than throwing a terminal on screen whose
// first line is a bare "[sudo] password for ahaan:" with no indication of what
// asked or why.
//
// ── 2026-09-12: it is now a plain box, and nothing else ───────────────────
// Ahaan sent four reference shots of a single bordered rectangle with one
// centred line in it — "Enter Password", then dots with a caret, then
// "Checking…", then an italic "Authentication failed (2)" — and asked for
// exactly that: "a simple plain box for me to type the password into … no need
// for the green check authenticated text or any of that extra shit. If it
// works the box just goes away cuz pass was correct and if wrong you have the
// image to show authentication failed and i can just type again."
//
// So the box is four items: a centred row of dots with a caret after them, one
// centred line of text shown only while the field is empty, and an invisible
// TextInput over the whole thing. Gone: the lock glyph in its tinted square,
// the headline, the two-line subline, the inset field with its own fill and
// focus border, the hairline, the "↵ confirm / esc cancel" footer, the red
// failure border, and the entire success state — a green 3px edge, a green
// lock, and a check mark that popped and then drew itself.
//
// This is every flow it serves: sudo through the settings menu, polkit's
// prompts, changing the login password, and verify-only. Ahaan: "this is for
// all of them, polkit, firewall, etc etc." Nothing below the UI changed — the
// vlock pre-check, the PAM handling and the three flows are exactly as they
// were, and the notes on them are still accurate.
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

    // Three words, where there used to be a head and a hint each. The hints
    // ("Confirm it is you before changing it", "Type it once more") explained
    // the step the head had already named, and there is nowhere on this box to
    // put a second line any more — the placeholder IS the label. Same rule the
    // reminder prompt follows: which step you are on is said by what it asks
    // for, and by nothing else.
    readonly property var _passwdSteps: ["Current password", "New password", "Confirm new password"]

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
        // Only the not-us case is a wrong guess; ours was already vetted by
        // vlock, so a "no" from polkit is a locked or expired account and does
        // not advance the counter.
        if (!prompt.polkitSelf) prompt.attempts += 1
        prompt.failed = true
        shakeAnim.restart()
        field.forceActiveFocus()
    }

    function polkitAccepted() {
        prompt.busy = false
        prompt._pending = ""
        // Straight out. No held beat, no mark — see the note where `succeeded`
        // used to be declared.
        prompt.finished(true)
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
        prompt.attempts = 0
        prompt.busy = false
        prompt.failed = false
        prompt.commandFailed = false
        prompt.mismatch = false
        field.text = ""
    }

    readonly property bool alarm: prompt.failed || prompt.mismatch

    // There is no success state at all any more, and that is the ask: "if it
    // works the box just goes away cuz pass was correct".
    //
    // What went with it: a `succeeded` flag, a 1000ms hold on a doneTimer, a
    // two-part okAnim that popped a green disc and then DREW a check inside it
    // by walking the endpoint of a two-segment stroke (the dash-offset trick
    // silently does nothing under Shape.CurveRenderer, which is why it was
    // built that way), a green 3px border, a green lock glyph, and the
    // co-ordinated fade that cleared the dots and the placeholder out from
    // under the word "Authenticated". All of it to say a thing the box
    // disappearing says by itself.
    //
    // The check mark is not gone from the codebase — the fingerprint box still
    // morphs into one, because there the enrolment finishing is genuinely not
    // obvious from anything else on screen.

    // The confirm step disagreeing with the new password is neither an
    // authentication failure nor a command failure, and saying "Authentication
    // failed" there would be simply wrong.
    property bool mismatch: false

    // The (2) in "Authentication failed (2)". Counted only for attempts that
    // were actually WRONG — a command that failed after a correct password is
    // not a wrong guess and must not advance it. Reset by _reset(), so it
    // counts within one raising of the box rather than forever.
    property int attempts: 0

    // ── the one line this box has ─────────────────────────────────────────
    // It used to have three: a headline, a subline, and a footer of keybind
    // hints, plus a lock glyph in a tinted square. Ahaan's ask was a plain box
    // with one thing in it, so there is one string and it changes by state.
    //
    // It is only drawn when the field is EMPTY, which is what makes the four
    // states read as one line rather than as a stack: the field is cleared the
    // instant Enter is pressed, so "Checking…" and a failure both land in a box
    // that has just emptied itself, and the first keystroke after either
    // replaces the line with dots.
    readonly property string message: {
        if (prompt.busy)     return "Checking…"
        if (prompt.mismatch) return "Passwords do not match"
        if (prompt.failed)   return prompt.commandFailed
                                    ? "That did not work"
                                    : "Authentication failed (" + prompt.attempts + ")"
        if (prompt.flow === "passwd") return prompt._passwdSteps[prompt.stepIndex]
        // A polkit action that wants somebody else's password says so. Every
        // action on this machine resolves to this user, so this is the branch
        // that never fires — and it is here so that the day one does not, the
        // box is not quietly asking for the wrong password. It is also the one
        // piece of polkit's own wording that survives: the REASON it supplies
        // ("Authentication is required to…") is gone with the subline, and
        // whose password is wanted is the part that changes what you type.
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

    // Italic for anything that went wrong, upright for everything else. It is
    // the whole of the failure styling — there is no red border and no red
    // text, because the reference Ahaan gave has neither: the box keeps its
    // own edge and the words lean.
    readonly property bool messageItalic: prompt.alarm

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
        prompt.attempts += 1
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
                    // Verified and done. No command, no sudo — finished() hands
                    // straight off to whatever asked, which for the fingerprint
                    // flow means this box disappears and the enrol box takes
                    // its place on the next frame.
                    prompt.busy = false
                    prompt._pending = ""
                    prompt.finished(true)
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

    // There is no doneTimer. It held the box open for 1000ms so the success
    // mark had time to pop and then draw itself; with no mark to watch, that
    // 1000ms is just the box refusing to leave after it has been told the
    // password was right.

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
                prompt.finished(true)
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
                if (!prompt.commandFailed) prompt.attempts += 1
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

    // ── the box ───────────────────────────────────────────────────────────
    // One rectangle with one line of text centred in it, and nothing else.
    //
    // What this replaces: a 38px lock glyph in a tinted rounded square, a
    // headline, a two-line subline, a separate inset field with its own fill
    // and its own focus border, a hairline, and a footer reading "↵ confirm"
    // and "esc cancel". Ahaan, with four reference shots of exactly this shape:
    // "a simple plain box for me to type the password into … no need for the
    // green check authenticated text or any of that extra shit."
    //
    // The edge is this repo's, not the reference's — Theme.cardRadius and
    // Theme.cardBorder, the same 2px of alpha(col7, 0.8) the settings card and
    // every taskbar dropdown draw. "Of course borders and ui matches my style."
    width: Theme.cardWidth
    // FIXED, and that is the point of the whole redesign: every state — empty,
    // typing, checking, failed — is one line of text in a box of one size, so
    // nothing on screen moves as you go between them. The old card grew by a
    // line when polkit supplied a long reason and shrank again afterwards.
    height: 68
    radius: Theme.cardRadius
    color: Theme.bg
    border.width: Theme.cardBorder
    // One colour, always. The border used to go red on a failure and green at
    // 3px on success; the reference does neither, and with the failure said in
    // words inside the box a coloured edge is the same thing said twice.
    border.color: Theme.line

    // Appears and goes, like the settings card — see the note in
    // SettingsPanel.qml. It used to fade over 130ms.
    visible: prompt.shown

    // A wrong password should be felt, not just read. Kept when the red went:
    // this is the one failure signal that is not a word, it costs nothing to
    // read, and it fires on the same frame the message changes.
    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: prompt; property: "anchors.horizontalCenterOffset"; to:  9; duration: 45 }
        NumberAnimation { target: prompt; property: "anchors.horizontalCenterOffset"; to: -8; duration: 70 }
        NumberAnimation { target: prompt; property: "anchors.horizontalCenterOffset"; to:  5; duration: 60 }
        NumberAnimation { target: prompt; property: "anchors.horizontalCenterOffset"; to:  0; duration: 55 }
    }

    MouseArea { anchors.fill: parent }   // swallow clicks; the scrim is behind

    // ── the dots, centred, with the caret riding after them ───────────────
    // Centred rather than left-aligned, which is the reference and is also the
    // only arrangement that works in a box with no other content: a row of
    // dots starting 16px from the left edge of an otherwise empty 430px box
    // reads as text that has been cut off.
    Row {
        id: dotRow
        anchors.centerIn: parent
        spacing: 7
        visible: dots.count > 0

        Repeater {
            model: dots.count
            Rectangle {
                width: 7; height: 7; radius: 3.5
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.alpha(Theme.text, 0.75)
            }
        }

        // The caret. The field's own is suppressed (cursorDelegate is an empty
        // Item) because the field draws no glyphs either — so the caret has to
        // be drawn here, at the end of the dots, or there is nothing at all
        // saying the box is taking input. It is in the reference shot.
        Rectangle {
            width: 2
            height: 17
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.alpha(Theme.text, 0.85)
            // OPACITY, not visible. The Row is centred on the box, so a caret
            // that stops being laid out every half second makes the whole row
            // of dots step left and back — measured in the harness before this
            // was written, and it is the kind of jitter that is only obvious
            // once you have seen it. Its width is always reserved; only the ink
            // blinks.
            //
            // Blinks only while the field actually has the keyboard, so a box
            // that has lost focus does not look like it is still listening.
            opacity: (field.activeFocus && caretBlink.on) ? 1 : 0
        }
    }
    Timer {
        id: caretBlink
        property bool on: true
        interval: 530          // the X11/Qt default cursorFlashTime, halved
        running: prompt.shown && field.activeFocus
        repeat: true
        onTriggered: caretBlink.on = !caretBlink.on
        // Restarted from zero on every keystroke, so the caret is solid while
        // you type rather than winking out mid-word — which is what every text
        // field does and what its absence would look like a bug.
        function kick() { caretBlink.on = true; caretBlink.restart() }
    }

    // An INT model, not a JS array. Qt grows and shrinks an integer model by
    // the difference; rebinding an array destroys and recreates every delegate
    // on each keystroke, which this repo has been bitten by twice (notification
    // popups, and the lock screen's own dots).
    QtObject { id: dots; property int count: 0 }

    // ── the line ──────────────────────────────────────────────────────────
    // Shown only with the field empty, so it never shares the box with the
    // dots. See `message` for what it says in each of the four states.
    Text {
        anchors.centerIn: parent
        visible: dots.count === 0
        width: prompt.width - Theme.pad * 2
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: prompt.message
        color: Theme.dim
        font.family: Theme.font
        font.pixelSize: Theme.fsInput
        font.italic: prompt.messageItalic
    }

    // The field itself is invisible in every respect: no glyphs (colour
    // transparent), no caret (empty cursorDelegate), no fill and no border of
    // its own. It exists to hold the keyboard and the text; the dots and the
    // line above are the entire visible box.
    TextInput {
        id: field
        anchors.fill: parent
        anchors.leftMargin: Theme.pad
        anchors.rightMargin: Theme.pad
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        echoMode: TextInput.Password
        color: "transparent"
        cursorDelegate: Item {}
        font.family: Theme.font
        font.pixelSize: Theme.fsInput
        onTextChanged: {
            dots.count = Math.min(text.length, 32)
            caretBlink.kick()
            // Typing clears the failure, which is what makes "and i can just
            // type again" true: the line goes back to dots on the first key
            // rather than sitting there saying the last attempt was wrong.
            if (prompt.failed)   prompt.failed = false
            if (prompt.mismatch) prompt.mismatch = false
        }
        onAccepted: prompt.submit()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) { prompt.cancelled(); event.accepted = true }
        }
    }
}
