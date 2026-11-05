// Notifications.qml — the notification center in the bar's centre island
// (SUPER+SHIFT+N). NotifState.qml has why it moved here.
//
// The reminders' shape (Reminders.qml): the island grows down — Bar.qml sizes
// it from NotifState — the list sits under the clock row, and a line under
// the list holds what the old panel's title row held: Do Not Disturb and
// Clear all. There is nothing to type, so there is no box; the keyboard is
// the list's from the moment it opens, the top row selected.
//
// Keys: Up/Down move. Enter opens the selected one (its app's default action,
// if it has one) and clears it; Delete clears it. D toggles Do Not Disturb,
// Shift+Delete clears all. Esc, or a click anywhere outside, closes.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

Scope {
    id: scope

    // The line under the list: Do Not Disturb on the left, Clear all
    // on the right, both in the reminders' Clear all button's style.
    component LineButton: Rectangle {
        id: lb
        property string label
        property bool on: false
        signal clicked()
        width: lbText.implicitWidth + 28
        height: NotifState.boxH
        radius: 11
        color: lb.on ? Theme.alpha(Theme.accent, lbHover.hovered ? 0.32 : 0.24)
             : lbHover.hovered ? Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.10))
             : Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
        border.width: 1.5
        border.color: lb.on ? Theme.alpha(Theme.accent, 0.6) : Theme.hairline
        HoverHandler { id: lbHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: lb.clicked() }
        Text {
            id: lbText
            anchors.centerIn: parent
            text: lb.label
            font.family: Theme.font
            font.pixelSize: Theme.fsRow
            color: lb.on || lbHover.hovered ? Theme.text : Theme.dim
        }
    }

    PanelWindow {
        id: win
        // Kept mapped while the island is still closing, so the rows fade out
        // with it instead of vanishing before it has moved.
        visible: NotifState.open || NotifState.amount > 0.01
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-notifications"
        // OnDemand, never Exclusive (Todo.qml has the history).
        WlrLayershell.keyboardFocus: NotifState.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        mask: Region { item: NotifState.open ? everywhere : nothing }
        Item { id: everywhere; anchors.fill: parent }
        Item { id: nothing; width: 0; height: 0 }

        MouseArea { anchors.fill: parent; onClicked: NotifState.close() }

        // ── the selection, held as the notification's id ─────────────
        // An id rather than a row number for the reminders' reason: one
        // arriving while the list is open goes on top, and a row number would
        // then point at its neighbour.
        property int selId: -1
        readonly property int sel: {
            for (let i = 0; i < NotifState.items.length; i++)
                if (NotifState.items[i].id === selId) return i
            return -1
        }
        onSelChanged: {
            // Gone (cleared elsewhere, or expired): the top row instead.
            if (sel < 0 && NotifState.count > 0) selectRow(0)
            else if (sel >= 0) list.positionViewAtIndex(sel, ListView.Contain)
        }
        function selectRow(i) {
            const it = NotifState.items
            selId = i >= 0 && i < it.length ? it[i].id : -1
        }
        // Clearing the selected row moves the selection to the one under it,
        // or the one above when it was the last.
        function drop(n, open) {
            const i = sel
            if (n && n.id === selId) {
                const it = NotifState.items
                selId = i + 1 < it.length ? it[i + 1].id : i > 0 ? it[i - 1].id : -1
            }
            if (open) NotifState.activate(n)
            else NotifState.dismiss(n)
        }

        Connections {
            target: NotifState
            function onOpenChanged() {
                if (!NotifState.open) return
                win.selectRow(0)
                focusTimer.tries = 0
                focusTimer.start()
            }
        }
        // A layer surface is not reliably focusable on the frame it maps.
        Timer {
            id: focusTimer
            property int tries: 0
            interval: 40; repeat: true
            onTriggered: {
                keys.forceActiveFocus()
                if (keys.activeFocus || ++tries > 12) stop()
            }
        }

        // The part of the island under its clock row, in this window's
        // coordinates.
        Item {
            id: area
            readonly property var isl: NotifState.island
            // The island's grown part, wherever the bar is (Island.areaX/Y/W/H
            // in Bar.qml): under the row on a top bar, beside the column on a
            // side one. The bar's surface starts at the screen's top-left on
            // every edge, so its coordinates are this window's.
            x: isl ? isl.areaX : 0
            y: isl ? isl.areaY : 0
            width: isl ? isl.areaW : 0
            height: isl ? isl.areaH : 0
            clip: true
            opacity: Math.max(0, (NotifState.amount - 0.35) / 0.65)

            // Clicks inside the island but on nothing take the keyboard back.
            MouseArea { anchors.fill: parent; onPressed: keys.forceActiveFocus() }

            Item {
                id: keys
                Keys.onUpPressed: win.selectRow(Math.max(0, win.sel - 1))
                Keys.onDownPressed: win.selectRow(Math.min(NotifState.count - 1, win.sel + 1))
                Keys.onReturnPressed: if (win.sel >= 0) win.drop(NotifState.items[win.sel], true)
                Keys.onEnterPressed: if (win.sel >= 0) win.drop(NotifState.items[win.sel], true)
                Keys.onEscapePressed: NotifState.close()
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Delete && (event.modifiers & Qt.ShiftModifier)) NotifState.clearAll()
                    else if (event.key === Qt.Key_Delete) { if (win.sel >= 0) win.drop(NotifState.items[win.sel], false) }
                    else if (event.key === Qt.Key_D && !(event.modifiers & Qt.ControlModifier)) NotifState.setDnd(!NotifState.dnd)
                    else return
                    event.accepted = true
                }
            }

            // Nothing to show: said in the room the list would take.
            Text {
                visible: NotifState.count === 0
                x: 0; y: 6
                width: parent.width
                height: NotifState.emptyH
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: "No notifications"
                font.family: Theme.font
                font.pixelSize: Theme.fsRow
                color: Theme.dimmer
            }

            ListView {
                id: list
                visible: NotifState.count > 0
                x: 8; y: 6
                width: parent.width - 16
                height: NotifState.listH - 8
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                model: NotifState.items
                delegate: Item {
                    id: row
                    required property var modelData
                    readonly property bool selected: modelData.id === win.selId
                    readonly property string icon: NotifState.iconFor(modelData)
                    width: list.width
                    height: NotifState.rowH
                    HoverHandler { id: rowHover }
                    TapHandler { onTapped: { win.selId = row.modelData.id; win.drop(row.modelData, true); keys.forceActiveFocus() } }

                    // The selection band, the todo list's.
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.rowRadius
                        color: Theme.rowSel
                        visible: row.selected
                    }
                    // The announcement's dot, so a row reads as what arrived;
                    // the app's picture beside it when it sent one.
                    Rectangle {
                        x: 14
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8; radius: 4
                        color: Theme.text
                    }
                    Image {
                        id: pic
                        x: 32
                        anchors.verticalCenter: parent.verticalCenter
                        width: visible ? 30 : 0; height: 30
                        visible: row.icon !== "" && status !== Image.Error
                        source: row.icon
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 60; sourceSize.height: 60
                        asynchronous: true
                    }
                    Column {
                        anchors.left: pic.right; anchors.leftMargin: pic.visible ? 12 : 0
                        anchors.right: tail.left; anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            width: parent.width
                            text: NotifState.plain(row.modelData.summary) || row.modelData.appName
                            elide: Text.ElideRight
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow
                            color: row.selected ? Theme.text : Theme.alpha(Theme.text, 0.85)
                        }
                        Text {
                            width: parent.width
                            visible: text !== ""
                            text: NotifState.plain(row.modelData.body)
                            elide: Text.ElideRight
                            font.family: Theme.font
                            font.pixelSize: Theme.fsSub + 1
                            color: Theme.dim
                        }
                    }
                    // When it came; under the pointer, the x that clears it.
                    Item {
                        id: tail
                        anchors.right: parent.right; anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(when.implicitWidth, 18)
                        height: parent.height
                        Text {
                            id: when
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !rowHover.hovered
                            text: NotifState.timeText(NotifState.times[row.modelData.id])
                            font.family: Theme.font
                            font.pixelSize: Theme.fsSub + 1
                            color: Theme.dim
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: rowHover.hovered
                            text: "󰅖"
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow + 2
                            color: xHover.hovered ? Theme.text : Theme.dim
                            HoverHandler { id: xHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { margin: 8; onTapped: { win.drop(row.modelData, false); keys.forceActiveFocus() } }
                        }
                    }
                }
            }

            LineButton {
                x: NotifState.pad
                y: 6 + NotifState.listH
                label: (NotifState.dnd ? "" : "") + "  Do not disturb"
                on: NotifState.dnd
                onClicked: { NotifState.setDnd(!NotifState.dnd); keys.forceActiveFocus() }
            }
            LineButton {
                anchors.right: parent.right; anchors.rightMargin: NotifState.pad
                y: 6 + NotifState.listH
                visible: NotifState.count > 0
                label: "Clear all"
                onClicked: { NotifState.clearAll(); keys.forceActiveFocus() }
            }
        }
    }
}
