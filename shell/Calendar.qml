// Calendar.qml — the calendar in the bar's centre island (a click on the
// clock, or SUPER+SHIFT+C).
//
// It was a dropdown under the clock with the reminders list beside it; it is
// an island tenant now, like jarvis, the todo list and the Gita reader (Ahaan,
// 2026-10-21), and the reminders are their own (Reminders.qml). The island
// grows down for it (Bar.qml sizes it from CalendarState), to the Gita
// reader's full width; this window draws what is in it, on a full-screen
// catcher, for the reason Todo.qml gives: the bar's surface never takes the
// keyboard. A click anywhere outside closes it.
//
// Month view: the grid, a cursor on a day, and how far through the year
// today is. Arrows move the cursor (Ahaan: "let arrow keys in the calendar
// browse the days itself and enter go in on one"); Tab / Shift+Tab change
// month, Ctrl+Tab / Ctrl+Shift+Tab year; T back to today; Esc closes.
//
// Day view (a click on a day, or Enter): the date, large, that day's tasks,
// and a box to add one — the todo list's box and its Urgent / Important chips
// (Chip.qml, the same ones), plus a time. The task goes into the todo list
// due that day; given a time still ahead, it gets a reminder too, which it
// owns (TodoState.rid): editing the task moves it, checking it off or
// deleting it drops it.
// Since 2026-11-11 the day lists more than the tasks made here: a task from
// the todo list is on the day it was written, and a reminder set in the
// reminders panel is on the day it fires, by its time, with a bell for a box
// (CalendarState.dayAgenda has the rules). Delete removes a reminder; the
// other keys below are a task's and leave a reminder row alone.
// The day's tasks are worked as in the todo list: Up from the box walks into
// them, Enter checks one off, Delete removes it, Ctrl+U / Ctrl+I flip its
// chips. Ctrl+E (or a double-click) loads it into the box to edit; Enter
// saves, Esc lets it go. Tab moves between the task and the time; Esc goes
// back to the month.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

