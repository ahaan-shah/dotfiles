// Reminders.qml — the reminders in the bar's centre island (SUPER+SHIFT+R).
//
// Ahaan, 2026-10-21: "SUPER+SHIFT+R opens the reminders panel where I can type
// in a new one in the same flow as the pill that pops up rn (in how many mins
// followed by the reminder itself). Pill goes away now." The pill was a
// centred modal box over a scrim; the list was a column of the calendar
// dropdown. Both are here now, in the todo list's shape: the island grows down
// (Bar.qml sizes it from RemindersState), the reminders are listed above a box
// that already has the cursor, and a click anywhere outside closes it.
//
// The box keeps the pill's two steps, one field asked twice: how long, then
// what. The delay is asked FIRST because it is the part you already know when
// you reach for the keybind — the message is what you are still composing.
// Once the delay is in, it sits in the box as a chip ahead of the message.
// Backspace on an empty message goes back to it; a delay that will not parse
// tints the box and keeps what was typed.
//
// Keys: Enter moves on / sets it. Up from the box walks into the list, Down
// past the last row is the box again, Delete removes the selected reminder
// (acknowledging it, if it is due). Typing lands in the box. Esc closes.
//
// Right-clicking the due chip in the island's row opens this same panel in
// RemindersState.dueOnly: only the reminders that have come due and are not
// yet cleared, no box, the top row already selected. Up/Down move, Enter (or
// Delete) clears the selected one, and clearing the last closes it.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

