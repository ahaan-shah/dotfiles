// Todo.qml — the todo list in the bar's centre island (SUPER+SHIFT+T).
//
// The island grows down for it exactly as it does for a jarvis reply (Bar.qml
// sizes it from TodoState); this window draws what is in it. It is drawn HERE,
// on a full-screen catcher, and not in the island, for the reason the jarvis
// reply box is: the bar's surface never takes the keyboard, and an OnDemand
// layer that maps gets it — which is "immediately the cursor is in a new
// reminders typebox". The whole output is the input region, so a click
// anywhere outside the island closes the list, as on every card here.
//
// Priority is the Eisenhower matrix (TodoState has the quadrants): the two
// chips beside the box say whether a new task is Urgent and/or Important, and
// the box names the quadrant it will land in. The list is one plain list,
// ordered by quadrant, with the quadrant's coloured dot before each task's
// checkbox (Ahaan, 2026-10-21: "one simple task list with priority keys via
// the dots" — headers per quadrant came and went the same day). The selected
// (or hovered) row shows the same two chips
// for itself. Ctrl+U / Ctrl+I flip Urgent / Important — on the selected task
// if there is one, otherwise on the next new one.
//
// Keys: type + Enter adds. Down from the box starts at the TOP row — the
// most urgent open task (Ahaan, 2026-10-24: it used to stay in the box, and
// Up walked in from the bottom, through every checked-off task, to reach
// the open ones). Up from the box still walks in from the bottom, the row
// nearest the box. Up/Down move, Down past the last row is the box again; Enter on a row checks it off (or back on), Delete removes it. Typing
// always lands in the box and puts the selection back there. Esc closes.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

