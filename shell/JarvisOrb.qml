// JarvisOrb.qml — EVE's face: the orb that is the assistant on screen.
//
// One component, drawn at any size, used in two places: in the pill and in
// flight (Jarvis.qml, on the overlay), and resting in the bar's centre island
// (Bar.qml). The hand-off between them is a swap of identical drawings at the
// same pixel, which only works because there is one drawing.
//
// ── The design (2026-10-06) ──────────────────────────────────────────────
// From two references Ahaan sent (a white sphere with black capsule eyes; the
// "Grok Bot" disc), then: "eyes straight normally", "nice and big", "blink
// these long eyes", "morph into other shapes like >< and -- and circles like
// the agent bar bot", "super natural looking and cute AI types". So:
//
//   - a plain col7 disc (the bar's text colour, the agents bot's fill) with
//     big Theme.bg eyes that read as cut-outs on the bar's island;
//   - the eyes are one of four SHAPES, and every mood is a shape plus where
//     the eyes are looking:
//         capsule  tall and upright — at rest, and thinking (glancing about)
//         circle   wide, like the agents bot — waiting on an answer
//         chevron  > <  — done, pleased
//         dash     – –  — something went wrong
//     A change of shape is a MORPH, not a cut: the blob's width, height and
//     corner radius animate (capsule ⇄ circle ⇄ dash are all one rounded
//     rectangle), and the chevrons grow out of a shrinking blob;
//   - she blinks — a squash to a slit and a slightly springy reopen, now and
//     then twice — and glances while idle, on randomised clocks, so the face
//     is never on a visible loop.
//
// ── Why nothing here is a Behavior ───────────────────────────────────────
// Pose and blink both shape the eye's height, so they are separate factors —
// eyeH * blinkK — each with exactly one animation writing it. Bar.qml's fifth
// toolkit trap: a Behavior cannot be stopped, so two animations on one
// property both write it every frame and the face settles at a size nothing
// chose. Rotation is gone entirely: "the eyes are turning on a pivot, real
// weird" — eyes move and change shape; they do not spin.
import QtQuick
import QtQuick.Shapes

