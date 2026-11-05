// Vinyl.qml — the album cover as a disc: circular, spins while `spinning`.
//
// It lived in Bar.qml as an inline component for the notification center's media
// box, masked into a circle with a MultiEffect. The player moved to the centre
// island (Music.qml, 2026-10-25) and three ways of doing the circle have been
// through here:
//
//   1. MultiEffect mask (the original). "Super laggy and choppy" to open:
//      QSG_RENDER_TIMING put the player's window at a 29 ms worst frame
//      against 17 (todo) and 14 (reminders) — the effect compiles its shaders
//      on first use and re-renders its layers while the disc turns.
//   2. A square image turning behind a plate, the island's colour with a
//      circular hole in it. Two faults, both Ahaan's screenshots: the plate
//      is a rectangle laid over the island, so it painted over the island's
//      own border at the left and bottom; and the tenant fades in with the
//      island, so for the first frames the plate was translucent and the
//      turning square showed through it ("I can see the square for a fraction
//      of a second"). A plate can only work on an opaque, borderless
//      background, which this is not.
//   3. This: the circle IS the shape. A Shape draws a circle path filled
//      with the image as its texture (ShapePath.fillItem), and the Shape is
//      what turns, so picture and outline go round together. There is no
//      square anywhere to show, no mask, no offscreen layer, and nothing
//      laid over the island.
//
// It still pauses rather than stops, so a resume carries on from the angle it
// froze at. The rim is static and drawn on top.
import QtQuick
import QtQuick.Shapes

Item {
    id: v
    property string art: ""
    property bool spinning: false
    // the play/pause button's ring colour (Music.qml), so the two match on any theme
    property color rim: Theme.text
    property real rimWidth: 3

    // The texture. Not drawn itself (the Shape draws it); asynchronous so the
    // first open is not held up decoding a cover.
    Image {
        id: img
        visible: false
        width: v.width; height: v.height
        source: v.art
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize.width: 320; sourceSize.height: 320
    }

    Item {
        id: disc
        anchors.fill: parent

        Shape {
            anchors.fill: parent
            visible: v.art !== ""
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillItem: img
                strokeColor: "transparent"
                startX: v.width; startY: v.height / 2
                PathArc { x: 0; y: v.height / 2; radiusX: v.width / 2; radiusY: v.height / 2 }
                PathArc { x: v.width; y: v.height / 2; radiusX: v.width / 2; radiusY: v.height / 2 }
            }
        }

        NumberAnimation on rotation {
            from: 0; to: 360
            duration: 10000
            loops: Animation.Infinite
            running: true
            paused: !v.spinning
        }
    }

    // fallback when there's no cover art. Outside `disc` on purpose: inside
    // it the note glyph turned with the disc and, with nothing playing, sat
    // frozen at whatever angle it had stopped at (Ahaan's screenshot: the
    // note tilted). There is no picture to spin here, so it stays upright.
    Rectangle {
        anchors.fill: parent
        visible: v.art === ""
        radius: width / 2
        color: Theme.alpha(Theme.text, 0.10)
        Text {
            anchors.centerIn: parent
            text: ""
            color: Theme.dim
            font.family: Theme.font
            font.pixelSize: parent.width * 0.3
        }
    }

    // static rim, drawn inside the edge so it is a full ring however the
    // texture's edge antialiases against it
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.color: v.rim
        border.width: v.rimWidth
    }
}
