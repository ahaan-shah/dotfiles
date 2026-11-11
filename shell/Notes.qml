// Notes.qml — the quick notes pad in the bar's centre island (SUPER+SHIFT+W).
//
// A tenant like the todo list (Todo.qml has the pattern and why it is drawn
// here and not in the island): a full-screen OnDemand catcher, the pad drawn
// over the island's grown part, a click anywhere outside closes it. The text
// is NotesState's; this file is the editor and the IPC.
//
// Typing goes straight in: the cursor is at the end of the page when it
// opens, as the todo box has it. Enter is a new line, Esc closes, and every
// change is saved (NotesState debounces it). Paste is the TextEdit's own
// Ctrl+V, plain text only — a note copied from a web page should not bring
// its fonts with it.
//
// ── emoji ─────────────────────────────────────────────────────────────────
// Typed or pasted emoji draw in colour: the font is Theme.font, and Qt falls
// back through fontconfig to Noto Color Emoji for anything it lacks (the
// launcher's picker draws them the same way). To TYPE one there is a
// shortcode, as in a chat app: ":" then two or more letters of its name
// (":fire", ":thumbs_up") brings up a strip of matches from the launcher's
// own EmojiIndex. Tab / Shift+Tab move along it, Enter puts it in, Esc puts
// the strip away; a click on one puts it in too. The colon has to start a
// word, so "12:30" and "http://" never ask.

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

