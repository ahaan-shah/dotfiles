pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import "."

// The Downloads stack's popup: the files most recently opened, then the newest
// downloads, one row each under a section label, and a footer that opens the
// folder. Hosted in MacShell's content-sized PanelWindow (the
// same arrangement as WindowPreviewPopup), so it only intercepts input over
// its own card.
//
// The chrome is the dock's own — Theme.bg, the 2px Theme.barLine edge,
// Theme.cardRadius — because this is the dock's popup and should read as one
// piece with it. No shadow: the dock has none (see Dock.qml's pill), so a card
// beside it carrying one would be the odd one out.
Item {
    id: root

    // Padding around the card so a hairline edge isn't flush with the surface.
    readonly property int margin: 4
    implicitWidth:  card.width  + margin * 2
    implicitHeight: card.height + margin * 2

    readonly property int rowH:  48
    readonly property int iconS: 34

    Rectangle {
        id: card
        anchors.centerIn: parent
        width:  320
        height: col.implicitHeight + 16
        radius: Theme.cardRadius
        color:        Theme.bg
        border.color: Theme.barLine
        border.width: Theme.cardBorder

        // Swallows clicks on the card's own padding, so they don't fall
        // through to the catcher behind it and close the popup.
        MouseArea { anchors.fill: parent }

        Column {
            id: col
            x: 8; y: 8
            width: parent.width - 16

            // Two halves, Recents over Downloads (Ahaan, 2026-10-29): what
            // was last opened anywhere, then what last arrived. Each has its
            // own label, so a file's place says which list it came from.
            SectionLabel { text: "Recents"; first: true }
            Repeater { model: DownloadsStack.recents; delegate: fileRow }
            EmptyRow {
                visible: DownloadsStack.recents.length === 0
                text: "Nothing opened recently"
            }

            SectionLabel { text: "Downloads" }
            Repeater { model: DownloadsStack.downloadRows; delegate: fileRow }
            EmptyRow {
                visible: DownloadsStack.downloadRows.length === 0
                text: DownloadsStack.files.length === 0 ? "No downloads yet"
                                                        : "Every download is in Recents"
            }

            // Footer: the folder itself.
            Rectangle {
                width:  col.width
                height: root.rowH - 10
                radius: Theme.rowRadius
                color:  footMouse.containsMouse ? Theme.rowSel : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "Open Downloads folder"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fsRow - 1
                }
                MouseArea {
                    id: footMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: DownloadsStack.openFolder()
                }
            }
        }
    }

    // One file's row, shared by both sections.
    Component {
        id: fileRow
        Rectangle {
            id: row
            required property var modelData
            width:  col.width
            height: root.rowH
            radius: Theme.rowRadius
            color:  rowMouse.containsMouse ? Theme.rowSel : "transparent"

            // What the file is, at a glance: an image shows itself, in
            // a rounded crop; everything else shows the icon theme's
            // icon for its MIME type — the coloured PDF, Word, sheet
            // and video glyphs the file manager uses. These were text
            // tiles reading "DOCX" / "PDF" until 2026-10-29; Ahaan
            // found them ugly, and a word is slower to read than a
            // colour and a shape anyway.
            Item {
                id: thumb
                x: 7
                anchors.verticalCenter: parent.verticalCenter
                width: root.iconS; height: root.iconS

                Image {
                    id: img
                    anchors.fill: parent
                    visible: false          // drawn through the mask below
                    source:  row.modelData.image ? DownloadsStack.fileUrl(row.modelData.path) : ""
                    sourceSize.width:  root.iconS * 2
                    sourceSize.height: root.iconS * 2
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
                Rectangle {
                    id: imgMask
                    anchors.fill: parent
                    radius: 8
                    visible: false
                    layer.enabled: true
                }
                MultiEffect {
                    anchors.fill: parent
                    visible: img.status === Image.Ready
                    source: img
                    maskEnabled: true
                    maskSource: imgMask
                }

                Image {
                    anchors.fill: parent
                    visible: img.status !== Image.Ready
                    source: row.modelData.icon
                    sourceSize.width:  root.iconS * 2
                    sourceSize.height: root.iconS * 2
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    mipmap: true
                }
            }

            Text {
                anchors.left: thumb.right
                anchors.leftMargin: 11
                anchors.right: age.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.name
                elide: Text.ElideMiddle
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: Theme.fsRow
            }

            Text {
                id: age
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                // Against DownloadsStack.now, which every poll bumps,
                // so this re-reads itself; Date.now() in a binding
                // never would.
                text: root.ago(row.modelData.mtime, DownloadsStack.now)
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fsRow - 2
            }

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: DownloadsStack.open(row.modelData.path)
            }

            // ── Drag out ──────────────────────────────────────
            // Pick a row up and drop it on any app: a browser upload
            // field, a chat, the file manager, a terminal (which pastes
            // the path). A real Wayland data-device drag carrying
            // text/uri-list, the one format every toolkit's file drop
            // understands — what Nautilus offers for the same gesture.
            //
            // Drag.Automatic hands the gesture to the platform once
            // the DragHandler passes its threshold, so a plain click
            // still reaches rowMouse and opens the file. The proxy is
            // a separate item so the row itself never moves.
            Item {
                id: dragProxy
                anchors.fill: thumb
                readonly property string uri: DownloadsStack.fileUrl(row.modelData.path)
                Drag.active: dragH.active
                Drag.dragType: Drag.Automatic
                Drag.supportedActions: Qt.CopyAction
                Drag.mimeData: ({ "text/uri-list": dragProxy.uri + "\r\n",
                                  "text/plain":    row.modelData.path })
                // The file's own picture under the pointer while it
                // travels.
                Drag.imageSource: row.modelData.image ? dragProxy.uri : row.modelData.icon
                Drag.imageSourceSize: Qt.size(48, 48)
                Drag.onDragStarted:  DownloadsStack.dragging = true
                Drag.onDragFinished: DownloadsStack.endDrag()
            }
            DragHandler {
                id: dragH
                target: null
            }
        }
    }

    // A section's heading: small caps, spaced, dim — the same treatment as
    // Gita.qml's section titles. A hairline above every one but the first
    // separates the halves.
    component SectionLabel: Item {
        property alias text: label.text
        property bool first: false
        width:  parent ? parent.width : 0
        height: first ? 26 : 36
        Rectangle {
            visible: !parent.first
            x: 12; y: 5
            width: parent.width - 24; height: 1
            color: Theme.hairline
        }
        Text {
            id: label
            x: 8
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            font.capitalization: Font.AllUppercase
            font.family: Theme.font
            font.pixelSize: Theme.fsSub
            font.weight: Font.DemiBold
            font.letterSpacing: 1.4
            color: Theme.dim
        }
    }

    component EmptyRow: Text {
        width:  parent ? parent.width : 0
        height: 40
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
        color: Theme.dimmer
        font.family: Theme.font
        font.pixelSize: Theme.fsRow - 1
    }

    // "now", "5m", "3h", "2d" — enough to tell this morning's file from last
    // week's, which is all a stack needs.
    function ago(mtime, now) {
        const s = Math.max(0, now - mtime)
        if (s < 60)     return "now"
        if (s < 3600)   return Math.floor(s / 60) + "m"
        if (s < 86400)  return Math.floor(s / 3600) + "h"
        return Math.floor(s / 86400) + "d"
    }
}