Scope {
    id: scope

    // `qs -p <shell> ipc call todo <fn>` — `toggle` is what SUPER+SHIFT+T
    // fires; the rest exist so a repo instance can be exercised with no
    // keyboard (CLAUDE.md step 2).
    IpcHandler {
        target: "todo"
        function toggle(): void { TodoState.toggleOpen() }
        function open(): void { TodoState.show() }
        function close(): void { TodoState.close() }
        function add(text: string): string { return TodoState.add(text) ? "ok" : "empty text" }
        function list(): string {
            // Due dates and the priority chips too since 2026-10-26: EVE's
            // agenda reads this, and "today" means nothing without dates.
            return TodoState.items.map(x => (x.done ? "[x] " : "[ ] ") + x.text
                + (x.due > 0 ? "  (due " + TodoState.dueLabel(x.due, x.timed) + ")" : "")
                + (x.urgent ? "  [urgent]" : "") + (x.important ? "  [important]" : "")).join("\n") || "(none)"
        }
        // EVE's delete (2026-11-02). list() carries no ids — the agenda reads
        // it and ids are noise there — so the broker matches Ahaan's words
        // against items() and removes by id. remove() goes through
        // TodoState.remove, so a timed task's reminder goes with it, the
        // same as the row's own delete.
        function items(): string {
            return JSON.stringify(TodoState.items.map(x => ({ id: x.id, text: x.text, done: x.done, due: x.due,
                timed: x.timed, urgent: x.urgent, important: x.important, rid: x.rid })))
        }
        // fields: JSON of any of text, urgent, important, due (epoch ms, 0 =
        // none), timed. The broker resolves dates; this only applies them.
        function edit(id: string, fields: string): string {
            let f
            try { f = JSON.parse(fields) } catch (e) { return "bad fields" }
            return TodoState.edit(id, f) ? "edited" : "no such task, or empty text"
        }
        function remove(id: string): string {
            const x = TodoState.items.find(t => t.id === id)
            if (!x) return "no such task"
            TodoState.remove(id)
            return "removed"
        }
    }

    // The chips (Chip.qml) were an inline component here until the calendar's
    // day view needed the same ones.

    PanelWindow {
        id: win
        // Kept mapped while the island is still closing, so the rows fade out
        // with it instead of vanishing before it has moved.
        visible: TodoState.open || TodoState.amount > 0.01
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-todo"
        // OnDemand, never Exclusive: Hyprland routes every click to an
        // Exclusive layer whatever its mask says (the jarvis catcher's
        // measurement), and Exclusive left the pill stuck on 2026-10-06.
        WlrLayershell.keyboardFocus: TodoState.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        mask: Region { item: TodoState.open ? everywhere : nothing }
        Item { id: everywhere; anchors.fill: parent }
        Item { id: nothing; width: 0; height: 0 }

        MouseArea { anchors.fill: parent; onClicked: TodoState.close() }

        // ── the selection ───────────────────────────────────────────
        // Held as a task's id, not a row number ("" is the box). Every
        // check-off reorders the list, and a row number then points at
        // whichever task slid into that row — the selection jumping and
        // arrows "skipping" tasks were both that (Ahaan, 2026-10-21). sel is
        // the row the id is on now in the VIEW's model (rows, below), which is
        // what is on screen while a check-off is still settling.
        property string selId: ""
        property int sel: -1
        function rowOf(id) {
            for (let i = 0; i < rows.count; i++) if (rows.get(i).tid === id) return i
            return -1
        }
        // The band's y, in the list's content coordinates. Every row is the
        // same height, so it is the index times that. (With group headers it
        // had to be summed from per-row flags; the headers are gone.)
        property real bandY: 0
        function refreshSel() {
            sel = selId === "" ? -1 : rowOf(selId)
            if (selId !== "" && sel < 0) selId = ""     // gone: cleared, or deleted elsewhere
            bandY = Math.max(0, sel) * TodoState.rowH
            list.currentIndex = sel
        }

        // The quadrant the next new task goes in. Remembered across opens for
        // as long as the shell runs; starts on Schedule it, the quadrant a plain
        // to-do most often belongs in, and the one older tasks are read as.
        property bool newUrgent: false
        property bool newImportant: true
        // Ctrl+U / Ctrl+I: on the selected task, else on the next new one.
        function flip(which) {
            if (sel >= 0) {
                const t = TodoState.items.find(x => x.id === selId)
                if (!t || t.done) return
                TodoState.setFlags(t.id, which === "u" ? !t.urgent : t.urgent,
                                         which === "i" ? !t.important : t.important)
            } else if (which === "u") newUrgent = !newUrgent
            else newImportant = !newImportant
        }
        onSelIdChanged: refreshSel()
        function selectRow(i) { selId = i >= 0 && i < rows.count ? rows.get(i).tid : "" }

        // Where the highlight goes when a task changes state — decided here,
        // once, rather than left to wherever a row number lands afterwards:
        //   checked off  -> the next open task (the one that slides up into
        //                   its row); else the open task above it; else, with
        //                   nothing left to do, the box
        //   unchecked    -> the next checked task; else the checked one above
        //                   it; else the task itself
        //   deleted      -> the next row, else the previous, else the box
        // A task that is not the selected one changing (a click on its box)
        // leaves the highlight on the task it was on. "Open" and "checked" are
        // as shown, so a check-off still settling counts as checked.
        function neighbour(i, sameDone) {
            for (let k = i + 1; k < rows.count; k++) if (sameDone === null || rows.get(k).done === sameDone) return rows.get(k).tid
            for (let k = i - 1; k >= 0; k--) if (sameDone === null || rows.get(k).done === sameDone) return rows.get(k).tid
            return ""
        }

        // ── a check-off, in two beats ───────────────────────────────
        // Ahaan, 2026-10-21: "smoother check offs … its too abrupt" — the row
        // used to vanish to the bottom on the frame Enter went down. Now the
        // row ticks where it is first (the box pops, the text dims, a strike
        // sweeps across it), and only once that has been seen does the list
        // reorder, with the rows sliding to their places. Checks made in
        // quick succession settle together after the last one, so working
        // down a list is not a row moving out from under every keypress.
        property var pending: ({})          // id -> true while shown toggled, not yet stored
        function check(id) {
            const i = rowOf(id)
            if (i < 0) return
            const was = rows.get(i).done
            if (id === selId) {
                const n = neighbour(i, was)
                selId = n !== "" ? n : (was ? id : "")
            }
            rows.setProperty(i, "done", !was)
            const p = Object.assign({}, pending)
            if (p[id]) delete p[id]; else p[id] = true      // a second press undoes the first
            pending = p
            settle.restart()
        }
        Timer {
            id: settle
            interval: 380
            onTriggered: win.flush()
        }
        function flush() {
            const ids = Object.keys(pending)
            pending = ({})
            settle.stop()
            if (ids.length) TodoState.toggleMany(ids)
        }
        function drop(id) {
            const i = rowOf(id)
            if (i < 0) return
            flush()
            if (id === selId) selId = neighbour(i, null)
            TodoState.remove(id)
        }

        Connections {
            target: TodoState
            function onOpenChanged() {
                // Closing mid-settle still stores what was checked.
                if (!TodoState.open) { win.flush(); return }
                win.selId = ""
                input.text = ""
                focusTimer.tries = 0
                focusTimer.start()
            }
            function onItemsChanged() { win.sync() }
        }

        // ── the rows ────────────────────────────────────────────────
        // A ListModel kept in step with TodoState.items by id — rows moved,
        // updated, inserted or removed, never rebuilt. Handing the view the
        // JS array instead rebuilt every delegate on each check-off and reset
        // its currentIndex to 0, so the highlight flashed on the top row for
        // a frame: the first glitch on checking off. Moves here are what the
        // view's move/displaced transitions animate.
        ListModel { id: rows }
        function sync() {
            const want = TodoState.items
            for (let i = rows.count - 1; i >= 0; i--)
                if (!want.some(x => x.id === rows.get(i).tid)) rows.remove(i)
            for (let i = 0; i < want.length; i++) {
                const w = want[i]
                // A row still settling keeps showing what was pressed.
                const done = pending[w.id] ? !w.done : w.done
                let j = -1
                for (let k = i; k < rows.count; k++) if (rows.get(k).tid === w.id) { j = k; break }
                if (j < 0) {
                    rows.insert(i, { tid: w.id, label: w.text, done: done,
                                     urgent: w.urgent, important: w.important,
                                     due: w.due, timed: w.timed })
                    continue
                }
                if (j !== i) rows.move(j, i, 1)
                if (rows.get(i).urgent !== w.urgent) rows.setProperty(i, "urgent", w.urgent)
                if (rows.get(i).important !== w.important) rows.setProperty(i, "important", w.important)
                if (rows.get(i).label !== w.text) rows.setProperty(i, "label", w.text)
                if (rows.get(i).due !== w.due) rows.setProperty(i, "due", w.due)
                if (rows.get(i).timed !== w.timed) rows.setProperty(i, "timed", w.timed)
                if (rows.get(i).done !== done) rows.setProperty(i, "done", done)
            }
            refreshSel()
        }
        Component.onCompleted: sync()
        // A layer surface is not reliably focusable on the frame it maps; the
        // pill, the launcher and the reminder prompt all retry, and so does this.
        Timer {
            id: focusTimer
            property int tries: 0
            interval: 40; repeat: true
            onTriggered: {
                input.forceActiveFocus()
                if (input.activeFocus || ++tries > 12) stop()
            }
        }

        // The part of the island under its clock row, in this window's
        // coordinates — the bar sits at the screen's top-left like this one.
        Item {
            id: area
            readonly property var isl: TodoState.island
            // The island's grown part, wherever the bar is (Island.areaX/Y/W/H
            // in Bar.qml): under the row on a top bar, beside the column on a
            // side one. The bar's surface starts at the screen's top-left on
            // every edge, so its coordinates are this window's.
            x: isl ? isl.areaX : 0
            y: isl ? isl.areaY : 0
            width: isl ? isl.areaW : 0
            height: isl ? isl.areaH : 0
            clip: true
            opacity: Math.max(0, (TodoState.amount - 0.35) / 0.65)

            // Clicks inside the island but on nothing take the keyboard back
            // rather than closing.
            MouseArea { anchors.fill: parent; onPressed: input.forceActiveFocus() }

            ListView {
                id: list
                x: 8; y: 6
                width: parent.width - 16
                height: TodoState.listH - 8
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                model: rows
                // currentIndex is assigned by win (refreshSel), never bound: a
                // ListView resets it on its own and breaks a binding when it
                // does. It is kept only so the view scrolls the selection into
                // range; the wash itself is drawn by the row (see below).
                highlightRangeMode: ListView.ApplyRange
                preferredHighlightBegin: 0
                preferredHighlightEnd: height
                highlightMoveDuration: 0
                // The selection is the settings menu's band (SettingsPanel.qml):
                // ONE rectangle, placed from the index, snapping — no travel.
                // It was a wash per row cross-fading over 110 ms, which is the
                // blink that file's comments record replacing: two rows a whole
                // row apart fading at once gives the eye no path, and Ahaan
                // called it glitchy scrolling up and down (2026-10-21).
                // Computed from the index rather than read off the current
                // delegate, for the reason given there too — and here also
                // because the current delegate may be mid-slide after a
                // check-off, where the band should already be on the row it is
                // sliding into.
                highlightFollowsCurrentItem: false
                highlight: Rectangle {
                    width: list.width
                    y: win.bandY
                    height: TodoState.rowH
                    visible: win.sel >= 0
                    radius: Theme.rowRadius
                    color: Theme.rowSel
                }
                // The reorder after a check-off: the moved row and the ones it
                // passes slide rather than jump. OutCubic over 320 ms, a touch
                // longer than Theme.motion, because a row crossing the whole
                // list travels further than anything else here does.
                move: Transition { NumberAnimation { properties: "y"; duration: 320; easing.type: Easing.OutCubic } }
                displaced: Transition { NumberAnimation { properties: "y"; duration: 320; easing.type: Easing.OutCubic } }
                add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.motion } }
                remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.motion } }
                delegate: Item {
                    id: row
                    required property int index
                    required property string tid
                    required property string label
                    required property bool done
                    required property bool urgent
                    required property bool important
                    required property real due
                    required property bool timed
                    readonly property bool selected: tid === win.selId
                    // The row's own priority chips show while it is the one
                    // being looked at — selected, or under the pointer.
                    readonly property bool chipsShown: !done && (selected || rowHover.hovered)
                    width: list.width
                    height: TodoState.rowH

                    Item {
                    width: parent.width
                    height: TodoState.rowH
                    HoverHandler { id: rowHover }
                    Row {
                        id: rowChips
                        anchors.right: parent.right; anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        visible: row.chipsShown
                        Chip {
                            small: true; label: "Urgent"; on: row.urgent
                            onClicked: { TodoState.setFlags(row.tid, !row.urgent, row.important); input.forceActiveFocus() }
                        }
                        Chip {
                            small: true; label: "Important"; on: row.important
                            onClicked: { TodoState.setFlags(row.tid, row.urgent, !row.important); input.forceActiveFocus() }
                        }
                    }
                    // A task made on a date in the calendar says when it is due,
                    // where the chips go while they are hidden.
                    Text {
                        id: dueText
                        anchors.right: parent.right; anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.due > 0 && !row.chipsShown
                        // `open` is read only so reopening the list re-checks
                        // which day is tomorrow.
                        text: row.due > 0 && (TodoState.open || true) ? TodoState.dueLabel(row.due, row.timed) : ""
                        font.family: Theme.font
                        font.pixelSize: Theme.fsSub + 1
                        color: Theme.dim
                        opacity: row.done ? 0.35 : 1
                    }
                    // The priority key: the quadrant's colour (TodoState.quadColor),
                    // the same dot the new-task box shows for where a task will
                    // land. Faded with the rest of a checked-off row.
                    Rectangle {
                        x: 14
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8; radius: 4
                        color: TodoState.quadColor(TodoState.quadrantOf(row.urgent, row.important))
                        opacity: row.done ? 0.35 : 1
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }
                    Text {
                        id: box
                        x: 30
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18
                        text: row.done ? "󰄲" : "󰄱"
                        font.family: Theme.font
                        font.pixelSize: Theme.fsRow + 2
                        color: row.done ? Theme.dimmer
                             : boxHover.hovered ? Theme.text : Theme.dim
                        Behavior on color { ColorAnimation { duration: 200 } }
                        HoverHandler { id: boxHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            // A touch more than the glyph, so it is not a
                            // pixel hunt.
                            margin: 8
                            onTapped: { win.check(row.tid); input.forceActiveFocus() }
                        }
                        // The tick lands with a small pop.
                        SequentialAnimation {
                            id: pop
                            NumberAnimation { target: box; property: "scale"; to: 1.25; duration: 90; easing.type: Easing.OutQuad }
                            NumberAnimation { target: box; property: "scale"; to: 1.0; duration: 160; easing.type: Easing.OutBack }
                        }
                    }
                    Connections { target: row; function onDoneChanged() { if (row.done) pop.restart() } }
                    Text {
                        id: labelText
                        anchors.left: box.right; anchors.leftMargin: 10
                        anchors.right: row.chipsShown ? rowChips.left : dueText.visible ? dueText.left : parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.label
                        elide: Text.ElideRight
                        font.family: Theme.font
                        font.pixelSize: Theme.fsRow
                        // Selection brightens instantly, with the band; only a
                        // check-off fades. One colour Behavior carried both, so
                        // every arrow press faded two rows' text as well — part
                        // of the blink. The dim is opacity (0.3 of the text is
                        // Theme.dimmer), which also takes the strike with it.
                        color: row.selected && !row.done ? Theme.text : Theme.alpha(Theme.text, 0.85)
                        opacity: row.done ? 0.35 : 1
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                        // The strikethrough, drawn rather than font.strikeout so
                        // it can sweep left to right instead of appearing.
                        Rectangle {
                            y: Math.round(parent.height / 2)
                            height: 1.5
                            radius: 1
                            color: Theme.text
                            width: row.done ? Math.min(parent.paintedWidth, parent.width) : 0
                            Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        }
                    }
                    }
                }
            }

            // The new-task box: the jarvis reply box, to the pixel, less the
            // room Clear all takes beside it.
            Rectangle {
                id: field
                x: TodoState.pad
                y: 6 + TodoState.listH
                width: parent.width - TodoState.pad * 2 - newChips.width - 8 - (clear.visible ? clear.width + 8 : 0)
                height: TodoState.boxH
                radius: 11
                color: Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
                border.width: 1.5
                border.color: Theme.hairline

                // Where the new task will land: the quadrant's colour here, its
                // name in the placeholder.
                readonly property int q: TodoState.quadrantOf(win.newUrgent, win.newImportant)
                Rectangle {
                    x: 15
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8; height: 8; radius: 4
                    color: TodoState.quadColor(field.q)
                }
                TextInput {
                    id: input
                    x: 32
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - x - 14
                    verticalAlignment: TextInput.AlignVCenter
                    font.family: Theme.font
                    font.pixelSize: Theme.fsRow
                    color: Theme.text
                    clip: true
                    selectionColor: Theme.alpha(Theme.accent, 0.45)
                    // The caret only shows while the box is the selection, so
                    // a highlighted row reads as where Enter goes.
                    cursorVisible: activeFocus && win.sel < 0
                    onTextEdited: win.selId = ""
                    onAccepted: {
                        if (win.sel >= 0) win.check(win.selId)
                        else if (TodoState.add(text, win.newUrgent, win.newImportant)) text = ""
                    }
                    Keys.onUpPressed: {
                        if (TodoState.count === 0) return
                        win.selectRow(win.sel < 0 ? TodoState.count - 1 : Math.max(0, win.sel - 1))
                    }
                    Keys.onDownPressed: {
                        if (TodoState.count === 0) return
                        win.selectRow(win.sel < 0 ? 0 : win.sel + 1 >= TodoState.count ? -1 : win.sel + 1)
                    }
                    Keys.onDeletePressed: event => {
                        if (win.sel >= 0) win.drop(win.selId)
                        else event.accepted = false
                    }
                    Keys.onEscapePressed: TodoState.close()
                    Keys.onPressed: event => {
                        if (!(event.modifiers & Qt.ControlModifier)) return
                        if (event.key === Qt.Key_U) win.flip("u")
                        else if (event.key === Qt.Key_I) win.flip("i")
                        else return
                        event.accepted = true
                    }
                    Text {
                        anchors.fill: parent
                        anchors.leftMargin: 6       // clear of the caret, as on the reply box
                        verticalAlignment: Text.AlignVCenter
                        visible: input.text.length === 0
                        text: "New task  →  " + TodoState.quadrants[field.q].name
                        font: input.font
                        color: Theme.dimmer
                    }
                }

            }

            // The new task's two questions, with their keys on them.
            Row {
                id: newChips
                x: field.x + field.width + 8
                y: field.y
                height: TodoState.boxH
                spacing: 6
                Chip {
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Urgent"; keyHint: "^U"; on: win.newUrgent
                    onClicked: { win.newUrgent = !win.newUrgent; input.forceActiveFocus() }
                }
                Chip {
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Important"; keyHint: "^I"; on: win.newImportant
                    onClicked: { win.newImportant = !win.newImportant; input.forceActiveFocus() }
                }
            }

            // Clear all: its own button on the box's line (Ahaan, same day:
            // "separate the new task and clear buttons but keep them in the
            // same line") — the box's surface and edge, sized to its label.
            Rectangle {
                id: clear
                anchors.right: parent.right; anchors.rightMargin: TodoState.pad
                y: field.y
                width: clearLabel.implicitWidth + 28
                height: TodoState.boxH
                radius: 11
                visible: TodoState.count > 0
                color: clearHover.hovered ? Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.10))
                                          : Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
                border.width: 1.5
                border.color: Theme.hairline
                HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: { TodoState.clearAll(); win.selId = ""; input.forceActiveFocus() } }
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
