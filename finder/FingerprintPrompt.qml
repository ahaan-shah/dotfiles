pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
// QtQuick.Effects is back with the masked fill — see the header. It ships in
// qt6-declarative, which Quickshell already requires, so it is no new
// dependency. No QtQuick.Layouts, though. The box is anchored items rather than a ColumnLayout —
// there are only ever two of them visible at once.
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
// ── 2026-09-12: the box is the graphic ───────────────────────────────────
// Ahaan, having just had the password box stripped to a plain rectangle:
// "the fingerprint register box shows up with just a fingerprint design which
// has its grooves smoothly flow fill green part by part until the print is
// fully enrolled. No need for esc to cancel (thats obvious). Once enrolled the
// fingerprint design morphs into the green check here and a couple instants
// later the box vanishes on its own."
//
// So everything that was sharing the box with the graphic is gone: the glyph
// in its tinted square, "Place your finger" / "Keep pressing" / "Fingerprint
// enrolled", the divider and the keybind footer. One line survives under it —
// see `message`.
//
// ── The scanning graphic, and the version that is NOT here ───────────────
// A fingerprint glyph that fills green from the bottom as the presses land,
// with a soft edge, and morphs into a tick when it completes.
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
//
// ── What was tried in between, and reverted ──────────────────────────────
// Worth recording so nobody rebuilds it. Ahaan said "when i said green fill i
// meant the grooves fill, not the entire thing. And drop the gradient." Read
// literally, that asks for the print to be a set of separately-fillable
// grooves — so the glyph was replaced with five stroked arcs drawn in
// QtQuick.Shapes, each lit from its own start to a moving tip, in order, core
// outward, with no mask and no gradient anywhere.
//
// It did exactly what was asked and it did not look like a fingerprint. Three
// geometries were tried and each was wrong in a way that had a name: concentric
// near-rings were a TARGET, mouths widening outward were a RAINBOW, and the
// version that shipped — outer ridges wrapping further down the flanks, ends
// staggered off one radius — was, in Ahaan's words, "dude from what angle is
// this a fingerprint design?"
//
// The lesson is not about arcs. Five strokes cannot carry a fingerprint at
// 90px; the glyph is drawn by someone who solved that, and the request was
// about how the FILL reads, not about what the print is made of. The mask
// fills a shape that looks right; the arcs filled a shape that did not. So the
// glyph and the gradient are back exactly as they were, and only the size
// changed.
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
        dupeTimer.stop()
        nameField.text = ""
    }

    function focusInput() { nameField.forceActiveFocus() }

    readonly property bool alarm: fp.failed

    // ── what the box says, which on a good enrolment is nothing ───────────
    // One string each, where there used to be a head and a sub. The subs
    // ("All ten fingers are enrolled — delete one first", "polkit refused —
    // 49-fprintd-enroll.rules is not installed") were the more useful half in
    // two cases out of six, so these are not the heads: each is the one
    // sentence that says both what happened and what to do about it, inside
    // the width of the box.
    readonly property var _failWords: ({
        "no-free-slot":  "All ten slots are full",
        "duplicate":     "That finger is already enrolled",
        "unauthorized":  "polkit refused the enrolment",
        "nodevice":      "The sensor did not answer",
        "failed":        "The sensor rejected the scan",
        "incomplete":    "Enrolment did not finish"
    })

    // The single line under the art. Four things can land in it, and they are
    // ordered by how much they override each other.
    //
    // The COUNTER is back, in Ahaan's own notation: "you can keep the 10/21
    // text for enrolls left". It was taken out one pass earlier on "no need for
    // numbers" — that read as a rejection of the counter, and it was not; what
    // he did not want was the paragraph of prose it used to sit in. "10/21" is
    // three glyphs and says how much longer this will take, which a
    // fingerprint filling up does not, quite.
    //
    // Gone for good: "Place your finger", "Keep pressing", "N of M scans" as a
    // sentence, and "Fingerprint enrolled" — the glyph turns into a green
    // check, which is the same sentence.
    readonly property string message: {
        if (fp.done)   return ""
        if (fp.failed) return fp._failWords[fp.failReason] || fp._failWords["incomplete"]
        if (fp.flow === "name") return ""
        // A bad press is not a failure and it is the one thing the picture
        // cannot say: a sensor that silently ignores you reads as a broken
        // sensor. It displaces the counter for as long as it stands, which is
        // until the next accepted press — and that press moves the counter, so
        // nothing is lost by the swap.
        if (fp.retry !== "") return fp.retry
        // Only once the script has said how many presses this sensor wants.
        // Before STAGES arrives, stages is 0 and "0/0" would be a lie about a
        // number we do not have yet.
        if (fp.stages > 0) return fp.stage + "/" + fp.stages
        return ""
    }
    // Italic for a failure, upright for a retry hint — the same split the
    // password box uses, and it is what separates "this went wrong" from
    // "do that again, differently".
    readonly property bool messageItalic: fp.failed

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
        // Escape during the duplicate's 1.6s window would otherwise leave the
        // timer armed, and it would fire finished(false) a second later and
        // yank the user out of wherever they had navigated to by then.
        dupeTimer.stop()
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
                "move":   "Move your finger and press again",
                "short":  "Held too briefly — press and hold",
                "centre": "Not centred on the sensor",
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
            // A duplicate closes the box by itself, on Ahaan's instruction:
            // "when i try to enroll an already enrolled fprint, close the
            // registering box automatically."
            //
            // It is the one failure with nothing to decide. The other five are
            // either retryable (the sensor rejected the scan, the enrolment did
            // not finish — Return runs it again) or a state of the machine you
            // may want to sit and read (all ten slots full, polkit refused, no
            // reader). A finger that is already saved is none of those: there
            // is no second thing to try and no decision to make, so holding a
            // box open over it is asking for an Escape that says nothing.
            //
            // Long enough to read the line first, and the notification carries
            // the reason past the box closing — the box is gone by the time you
            // would go looking for why.
            if (rest === "duplicate") {
                Settings.notify("Already enrolled", "That finger is saved under another name")
                dupeTimer.restart()
            }
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

    // The duplicate auto-close. finished(false) rather than cancelled() because
    // both land in the same place in Finder.qml — back on the Fingerprints page
    // the enrolment was started from — and finished() is the one that also
    // re-reads the listing, which a duplicate has every reason to want: the
    // finger IS in that list, under the name it already has.
    property var _dupeTimer: Timer {
        id: dupeTimer
        interval: 1600
        repeat: false
        onTriggered: fp.finished(false)
    }

    // The success hold. There is a morph to watch here — the grooves fade out
    // as the check springs in — and cutting away mid-animation is what this was
    // added to avoid. Ahaan: "once enrolled the fingerprint design morphs into
    // the green check here and a couple instants later the box vanishes on its
    // own."
    //
    // The password box used to have one of these and no longer does: there is
    // nothing to watch there, so its beat was just the box refusing to leave.
    property var _doneTimer: Timer {
        id: doneTimer
        interval: 1100
        repeat: false
        onTriggered: fp.finished(true)
    }

    // ── the scanning graphic ──────────────────────────────────────────────
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

        // 92 in a 250x150 box. The size is the only thing about this graphic
        // that changed in the revert — see the header for why the rest of it
        // came back exactly as it was.
        implicitWidth: 92
        implicitHeight: 92
        readonly property int glyphSize: 88

        // ── centring the INK, which is not the same as centring the glyph ──
        // Ahaan: "make sure the fingerprint design is centered". The art Item
        // was already dead centre in the box and the print still sat visibly
        // right of it, because Text's AlignHCenter centres the glyph's ADVANCE
        // BOX and 󰈷's ink is not centred inside its own advance.
        //
        // Measured rather than nudged by eye, and measured TWICE because the
        // first pass over-corrected. Method: draw a magenta outline around the
        // art Item, screenshot the fully-green print, and read both boxes off
        // the pixels — the art Item from the outline, the ink by matching
        // Theme.good with a small fuzz. On a 2x display, in the art's own
        // 184x184 physical box whose centre is (92, 92):
        //
        //   no padding    ink centre (105, 91)   13 px right, 1 up
        //   0.205 / 0.045 ink centre  (87, 87)    5 px left,  5 up   <- too far
        //   0.148 / 0     ink centre  (92, 91)    centred            <- this
        //
        // So the glyph is off in X by about 6.5 logical px at this size and is
        // already centred in Y; the vertical correction in the first pass was
        // measuring its own error. The X figure is a bearing and scales with
        // the font, so it is a fraction of glyphSize rather than a pixel count
        // — change glyphSize and it still holds.
        //
        // Applied as PADDING and not as an offset or a transform, and that is
        // load-bearing: rightPadding shrinks the box the text centres itself
        // in, so the glyph moves by half of it, while the ITEM keeps the art's
        // exact size. greenGlyph has to stay exactly the art's size or the mask
        // below stops lining up with it 1:1 and MultiEffect stretches the
        // texture. An anchors margin or a Translate would each break that.
        readonly property real inkPadX: art.glyphSize * 0.148   // shifts left by half

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
            rightPadding: art.inkPadX
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
            rightPadding: art.inkPadX
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

    // ── the box ───────────────────────────────────────────────────────────
    // Two shapes, one for each step, and both are the password box's shape:
    // a plain bordered rectangle with the content centred in it and nothing
    // around the content.
    //
    //   name   430x68, exactly the password box. It asks for a label, so it is
    //          the same object asking — and the placeholder is the only thing
    //          that says which of the two it is.
    //   scan   250x150. 250 is Ahaan's width; the height is the "if u need
    //          more height in the box for that then do it" he granted when he
    //          asked for the scan counter back. 92px of art, 10px, one line of
    //          text, centred as a GROUP — see the Column, which is what makes
    //          the print sit in the middle of the box rather than high in it.
    //          250 fits every string this box produces on one line: the
    //          longest is "That finger is already enrolled" at 31 characters
    //          against roughly 33 that fit. The two-line wrap stays as a
    //          backstop.
    //
    // Removed, on Ahaan's instruction: the fingerprint glyph in its tinted
    // rounded square, the headline and subline on both steps, the hairline,
    // and the "↵ continue / esc cancel" footer. Escape and Return both still
    // do what they did — "no need for esc to cancel (thats obvious)".
    readonly property bool naming: fp.flow === "name"

    width:  fp.naming ? Theme.cardWidth : 250
    height: fp.naming ? 68 : 150
    radius: Theme.cardRadius
    color: Theme.bg
    border.width: Theme.cardBorder
    // One colour, always. It used to go 3px green on completion and red on a
    // failure; the completion is now said by the glyph turning into a check,
    // and the failure by the words inside the box, so a coloured edge is each
    // of those said twice.
    border.color: Theme.line

    visible: fp.shown

    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: fp; property: "anchors.horizontalCenterOffset"; to:  9; duration: 45 }
        NumberAnimation { target: fp; property: "anchors.horizontalCenterOffset"; to: -8; duration: 70 }
        NumberAnimation { target: fp; property: "anchors.horizontalCenterOffset"; to:  5; duration: 60 }
        NumberAnimation { target: fp; property: "anchors.horizontalCenterOffset"; to:  0; duration: 55 }
    }

    MouseArea { anchors.fill: parent }   // swallow clicks; the scrim is behind

    // ── name step ─────────────────────────────────────────────────────────
    // The text is drawn, not dotted. A label is not a secret, and hiding one
    // behind dots would be theatre — which is the same reason this step was
    // never folded into PasswordPrompt.
    Text {
        anchors.centerIn: parent
        visible: fp.naming && nameField.text.length === 0
        text: "Name this fingerprint"
        color: Theme.dim
        font.family: Theme.font
        font.pixelSize: Theme.fsInput
    }

    TextInput {
        id: nameField
        anchors.fill: parent
        anchors.leftMargin: Theme.pad
        anchors.rightMargin: Theme.pad
        visible: fp.naming
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        color: Theme.text
        selectionColor: Theme.alpha(Theme.accent, 0.45)
        font.family: Theme.font
        font.pixelSize: Theme.fsInput
        // The store caps at 48 too (scripts/fingerprint.sh); stopping it here
        // as well means the name shown back is the name saved.
        maximumLength: 48
        onAccepted: fp.submitName()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) { fp.cancelled(); event.accepted = true }
        }
    }

    // ── scan step ─────────────────────────────────────────────────────────
    // The art and, when there is something to say, one line under it. The line
    // is not `visible: false` when empty — its HEIGHT is always reserved, so a
    // bad press appearing and clearing does not shuffle the picture up and down
    // the box. Same reservation rule as the settings rows' trailing slots.
    // The art and its line are ONE centred group, which is the fix for "make
    // sure the fingerprint design is centered".
    //
    // They used to be anchored separately — the art to the box's middle with a
    // hand-tuned offset, the line to the box's bottom — and that offset was a
    // number that had to be re-guessed every time either the box height or the
    // art size changed. It was wrong by the time Ahaan saw it. A Column
    // centred in the box has no number to get wrong: whatever the two children
    // measure, the pair of them sits in the middle.
    //
    // Column and not ColumnLayout — a positioner, not a layout, so no
    // QtQuick.Layouts import for two items.
    Column {
        anchors.centerIn: parent
        visible: !fp.naming
        spacing: 10

        ScanArt {
            id: art
            anchors.horizontalCenter: parent.horizontalCenter
            stage: fp.stage
            stages: fp.stages
            complete: fp.done
            failed: fp.failed
        }

        Text {
            width: fp.width - 16 * 2
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            text: fp.message
            // A bad press is an instruction and a failure is a failure, but
            // neither is red — the art already goes red on a failure, which is
            // the louder of the two signals and does not need the words to
            // join in.
            color: Theme.dim
            font.family: Theme.font
            font.pixelSize: Theme.fsSub
            font.italic: fp.messageItalic
        }
    }

    // The scan step has no focused input, so Escape has nothing to arrive
    // through. This gives the box its own handler for it — and it is the only
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
