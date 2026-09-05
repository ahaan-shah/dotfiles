pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell.Io

// Enrolling a fingerprint: name it, then press the sensor until fprintd is
// satisfied. Raised by Security → Fingerprints → Add fingerprint, and it takes
// the settings menu's place exactly as the password box does — one card on
// screen at a time.
//
// ── Why this is not another flow inside PasswordPrompt ────────────────────
// Changing a password reuses the password box, and the reasoning there was
// Ahaan's "one authenticate-password design everywhere". This deliberately
// does not, because there is no password in it: the name step is plain visible
// text (a label is not a secret and hiding it behind dots would be theatre),
// the scan step has no input at all, and nothing here touches PAM, sudo or
// privileged-run.sh. Folding it in would have meant guarding almost every
// property in that file on a flow that shares none of its machinery.
//
// What it does share is the look, and that is not a copy — the card metrics,
// the palette and the type scale all come from Theme.qml, which exists so that
// this and the password box cannot drift apart.
//
// ── The authentication still happens; it happens first ────────────────────
// Settings.qml raises the password box BEFORE this one and only opens this on
// a verified password. So by the time a finger touches the sensor the user has
// already proved who they are, through the same box as everything else.
//
// ── The scanning graphic ──────────────────────────────────────────────────
// A fingerprint that fills green from the bottom as the presses land, with a
// soft edge, and morphs into a tick when it completes.
//
// The first version scattered the fill across a 7x9 grid of clipped copies of
// the glyph, lit in a shuffled order. On screen that read as BLOCKY — 63 cells
// is coarse enough that each press lit a visible rectangle, and the fill looked
// like tiling rather than like a scan. Making the cells smaller only trades
// that for hundreds of clipped glyph rasterisations.
//
// So the reveal is a mask, not a mosaic: one green glyph rendered to a texture,
// masked by a vertical alpha ramp whose threshold slides with progress.
// MultiEffect's maskSpreadAtMin is what softens the boundary, so the edge is a
// gradient rather than a line. QtQuick.Effects ships in qt6-declarative, which
// Quickshell already requires — no new dependency.
//
// The slide is eased rather than stepped: `fill` is a Behavior'd copy of the
// raw progress, so each accepted press glides the boundary up over 420ms
// instead of jumping it 1/21 of the way.
Rectangle {
    id: fp

    property bool shown: false

    // "name"  type a label for it.
    // "scan"  fingerprint.sh is running; presses are arriving.
    property string flow: "name"

    property string fpName: ""
    // Both come off the script's protocol and neither is displayed, which is
    // deliberate rather than an oversight — see the subline below. They are
    // kept because they are what a failure has to be diagnosed against: the
    // console warning on a failed enrolment is meaningless without knowing
    // which slot fprintd was working on.
    property string finger: ""        // the fprintd slot the script picked
    property string fingerLabel: ""   // "Right index finger"
    property int stages: 0            // how many presses this sensor wants
    property int stage: 0             // how many it has accepted
    property bool done: false
    property bool failed: false
    property string failReason: ""
    // Set by a RETRY line and cleared by the next accepted press. A bad press
    // is not a failure and must not turn the card red — it just needs saying,
    // because a sensor that silently ignores you reads as a broken sensor.
    property string retry: ""

    signal finished(bool ok)
    signal cancelled()

    function begin() {
        fp.flow = "name"
        fp.fpName = ""
        fp.finger = ""
        fp.fingerLabel = ""
        fp.stages = 0
        fp.stage = 0
        fp.done = false
        fp.failed = false
        fp.failReason = ""
        fp.retry = ""
        nameField.text = ""
    }

    function focusInput() { nameField.forceActiveFocus() }

    readonly property bool alarm: fp.failed

    // ── what the card says ────────────────────────────────────────────────
    readonly property var _failWords: ({
        "no-free-slot":  { head: "No free slots",           sub: "All ten fingers are enrolled — delete one first" },
        "duplicate":     { head: "Already enrolled",        sub: "That finger is saved under another name" },
        "unauthorized":  { head: "Not allowed to enrol",    sub: "polkit refused — 49-fprintd-enroll.rules is not installed" },
        "nodevice":      { head: "No reader",               sub: "The fingerprint sensor did not answer" },
        "failed":        { head: "Enrolment failed",        sub: "The sensor rejected the scan — try again" },
        "incomplete":    { head: "Enrolment did not finish", sub: "Try again, or press esc to cancel" }
    })

    readonly property string headline: {
        if (fp.done)   return "Fingerprint enrolled"
        if (fp.failed) return (fp._failWords[fp.failReason] || fp._failWords["incomplete"]).head
        if (fp.flow === "name") return "Name this fingerprint"
        if (fp.stage === 0) return "Place your finger"
        return "Keep pressing"
    }
    readonly property string subline: {
        // Nothing under "Fingerprint enrolled" — the tick and the headline have
        // already said it, and the notification carries the detail. Same rule
        // the password box's success state follows.
        if (fp.done)   return ""
        if (fp.failed) return (fp._failWords[fp.failReason] || fp._failWords["incomplete"]).sub
        // No subtitle on the name step. "So you can tell it apart later" was
        // explaining why you would want to name a thing the headline has just
        // asked you to name, which is the same redundancy the settings menu's
        // no-subtitle-on-a-row-that-does-what-it-says rule already covers. The
        // Text collapses on an empty string, so the card gets shorter too.
        if (fp.flow === "name") return ""
        if (fp.retry !== "") return fp.retry
        // Deliberately does NOT name the finger. The slot is picked by the
        // script from whatever is free, so "Right thumb" here was reporting an
        // implementation detail as though the user had chosen it — and the
        // name they typed a moment earlier already says which fingerprint this
        // is. Enrolments are identified by their name and are independent of
        // whichever slot fprintd happened to hand out.
        if (fp.stages > 0) return fp.stage + " of " + fp.stages + " scans"
        return "Press and lift until it completes"
    }

    // ── name step ─────────────────────────────────────────────────────────
    function submitName() {
        const n = nameField.text.trim()
        if (n.length === 0) return
        fp.fpName = n
        fp.flow = "scan"
        fp.stage = 0
        fp.retry = ""
        // Take the focus explicitly rather than leaving it to the `focus`
        // binding at the bottom of this file. The name field is inside an item
        // that goes invisible on this same tick, and Escape during a scan has
        // no other way in — it is the only way out of an enrolment short of
        // finishing one, and a scan you cannot cancel holds the sensor.
        fp.forceActiveFocus()
        enrollProc.command = ["bash", "-c",
            Sys.quote(Settings.scriptDir + "/fingerprint.sh") + " enroll " + Sys.quote(n)]
        enrollProc.running = true
    }

    // Only the two that another go could actually fix. "No free slots",
    // "already enrolled", "polkit refused" and "no reader" are all states of
    // the machine, not of the scan, and offering "try again" against any of
    // them would be offering something that cannot work.
    readonly property bool retryable: fp.failed
        && (fp.failReason === "failed" || fp.failReason === "incomplete")

    // Same name, same box, a fresh run. The slot is chosen again from scratch
    // rather than reused — the previous attempt did not fill one, and asking
    // the script for a free slot is how that stays true.
    function retryScan() {
        if (!fp.retryable) return
        fp.failed = false
        fp.failReason = ""
        fp.stage = 0
        fp.retry = ""
        enrollProc.running = false
        enrollProc.command = ["bash", "-c",
            Sys.quote(Settings.scriptDir + "/fingerprint.sh") + " enroll " + Sys.quote(fp.fpName)]
        enrollProc.running = true
    }

    function abort() {
        // Setting running = false terminates the script, whose own trap kills
        // fprintd-enroll — which MATTERS: a live fprintd-enroll keeps the
        // device claimed, and a claimed device makes the lock screen's
        // fprintd-verify fail. See the enrol section of scripts/fingerprint.sh.
        enrollProc.running = false
        fp.cancelled()
    }

    // ── the script's line protocol ────────────────────────────────────────
    // SLOT / LABEL / STAGES / STAGE n / RETRY why / DONE / FAIL why.
    function _onLine(raw) {
        const line = String(raw).trim()
        if (line === "") return
        const sp = line.indexOf(" ")
        const verb = sp < 0 ? line : line.substring(0, sp)
        const rest = sp < 0 ? "" : line.substring(sp + 1)

        if (verb === "SLOT")   { fp.finger = rest; return }
        if (verb === "LABEL")  { fp.fingerLabel = rest; return }
        if (verb === "STAGES") { fp.stages = parseInt(rest, 10) || 0; return }
        if (verb === "STAGE")  {
            fp.stage = parseInt(rest, 10) || 0
            fp.retry = ""
            return
        }
        if (verb === "RETRY") {
            fp.retry = ({
                "move":   "Move your finger a little and press again",
                "short":  "Held too briefly — press and hold",
                "centre": "Not centred on the sensor — try again",
                "lift":   "Lift your finger, then press again"
            })[rest] || "That press did not register — try again"
            return
        }
        if (verb === "DONE") {
            fp.done = true
            Settings.notify("Fingerprint enrolled", fp.fpName)
            doneTimer.restart()
            return
        }
        if (verb === "FAIL") {
            fp.failed = true
            fp.failReason = rest
            shakeAnim.restart()
            return
        }
    }

    property var _enrollProc: Process {
        id: enrollProc
        running: false
        // SplitParser, so each press is acted on as it arrives rather than at
        // exit — the script's `stdbuf -oL` is the other half of that.
        stdout: SplitParser { splitMarker: "\n"; onRead: data => fp._onLine(data) }
        // Collected, not dropped: a `die` from the script goes to stderr and
        // is the only thing that would say why an enrolment never started.
        stderr: StdioCollector { id: enrollErr }
        onExited: (code, status) => {
            if (fp.done || fp.failed) return
            const why = String(enrollErr.text || "").trim()
            if (why !== "")
                console.warn("fingerprint enrol failed on", fp.finger || "(no slot)", ":", why)
            fp.failed = true
            fp.failReason = "incomplete"
            shakeAnim.restart()
        }
    }

    // Longer than the password box's 700ms: there is a morph to watch here,
    // and cutting away mid-animation is what it was added to avoid.
    property var _doneTimer: Timer {
        id: doneTimer
        interval: 1100
        repeat: false
        onTriggered: fp.finished(true)
    }

    // ── the scanning graphic ──────────────────────────────────────────────
    component ScanArt: Item {
        id: art
        property int stage: 0
        property int stages: 0
        property bool complete: false
        // Seen in the harness: a duplicate finger left a fully green
        // fingerprint sitting under a red "Already enrolled", so the picture
        // and the words disagreed. What was collected turns red instead — the
        // progress was real, it just did not end well.
        property bool failed: false

        implicitWidth: 64
        implicitHeight: 64
        readonly property int glyphSize: 58

        readonly property real progress: art.complete ? 1
            : (art.stages > 0 ? Math.min(1, art.stage / art.stages) : 0)

        // The eased copy. A Behavior fires on a binding change as well as an
        // assignment, so each press slides the boundary rather than stepping
        // it — which is the whole difference between this reading as a scan
        // and reading as a progress bar.
        property real fill: art.progress
        Behavior on fill { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }

        // The unlit fingerprint underneath. Faint, so the filled part carries
        // the contrast and the shape is still legible before the first press.
        Text {
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "󰈷"
            font.family: Theme.font
            font.pixelSize: art.glyphSize
            color: Theme.alpha(Theme.text, 0.18)
            opacity: art.complete ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 240 } }
        }

        // The green copy. Never drawn directly — `layer.enabled` renders it to
        // a texture for MultiEffect to sample, and `visible: false` keeps the
        // unmasked version off the screen.
        Text {
            id: greenGlyph
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "󰈷"
            font.family: Theme.font
            font.pixelSize: art.glyphSize
            color: art.failed ? Theme.danger : Theme.good
            Behavior on color { ColorAnimation { duration: 220 } }
            visible: false
            layer.enabled: true
        }

        // The ramp the threshold slides along: transparent at the top, opaque
        // at the bottom, so a falling threshold reveals upward. Taller than the
        // art and centred on it, which keeps the glyph inside the ramp's middle
        // band — at exactly the art's height the extreme rows sit at alpha 0
        // and 1, where a clamped threshold can neither fully hide nor fully
        // show them.
        Rectangle {
            id: fillMask
            width: art.width
            height: art.height * 1.5
            anchors.centerIn: parent
            visible: false
            layer.enabled: true
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#00ffffff" }
                GradientStop { position: 1.0; color: "#ffffffff" }
            }
        }

        MultiEffect {
            anchors.fill: parent
            source: greenGlyph
            maskEnabled: true
            maskSource: fillMask
            // Threshold falls as the fill rises. maskSpreadAtMin widens the
            // band either side of it, and that band IS the soft edge.
            maskThresholdMin: 1.0 - art.fill
            // 0.35, not 0.6. Wider than this and the whole lower half sits at
            // partial opacity rather than filling solid behind a soft edge —
            // it looked like a glow, and an individual press stopped being
            // visible in it. This is the band, not the fill.
            maskSpreadAtMin: 0.35
            opacity: art.complete ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 240 } }
        }

        // The morph: the green fill and the faint base both fade as this fades
        // and springs in, so one mark becomes the other in place.
        Text {
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "󰄬"
            font.family: Theme.font
            font.pixelSize: art.glyphSize
            color: Theme.good
            opacity: art.complete ? 1 : 0
            scale: art.complete ? 1 : 0.55
            Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            Behavior on scale   { NumberAnimation { duration: 340; easing.type: Easing.OutBack } }
        }
    }

    // ── card ──────────────────────────────────────────────────────────────
    width: Theme.cardWidth
    implicitHeight: col.implicitHeight + Theme.pad * 2
    radius: Theme.cardRadius
    color: Theme.bg
    border.width: fp.done ? 2.5 : 1
    border.color: fp.done ? Theme.alpha(Theme.good, 0.85)
                : fp.alarm ? Theme.alpha(Theme.danger, 0.55) : Theme.line
    Behavior on border.color { ColorAnimation { duration: 160 } }

    opacity: fp.shown ? 1 : 0
    scale:   fp.shown ? 1 : 0.97
    visible: opacity > 0.001
    Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
    Behavior on scale   { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: fp; property: "anchors.horizontalCenterOffset"; to:  9; duration: 45 }
        NumberAnimation { target: fp; property: "anchors.horizontalCenterOffset"; to: -8; duration: 70 }
        NumberAnimation { target: fp; property: "anchors.horizontalCenterOffset"; to:  5; duration: 60 }
        NumberAnimation { target: fp; property: "anchors.horizontalCenterOffset"; to:  0; duration: 55 }
    }

    MouseArea { anchors.fill: parent }   // swallow clicks; the scrim is behind

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: Theme.pad
        spacing: 14

        // ── name step: the password box's header, and a visible field ─────
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            visible: fp.flow === "name"

            Rectangle {
                implicitWidth: 38; implicitHeight: 38
                radius: 12
                color: Theme.alpha(Theme.accent, 0.20)
                Text {
                    anchors.centerIn: parent
                    text: "󰈷"
                    color: Theme.text
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
                    text: fp.headline
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: Theme.fsRow + 1
                    font.weight: Font.Medium
                }
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    visible: text.length > 0
                    text: fp.subline
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fsSub
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 42
            radius: 12
            visible: fp.flow === "name"
            color: Theme.alpha(Theme.col7, 0.07)
            border.width: 1
            border.color: nameField.activeFocus ? Theme.alpha(Theme.accent, 0.55) : Theme.hairline
            Behavior on border.color { ColorAnimation { duration: 140 } }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                visible: nameField.text.length === 0
                text: "Right thumb, Work finger…"
                color: Theme.dimmer
                font.family: Theme.font
                font.pixelSize: Theme.fsInput
            }

            TextInput {
                id: nameField
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.text
                selectionColor: Theme.alpha(Theme.accent, 0.45)
                font.family: Theme.font
                font.pixelSize: Theme.fsInput
                // The store caps at 48 too (scripts/fingerprint.sh); stopping
                // it here as well means the name shown back is the name saved.
                maximumLength: 48
                onAccepted: fp.submitName()
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) { fp.cancelled(); event.accepted = true }
                }
            }
        }

        // ── scan step ─────────────────────────────────────────────────────
        // No top margin, and the column's own 14px spacing is all that sits
        // above it: at 128px with a 6px margin on top this card stood about
        // 265px tall, which is half again the password box it is meant to
        // match. 78px art brings the two within ~20px of each other.
        ScanArt {
            id: art
            Layout.alignment: Qt.AlignHCenter
            // Pulls the headline up under the mark. The column's 14px spacing
            // is right between a field and a divider and too much between a
            // graphic and its own caption.
            Layout.bottomMargin: -5
            visible: fp.flow === "scan"
            stage: fp.stage
            stages: fp.stages
            complete: fp.done
            failed: fp.failed
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3
            visible: fp.flow === "scan"
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: fp.headline
                color: fp.done ? Theme.good : fp.alarm ? Theme.danger : Theme.text
                font.family: Theme.font
                font.pixelSize: Theme.fsRow + 1
                font.weight: Font.Medium
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                visible: text.length > 0
                text: fp.subline
                // A bad press is amber-ish rather than red: it is an
                // instruction, not a failure, and colouring it like one made a
                // perfectly normal enrolment look like it was going wrong.
                color: fp.alarm ? Theme.danger
                     : fp.retry !== "" ? Theme.alpha(Theme.text, 0.7) : Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fsSub
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.hairline }

        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Text {
                visible: fp.flow === "name" || fp.retryable
                text: fp.retryable ? "↵ try again" : "↵ continue"
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

    // The scan step has no focused input, so Escape has nothing to arrive
    // through. This gives the card its own handler for it — and it is the only
    // way out of a scan short of finishing one.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            if (fp.flow === "scan" && !fp.done) fp.abort()
            else fp.cancelled()
            event.accepted = true
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && fp.retryable) {
            fp.retryScan()
            event.accepted = true
        }
    }
    focus: fp.shown && fp.flow === "scan"
}
