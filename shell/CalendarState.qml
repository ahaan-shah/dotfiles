pragma Singleton

// CalendarState.qml — the month the calendar shows, the day under its cursor,
// the day open in its day view, and whether it is open.
//
// The calendar lives in the bar's centre island, which grows down to show it
// the way it grows for jarvis, the todo list and the Gita reader (Ahaan,
// 2026-10-21: "make my calendar and reminders also their own individual
// things like this dropdown UI/UX"). It was a 580 px dropdown under the clock
// with the reminders list bolted to its right; the reminders are their own
// island tenant now (RemindersState). Clicking the clock or SUPER+SHIFT+C
// opens it. Calendar.qml draws it; Bar.qml sizes the island from `amount`,
// `width` and `wantHeight` below.
//
// Two views. "month" is the grid, with a cursor the arrow keys move. "day" is
// one date — click it, or Enter on the cursor — where a task can be added for
// that day, with the todo list's priority chips and an optional time; the
// task lands in the todo list, and with a time also in the reminders (Ahaan,
// same day: "this task shows up in tasks as well as reminders accordingly").

import QtQuick
import Quickshell

Singleton {
    id: root

    property bool open: false
    // The island's expansion, 0..1 — animated here rather than in the bar so
    // the bar and Calendar.qml read the same number on the same frame.
    property real amount: open ? 1 : 0
    Behavior on amount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

    // The centre island Calendar.qml draws over. Set by the bar.
    property var island: null

    // "month" | "day"
    property string view: "month"

    // Which month is showing — independent of today — and the cursor's day in
    // it. In the day view, the cursor's day is the day that is open.
    property int year: new Date().getFullYear()
    property int month: new Date().getMonth()          // 0 = January
    property int cur: new Date().getDate()
    readonly property var monthNames: ["January", "February", "March", "April",
        "May", "June", "July", "August", "September", "October", "November", "December"]

    function toggleOpen() { open ? close() : show() }
    function show() {
        if (JarvisState.expanded) JarvisState.dismiss()
        // Always opens on today's month view, not wherever it was left.
        today()
        view = "month"
        open = true
    }
    function close() { open = false }
    // Open straight into one day's view (EVE, 2026-10-26: "show me today's
    // agenda in the calendar" opened the month and stopped there). "YYYY-MM-DD"
    // only; anything else, or a date that does not exist, opens the month.
    function showDay(iso) {
        const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ""))
        show()
        if (!m) return
        const d = new Date(+m[1], +m[2] - 1, +m[3])
        if (d.getMonth() !== +m[2] - 1) return          // 2026-02-30 rolls over: refuse it
        openDay(d)
    }

    function today() { goTo(new Date()) }
    // A month (or, by 12, a year) away; the cursor keeps its day where the
    // new month has one (31 Jan -> 28 Feb).
    function step(n) {
        const m = month + n
        const y = year + Math.floor(m / 12)
        const mm = ((m % 12) + 12) % 12
        cur = Math.min(cur, new Date(y, mm + 1, 0).getDate())
        year = y
        month = mm
    }
    // The cursor, by days; across a month's edge it takes the month with it.
    function move(n) { goTo(new Date(year, month, cur + n)) }
    function goTo(d) {
        // Day first: a month change with a day the old month lacks would
        // otherwise be read, for a frame, as a date that does not exist.
        cur = 1
        year = d.getFullYear()
        month = d.getMonth()
        cur = d.getDate()
    }
    function openDay(d) {
        if (d) goTo(d)
        view = "day"
    }
    function back() { view = "month" }

    readonly property bool onToday: year === clock.date.getFullYear() && month === clock.date.getMonth()
    readonly property var selDate: new Date(year, month, cur)
    function dayKey(d) {
        const p = n => (n < 10 ? "0" : "") + n
        return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate())
    }

    // ── geometry, shared with the bar so the island grows to fit ─────────
    readonly property real pad: 20
    readonly property real headH: 36
    readonly property real dayHeadH: 18
    // The days are circles, the dropdown's look. Their rows are this far
    // apart; their columns are spread across whatever width the island has
    // (Calendar.qml), so nothing sits in a strip with empty margins either
    // side (Ahaan: "fill the space like the gita thing did and not leave
    // borders" — wide tiles at the Gita's 760 were tried and taken back).
    readonly property real cell: 38
    readonly property real gap: 6
    readonly property real gridH: 6 * cell + 5 * gap
    readonly property real boxH: 38
    // "Through the year" under the grid: a label line and a 6 px bar.
    readonly property real yearH: 30
    // Both views are this tall, so moving between them never resizes the
    // island's height — only its width, below.
    readonly property real wantHeight: 6 + headH + 10 + dayHeadH + 8 + gridH + 18 + yearH + 16
    // The island's width floor, as it was: room for the grid in the month
    // view, for a box, a time and two chips in the day view. The island is
    // often wider than this (its clock row sets it), and the content
    // spreads to fill whatever it is.
    readonly property real monthW: 7 * cell + 6 * gap + 2 * pad + 60
    readonly property real dayW: 620
    property real width: view === "day" ? dayW : monthW
    Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

    // Drives `cells` and the year bar across midnight. `new Date()` in a
    // binding is not a dependency the binding engine can see — the old
    // dropdown recorded "today" going stale for the rest of the day without one.
    property var _clock: SystemClock { id: clock; precision: SystemClock.Minutes }

    // Days with an open task on them, for the grid's dot.
    readonly property var marked: {
        const s = {}
        for (const t of TodoState.items) if (t.due > 0 && !t.done) s[dayKey(new Date(t.due))] = true
        return s
    }

    // 6 weeks x 7 days, Sunday first as the dropdown had it, with the
    // neighbouring months' days muted so the grid is always a full rectangle
    // and the island never changes height between months.
    readonly property var cells: {
        const first = new Date(year, month, 1).getDay()                 // 0 = Sunday
        const tk = dayKey(clock.date)
        const out = []
        for (let i = 0; i < 42; i++) {
            const d = new Date(year, month, 1 - first + i)
            const k = dayKey(d)
            const inMonth = d.getMonth() === month
            out.push({ date: d, num: d.getDate(), inMonth: inMonth,
                       weekend: i % 7 === 0 || i % 7 === 6, today: k === tk,
                       cursor: inMonth && d.getDate() === cur, marked: !!marked[k] })
        }
        return out
    }

    // How far through the shown year today is: a past year is whole, a
    // future one not begun.
    readonly property real yearFrac: {
        const t = clock.date
        if (year < t.getFullYear()) return 1
        if (year > t.getFullYear()) return 0
        const a = new Date(year, 0, 1), b = new Date(year + 1, 0, 1)
        return (t - a) / (b - a)
    }

    // The open day's tasks, timed ones by time first, then the rest.
    readonly property var dayTasks: {
        const k = dayKey(selDate)
        return TodoState.items.filter(x => x.due > 0 && dayKey(new Date(x.due)) === k)
            .sort((a, b) => (a.timed !== b.timed ? (a.timed ? -1 : 1) : a.due - b.due))
    }

    // ── the time box ──────────────────────────────────────────────────────
    // It takes only digits and a / p (m is accepted and means nothing more),
    // so it cannot hold a typo (Ahaan, 2026-10-21: "no other keys other than
    // A, P, M and numbers are registered … if I type AM first, it should set
    // AM, then I can type numbers"). Its text is the keys as typed, at most
    // four digits and one half, in any order: "540p", "a1240", "2130".
    // Digits read one way everywhere — the mask, the parse — so what is lit
    // is what is saved:
    //   1 or 2 digits   the hour ("5", "12"); 2 that cannot be an hour
    //                   ("54") are H and the first digit of the minutes
    //   3               H MM   ("540"  -> 5:40)
    //   4               HH MM  ("1240" -> 12:40)
    // With a or p it is a 12-hour time; without, a 24-hour one ("2130" is
    // 9:30 PM), shown with the half it implies.
    function timeKeys(s) {
        s = String(s || "")
        return { d: s.replace(/[^0-9]/g, "").slice(0, 4),
                 half: ((/[ap]/i.exec(s) || [""])[0]).toUpperCase() }
    }
    function timeSplit(d, half) {
        if (d.length === 1) return { h: +d, mi: 0, lit: 2, whole: true }
        if (d.length === 2) return +d <= (half ? 12 : 23)
            ? { h: +d, mi: 0, lit: 2, whole: true }
            : { h: +d[0], mi: +d[1] * 10, lit: 4, whole: false }
        if (d.length === 3) return { h: +d[0], mi: +d.slice(1), lit: 5, whole: true }
        if (d.length === 4) return { h: +d.slice(0, 2), mi: +d.slice(2), lit: 5, whole: true }
        return { h: 0, mi: 0, lit: 0, whole: false }
    }
    // -> minutes after midnight, or -1 if it is not a whole, real time.
    function parseTime(s) {
        const k = timeKeys(s)
        const t = timeSplit(k.d, k.half)
        if (!t.whole || t.mi > 59) return -1
        let h = t.h
        if (k.half) {
            if (h < 1 || h > 12) return -1
            h = h % 12 + (k.half === "P" ? 12 : 0)
        } else if (h > 23) return -1
        return h * 60 + t.mi
    }
    // The box drawn as "00:00 AM": `lit` characters typed, the half lit once
    // a or p is, and `next` — the pair the next keys fill (hours, minutes,
    // then the half while it is still unset), which the box shows a step
    // brighter than the rest.
    function timeMask(s) {
        const k = timeKeys(s)
        const t = timeSplit(k.d, k.half)
        const p = n => (n < 10 ? "0" : "") + n
        let h12 = t.h, half = k.half
        if (!half) { half = t.h >= 12 && t.h < 24 ? "P" : "A"; h12 = t.h % 12 === 0 && k.d !== "" ? 12 : t.h % 12 }
        return { text: p(h12) + ":" + p(t.mi) + " " + half + "M", lit: t.lit, halfLit: k.half !== "",
                 next: t.lit < 2 ? 0 : t.lit < 5 ? 3 : k.half === "" ? 6 : -1 }
    }
    // Minutes -> the keys that type it, as the box holds an edited task's
    // time ("0540p").
    function timeKeysOf(mins) {
        const p = n => (n < 10 ? "0" : "") + n
        const h = Math.floor(mins / 60)
        return p(h % 12 === 0 ? 12 : h % 12) + p(mins % 60) + (h < 12 ? "a" : "p")
    }
    // Minutes after midnight -> "12:40 AM", the form the time box settles to.
    function fmtTime(mins) {
        const p = n => (n < 10 ? "0" : "") + n
        const h = Math.floor(mins / 60)
        return p(h % 12 === 0 ? 12 : h % 12) + ":" + p(mins % 60) + (h < 12 ? " AM" : " PM")
    }
}