Scope {
    id: scope

    // `qs -p <shell> ipc call notes <fn>`. toggle is SUPER+SHIFT+W; read,
    // append and set are EVE's (jarvis/broker.py, the notes tool), and let a
    // repo instance be driven with no keyboard.
    IpcHandler {
        target: "notes"
        function toggle(): void { NotesState.toggleOpen() }
        function open(): void { NotesState.show() }
        function close(): void { NotesState.close() }
        function read(): string { return NotesState.text }
        function append(text: string): string { return NotesState.append(text) ? "appended" : "empty text" }
        function set(text: string): string { NotesState.replace(text); return "saved" }
    }

    PanelWindow {
        id: win
        visible: NotesState.open || NotesState.amount > 0.01
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-notes"
        // OnDemand, never Exclusive (Todo.qml: Exclusive takes every click).
        WlrLayershell.keyboardFocus: NotesState.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        mask: Region { item: NotesState.open ? everywhere : nothing }
        Item { id: everywhere; anchors.fill: parent }
        Item { id: nothing; width: 0; height: 0 }

        MouseArea { anchors.fill: parent; onClicked: NotesState.close() }

        // ── the emoji strip's state ─────────────────────────────────
        // emoStart is where the ":" is, -1 with no shortcode being typed.
        property int emoStart: -1
        property string emoQuery: ""
        property int emoSel: 0
        // Esc on the strip hides it for THIS shortcode; typing on changes
        // the query and brings it back.
        property string emoDismissed: ""
        readonly property var emoHits: emoQuery.length >= 2 && emoQuery !== emoDismissed
            ? EmojiIndex.search(emoQuery.replace(/[_-]/g, " "), 8) : []
        readonly property bool emoShown: emoHits.length > 0
        onEmoHitsChanged: emoSel = 0

        function scanShortcode() {
            const pos = edit.cursorPosition
            const before = edit.getText(Math.max(0, pos - 40), pos)
            const m = /(^|\s):([A-Za-z0-9_+-]{0,30})$/.exec(before)
            if (!m || edit.selectedText !== "") { emoStart = -1; emoQuery = ""; return }
            emoStart = pos - m[2].length - 1
            emoQuery = m[2].toLowerCase()
        }
        function putEmoji(glyph) {
            if (emoStart < 0) return
            const at = emoStart
            edit.remove(at, edit.cursorPosition)
            edit.insert(at, glyph)
            edit.cursorPosition = at + glyph.length
            emoStart = -1; emoQuery = ""
            edit.forceActiveFocus()
        }

        Connections {
            target: NotesState
            function onOpenChanged() {
                if (!NotesState.open) return
                EmojiIndex.ensure()
                win.emoDismissed = ""
                edit.cursorPosition = edit.length
                focusTimer.tries = 0
                focusTimer.start()
            }
            // A write from elsewhere (EVE, an editor): the page follows, the
            // cursor stays where it was as far as the new text allows.
            function onTextChanged() {
                if (edit.text === NotesState.text) return
                const c = edit.cursorPosition
                edit.text = NotesState.text
                edit.cursorPosition = Math.min(c, edit.length)
            }
        }
        Timer {
            id: focusTimer
            property int tries: 0
            interval: 40; repeat: true
            onTriggered: {
                edit.forceActiveFocus()
                if (edit.activeFocus || ++tries > 12) stop()
            }
        }

        Item {
            id: area
            readonly property var isl: NotesState.island
            x: isl ? isl.areaX : 0
            y: isl ? isl.areaY : 0
            width: isl ? isl.areaW : 0
            height: isl ? isl.areaH : 0
            clip: true
            opacity: Math.max(0, (NotesState.amount - 0.35) / 0.65)

            // Inside the island but on nothing: the keyboard goes back to
            // the page rather than the pad closing.
            MouseArea { anchors.fill: parent; onPressed: edit.forceActiveFocus() }

            // ── the head: what this is, and how much is in it ─────────
            Item {
                id: head
                x: NotesState.pad; y: 6
                width: parent.width - NotesState.pad * 2
                height: NotesState.headH
                Text {
                    id: headGlyph
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰎞"
                    font.family: Theme.font
                    font.pixelSize: Theme.fsInput + 2
                    color: Theme.dim
                }
                Text {
                    anchors.left: headGlyph.right; anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Notes"
                    font.family: Theme.font
                    font.pixelSize: Theme.fsInput
                    font.weight: Font.Medium
                    color: Theme.text
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property int words: (NotesState.text.match(/\S+/g) || []).length
                    text: NotesState.text === "" ? ""
                        : words + (words === 1 ? " word" : " words") + (NotesState.dirty ? "  ·  saving" : "  ·  saved")
                    font.family: Theme.font
                    font.pixelSize: Theme.fsSub + 1
                    color: Theme.dim
                }
            }

            // ── the page: the todo box's surface, a page tall ─────────
            Rectangle {
                id: paper
                x: NotesState.pad
                y: head.y + head.height + 4
                width: parent.width - NotesState.pad * 2
                height: parent.height - y - NotesState.pad
                radius: 11
                color: Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
                border.width: 1.5
                border.color: edit.activeFocus ? Theme.alpha(Theme.text, 0.18) : Theme.hairline

                Flickable {
                    id: flick
                    x: 14; y: 10
                    width: parent.width - 28
                    // The strip, when it is up, takes the page's last line.
                    height: parent.height - 20 - (win.emoShown ? strip.height + 6 : 0)
                    contentWidth: width
                    contentHeight: edit.contentHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    // Follow the caret: typing past the bottom scrolls.
                    function follow(r) {
                        if (r.y < contentY) contentY = r.y
                        else if (r.y + r.height > contentY + height) contentY = r.y + r.height - height
                    }

                    TextEdit {
                        id: edit
                        width: flick.width
                        text: NotesState.text
                        textFormat: TextEdit.PlainText
                        wrapMode: TextEdit.Wrap
                        font.family: Theme.font
                        font.pixelSize: Theme.fsRow + 1
                        color: Theme.text
                        selectByMouse: true
                        persistentSelection: true
                        selectionColor: Theme.alpha(Theme.accent, 0.45)
                        onTextChanged: { NotesState.setText(text); win.scanShortcode() }
                        onCursorPositionChanged: win.scanShortcode()
                        onCursorRectangleChanged: flick.follow(cursorRectangle)

                        Keys.onPressed: event => {
                            const k = event.key
                            if (win.emoShown) {
                                const n = win.emoHits.length
                                if (k === Qt.Key_Tab) { win.emoSel = (win.emoSel + 1) % n; event.accepted = true; return }
                                if (k === Qt.Key_Backtab) { win.emoSel = (win.emoSel + n - 1) % n; event.accepted = true; return }
                                if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                                    win.putEmoji(win.emoHits[win.emoSel].emoji); event.accepted = true; return
                                }
                                if (k === Qt.Key_Escape) { win.emoDismissed = win.emoQuery; event.accepted = true; return }
                            }
                            if (k === Qt.Key_Escape) { NotesState.close(); event.accepted = true }
                        }
                    }
                }
                // No placeholder: Ahaan, 2026-11-11, "remove this text its
                // useless" — an empty page with the caret in it says enough.

                // ── the emoji strip ───────────────────────────────────
                Row {
                    id: strip
                    x: 10
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                    height: 30
                    spacing: 4
                    visible: win.emoShown
                    Repeater {
                        model: win.emoHits
                        delegate: Rectangle {
                            id: chip
                            required property var modelData
                            required property int index
                            readonly property bool on: index === win.emoSel
                            width: on ? Math.min(170, glyph.implicitWidth + nameT.implicitWidth + 26)
                                      : glyph.implicitWidth + 18
                            height: 30
                            radius: 9
                            color: on ? Theme.rowSel : hov.hovered ? Theme.alpha(Theme.text, 0.06) : "transparent"
                            HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: win.putEmoji(chip.modelData.emoji) }
                            Text {
                                id: glyph
                                x: 9
                                anchors.verticalCenter: parent.verticalCenter
                                text: chip.modelData.emoji
                                font.pixelSize: Theme.fsRow + 3
                            }
                            Text {
                                id: nameT
                                anchors.left: glyph.right; anchors.leftMargin: 6
                                anchors.right: parent.right; anchors.rightMargin: 9
                                anchors.verticalCenter: parent.verticalCenter
                                // Only the selected one is named in full;
                                // the rest stay short so eight fit.
                                text: chip.modelData.name
                                elide: Text.ElideRight
                                visible: chip.on
                                font.family: Theme.font
                                font.pixelSize: Theme.fsSub
                                color: Theme.dim
                            }
                        }
                    }
                }
            }
        }
    }
}
