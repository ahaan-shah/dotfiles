pragma Singleton

// TodoState.qml — the todo list's model, its store, and whether it is open.
//
// The list lives in the bar's centre island, which grows down to show it the
// way it grows for jarvis (Ahaan, 2026-10-21: "add a todo thing to my center
// island … UI/UX like the jarvis dropdown"). SUPER+SHIFT+T opens it with the
// cursor already in the new-task box. Todo.qml draws it; Bar.qml sizes the
// island from `amount` and `wantHeight` below; this file owns the data.
//
// Order is the spec: open tasks in the order they were added, then the
// checked-off ones, each sent to the very bottom as it is checked — so they
// sort by when they were checked, not when they were made. Unchecking one puts
// it back among the open tasks at its original place.
//
// Stored in $XDG_STATE_HOME/hyprahaan/todos.json, through FileView for the
// reasons the reminders store gives in Bar.qml (an ordered write queue; a
// Process per save lost writes), with watchChanges so a repo instance and the
// live one agree while both are up.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool open: false
    // The island's expansion, 0..1 — animated here rather than in the bar so
    // the bar and Todo.qml read the same number on the same frame.
    property real amount: open ? 1 : 0
    Behavior on amount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

    // The centre island Todo.qml draws over. Set by the bar, like
    // JarvisState.island; with more than one monitor the last bar wins, as it
    // does for jarvis.
    property var island: null

    // [{ id, text, done, at, doneAt }], already in display order.
    property var items: []
    readonly property int count: items.length

    // ── geometry, shared with the bar so the island grows to fit ─────────
    // The island's jarvis reply is the model (Ahaan's screenshot, same day):
    // the reply card's reading width, its 16 px inset, and its "Reply…" box as
    // the new-task box, with the tasks listed above it.
    readonly property real pad: 16
    readonly property real rowH: 38
    readonly property int maxRows: 10
    readonly property real boxH: 38
    readonly property real listH: count > 0 ? Math.min(count, maxRows) * rowH + 8 : 0
    readonly property real wantHeight: 6 + listH + boxH + pad

    function toggleOpen() { open ? close() : show() }
    function show() {
        // One thing in the island at a time: a jarvis card that is up goes.
        if (JarvisState.expanded) JarvisState.dismiss()
        open = true
    }
    function close() { open = false }

    // ── priority: the Eisenhower matrix ───────────────────────────────────
    // Ahaan, 2026-10-21: "let me choose priority based on eisenhower matrix".
    // A task carries the matrix's two questions as two flags, and its
    // quadrant is derived from them, never stored:
    //   0 Do now       urgent + important   (the textbook's Do)
    //   1 Do soon      urgent               (Delegate)
    //   2 Schedule it  important            (Schedule)
    //   3 Do whenever  neither              (Eliminate)
    // Urgent before important is Ahaan's order (2026-10-21); the textbook
    // puts Schedule second.
    // The list is ordered by quadrant, Do now first, then the checked-off
    // tasks; each task wears its quadrant's colour as a dot (Todo.qml).
    // A task with no flags on disk (made before priorities) is read as
    // Schedule it — important, not urgent — rather than Do whenever: nobody
    // wrote those down to have them filed as the least of their concerns.
    // Named for what to do about them, not the textbook's verbs (Ahaan,
    // 2026-10-21): they are the key to the dots, read in the new-task box.
    readonly property var quadrants: [
        { name: "Do now" },        // urgent + important
        { name: "Do soon" },       // urgent
        { name: "Schedule it" },   // important
        { name: "Do whenever" },   // neither
    ]
    function quadrantOf(urgent, important) { return urgent && important ? 0 : urgent ? 1 : important ? 2 : 3 }
    function quadColor(q) { return [Theme.danger, Theme.warn, Theme.good, Theme.dim][q] }

    // A row's due text. The day next to today reads as a word ("Tomorrow ·
    // 09:00 AM") rather than a date you have to work out; anything further
    // keeps the date. Days are compared at local midnight, so DST can't
    // shift one. Evaluated against the clock when the list opens — Todo.qml
    // binds it to `open` — not live across midnight.
    function dueLabel(due, timed) {
        var d = new Date(due);
        var day = new Date(d.getFullYear(), d.getMonth(), d.getDate());
        var now = new Date();
        var today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        var off = Math.round((day - today) / 86400000);
        var word = off === 1 ? "Tomorrow" : off === -1 ? "Yesterday" : "";
        if (word) return timed ? word + " · " + Qt.formatDateTime(d, "hh:mm AP") : word;
        return Qt.formatDateTime(d, timed ? "ddd d MMM · hh:mm AP" : "ddd d MMM");
    }

    // `due` (epoch ms) and `timed` come from the calendar's day view: a task
    // made on a date is due that day, at a time when one was given (midnight
    // and timed=false otherwise). A task from the list itself has neither.
    // `rid` is the reminder the day view set for a timed task, if any: the
    // task owns it, so deleting the task or checking it off drops it.
    function add(text, urgent, important, due, timed, rid) {
        const t = String(text || "").trim()
        if (t === "") return false
        const now = Date.now()
        apply(items.concat([{ id: now + "-" + Math.floor(Math.random() * 1e6), text: t,
                              done: false, at: now, doneAt: 0,
                              urgent: urgent === true, important: important !== false,
                              due: Number(due) || 0, timed: timed === true,
                              rid: String(rid || "") }]))
        save()
        return true
    }
    // The day view's edit: any of text, urgent, important, due, timed, rid.
    function update(id, fields) {
        apply(items.map(x => x.id !== id ? x : Object.assign({}, x, fields)))
        save()
    }
    // A task done or gone takes its pending reminder with it.
    function dropReminder(x) { if (x && x.rid) RemindersState.remove(x.rid) }
    function setFlags(id, urgent, important) {
        apply(items.map(x => x.id !== id ? x : Object.assign({}, x, { urgent: urgent, important: important })))
        save()
    }
    function toggle(id) {
        apply(items.map(x => {
            if (x.id !== id) return x
            if (!x.done) dropReminder(x)
            return Object.assign({}, x, { done: !x.done, doneAt: x.done ? 0 : Date.now(), rid: x.done ? x.rid : "" })
        }))
        save()
    }
    // A batch of check-offs settling at once (Todo.qml holds them back until
    // their tick has shown): one reorder and one write, not one per task.
    function toggleMany(ids) {
        const set = {}
        ids.forEach(i => set[i] = true)
        const now = Date.now()
        apply(items.map(x => {
            if (!set[x.id]) return x
            if (!x.done) dropReminder(x)
            return Object.assign({}, x, { done: !x.done, doneAt: x.done ? 0 : now, rid: x.done ? x.rid : "" })
        }))
        save()
    }
    // EVE's edit (2026-11-02): any of text, urgent, important, due, timed.
    // The day view's commit() rules, so the two cannot disagree: the old
    // reminder goes, and a timed task still ahead and not done gets a new
    // one at its (new) due, quiet — the edit is its own confirmation. A
    // text-only edit takes this path too, so the reminder's words follow.
    function edit(id, fields) {
        const old = items.find(x => x.id === id)
        if (!old) return false
        const n = Object.assign({}, old, fields)
        n.text = String(n.text || "").trim()
        if (n.text === "") return false
        n.due = Number(n.due) || 0
        n.timed = n.due > 0 && n.timed === true
        dropReminder(old)
        n.rid = n.timed && !n.done && n.due > Date.now() ? RemindersState.addAt(n.due, n.text, true) : ""
        update(id, { text: n.text, urgent: n.urgent === true, important: n.important === true,
                     due: n.due, timed: n.timed, rid: n.rid })
        return true
    }
    function remove(id) {
        dropReminder(items.find(x => x.id === id))
        apply(items.filter(x => x.id !== id)); save()
    }
    function clearAll() { items.forEach(dropReminder); apply([]); save() }

    // Normalise whatever came off disk (or out of an edit) into display order.
    // A record with no text is dropped rather than drawn as a blank row.
    function apply(list) {
        const out = []
        for (let i = 0; i < list.length; i++) {
            const r = list[i]
            if (!r || typeof r !== "object") continue
            const text = String(r.text || "").trim()
            if (text === "") continue
            const at = Number(r.at) || 0
            out.push({ id: String(r.id || (at + "-" + i)), text: text, done: r.done === true,
                       at: at, doneAt: Number(r.doneAt) || 0,
                       urgent: r.urgent === true, important: r.important !== false,
                       due: Number(r.due) || 0, timed: r.timed === true && Number(r.due) > 0,
                       rid: String(r.rid || "") })
        }
        // Open tasks by quadrant, then by when they were added; checked ones
        // after them all, by when they were checked.
        out.sort((a, b) => a.done !== b.done ? (a.done ? 1 : -1)
                         // A batch checked off together shares one doneAt
                         // (toggleMany); creation order breaks the tie, so the
                         // order — and which of them the cap below drops — is
                         // not arbitrary.
                         : a.done ? (a.doneAt - b.doneAt) || a.at - b.at
                         : (quadrantOf(a.urgent, a.important) - quadrantOf(b.urgent, b.important)) || a.at - b.at)
        // Checked-off tasks only fill what the island has room for (Ahaan,
        // 2026-10-24: "if they go beyond the 10th then delete them away so
        // they dont unnecessarily expand the island"). The list shows maxRows
        // rows; open tasks are never dropped and scroll past that, but a
        // checked one that would sit past row maxRows is deleted — the
        // oldest-checked first, so the one just ticked stays where it can be
        // unticked. Deleted, not hidden: the calendar's day view reads the
        // same list, and a task kept but never shown is clutter in the file.
        // (nOpen, not open: that name is the panel's state above.)
        const nOpen = out.filter(x => !x.done).length
        const keep = Math.max(0, maxRows - nOpen)
        const nDone = out.length - nOpen
        const pruned = nDone > keep
        if (pruned) out.splice(nOpen, nDone - keep)
        items = out
        return pruned
    }

    readonly property string path:
        (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
        + "/hyprahaan/todos.json"

    property bool _retried: false
    function save() { store.setText(JSON.stringify(items)) }

    property var _store: FileView {
        id: store
        path: root.path
        watchChanges: true
        // Absent until the first task is added; ENOENT at startup is not a fault.
        printErrors: false
        atomicWrites: true
        onFileChanged: reload()
        onLoadFailed: root.apply([])
        onLoaded: {
            try {
                const p = JSON.parse(store.text() || "[]")
                // A store from before the cap (or written by an older
                // instance) is trimmed on load, and the trim written back.
                if (root.apply(Array.isArray(p) ? p : [])) root.save()
            } catch (e) {
                console.warn("todo: ignoring unparseable store", e)
            }
        }
        onSaved: root._retried = false
        // Only ever "the state dir does not exist yet": make it, write once more.
        onSaveFailed: {
            if (root._retried) { console.warn("todo: could not write", root.path); return }
            root._retried = true
            mkdir.running = true
        }
    }
    property var _mkdir: Process {
        id: mkdir
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")"', "todo-mkdir", root.path]
        onExited: root.save()
    }
}