Scope {
    id: scope

    PanelWindow {
        id: win
        // Kept mapped while the island is still closing, so the rows fade out
        // with it instead of vanishing before it has moved.
        visible: RemindersState.open || RemindersState.amount > 0.01
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-reminders"
        // OnDemand, never Exclusive (Todo.qml has the history).
        WlrLayershell.keyboardFocus: RemindersState.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        mask: Region { item: RemindersState.open ? everywhere : nothing }
        Item { id: everywhere; anchors.fill: parent }
        Item { id: nothing; width: 0; height: 0 }

        MouseArea { anchors.fill: parent; onClicked: RemindersState.close() }

        // ── the box's two steps ─────────────────────────────────────
        property int stage: 0                 // 0 = minutes, 1 = message
        property string mins: ""
        property string msg: ""
        property bool bad: false
        function reset() {
            // Fields before stage: the stage change is what reloads the box
            // from them, so clearing them afterwards would put the previous
            // answer back on screen (the pill's own note).
            mins = ""; msg = ""; bad = false
            if (stage === 0) input.text = ""
            stage = 0
        }
        onStageChanged: {
            input.text = stage === 0 ? mins : msg
            input.cursorPosition = input.text.length
        }
        function accept() {
            if (stage === 0) {
                if (RemindersState.parseMinutes(mins) < 0) { bad = true; return }
                bad = false
                stage = 1
                return
            }
            if (msg.trim() === "") { bad = true; return }
            if (RemindersState.add(RemindersState.parseMinutes(mins), msg, true)) reset()
        }
        // "10" -> "in 10 min", for the chip.
        function minsLabel() {
            const v = RemindersState.parseMinutes(mins)
            return v < 0 ? "" : "in " + (v >= 60 && v % 60 === 0 ? v / 60 + " h" : v + " min")
        }

        // ── the selection, held as an id ("" is the box) ─────────────
        // An id rather than a row number for the todo list's reason: a
        // reminder firing or being added re-sorts the list, and a row number
        // then points at whichever reminder slid into that row.
        property string selId: ""
        readonly property int sel: {
            for (let i = 0; i < RemindersState.shown.length; i++)
                if (RemindersState.shown[i].id === selId) return i
            return -1
        }
        onSelChanged: {
            if (selId !== "" && sel < 0) selId = ""     // gone: removed elsewhere
            // Scrolled into view by hand: a bound currentIndex is one the
            // ListView resets and unbinds (Todo.qml's measurement).
            else if (sel >= 0) list.positionViewAtIndex(sel, ListView.Contain)
        }
        function selectRow(i) {
            const it = RemindersState.shown
            selId = i >= 0 && i < it.length ? it[i].id : ""
        }
        function drop(id) {
            const i = sel
            if (id === selId) {
                const it = RemindersState.shown
                selId = i + 1 < it.length ? it[i + 1].id : i > 0 ? it[i - 1].id : ""
            }
            RemindersState.remove(id)
        }

        Connections {
            target: RemindersState
            function onOpenChanged() {
                if (!RemindersState.open) return
                win.selId = ""
                win.reset()
                if (RemindersState.dueOnly) win.selectRow(0)
                focusTimer.tries = 0
                focusTimer.start()
            }
            // The chip clicked with the full panel already up: the list
            // narrows to the due ones under the same open.
            function onDueOnlyChanged() {
                if (!RemindersState.open) return
                win.selId = ""
                if (RemindersState.dueOnly) win.selectRow(0)
                focusTimer.tries = 0
                focusTimer.start()
            }
        }
        // Who holds the keyboard: the box, or — with no box — the due list.
        readonly property Item keyTarget: RemindersState.dueOnly ? dueKeys : input
        // A layer surface is not reliably focusable on the frame it maps.
        Timer {
            id: focusTimer
            property int tries: 0
            interval: 40; repeat: true
            onTriggered: {
                win.keyTarget.forceActiveFocus()
                if (win.keyTarget.activeFocus || ++tries > 12) stop()
            }
        }

        // The part of the island under its clock row, in this window's
        // coordinates.
        Item {
            id: area
            readonly property var isl: RemindersState.island
            // The island's grown part, wherever the bar is (Island.areaX/Y/W/H
            // in Bar.qml): under the row on a top bar, beside the column on a
            // side one. The bar's surface starts at the screen's top-left on
            // every edge, so its coordinates are this window's.
            x: isl ? isl.areaX : 0
            y: isl ? isl.areaY : 0
            width: isl ? isl.areaW : 0
            height: isl ? isl.areaH : 0
            clip: true
            opacity: Math.max(0, (RemindersState.amount - 0.35) / 0.65)

            // Clicks inside the island but on nothing take the keyboard back.
            MouseArea { anchors.fill: parent; onPressed: win.keyTarget.forceActiveFocus() }

            // The due list's keys. There is no box to type into, so they are
            // taken by this instead of the TextInput, which is hidden.
            Item {
                id: dueKeys
                Keys.onUpPressed: win.selectRow(Math.max(0, win.sel - 1))
                Keys.onDownPressed: win.selectRow(Math.min(RemindersState.shown.length - 1, win.sel + 1))
                Keys.onReturnPressed: if (win.sel >= 0) win.drop(win.selId)
                Keys.onEnterPressed: if (win.sel >= 0) win.drop(win.selId)
                Keys.onDeletePressed: if (win.sel >= 0) win.drop(win.selId)
                Keys.onEscapePressed: RemindersState.close()
            }

            ListView {
                id: list
                x: 8; y: 6
                width: parent.width - 16
                height: RemindersState.listH - 8
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                model: RemindersState.shown
                delegate: Item {
                    id: row
                    required property var modelData
                    readonly property bool selected: modelData.id === win.selId
                    readonly property bool due: modelData.fired
                    width: list.width
                    height: RemindersState.rowH
                    HoverHandler { id: rowHover }

                    // The selection band, the todo list's.
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.rowRadius
                        color: Theme.rowSel
                        visible: row.selected
                    }
                    // A due reminder's dot is lit; a pending one's is hollow.
                    Rectangle {
                        x: 14
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8; radius: 4
                        color: row.due ? Theme.warn : "transparent"
                        border.width: row.due ? 0 : 1.5
                        border.color: Theme.dim
                    }
                    Text {
                        id: when
                        x: 32
                        width: 74
                        anchors.verticalCenter: parent.verticalCenter
                        text: Qt.formatDateTime(new Date(row.modelData.at), "hh:mm AP")
                        font.family: Theme.font
                        font.pixelSize: Theme.fsRow
                        color: Theme.dim
                    }
                    Text {
                        anchors.left: when.right; anchors.leftMargin: 8
                        anchors.right: tail.left; anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.text
                        elide: Text.ElideRight
                        font.family: Theme.font
                        font.pixelSize: Theme.fsRow
                        color: row.selected ? Theme.text : Theme.alpha(Theme.text, 0.85)
                    }
                    // How long to go, or that it is due; under the pointer, the
                    // x that removes it.
                    Item {
                        id: tail
                        anchors.right: parent.right; anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(togo.implicitWidth, 18)
                        height: parent.height
                        Text {
                            id: togo
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !rowHover.hovered
                            text: row.due ? "due" : RemindersState.countdown(row.modelData.at)
                            font.family: Theme.font
                            font.pixelSize: Theme.fsSub + 1
                            color: row.due ? Theme.warn : Theme.dim
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
                            TapHandler { margin: 8; onTapped: { win.drop(row.modelData.id); win.keyTarget.forceActiveFocus() } }
                        }
                    }
                }
            }

            // The box: the todo list's, to the pixel, Clear all beside it.
            Rectangle {
                id: field
                visible: !RemindersState.dueOnly
                x: RemindersState.pad
                y: 6 + RemindersState.listH
                width: parent.width - RemindersState.pad * 2 - (clear.visible ? clear.width + 8 : 0)
                height: RemindersState.boxH
                radius: 11
                color: Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
                border.width: 1.5
                // The only feedback for a bad answer; it clears on the next key.
                border.color: win.bad ? Theme.alpha(Theme.danger, 0.8) : Theme.hairline
                Behavior on border.color { ColorAnimation { duration: 140 } }

                // The delay, once given: a chip ahead of the message. Clicking
                // it goes back to change it, as Backspace on an empty box does.
                Rectangle {
                    id: chip
                    x: 6
                    anchors.verticalCenter: parent.verticalCenter
                    visible: win.stage === 1
                    width: visible ? chipText.implicitWidth + 20 : 0
                    height: parent.height - 12
                    radius: 8
                    color: Theme.alpha(Theme.text, chipHover.hovered ? 0.16 : 0.12)
                    Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: win.minsLabel()
                        font.family: Theme.font
                        font.pixelSize: Theme.fsSub + 1
                        color: Theme.text
                    }
                    HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { win.stage = 0; input.forceActiveFocus() } }
                }

                TextInput {
                    id: input
                    x: win.stage === 1 ? chip.x + chip.width + 10 : 16
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - x - 14
                    verticalAlignment: TextInput.AlignVCenter
                    font.family: Theme.font
                    font.pixelSize: Theme.fsRow
                    color: Theme.text
                    clip: true
                    selectionColor: Theme.alpha(Theme.accent, 0.45)
                    // The caret only shows while the box is the selection.
                    cursorVisible: activeFocus && win.sel < 0
                    onTextEdited: {
                        if (win.stage === 0) win.mins = text
                        else win.msg = text
                        win.bad = false
                        win.selId = ""
                    }
                    onAccepted: win.accept()
                    Keys.onUpPressed: {
                        const n = RemindersState.shown.length
                        if (n === 0) return
                        win.selectRow(win.sel < 0 ? n - 1 : Math.max(0, win.sel - 1))
                    }
                    Keys.onDownPressed: {
                        if (win.sel < 0) return
                        win.selectRow(win.sel + 1 >= RemindersState.shown.length ? -1 : win.sel + 1)
                    }
                    Keys.onDeletePressed: event => {
                        if (win.sel >= 0) win.drop(win.selId)
                        else event.accepted = false
                    }
                    Keys.onEscapePressed: RemindersState.close()
                    Keys.onPressed: event => {
                        // Backspace on an empty message walks back to the
                        // delay, so a mistyped number costs one key.
                        if (event.key === Qt.Key_Backspace && win.stage === 1 && text === "" && win.sel < 0) {
                            win.stage = 0
                            event.accepted = true
                        }
                    }
                    // The placeholder is the only label: which step you are on
                    // is said by what it asks for.
                    Text {
                        anchors.fill: parent
                        anchors.leftMargin: 6       // clear of the caret, as on the todo box
                        verticalAlignment: Text.AlignVCenter
                        visible: input.text.length === 0
                        // The pill's own wording (Ahaan asked for it back).
                        text: win.stage === 0 ? "Remind in minutes..." : "Reminder message..."
                        font: input.font
                        color: Theme.dimmer
                    }
                }
            }
            // Clear all: the todo list's button, on the box's line. Clears
            // every reminder, due cards included.
            Rectangle {
                id: clear
                anchors.right: parent.right; anchors.rightMargin: RemindersState.pad
                y: field.y
                width: clearLabel.implicitWidth + 28
                height: RemindersState.boxH
                radius: 11
                visible: RemindersState.count > 0 && !RemindersState.dueOnly
                color: clearHover.hovered ? Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.10))
                                          : Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
                border.width: 1.5
                border.color: Theme.hairline
                HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: { RemindersState.clearAll(); win.selId = ""; input.forceActiveFocus() } }
                Text {
                    id: clearLabel
                    anchors.centerIn: parent
                    text: "Clear all"
                    font.family: Theme.font
                    font.pixelSize: Theme.fsRow
                    color: clearHover.hovered ? Theme.text : Theme.dim
                }
            }
        }
    }
}
