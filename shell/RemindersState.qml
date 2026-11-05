pragma Singleton

// RemindersState.qml — the reminders: their store, the sweep that fires them,
// and whether the reminders island is open.
//
// The store and the sweep were Bar.qml's until 2026-10-21, when the reminders
// became their own centre-island tenant (Ahaan: "SUPER+SHIFT+R opens the
// reminders panel where I can type in a new one in the same flow as the pill
// … pill goes away now"). They moved here unchanged so Reminders.qml can read
// and edit the list without reaching into the bar. What stayed in Bar.qml is
// the due chip in the centre island's row: this file says what is due
// (`fired`), the bar draws it. (It was a sticky card in the notification popup
// stack until 2026-10-24.)
//
// One JSON file is the source of truth:
//
//     [ { "id": "1789...-42", "at": 1789200000000,
//         "text": "drink water", "fired": false } ]
//
//     at     epoch ms the reminder is due
//     fired  set once its card has been shown. The row is DELETED when that
//            card is clicked, never merely marked — so "fired but still
//            present" means "shown and not yet acknowledged", and sweep() can
//            rebuild the on-screen stack from the file alone after a restart.
//
// Two behaviours fall out of storing `fired` rather than deleting on fire, and
// both are deliberate: a reminder that came due while the machine was
// suspended fires on the next tick instead of being silently skipped, and one
// that was never clicked comes back after SUPER+K.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool open: false
    // Opened from the bar's due chip rather than SUPER+SHIFT+R: the panel
    // shows only the reminders that have come due and are still uncleared,
    // with no new-reminder box, and Enter clears the selected one (Ahaan,
    // 2026-10-24: "left click expands it in its region to show the reminders
    // that triggered so far that i havent cleared"). Reset by every open.
    property bool dueOnly: false
    // The island's expansion, 0..1, animated here so the bar and
    // Reminders.qml read the same number on the same frame.
    property real amount: open ? 1 : 0
    Behavior on amount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

    // The arrival announcement (Ahaan, 2026-10-24: set a couple of reminders
    // and "barely noticed them until a little later" — a chip appearing in the
    // row is easy to miss). A reminder that comes due now grows the island
    // down by announceH for announceMs, showing its text under a wobbling
    // bell; then the island shrinks back and the bar's chip grows in from
    // zero width. `announcing` is the whole phase: the bar sizes the island
    // from announceAmount and holds the chip at zero width while it is set.
    property bool announcing: false
    property string announceText: ""
    readonly property real announceH: 64
    // Since 2026-11-02 a due reminder follows the notification settings
    // (Settings -> Setup -> Notifications): Show for, Auto-dismiss and Sound
    // — but NOT Do not disturb, at Ahaan's call: a reminder is one you set
    // yourself. Read straight off NotifState rather than duplicated here, so
    // there is one copy of each setting and no second watcher.
    readonly property int announceMs: NotifState.announceMs
    readonly property bool _autoDismiss: NotifState.autoDismiss
    property real announceAmount: announcing ? 1 : 0
    Behavior on announceAmount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    property var _announceTimer: Timer {
        interval: root.announceMs
        onTriggered: root.announcing = false
    }
    // A click on the drop (Bar.qml) — the only end to it with Auto-dismiss
    // off. The chip then grows in, as it does after a timed drop.
    function endAnnounce() { _announceTimer.stop(); announcing = false }
    // Same as NotifState's: switched on under a staying drop, it gets its
    // time from then.
    on_AutoDismissChanged: if (announcing) { if (_autoDismiss) _announceTimer.restart(); else _announceTimer.stop() }
    // Only announced into an island nobody else is using: the panel, the todo
    // list, the calendar, the Gita reader and a jarvis card all draw in the
    // same space below the row, and a bell over a reply is worse than the
    // chip alone.
    // A notification's announcement (NotifState) is cut short for it: a
    // reminder is the one you asked for.
    function announce(text) {
        if (open || JarvisState.expanded || TodoState.amount > 0.01 || GitaState.amount > 0.01
            || CalendarState.amount > 0.01 || NotifState.amount > 0.01) return
        NotifState.announcing = false
        announceText = text
        announcing = true
        if (_autoDismiss) _announceTimer.restart(); else _announceTimer.stop()
    }

    // The centre island Reminders.qml draws over. Set by the bar.
    property var island: null

    // Sorted by due time.
    property var items: []
    readonly property int count: items.length
    // Due and not yet cleared, oldest first — what the bar's chip counts and
    // the due-only panel lists. Since 2026-10-24 a due reminder is no longer
    // a sticky card in the popup stack: it waits in the centre island's row.
    readonly property var fired: items.filter(r => r.fired)
    // What the panel lists, and so what it is sized for.
    readonly property var shown: dueOnly ? fired : items

    // A reminder was made; the bar shows the "Reminder set" notice unless
    // `quiet` — the panel's own new row is confirmation enough.
    signal added(string text, real at, bool quiet)
    // A reminder is gone.
    signal removed(string id)

    // ── geometry, shared with the bar so the island grows to fit ─────────
    // The todo list's, so the two read as one family: its row height, its
    // reading width (the bar's), its box.
    readonly property real pad: 16
    readonly property real rowH: 38
    readonly property int maxRows: 8
    readonly property real boxH: 38
    readonly property real listH: shown.length > 0 ? Math.min(shown.length, maxRows) * rowH + 8 : 0
    // The due-only list has no box under it, only the inset the box would
    // have had below its last row.
    readonly property real wantHeight: dueOnly ? 6 + listH + 4 : 6 + listH + boxH + pad

    function toggleOpen() { open ? close() : show() }
    function show() {
        if (JarvisState.expanded) JarvisState.dismiss()
        dueOnly = false
        open = true
    }
    // The chip's right click. A toggle, like every other island opener; with
    // the full panel up it switches to the due list rather than closing.
    function toggleDue() {
        if (open && dueOnly) { close(); return }
        if (fired.length === 0) return
        if (JarvisState.expanded) JarvisState.dismiss()
        dueOnly = true
        open = true
    }
    function close() { open = false }

    // ── the list ──────────────────────────────────────────────────────────
    function add(minutes, text, quiet) {
        const mins = Number(minutes)
        if (!isFinite(mins) || mins <= 0) return false
        return addAt(Date.now() + Math.round(mins * 60000), text, quiet) !== ""
    }
    // At a moment rather than after a delay — the calendar's day view, for a
    // task given a time. Returns the new reminder's id ("" if refused), which
    // the task keeps so editing or deleting it can move or drop its reminder.
    function addAt(at, text, quiet) {
        const t = String(text || "").trim()
        if (!isFinite(at) || at <= 0 || t === "") return ""
        const id = Date.now() + "-" + Math.floor(Math.random() * 1e6)
        apply(items.concat([{ id: id, at: at, text: t, fired: false }]))   // sorts, and sweeps in case mins rounded to now
        save()
        added(t, at, quiet === true)
        return id
    }

    // The single removal path: the due card's click, the panel's Delete and
    // the IPC verb all land here, so a reminder can never survive in one half
    // of the UI after being dismissed in the other.
    function remove(id) {
        removed(id)
        const list = items.filter(r => r.id !== id)
        if (list.length === items.length) return
        items = list
        save()
        if (dueOnly && fired.length === 0) close()
        if (announcing && fired.length === 0) announcing = false
    }
    // EVE's edit (2026-11-02): new words and/or a new moment, same id. "" /
    // 0 keeps the old one. Moved into the future it is pending again (a
    // snooze, in effect), and the due list closes if that emptied it, as in
    // remove(); moved into the past, apply()'s sweep fires it at once.
    function edit(id, text, at) {
        const r = items.find(x => x.id === id)
        if (!r) return false
        const t = String(text || "").trim() || r.text
        const when = Number(at) > 0 ? Number(at) : r.at
        apply(items.map(x => x.id !== id ? x
            : { id: x.id, at: when, text: t, fired: when > Date.now() ? false : x.fired }))
        save()
        if (dueOnly && fired.length === 0) close()
        if (announcing && fired.length === 0) announcing = false
        return true
    }
    function clearAll() {
        for (const r of items) removed(r.id)
        items = []
        save()
    }

    // Normalises whatever came off disk before it reaches the UI: a record
    // with no text or no due time is dropped rather than rendering as a blank
    // row, and the list is kept sorted by due time.
    function apply(list) {
        const out = []
        for (let i = 0; i < list.length; i++) {
            const r = list[i]
            if (!r || typeof r !== "object") continue
            const at = Number(r.at)
            const text = String(r.text || "").trim()
            if (!isFinite(at) || at <= 0 || text === "") continue
            out.push({ id: String(r.id || (at + "-" + i)), at: at, text: text, fired: r.fired === true })
        }
        out.sort((a, b) => a.at - b.at)
        items = out
        sweep()
    }

    readonly property bool pending: items.some(r => !r.fired)

    // 1 s is finer than a minutes-granularity feature needs, but it is what
    // keeps "in 1 minute" honest, and it only runs while something is pending.
    property var _tick: Timer {
        interval: 1000; repeat: true; running: root.pending
        onTriggered: root.sweep()
    }

    // Marks everything due as fired. Called on every tick AND on every load,
    // which is what makes this recover rather than merely schedule. The bar's
    // chip reads `fired`, so there is nothing to announce. Safe to repeat: the
    // file is only rewritten when something changed, so a load → sweep →
    // save → load cycle terminates.
    function sweep() {
        const now = Date.now()
        let changed = false
        const out = []
        for (const r of items) {
            const fired = r.fired || r.at <= now
            // The sound plays even when the island is busy and the drop is
            // skipped — the reminder still came due. chime(true): DND does
            // not silence a reminder. Its one-a-second throttle makes several
            // falling due on one sweep (or on load, after a reboot) one sound.
            if (fired !== r.fired) { changed = true; announce(r.text); NotifState.chime(true) }
            const n = { id: r.id, at: r.at, text: r.text, fired: fired }
            out.push(n)
        }
        if (!changed) return
        items = out
        save()
    }

    // Ticks only while the panel is open — the "in 12m" beside each row is
    // the only thing that reads it.
    property double now: Date.now()
    property var _nowTick: Timer {
        interval: 1000; repeat: true; running: root.open; triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }
    function countdown(at) {
        const s = Math.round((at - now) / 1000)
        if (s <= 0) return "due"
        if (s < 60) return "in " + s + "s"
        const m = Math.round(s / 60)
        if (m < 60) return "in " + m + "m"
        return "in " + Math.floor(m / 60) + "h " + (m % 60) + "m"
    }

    // Read leniently: "10", " 10 ", "10m" and "10 min" all mean the same
    // thing. Anything else is -1, which tints the box and keeps what was typed.
    function parseMinutes(s) {
        const m = /^\s*(\d+(?:\.\d+)?)\s*(?:m|min|mins|minute|minutes)?\s*$/i.exec(String(s || ""))
        if (!m) return -1
        const v = parseFloat(m[1])
        return isFinite(v) && v > 0 ? v : -1
    }

    // ── persistence ───────────────────────────────────────────────────────
    readonly property string path:
        (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
        + "/hyprahaan/reminders.json"

    // Saving goes through FileView, which owns an ordered job queue, and NOT
    // through a Process per save. The Process version silently lost writes:
    // two `ipc call reminder add` a few ms apart left the store holding only
    // the first, because restarting the writer that fast dropped the second
    // command. Measured, twice, before it was rewritten.
    property bool _retried: false
    function save() { store.setText(JSON.stringify(items)) }

    property var _store: FileView {
        id: store
        path: root.path
        // Keeps a repo instance and the live one agreeing while both are up.
        watchChanges: true
        // Absent until the first reminder is made; ENOENT at startup is not a fault.
        printErrors: false
        // The other instance's watcher reads it, so never half-written.
        atomicWrites: true
        onFileChanged: reload()
        onLoadFailed: root.apply([])
        onLoaded: {
            try {
                const p = JSON.parse(store.text() || "[]")
                root.apply(Array.isArray(p) ? p : [])
            } catch (e) {
                // A store that will not parse is a bug in the writer, not a
                // reason to take the panel down — keep what is in memory.
                console.warn("reminders: ignoring unparseable store", e)
            }
        }
        onSaved: root._retried = false
        // Only ever "the state dir does not exist yet" (a reminder added in
        // the first ms of a fresh machine's first session): make it, write
        // once more; a second failure is real and is logged, not retried.
        onSaveFailed: {
            if (root._retried) { console.warn("reminders: could not write", root.path); return }
            root._retried = true
            mkdir.running = true
        }
    }
    property var _mkdir: Process {
        id: mkdir
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")"', "reminders-mkdir", root.path]
        onExited: root.save()
    }
}