Scope {
    id: scope

    // `qs -p <shell> ipc call calendar <fn>` — `toggle` is SUPER+SHIFT+C's.
    IpcHandler {
        target: "calendar"
        function toggle(): void { CalendarState.toggleOpen() }
        function open(): void { CalendarState.show() }
        function close(): void { CalendarState.close() }
        function step(n: int): void { CalendarState.step(n) }
        function move(n: int): void { CalendarState.move(n) }
        function day(): void { CalendarState.openDay(null) }
        function date(iso: string): void { CalendarState.showDay(iso) }
        function back(): void { CalendarState.back() }
    }

    // Black or white on a filled tile, so today's number stays legible
    // whatever the wallpaper made the accent (the dropdown's rule, kept).
    function onFill(c) { return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? "black" : "white" }

    // A header arrow: the glyph on nothing, a wash under the pointer.
    component NavBtn: Rectangle {
        id: nav
        property string glyph
        property real size: 30
        signal clicked()
        width: size; height: size; radius: 10
        color: navHover.hovered ? Theme.alpha(Theme.text, 0.08) : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.motion } }
        Text {
            anchors.centerIn: parent
            text: nav.glyph
            font.family: Theme.font
            font.pixelSize: nav.size > 30 ? Theme.fsInput + 3 : Theme.fsRow
            color: navHover.hovered ? Theme.text : Theme.dim
        }
        HoverHandler { id: navHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: nav.clicked() }
    }

    // The todo list's box surface, for the task and the time.
    component Box: Rectangle {
        property bool bad: false
        property bool lit: false
        height: CalendarState.boxH
        radius: 11
        color: Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
        border.width: 1.5
        border.color: bad ? Theme.alpha(Theme.danger, 0.8) : lit ? Theme.alpha(Theme.text, 0.4) : Theme.hairline
        Behavior on border.color { ColorAnimation { duration: 140 } }
    }

    PanelWindow {
        id: win
        // Kept mapped while the island is still closing, so the grid fades
        // out with it instead of vanishing before it has moved.
        visible: CalendarState.open || CalendarState.amount > 0.01
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-calendar"
        // OnDemand, never Exclusive: Hyprland routes every click to an
        // Exclusive layer whatever its mask says (Todo.qml has the history).
        WlrLayershell.keyboardFocus: CalendarState.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        mask: Region { item: CalendarState.open ? everywhere : nothing }
        Item { id: everywhere; anchors.fill: parent }
        Item { id: nothing; width: 0; height: 0 }

        MouseArea { anchors.fill: parent; onClicked: CalendarState.close() }

        readonly property bool dayView: CalendarState.view === "day"

        // The new task's quadrant, remembered for as long as the shell runs —
        // starting where the todo list's does, on Schedule it.
        property bool newUrgent: false
        property bool newImportant: true
        property bool timeBad: false

        // ── the day's selection, held as a task id ("" is the box) ────
        // An id for the todo list's reason: a check-off or an edit re-sorts
        // the list, and a row number would then point at another task.
        property string selId: ""
        // Over the day's AGENDA: its tasks and, since 2026-11-11, its own
        // reminders (CalendarState.dayAgenda). A reminder row is kind "rem";
        // Delete removes it, and the task-only keys (Enter, Ctrl+U/I/E)
        // leave it alone.
        readonly property int sel: {
            const d = CalendarState.dayAgenda
            for (let i = 0; i < d.length; i++) if (d[i].id === selId) return i
            return -1
        }
        onSelChanged: if (selId !== "" && sel < 0) selId = ""
        function selectRow(i) {
            const d = CalendarState.dayAgenda
            selId = i >= 0 && i < d.length ? d[i].id : ""
        }
        function selected() { return CalendarState.dayAgenda.find(x => x.id === selId) }
        function selectedTask() { const t = selected(); return t && t.kind === "task" ? t : null }
        function dropSel() {
            const d = CalendarState.dayAgenda, i = sel
            const r = d[i]
            selId = i + 1 < d.length ? d[i + 1].id : i > 0 ? d[i - 1].id : ""
            if (!r) return
            if (r.kind === "rem") RemindersState.remove(r.rid)
            else TodoState.remove(r.id)
        }

        // ── editing ───────────────────────────────────────────────────
        property string editId: ""
        function startEdit(t) {
            if (!t || t.kind === "rem") return
            editId = t.id
            selId = ""
            taskInput.text = t.text
            timeInput.text = t.timed ? CalendarState.timeKeysOf(new Date(t.due).getHours() * 60 + new Date(t.due).getMinutes()) : ""
            newUrgent = t.urgent
            newImportant = t.important
            timeBad = false
            taskInput.forceActiveFocus()
            taskInput.cursorPosition = taskInput.text.length
        }
        function clearBox() {
            editId = ""
            taskInput.text = ""
            timeInput.text = ""
            timeBad = false
        }

        // Adds the box's task, or saves the one being edited.
        function commit() {
            const text = taskInput.text.trim()
            if (text === "") return
            const t = timeInput.text.trim()
            const mins = t === "" ? 0 : CalendarState.parseTime(t)
            if (mins < 0) { timeBad = true; timeInput.forceActiveFocus(); return }
            const d = CalendarState.selDate
            const due = new Date(d.getFullYear(), d.getMonth(), d.getDate(), Math.floor(mins / 60), mins % 60).getTime()
            // A reminder only for a time still ahead; a task logged for
            // earlier today is a task, not something to be reminded of.
            const remind = t !== "" && due > Date.now()
            if (editId !== "") {
                const old = TodoState.items.find(x => x.id === editId)
                if (old) {
                    TodoState.dropReminder(old)
                    const rid = remind && !old.done ? RemindersState.addAt(due, text, true) : ""
                    TodoState.update(old.id, { text: text, urgent: newUrgent, important: newImportant,
                                               due: due, timed: t !== "", rid: rid })
                }
            } else {
                const rid = remind ? RemindersState.addAt(due, text, false) : ""
                TodoState.add(text, newUrgent, newImportant, due, t !== "", rid)
            }
            clearBox()
            taskInput.forceActiveFocus()
        }

        // Ctrl+U / Ctrl+I flip the selected task's chips, else the new
        // one's; Ctrl+E edits the selected task. As in the todo list.
        function ctrlKeys(event) {
            if (!(event.modifiers & Qt.ControlModifier)) return
            const t = sel >= 0 ? selectedTask() : null
            // A reminder selected: its chips do not exist, and the new
            // task's are not what the keys are pointing at either.
            if (sel >= 0 && !t) { event.accepted = true; return }
            if (event.key === Qt.Key_U) {
                if (t) { if (!t.done) TodoState.setFlags(t.id, !t.urgent, t.important) }
                else newUrgent = !newUrgent
            } else if (event.key === Qt.Key_I) {
                if (t) { if (!t.done) TodoState.setFlags(t.id, t.urgent, !t.important) }
                else newImportant = !newImportant
            } else if (event.key === Qt.Key_E) startEdit(t)
            else return
            event.accepted = true
        }
        function onEsc() {
            if (editId !== "") clearBox()
            else if (selId !== "") selId = ""
            else CalendarState.back()
        }

        // Where the keyboard goes: the grid's key handler in the month view,
        // the task box in the day view.
        function focusNow() { focusTimer.tries = 0; focusTimer.start() }
        Connections {
            target: CalendarState
            function onOpenChanged() { if (CalendarState.open) win.focusNow() }
            function onViewChanged() {
                win.selId = ""
                win.clearBox()
                win.focusNow()
            }
        }
        // A layer surface is not reliably focusable on the frame it maps; the
        // todo list, the pill and the launcher all retry, and so does this.
        Timer {
            id: focusTimer
            property int tries: 0
            interval: 40; repeat: true
            onTriggered: {
                const want = win.dayView ? taskInput : keys
                want.forceActiveFocus()
                if (want.activeFocus || ++tries > 12) stop()
            }
        }

        // The month view's keys go to one item that holds focus.
        Item {
            id: keys
            focus: true
            Keys.onPressed: event => {
                const k = event.key
                const ctrl = event.modifiers & Qt.ControlModifier
                if (k === Qt.Key_Escape) CalendarState.close()
                else if (k === Qt.Key_Left) CalendarState.move(-1)
                else if (k === Qt.Key_Right) CalendarState.move(1)
                else if (k === Qt.Key_Up) CalendarState.move(-7)
                else if (k === Qt.Key_Down) CalendarState.move(7)
                else if (k === Qt.Key_Return || k === Qt.Key_Enter) CalendarState.openDay(null)
                else if (k === Qt.Key_Tab) CalendarState.step(ctrl ? 12 : 1)
                else if (k === Qt.Key_Backtab) CalendarState.step(ctrl ? -12 : -1)
                else if (k === Qt.Key_T || k === Qt.Key_Home) CalendarState.today()
                else return
                event.accepted = true
            }
        }

        // The part of the island under its clock row, in this window's
        // coordinates — the bar sits at the screen's top-left like this one.
        Item {
            id: area
            readonly property var isl: CalendarState.island
            // The island's grown part, wherever the bar is (Island.areaX/Y/W/H
            // in Bar.qml): under the row on a top bar, beside the column on a
            // side one. The bar's surface starts at the screen's top-left on
            // every edge, so its coordinates are this window's.
            x: isl ? isl.areaX : 0
            y: isl ? isl.areaY : 0
            width: isl ? isl.areaW : 0
            height: isl ? isl.areaH : 0
            clip: true
            opacity: Math.max(0, (CalendarState.amount - 0.35) / 0.65)

            // Clicks inside the island but on nothing keep it open.
            MouseArea { anchors.fill: parent; onPressed: (win.dayView ? taskInput : keys).forceActiveFocus() }

            // ══ month ═════════════════════════════════════════════════
            // Laid out at its final size and centred, so opening and closing
            // reveal it rather than reflow it.
            Item {
                id: monthSheet
                // The island's full width less its padding: the columns
                // spread to fill it rather than leaving margins.
                width: area.width - 2 * CalendarState.pad
                height: CalendarState.wantHeight
                x: CalendarState.pad
                readonly property real colW: width / 7
                opacity: win.dayView ? 0 : 1
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                // ── month and year, with the arrows either side ─────────
                Item {
                    id: head
                    y: 6
                    width: parent.width
                    height: CalendarState.headH
                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        NavBtn { glyph: "«"; onClicked: CalendarState.step(-12) }
                        NavBtn { glyph: "‹"; onClicked: CalendarState.step(-1) }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: CalendarState.monthNames[CalendarState.month] + " " + CalendarState.year
                        font.family: Theme.font
                        font.pixelSize: Theme.fsInput
                        font.weight: Font.Medium
                        color: Theme.text
                        // Away from this month, the title takes you back.
                        HoverHandler { id: titleHover; enabled: !CalendarState.onToday; cursorShape: Qt.PointingHandCursor }
                        TapHandler { enabled: !CalendarState.onToday; onTapped: CalendarState.today() }
                        opacity: titleHover.hovered ? 0.75 : 1
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        NavBtn { glyph: "›"; onClicked: CalendarState.step(1) }
                        NavBtn { glyph: "»"; onClicked: CalendarState.step(12) }
                    }
                }

                // ── weekday initials ─────────────────────────────────────
                Row {
                    id: dayHead
                    y: head.y + head.height + 10
                    Repeater {
                        model: ["S", "M", "T", "W", "T", "F", "S"]
                        Text {
                            required property string modelData
                            width: monthSheet.colW
                            height: CalendarState.dayHeadH
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: modelData
                            font.family: Theme.font
                            font.pixelSize: Theme.fsSub
                            font.weight: Font.DemiBold
                            color: Theme.dim
                        }
                    }
                }

                // ── the days ─────────────────────────────────────────────
                // Circles, each centred in its column of the full width.
                Item {
                    id: grid
                    y: dayHead.y + dayHead.height + 8
                    width: parent.width
                    height: CalendarState.gridH
                    Repeater {
                        model: CalendarState.cells
                        Rectangle {
                            id: day
                            required property var modelData
                            required property int index
                            x: (index % 7) * monthSheet.colW + (monthSheet.colW - width) / 2
                            y: Math.floor(index / 7) * (CalendarState.cell + CalendarState.gap)
                            width: CalendarState.cell
                            height: CalendarState.cell
                            radius: width / 2
                            // Every day the same faint neutral fill (the
                            // weekend's accent wash went, at Ahaan's word);
                            // a day with an open task on it takes the accent
                            // wash instead, where a dot under the number
                            // used to say so; today is the accent itself.
                            color: !modelData.inMonth ? "transparent"
                                 : modelData.today ? Theme.accent
                                 : dayHover.hovered ? Theme.alpha(Theme.text, 0.14)
                                 : modelData.marked ? Theme.alpha(Theme.accent, 0.32)
                                 : Theme.alpha(Theme.col7, 0.08)
                            Behavior on color { ColorAnimation { duration: 120 } }
                            // The keyboard's cursor: a ring, which reads on
                            // today's fill as well as on the washes.
                            border.width: modelData.cursor ? 1.5 : 0
                            border.color: modelData.today ? Theme.text : Theme.alpha(Theme.text, 0.75)
                            HoverHandler { id: dayHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: CalendarState.openDay(day.modelData.date) }
                            Text {
                                anchors.centerIn: parent
                                text: day.modelData.num
                                font.family: Theme.font
                                font.pixelSize: Theme.fsRow - 1
                                font.weight: day.modelData.today ? Font.DemiBold : Font.Normal
                                color: !day.modelData.inMonth ? Theme.dimmer
                                     : day.modelData.today ? scope.onFill(Theme.accent)
                                     : Theme.text
                            }
                        }
                    }
                }

                // ── through the year ─────────────────────────────────────
                // The Gita record's "Through the Gita" bar, for the year shown
                // (Ahaan: "add a 'through the year' thing like you did for the
                // gita below the calendar").
                Column {
                    y: grid.y + CalendarState.gridH + 18
                    width: parent.width
                    spacing: 8
                    Item {
                        width: parent.width
                        height: yearLabel.implicitHeight
                        Text {
                            id: yearLabel
                            text: "Through " + CalendarState.year
                            font.family: Theme.font
                            font.pixelSize: Theme.fsSub + 1
                            color: Theme.alpha(Theme.text, 0.8)
                        }
                        Text {
                            anchors.right: parent.right
                            text: Math.round(CalendarState.yearFrac * 100) + "%"
                            font.family: Theme.font
                            font.pixelSize: Theme.fsSub + 1
                            color: Theme.dim
                        }
                    }
                    Rectangle {
                        width: parent.width; height: 6; radius: 3
                        color: Theme.alpha(Theme.text, 0.08)
                        Rectangle {
                            width: CalendarState.yearFrac > 0 ? Math.max(6, parent.width * CalendarState.yearFrac) : 0
                            height: parent.height; radius: 3
                            color: Theme.alpha(Theme.text, 0.75)
                            Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                        }
                    }
                }
            }

            // ══ day ═══════════════════════════════════════════════════
            Item {
                id: daySheet
                width: area.width - 2 * CalendarState.pad
                height: CalendarState.wantHeight
                x: CalendarState.pad
                opacity: win.dayView ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                // The date, large (Ahaan: "a bigger more focused view"): the
                // day's number, and its weekday over its month beside it.
                Item {
                    id: hero
                    y: 10
                    width: parent.width
                    height: 64
                    NavBtn {
                        id: backBtn
                        size: 36
                        anchors.verticalCenter: parent.verticalCenter
                        glyph: "‹"
                        onClicked: CalendarState.back()
                    }
                    Text {
                        id: bigNum
                        anchors.left: backBtn.right; anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: CalendarState.cur
                        font.family: Theme.font
                        font.pixelSize: 48
                        font.bold: true
                        color: Theme.text
                    }
                    Column {
                        anchors.left: bigNum.right; anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            text: Qt.formatDate(CalendarState.selDate, "dddd")
                            font.family: Theme.font
                            font.pixelSize: Theme.fsInput + 3
                            font.weight: Font.Medium
                            color: Theme.text
                        }
                        Text {
                            readonly property bool isToday: CalendarState.dayKey(CalendarState.selDate) === CalendarState.dayKey(new Date())
                            text: Qt.formatDate(CalendarState.selDate, "MMMM yyyy") + (isToday ? "  ·  today" : "")
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow
                            color: Theme.dim
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        readonly property int open: CalendarState.dayTasks.filter(x => !x.done).length
                        readonly property int rems: CalendarState.dayReminders.length
                        visible: CalendarState.dayAgenda.length > 0
                        text: [CalendarState.dayTasks.length > 0 ? open + (open === 1 ? " task" : " tasks") : "",
                               rems > 0 ? rems + (rems === 1 ? " reminder" : " reminders") : ""]
                              .filter(x => x).join("  ·  ")
                        font.family: Theme.font
                        font.pixelSize: Theme.fsRow
                        color: Theme.dim
                    }
                }
                Rectangle {
                    id: rule
                    y: hero.y + hero.height + 12
                    width: parent.width; height: 1
                    color: Theme.hairline
                }

                // That day's tasks, as rows of the todo list.
                ListView {
                    id: dayList
                    y: rule.y + 10
                    width: parent.width
                    height: taskRow.y - y - 12
                    clip: true
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds
                    model: CalendarState.dayAgenda
                    delegate: Item {
                        id: trow
                        required property var modelData
                        required property int index
                        readonly property bool rem: modelData.kind === "rem"
                        readonly property bool selected: modelData.id === win.selId
                        readonly property bool editing: modelData.id === win.editId
                        readonly property bool chipsShown: !rem && !modelData.done && (selected || rowHover.hovered)
                        width: dayList.width
                        height: 38
                        HoverHandler { id: rowHover }
                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.rowRadius
                            color: Theme.rowSel
                            visible: trow.selected || trow.editing
                            opacity: trow.editing ? 0.6 : 1
                        }
                        Rectangle {
                            x: 14
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8; height: 8; radius: 4
                            color: TodoState.quadColor(TodoState.quadrantOf(trow.modelData.urgent, trow.modelData.important))
                            opacity: trow.modelData.done ? 0.35 : 1
                            // A reminder has no quadrant; its bell is enough.
                            visible: !trow.rem
                        }
                        Text {
                            id: tbox
                            x: 30
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18
                            // A reminder's bell, the due chip's glyph, where a
                            // task has its box: nothing to check off, so no
                            // hand cursor and no tap.
                            text: trow.rem ? "󰂚" : trow.modelData.done ? "󰄲" : "󰄱"
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow + 2
                            color: trow.rem ? (trow.modelData.fired ? Theme.dimmer : Theme.dim)
                                 : trow.modelData.done ? Theme.dimmer : tboxHover.hovered ? Theme.text : Theme.dim
                            HoverHandler { id: tboxHover; enabled: !trow.rem; cursorShape: Qt.PointingHandCursor }
                            TapHandler { margin: 8; enabled: !trow.rem; onTapped: { TodoState.toggle(trow.modelData.id); taskInput.forceActiveFocus() } }
                        }
                        Text {
                            anchors.left: tbox.right; anchors.leftMargin: 10
                            anchors.right: trow.chipsShown ? rowChips.left : tTime.left
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: trow.modelData.text
                            elide: Text.ElideRight
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow
                            font.strikeout: trow.modelData.done
                            color: trow.selected && !trow.modelData.done ? Theme.text : Theme.alpha(Theme.text, 0.85)
                            opacity: trow.modelData.done ? 0.35 : 1
                            // A double-click edits it, as Ctrl+E does.
                            TapHandler {
                                onDoubleTapped: win.startEdit(trow.modelData)
                                onTapped: { win.selId = trow.modelData.id; taskInput.forceActiveFocus() }
                            }
                        }
                        Text {
                            id: tTime
                            anchors.right: parent.right; anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !trow.chipsShown
                            // A reminder that has gone off says so, as its
                            // row in the reminders list does.
                            text: !trow.modelData.timed ? ""
                                : Qt.formatDateTime(new Date(trow.modelData.due), "hh:mm AP")
                                  + (trow.rem && trow.modelData.fired ? "  ·  due" : "")
                            font.family: Theme.font
                            font.pixelSize: Theme.fsSub + 1
                            color: Theme.dim
                            opacity: trow.modelData.done ? 0.35 : 1
                        }
                        // The row's own chips, shown while it is looked at.
                        Row {
                            id: rowChips
                            anchors.right: parent.right; anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            visible: trow.chipsShown
                            Chip {
                                small: true; label: "Urgent"; on: trow.modelData.urgent
                                onClicked: { TodoState.setFlags(trow.modelData.id, !trow.modelData.urgent, trow.modelData.important); taskInput.forceActiveFocus() }
                            }
                            Chip {
                                small: true; label: "Important"; on: trow.modelData.important
                                onClicked: { TodoState.setFlags(trow.modelData.id, trow.modelData.urgent, !trow.modelData.important); taskInput.forceActiveFocus() }
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: dayList.count === 0
                        text: "Nothing on this day yet"
                        font.family: Theme.font
                        font.pixelSize: Theme.fsRow
                        color: Theme.dimmer
                    }
                }

                // The new task: the todo list's box and chips, and a time.
                Item {
                    id: taskRow
                    y: parent.height - 16 - height
                    width: parent.width
                    height: CalendarState.boxH

                    Box {
                        id: field
                        width: parent.width - timeBox.width - chips.width - 16
                        // The box being typed into wears the brighter edge.
                        lit: win.editId !== "" || taskInput.activeFocus
                        // Where the new task will land: the quadrant's
                        // colour here, its name in the placeholder.
                        readonly property int q: TodoState.quadrantOf(win.newUrgent, win.newImportant)
                        Rectangle {
                            x: 15
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8; height: 8; radius: 4
                            color: TodoState.quadColor(field.q)
                        }
                        TextInput {
                            id: taskInput
                            x: 32
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - x - 14 - (editTag.visible ? editTag.width + 8 : 0)
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow
                            color: Theme.text
                            clip: true
                            selectionColor: Theme.alpha(Theme.accent, 0.45)
                            cursorVisible: activeFocus && win.sel < 0
                            KeyNavigation.tab: timeInput
                            KeyNavigation.backtab: timeInput
                            onTextEdited: win.selId = ""
                            onAccepted: {
                                if (win.sel >= 0) { if (win.selectedTask()) TodoState.toggle(win.selId) }
                                else win.commit()
                            }
                            Keys.onUpPressed: {
                                const n = CalendarState.dayAgenda.length
                                if (n === 0 || win.editId !== "") return
                                win.selectRow(win.sel < 0 ? n - 1 : Math.max(0, win.sel - 1))
                            }
                            Keys.onDownPressed: {
                                if (win.sel < 0) return
                                win.selectRow(win.sel + 1 >= CalendarState.dayAgenda.length ? -1 : win.sel + 1)
                            }
                            Keys.onDeletePressed: event => {
                                if (win.sel >= 0) win.dropSel()
                                else event.accepted = false
                            }
                            Keys.onEscapePressed: win.onEsc()
                            Keys.onPressed: event => win.ctrlKeys(event)
                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 6
                                verticalAlignment: Text.AlignVCenter
                                visible: taskInput.text.length === 0
                                text: "New task  →  " + TodoState.quadrants[field.q].name
                                font: taskInput.font
                                color: Theme.dimmer
                                // The box is narrower than the todo list's
                                // (a time and the chips share its line).
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            id: editTag
                            anchors.right: parent.right; anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            visible: win.editId !== ""
                            text: "editing"
                            font.family: Theme.font
                            font.pixelSize: Theme.fsSub + 1
                            color: Theme.dim
                        }
                    }

                    // The time. It takes digits and a / p only (m is let
                    // through as nothing), in any order, so it cannot hold a
                    // typo; Backspace takes back the last key. Shown as
                    // "00:00 AM" filling in: typed characters lit, the pair
                    // the next keys fill a step brighter, the rest dim
                    // (Ahaan: "the 00 gets brighter when I'm on it"). Leaving
                    // the box settles a whole time with its half lit. Empty
                    // is a task for the day, with no reminder.
                    Box {
                        id: timeBox
                        x: field.width + 8
                        width: 120
                        bad: win.timeBad
                        lit: timeInput.activeFocus
                        TextInput {
                            id: timeInput
                            x: 14
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 28
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow
                            // Holds the keys as typed ("540p"), never drawn:
                            // the mask below is what shows.
                            color: "transparent"
                            selectionColor: "transparent"
                            selectedTextColor: "transparent"
                            // Not cursorVisible: false — TextInput turns it
                            // back on whenever it takes focus. A delegate of
                            // nothing is a caret that cannot come back.
                            cursorDelegate: Item {}
                            clip: true
                            KeyNavigation.tab: taskInput
                            KeyNavigation.backtab: taskInput
                            onEditingFinished: {
                                const m = CalendarState.parseTime(text)
                                if (m >= 0) text = CalendarState.timeKeysOf(m)
                            }
                            onAccepted: win.commit()
                            Keys.onEscapePressed: win.onEsc()
                            // Every key is decided here; none reaches the
                            // TextInput's own editing, so nothing but the
                            // keys below can ever be in it.
                            Keys.onPressed: event => {
                                win.ctrlKeys(event)
                                if (event.accepted) return
                                const k = event.key, t = timeInput.text
                                if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Escape
                                    || k === Qt.Key_Tab || k === Qt.Key_Backtab) return
                                if (!(event.modifiers & Qt.ControlModifier)) {
                                    if (k >= Qt.Key_0 && k <= Qt.Key_9) {
                                        if (CalendarState.timeKeys(t).d.length < 4) timeInput.text = t + (k - Qt.Key_0)
                                    } else if (k === Qt.Key_A || k === Qt.Key_P)
                                        timeInput.text = t.replace(/[ap]/gi, "") + (k === Qt.Key_A ? "a" : "p")
                                    else if (k === Qt.Key_Backspace) timeInput.text = t.slice(0, -1)
                                    else if (k === Qt.Key_Delete) timeInput.text = ""
                                }
                                win.timeBad = false
                                event.accepted = true
                            }
                            Row {
                                id: mask
                                anchors.verticalCenter: parent.verticalCenter
                                readonly property var m: CalendarState.timeMask(timeInput.text)
                                Repeater {
                                    model: mask.m.text.length
                                    Text {
                                        required property int index
                                        readonly property bool lit: index < mask.m.lit || (mask.m.halfLit && index >= 6)
                                        readonly property bool next: timeInput.activeFocus && mask.m.next >= 0
                                            && (index === mask.m.next || index === mask.m.next + 1)
                                        text: mask.m.text[index]
                                        font: timeInput.font
                                        color: lit ? Theme.text : next ? Theme.alpha(Theme.text, 0.6) : Theme.dimmer
                                        Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.OutCubic } }
                                    }
                                }
                            }
                        }
                    }

                    // The new task's two questions, with their keys on them.
                    Row {
                        id: chips
                        anchors.right: parent.right
                        height: parent.height
                        spacing: 6
                        Chip {
                            anchors.verticalCenter: parent.verticalCenter
                            label: "Urgent"; keyHint: "^U"; on: win.newUrgent
                            onClicked: { win.newUrgent = !win.newUrgent; taskInput.forceActiveFocus() }
                        }
                        Chip {
                            anchors.verticalCenter: parent.verticalCenter
                            label: "Important"; keyHint: "^I"; on: win.newImportant
                            onClicked: { win.newImportant = !win.newImportant; taskInput.forceActiveFocus() }
                        }
                    }
                }
            }
        }
    }
}
