// EveAttachments.qml — the files and images waiting to go with EVE's next
// message (JarvisState.attachments), as chips in front of the text: in the
// reply box under a finished answer (Bar.qml) and in the pill (Jarvis.qml).
//
// Each chip is a glyph and the file's name; a picture shows a thumbnail
// instead of the glyph, so a pasted screenshot can be told from another one.
// A click on a chip takes it off (so does Backspace in an empty box, which
// the boxes handle). `maxW` caps the row, so a long name ellipsises instead
// of pushing the text out of the box; past `maxChips` the rest are a "+N".
import QtQuick

Row {
    id: row
    property real maxW: 300
    property int maxChips: 3
    property real chipH: 26
    property real fontSize: Theme.fsSub + 1
    readonly property var items: JarvisState.attachments
    readonly property int extra: Math.max(0, items.length - maxChips)
    spacing: 6
    visible: items.length > 0

    Repeater {
        model: row.items.slice(0, row.maxChips)
        delegate: Rectangle {
            id: chip
            required property var modelData
            required property int index
            readonly property real nameMax: Math.max(40, (row.maxW - (row.extra ? 40 : 0)) / Math.min(row.items.length, row.maxChips)
                                                     - row.spacing - chipH - 30)
            height: row.chipH
            width: Math.min(name.implicitWidth, nameMax) + row.chipH + 14
            radius: 7
            color: Theme.alpha(Theme.text, hov.hovered ? 0.14 : 0.08)
            // A thumbnail for a picture, a file glyph for the rest.
            Item {
                id: lead
                x: 3; y: 3
                width: row.chipH - 6; height: row.chipH - 6
                Image {
                    anchors.fill: parent
                    visible: chip.modelData.image && status === Image.Ready
                    source: chip.modelData.image ? "file://" + chip.modelData.path : ""
                    sourceSize.width: 64; sourceSize.height: 64
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
                Text {
                    anchors.centerIn: parent
                    visible: !chip.modelData.image
                    // While hovered the glyph turns into the × that removes it.
                    text: hov.hovered ? "󰅖" : "󰈔"
                    font.family: Theme.font; font.pixelSize: row.fontSize + 1
                    color: Theme.dim
                }
                Rectangle {        // the × over a thumbnail, on hover
                    anchors.fill: parent
                    visible: chip.modelData.image && hov.hovered
                    radius: 4
                    color: Theme.alpha(Theme.bg, 0.7)
                    Text {
                        anchors.centerIn: parent
                        text: "󰅖"
                        font.family: Theme.font; font.pixelSize: row.fontSize + 1
                        color: Theme.text
                    }
                }
            }
            Text {
                id: name
                x: lead.x + lead.width + 6
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, chip.nameMax)
                text: chip.modelData.name
                elide: Text.ElideMiddle
                font.family: Theme.font; font.pixelSize: row.fontSize
                color: Theme.text
            }
            HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: JarvisState.detach(chip.index) }
        }
    }
    Text {
        visible: row.extra > 0
        height: row.chipH
        verticalAlignment: Text.AlignVCenter
        text: "+" + row.extra
        font.family: Theme.font; font.pixelSize: row.fontSize
        color: Theme.dim
    }
}
