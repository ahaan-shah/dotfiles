// Chip.qml — a yes/no toggle chip: the todo list's Urgent / Important.
//
// Was an inline component of Todo.qml; a file of its own since 2026-10-21 so
// the calendar's day view (Calendar.qml) uses the very same chips rather than
// a lookalike (Ahaan: "eisenhower priority buttons like in tasks (exact
// same)").

import QtQuick

// A yes/no for one of the matrix's two questions. Lit, it is the text
// colour on a light wash; off, it is dim on nothing — readable as a toggle
// without a box or a tick. `small` is the in-row version.
Rectangle {
    id: chip
    property string label
    property string keyHint: ""
    property bool on: false
    property bool small: false
    signal clicked()
    width: chipRow.implicitWidth + (small ? 16 : 22)
    height: small ? 24 : 30
    radius: small ? 8 : 9
    color: on ? Theme.alpha(Theme.text, chipHover.hovered ? 0.16 : 0.12)
              : chipHover.hovered ? Theme.alpha(Theme.text, 0.06) : "transparent"
    border.width: 1
    border.color: on ? "transparent" : Theme.hairline
    Row {
        id: chipRow
        anchors.centerIn: parent
        spacing: 6
        Text {
            text: chip.label
            font.family: Theme.font
            font.pixelSize: chip.small ? Theme.fsSub : Theme.fsSub + 1
            color: chip.on ? Theme.text : Theme.dim
        }
        Text {
            visible: chip.keyHint !== ""
            text: chip.keyHint
            font.family: Theme.font
            font.pixelSize: Theme.fsSub
            color: Theme.dimmer
        }
    }
    HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: chip.clicked() }
}
