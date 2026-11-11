pragma Singleton

// NotesState.qml — the quick notes pad: its text, its store, and whether it
// is open.
//
// Ahaan, 2026-11-11: "a new panel for quick notes. Like i just wanna jot
// stuff down … design like the rest of the expansions from the center
// island. Simple notepad where i can type/paste text. Emoji support too.
// Add in support for EVE too with that (reading, writing in it)."
// SUPER+SHIFT+W opens it. Notes.qml draws it over the centre island, the way
// every tenant does (TodoState has the pattern); Bar.qml sizes the island
// from `amount` and `wantHeight` below; this file owns the text.
//
// ONE page of plain text, not a list of notes: the ask was a scratch pad.
// Stored as-is in $XDG_STATE_HOME/hyprahaan/notes.md, so it can be opened
// in an editor too, through FileView for the reminders store's reason (an
// ordered write queue; a Process per save lost writes).
//
// Saved 400 ms after the last keystroke, and at once on close and on every
// IPC write. EVE writes through the IPC (Notes.qml), never the file, so her
// append lands in this text and is saved from here: two writers to one file
// would be a race that loses whichever saved first.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool open: false
    // The island's expansion, 0..1 — animated here so the bar and Notes.qml
    // read the same number on the same frame (TodoState's reason).
    property real amount: open ? 1 : 0
    Behavior on amount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

    // The centre island Notes.qml draws over. Set by the bar.
    property var island: null

    property string text: ""
    // True once the store has been read (or found missing): until then an
    // empty pad is "not loaded yet", and a save would wipe the file.
    property bool loaded: false
    readonly property bool dirty: _save.running

    // ── geometry, shared with the bar ─────────────────────────────────────
    // Todo's width (min(760, bar − 160), in Bar.qml) and about the
    // calendar's height: a page, not a line, and the same island shape as
    // the tenants around it.
    readonly property real pad: 16
    readonly property real headH: 34
    readonly property real wantHeight: 360

    function toggleOpen() { open ? close() : show() }
    function show() {
        if (JarvisState.expanded) JarvisState.dismiss()
        open = true
    }
    function close() { open = false; flush() }

    // From the editor, per keystroke: debounced.
    function setText(t) {
        t = String(t)
        if (t === text) return
        text = t
        _save.restart()
    }
    // EVE's two writes. append adds a line at the end (a blank line is not
    // left between: notes are jotted, not paragraphs); replace is the whole
    // page, and the broker asks Ahaan before it.
    function append(t) {
        const add = String(t || "").replace(/\s+$/, "")
        if (add.trim() === "") return false
        text = text.replace(/\s+$/, "") === "" ? add : text.replace(/\n+$/, "") + "\n" + add
        flush()
        return true
    }
    function replace(t) {
        text = String(t || "")
        flush()
    }
    function flush() {
        _save.stop()
        if (!loaded) return
        store.setText(text)
    }

    property var _saveTimer: Timer { id: _save; interval: 400; onTriggered: root.flush() }

    readonly property string path:
        (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
        + "/hyprahaan/notes.md"

    property bool _retried: false
    property var _store: FileView {
        id: store
        path: root.path
        // An edit made in an editor while the shell runs shows up here. Not
        // while a save is pending: that would throw away what was just typed,
        // and the pending save then writes over the editor's change — the
        // pad being typed in wins, which is the one being looked at.
        watchChanges: true
        printErrors: false          // absent until the first note
        atomicWrites: true
        onFileChanged: reload()
        onLoadFailed: root.loaded = true
        onLoaded: {
            const t = store.text()
            if (!_save.running && t !== root.text) root.text = t
            root.loaded = true
        }
        onSaved: root._retried = false
        onSaveFailed: {
            if (root._retried) { console.warn("notes: could not write", root.path); return }
            root._retried = true
            mkdir.running = true
        }
    }
    property var _mkdir: Process {
        id: mkdir
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")"', "notes-mkdir", root.path]
        onExited: root.flush()
    }
}