Item {
    id: orb

    // idle | think | ask | happy | error
    property string mood: "idle"
    property real headSize: 16

    readonly property color skin: Theme.col7
    readonly property color ink: Theme.bg

    implicitWidth: headSize
    implicitHeight: headSize

    // ── pose, all in head diameters so it scales ───────────────────────
    property real eyeW: 0.15
    property real eyeH: 0.36
    property real chev: 0        // 0 blob .. 1 chevrons > <
    property real gazeX: 0
    property real gazeY: 0
    property real blinkK: 1      // owned by the blink animations alone

    readonly property real dia: headSize
    readonly property real eyeDX: 0.19

    function _pose(w, h, ch, gx, gy, ms) {
        poseAnim.stop()
        aw.to = w; ah.to = h; ac.to = ch; ax.to = gx; ay.to = gy
        for (const a of [aw, ah, ac, ax, ay]) a.duration = ms
        poseAnim.start()
    }
    function _look(gx, gy, ms) {      // move without changing shape
        _pose(eyeW, eyeH, chev, gx, gy, ms)
    }
    ParallelAnimation {
        id: poseAnim
        NumberAnimation { id: aw; target: orb; property: "eyeW";  easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        NumberAnimation { id: ah; target: orb; property: "eyeH";  easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        NumberAnimation { id: ac; target: orb; property: "chev";  easing.type: Easing.InOutCubic }
        NumberAnimation { id: ax; target: orb; property: "gazeX"; easing.type: Easing.InOutSine }
        NumberAnimation { id: ay; target: orb; property: "gazeY"; easing.type: Easing.InOutSine }
    }

    // ── blinking ────────────────────────────────────────────────────────
    // A squash to a slit, held a beat, and a reopen with a little spring —
    // the shape a cartoon eye blinks with. Sometimes twice.
    SequentialAnimation {
        id: blink
        NumberAnimation { target: orb; property: "blinkK"; to: 0.12; duration: 65;  easing.type: Easing.InQuad }
        PauseAnimation  { duration: 35 }
        NumberAnimation { target: orb; property: "blinkK"; to: 1.0;  duration: 150; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
    }
    SequentialAnimation {
        id: doubleBlink
        NumberAnimation { target: orb; property: "blinkK"; to: 0.12; duration: 60; easing.type: Easing.InQuad }
        NumberAnimation { target: orb; property: "blinkK"; to: 1.0;  duration: 90; easing.type: Easing.OutQuad }
        PauseAnimation  { duration: 90 }
        NumberAnimation { target: orb; property: "blinkK"; to: 0.12; duration: 60; easing.type: Easing.InQuad }
        NumberAnimation { target: orb; property: "blinkK"; to: 1.0;  duration: 150; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
    }
    readonly property bool canBlink: chev < 0.05 && mood !== "error"
    Timer {
        interval: 2800; repeat: true
        running: orb.visible && orb.canBlink
        onTriggered: {
            interval = 2200 + Math.random() * 3600
            if (blink.running || doubleBlink.running) return
            (Math.random() < 0.18 ? doubleBlink : blink).restart()
        }
    }
    function blinkNow() { blink.restart() }

    // ── idle life: the occasional glance ────────────────────────────────
    Timer {
        interval: 4000; repeat: true
        running: orb.visible && orb.mood === "idle"
        onTriggered: {
            interval = 3500 + Math.random() * 4000
            if (Math.random() < 0.45) orb._look(0, 0, 420)                       // back to centre
            else orb._look((Math.random() < 0.5 ? -1 : 1) * 0.06, (Math.random() - 0.6) * 0.06, 380)
        }
    }

    // Thinking: looking about while working something out — side, up, other
    // side — gliding, never turning.
    property int _step: 0
    readonly property var _thinkPath: [[0.08, -0.04], [-0.08, -0.04], [0.06, 0.0], [-0.07, -0.05]]
    Timer {
        interval: 700; repeat: true
        running: orb.mood === "think"
        triggeredOnStart: true
        onTriggered: {
            const p = orb._thinkPath[orb._step++ % orb._thinkPath.length]
            orb._pose(0.15, 0.36, 0, p[0], p[1], 420)
        }
    }

    // A little bob for "done" — scale, not position, so it cannot move the orb
    // off the pixel the bar placed it on.
    SequentialAnimation {
        id: hop
        NumberAnimation { target: body; property: "scale"; to: 1.14; duration: 130; easing.type: Easing.OutQuad }
        NumberAnimation { target: body; property: "scale"; to: 1.0;  duration: 280; easing.type: Easing.OutBack }
    }

    onMoodChanged: {
        switch (mood) {
        case "think": break                                                 // the timer drives it
        case "ask":   _pose(0.22, 0.22, 0, 0, 0.05, 300); blinkNow(); break   // circles, looking down at the card
        case "happy": _pose(0.10, 0.10, 1, 0, 0, 280); hop.restart(); break   // > <
        case "error": _pose(0.24, 0.07, 0, 0, 0.05, 280); break               // – –
        default:      _pose(0.15, 0.36, 0, 0, 0, 340)                         // tall capsules
        }
    }

    Item {
        id: body
        anchors.centerIn: parent
        width: orb.dia; height: orb.dia

        // The disc under the CurveRenderer, as the agents bot draws its head:
        // the bar has no multisampling, and a radius'd 14 px circle measured
        // as a stepped edge. Ahaan: "make sure the edge is clean".
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: orb.skin
                strokeColor: "transparent"
                strokeWidth: 0
                PathAngleArc {
                    centerX: orb.dia / 2; centerY: orb.dia / 2
                    radiusX: orb.dia / 2; radiusY: orb.dia / 2
                    startAngle: 0; sweepAngle: 360
                }
            }
        }

        Repeater {
            model: [-1, 1]
            delegate: Item {
                id: eye
                required property int modelData
                readonly property int side: modelData
                width: orb.dia * 0.4; height: width
                x: orb.dia / 2 + side * orb.eyeDX * orb.dia + orb.gazeX * orb.dia - width / 2
                y: orb.dia / 2 - orb.dia * 0.03 + orb.gazeY * orb.dia - height / 2

                // The blob: capsule, circle or dash — one rounded rectangle.
                // It shrinks away as the chevron takes over.
                Rectangle {
                    anchors.centerIn: parent
                    width: orb.eyeW * orb.dia * (1 - orb.chev * 0.6)
                    height: Math.max(orb.dia * 0.035, orb.eyeH * orb.dia * orb.blinkK * (1 - orb.chev * 0.6))
                    radius: Math.min(width, height) / 2
                    color: orb.ink
                    opacity: 1 - orb.chev
                    antialiasing: true
                }

                // The chevron: > on the left eye, < on the right, pointing at
                // each other — a squeezed, pleased look.
                Shape {
                    id: chevShape
                    anchors.centerIn: parent
                    width: orb.dia * 0.22; height: width
                    preferredRendererType: Shape.CurveRenderer
                    opacity: orb.chev
                    visible: orb.chev > 0.01
                    scale: 0.55 + 0.45 * orb.chev
                    readonly property real a: width * 0.26
                    readonly property real b: width * 0.36
                    readonly property real c: width / 2
                    // Left eye: >, its point toward the centre (+x);
                    // right eye: <, its point toward the centre (-x).
                    readonly property real tip: eye.side < 0 ? c + a : c - a
                    readonly property real tail: eye.side < 0 ? c - a : c + a
                    ShapePath {
                        strokeColor: orb.ink
                        strokeWidth: Math.max(1.2, orb.dia * 0.075)
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        startX: chevShape.tail; startY: chevShape.c - chevShape.b
                        PathLine { x: chevShape.tip;  y: chevShape.c }
                        PathLine { x: chevShape.tail; y: chevShape.c + chevShape.b }
                    }
                }
            }
        }
    }
}
