pragma Singleton

// GitaState.qml — the Gita reader's text, its place, its reading log, and
// whether it is open.
//
// Ahaan, 2026-10-21, with a screen recording of the Omarchy Bible reader:
// "build me the same thing but for the Bhagavad Gita (As it is by ISKON) …
// let it be a panel dropdown from the center island in the bar and add a lil
// button to open it in the bar (in the tray with audio and display)". The
// island grows down for it as it does for the todo list (Bar.qml sizes it from
// `amount`); Gita.qml draws what is in it; this file owns the data.
//
// Then, the same day, on the first build: "I want the sanskrit part followed
// by the translation below it. Just one verse per page with the verse label on
// top. No vim keybinds, simple interface." So a page is one text — its label,
// the Devanagari, the verse romanised, the translation — turned with the
// arrows or the ‹ › beside the label. The Bible reader's other two features
// stay, mouse-first: the label opens a chapter + verse picker, and the header
// has search and the reading activity. No layer chips, no j/k/h/l.
//
// Verses are As It Is's own numbering, merged ones included (1.16-18 is one
// page, as it is one text in the book).
//
// The text is NOT in this repo (it is the BBT's; the repo is mirrored to a
// public one). scripts/gita-from-pdf.py builds it from a PDF of the book into
// $XDG_DATA_HOME/hyprahaan/gita.json. It is parsed on first open, not at
// startup — ~2 MB of JSON the shell has no reason to hold until it is read.
//
// Place and the reading log live in $XDG_STATE_HOME/hyprahaan/gita.json,
// through FileView as TodoState does.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool open: false
    // The island's expansion, 0..1, animated here so the bar and Gita.qml
    // read the same number on the same frame (TodoState's reason).
    property real amount: open ? 1 : 0
    // EVE's expand, exactly (Bar.qml, centerIsland.ex: 300 ms OutCubic). It
    // was cut to 200 ms when the reader felt slow; the slowness was the page
    // re-wrapping on every frame (see targetWidth), and at 200 ms Ahaan found
    // it "too snappy now … model the animation speed off of the eve expand".
    Behavior on amount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

    // The centre island Gita.qml draws over. Set by the bar.
    property var island: null
    // The island's size once fully open, set by the bar (which knows the
    // screen): the page is laid out at THIS size from the start, and the
    // growing island only reveals it. Laid out at the island's size instead,
    // every line re-wrapped on every frame of the open and the close — the
    // lag Ahaan saw — and mid-animation the page was short enough to look
    // overflowing, so its scrollbar showed before the island had opened.
    property real targetWidth: 760
    property real reach: 600

    // "read" | "go" | "search" | "activity"
    property string view: "read"

    function toggleOpen() { open ? close() : show() }
    function show() {
        // One thing in the island at a time.
        if (JarvisState.expanded) JarvisState.dismiss()
        if (TodoState.open) TodoState.close()
        _wanted = true
        view = "read"
        open = true
    }
    function close() { open = false }

    // ── the text ──────────────────────────────────────────────────────────
    // [{ n, title, count, verses: [{ id, n, dev, roman, syn, tr, pp: [{t, q}] }] }]
    property var chapters: []
    property bool loaded: false
    // True once a load has been tried and found nothing to read.
    property bool missing: false
    readonly property string dataPath:
        (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share")
        + "/hyprahaan/gita.json"
    // The builder, as deployed — what the empty state tells you to run.
    readonly property string buildCmd: "python3 ~/.config/scripts/gita-from-pdf.py <book.pdf>"
    property bool _wanted: false
    // Read a few seconds after the shell starts, so the first open has the
    // text already rather than an empty island while it parses. It was read
    // on first open, when it was 2 MB; the reader's file is 252 KB now (the
    // page only draws the verse and translation), which costs little to hold.
    property var _preload: Timer { interval: 4000; running: true; onTriggered: root._wanted = true }

    property var _data: FileView {
        id: textFile
        // No path until _wanted, so nothing is read during startup itself.
        // (preload: false was tried first: with it, reload() reads nothing —
        // the file loads only when text() is called — so onLoaded never fired
        // and the reader sat on "no text".)
        path: root._wanted ? root.dataPath : ""
        printErrors: false
        // A rebuild (gita-from-pdf.py) is picked up without a relaunch.
        watchChanges: root.loaded || root.missing
        onFileChanged: reload()
        onLoadFailed: { root.missing = true }
        onLoaded: {
            try {
                const d = JSON.parse(textFile.text() || "{}")
                const ch = Array.isArray(d.chapters) ? d.chapters.filter(c => c.verses && c.verses.length) : []
                root.chapters = ch
                root.missing = ch.length === 0
                root._index = null
                root.loaded = ch.length > 0
                root.clampPos()
            } catch (e) {
                console.warn("gita: unreadable", root.dataPath, e)
                root.missing = true
            }
        }
    }

    // ── where you are ─────────────────────────────────────────────────────
    property int ci: 0          // chapter index into `chapters`
    property int vi: 0          // verse index into that chapter's verses
    readonly property var chapter: chapters.length ? chapters[Math.min(ci, chapters.length - 1)] : null
    readonly property var verses: chapter ? chapter.verses : []

    function clampPos() {
        if (!chapters.length) return
        ci = Math.max(0, Math.min(ci, chapters.length - 1))
        vi = Math.max(0, Math.min(vi, chapters[ci].verses.length - 1))
    }
    function goTo(c, v) {
        if (!chapters.length) return
        // vi to 0 first: with ci set first, a verse index past the end of a
        // shorter new chapter was live for one binding pass, and the header's
        // `verses[vi].id` threw "Cannot read property 'id' of undefined"
        // (seen on random jumps, 2026-10-22). Verse 0 exists in every chapter.
        vi = 0
        ci = Math.max(0, Math.min(c, chapters.length - 1))
        vi = Math.max(0, Math.min(v, chapters[ci].verses.length - 1))
        save()
    }
    function step(d) {
        const nv = vi + d
        if (nv >= 0 && nv < verses.length) { vi = nv; save(); return }
        // Off either end of a chapter: on into the next, or back to the
        // previous one's last verse, as turning a page would.
        if (d > 0 && ci < chapters.length - 1) goTo(ci + 1, 0)
        else if (d < 0 && ci > 0) goTo(ci - 1, chapters[ci - 1].verses.length - 1)
    }
    // Uniform over verses, not chapters — a long chapter gets as many
    // chances as it has pages — and never the verse already up, so R always
    // turns the page.
    function random() {
        let total = 0
        for (const c of chapters) total += c.verses.length
        if (total < 2) return
        for (;;) {
            let r = Math.floor(Math.random() * total), c = 0
            while (r >= chapters[c].verses.length) r -= chapters[c++].verses.length
            if (c !== ci || r !== vi) return goTo(c, r)
        }
    }
    function chapterStep(d) {
        if (ci + d >= 0 && ci + d < chapters.length) goTo(ci + d, 0)
    }
    // "2.13", "2.13-14", "2 13", "bg 2.13" — or any verse a merged range
    // covers ("1.17" finds 1.16-18). Returns [c, v] indices, or null.
    function find(ref) {
        const m = String(ref || "").match(/(\d+)\D+(\d+)/)
        if (!m) return null
        const c = chapters.findIndex(x => x.n === Number(m[1]))
        if (c < 0) return null
        const n = Number(m[2])
        const v = chapters[c].verses.findIndex(x => {
            const p = String(x.n).split("-").map(Number)
            return n >= p[0] && n <= (p[1] || p[0])
        })
        return v < 0 ? null : [c, v]
    }

    // ── how tall the page wants the island ────────────────────────────────
    // Set by Gita.qml from what the page holds; the bar grows the island to
    // it, up to the reach it allows. Animated here, so a short verse after a
    // long one closes the island up smoothly rather than in a jump.
    property real wantHeight: 420
    // EVE's 300 ms OutCubic, like the open: a page turn, a switch to the
    // overview or search, S and P all resize the island at one pace.
    Behavior on wantHeight { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

    // ── synonyms and purports, on request ────────────────────────────────
    // S and P in the reader (Ahaan, 2026-10-21: "add binds like S, P for
    // synonyms and purports if i wish to see it. The file for this can be
    // read only when it is called by me via the bind in the panel"). They
    // live in their own file, 1.3 MB, which gets a path — and so is read —
    // only on the first press of either; never at startup, never on open.
    // Once on, a part stays on from page to page until pressed again; it is
    // not remembered across shell restarts.
    property bool showSyn: false
    property bool showPp: false
    property var extras: ({})            // id -> { syn, pp: [paragraph] }
    property bool _extrasWanted: false
    readonly property string extrasPath: dataPath.replace("gita.json", "gita-extras.json")
    function toggleSyn() { _extrasWanted = true; showSyn = !showSyn }
    function togglePp() { _extrasWanted = true; showPp = !showPp }
    property var _extras: FileView {
        id: extrasFile
        path: root._extrasWanted ? root.extrasPath : ""
        printErrors: false
        watchChanges: root._extrasWanted
        onFileChanged: reload()
        onLoaded: {
            try { root.extras = JSON.parse(extrasFile.text() || "{}") }
            catch (e) { console.warn("gita: unreadable", root.extrasPath, e) }
        }
    }

    // ── search ────────────────────────────────────────────────────────────
    // Folded for matching: diacritics off (NFD, then the combining marks), case
    // off, hyphens and apostrophes out — "krsna" finds "Kṛṣṇa", "kuruksetra"
    // finds "kuru-kṣetre" in a verse's synonyms.
    function fold(s) {
        return String(s).normalize("NFD").replace(/[̀-ͯ]/g, "")
                        .replace(/[-'’]/g, "").toLowerCase()
    }
    property var _index: null   // [{ c, v, hay }], built on the first search
    function index() {
        if (_index) return _index
        const out = []
        for (let c = 0; c < chapters.length; c++) {
            const vs = chapters[c].verses
            for (let v = 0; v < vs.length; v++) {
                const x = vs[v]
                out.push({ c: c, v: v,
                           hay: fold(x.tr.map(p => p.t).join("\n") + "\n" + x.roman.map(p => p.t).join("\n")) })
            }
        }
        _index = out
        return out
    }
    // Words must all appear; "quoted phrases" as written; -word must not.
    function parse(q) {
        const must = [], not = []
        const re = /(-?)"([^"]+)"|(-?)(\S+)/g
        let m
        while ((m = re.exec(q)) !== null) {
            const neg = (m[1] || m[3]) === "-"
            const t = fold(m[2] !== undefined ? m[2] : m[4]).trim()
            if (t === "") continue
            ;(neg ? not : must).push(t)
        }
        return { must: must, not: not }
    }
    // { total, hits: [{ c, v, ref, snip }] } — at most `cap` hits carry a snippet.
    function search(q, cap) {
        const p = parse(q)
        if (!p.must.length) return { total: 0, hits: [] }
        const idx = index()
        const hits = []
        let total = 0
        for (let i = 0; i < idx.length; i++) {
            const h = idx[i].hay
            if (!p.must.every(t => h.indexOf(t) >= 0)) continue
            if (p.not.some(t => h.indexOf(t) >= 0)) continue
            total++
            if (hits.length < cap) hits.push({ c: idx[i].c, v: idx[i].v })
        }
        for (const h of hits) {
            const x = chapters[h.c].verses[h.v]
            h.ref = x.id
            h.snip = snippet(x, p.must[0])
        }
        return { total: total, hits: hits }
    }
    // Where the term is: the translation if it is there, else the verse —
    // cut to a window around it. (Purports and synonyms are not in the
    // reader's file: the page does not show them, so a hit in one would open
    // a page without the word on it.)
    function snippet(x, term) {
        const fields = x.tr.concat(x.roman).map(p => p.t)
        for (const f of fields) {
            const at = foldedIndex(f, term)
            if (at < 0) continue
            const from = Math.max(0, at - 70)
            const to = Math.min(f.length, at + 150)
            return { pre: (from > 0 ? "…" : "") + f.slice(from, at),
                     hit: f.slice(at, at + matchLen(f, at, term)),
                     post: f.slice(at + matchLen(f, at, term), to) + (to < f.length ? "…" : "") }
        }
        return { pre: (x.tr[0] ? x.tr[0].t : "").slice(0, 200), hit: "", post: "" }
    }
    // indexOf against the folded text, mapped back to the original's offsets:
    // folding drops characters (marks, hyphens), so the two do not line up.
    function foldedIndex(f, term) {
        let folded = "", map = []
        for (let i = 0; i < f.length; i++) {
            const k = fold(f[i])
            for (let j = 0; j < k.length; j++) map.push(i)
            folded += k
        }
        const at = folded.indexOf(term)
        return at < 0 ? -1 : map[at]
    }
    function matchLen(f, at, term) {
        let n = 0, len = 0
        while (at + len < f.length && n < term.length) { n += fold(f[at + len]).length; len++ }
        // Swallow any combining marks left on the last letter.
        while (at + len < f.length && fold(f[at + len]).length === 0) len++
        return len
    }

    // ── the reading log ───────────────────────────────────────────────────
    // A verse counts as read once its page has been up for a few seconds
    // (Gita.qml's dwell timer) — paging past one does not. Stored
    // per day as verse ids, nothing else: no text, no times, no network.
    // Always on. There was a "private tracking" switch, carried over from the
    // Bible reader; Ahaan removed it (2026-10-21) — nothing here was ever
    // anything but private, so it read as a setting with no other side. A
    // stored `"track": false` from that era is ignored.
    property var days: ({})         // "YYYY-MM-DD" -> ["2.13", …]
    function dayKey(d) {
        const p = n => (n < 10 ? "0" : "") + n
        return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate())
    }
    function markRead(id) {
        if (!id) return
        const k = dayKey(new Date())
        const list = days[k] || []
        if (list.indexOf(id) >= 0) return
        const d = Object.assign({}, days)
        d[k] = list.concat([id])
        days = d
        save()
    }

    readonly property var readSet: {
        const s = {}
        for (const k in days) for (const id of days[k]) s[id] = true
        return s
    }
    readonly property var stats: {
        const today = new Date()
        const keys = Object.keys(days).filter(k => days[k].length).sort()
        let streak = 0
        const d = new Date(today)
        // A streak survives a day not yet read: it counts back from yesterday
        // until today has an entry, then from today.
        if (!(days[dayKey(d)] || []).length) d.setDate(d.getDate() - 1)
        while ((days[dayKey(d)] || []).length) { streak++; d.setDate(d.getDate() - 1) }
        // This week from Monday.
        const mon = new Date(today)
        mon.setDate(mon.getDate() - ((mon.getDay() + 6) % 7))
        const monKey = dayKey(mon)
        let week = 0
        for (const k of keys) if (k >= monKey) week += days[k].length
        return { verses: Object.keys(readSet).length, activeDays: keys.length,
                 streak: streak, week: week, since: keys.length ? keys[0] : "",
                 today: (days[dayKey(today)] || []).length }
    }
    // Pages in the book (a joined page like 13.1-2 is one), the reading
    // record's denominator — readSet holds page ids, so the two match.
    readonly property int totalVerses: {
        let n = 0
        for (const c of chapters) n += c.verses.length
        return n
    }
    // How much of chapter c has been read, 0..1 — the go view's thin bar.
    function chapterRead(c) {
        const vs = chapters[c] ? chapters[c].verses : []
        if (!vs.length) return 0
        let n = 0
        for (const x of vs) if (readSet[x.id]) n++
        return n / vs.length
    }

    // ── persistence ───────────────────────────────────────────────────────
    readonly property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
        + "/hyprahaan/gita.json"
    property bool _retried: false
    property bool _stateLoaded: false
    function save() {
        // Before the first read lands, a save would write defaults over the
        // stored place and log.
        if (!_stateLoaded) return
        store.setText(JSON.stringify({ ci: ci, vi: vi, days: days }))
    }
    property var _store: FileView {
        id: store
        path: root.statePath
        watchChanges: true
        printErrors: false
        atomicWrites: true
        onFileChanged: reload()
        onLoadFailed: root._stateLoaded = true
        onLoaded: {
            try {
                const p = JSON.parse(store.text() || "{}")
                if (typeof p.ci === "number") root.ci = p.ci
                if (typeof p.vi === "number") root.vi = p.vi
                if (p.days && typeof p.days === "object") root.days = p.days
                root.clampPos()
            } catch (e) {
                console.warn("gita: ignoring unparseable state", e)
            }
            root._stateLoaded = true
        }
        onSaved: root._retried = false
        onSaveFailed: {
            if (root._retried) { console.warn("gita: could not write", root.statePath); return }
            root._retried = true
            mkdir.running = true
        }
    }
    property var _mkdir: Process {
        id: mkdir
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")"', "gita-mkdir", root.statePath]
        onExited: root.save()
    }
}
