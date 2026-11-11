pragma Singleton

// NotifState.qml — the notification center as a centre-island tenant
// (SUPER+SHIFT+N), and the way a notification arrives.
//
// Ahaan, 2026-10-26: "make notifications show up in the same style as how
// reminders expand the panel briefly and then have them sit in the
// notification center in the center island … UI/UX like reminders, todo".
// Until then a notification was a card in a popup stack at the top left that
// went after 2 s, and the history was a 320 px dropdown under the arch button.
// Both are gone: a notification drops the centre island for announceMs with
// its text beside a dot — the reminders' announcement, with the dot in the
// bell's place so the two read apart ("a dot beside the text so i know its
// just a notification") — and then waits in this list.
//
// The daemon stays in Bar.qml (NotificationServer owns the D-Bus name and has
// since swaync went); it hands this file the tracked list and the arrival
// times, and calls announce(). Nothing here holds a Notification it did not
// get from there, so dismissing one here is dismissing it in the daemon.

import QtQuick
import Quickshell

Singleton {
    id: root

    property bool open: false
    // The island's expansion, 0..1, animated here so the bar and
    // Notifications.qml read the same number on the same frame.
    property real amount: open ? 1 : 0
    Behavior on amount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

    // The centre island Notifications.qml draws over. Set by the bar.
    property var island: null

    // Do Not Disturb: no announcement and no sound, the list still fills.
    // Was Bar.qml's `dnd`, toggled from the old panel's bell button; since
    // 2026-11-02 it is ui.conf's NOTIF_DND, so it survives a shell restart and
    // Settings -> Setup -> Notifications, the center's button, its D key and
    // the IPC all move the one value. Read-only here: setDnd() is the way in.
    readonly property bool dnd: UiConfig.notifDnd === "on"
    function setDnd(on) { root.setPref("NOTIF_DND", on ? "on" : "off") }

    // The rest of that Settings page (Ahaan, 2026-11-02): a sound on arrival,
    // whether the drop ends by itself, and after how long.
    //   autoDismiss  on: the drop goes after announceMs into the center, as it
    //                always did. off: it stays until it is clicked.
    readonly property bool autoDismiss: UiConfig.notifAutodismiss !== "off"
    readonly property bool soundOn: UiConfig.notifSound === "on"
    // The sounds on offer. sound-theme-freedesktop's short ones only — GNOME's
    // "alarms" are alarms, several seconds long. A missing file just plays
    // nothing (pw-play exits), never an error in the shell.
    readonly property string _snd: "/usr/share/sounds/freedesktop/stereo/"
    readonly property var sounds: [
        { id: "chime",     title: "Chime",     file: _snd + "message-new-instant.oga" },
        { id: "bell",      title: "Bell",      file: _snd + "bell.oga" },
        { id: "message",   title: "Message",   file: _snd + "message.oga" },
        { id: "complete",  title: "Complete",  file: _snd + "complete.oga" },
        { id: "info",      title: "Info",      file: _snd + "dialog-information.oga" },
        { id: "attention", title: "Attention", file: _snd + "window-attention.oga" }
    ]
    // Anything ui.conf holds that is not one of the above is the first, so a
    // typo still plays a sound and the Sound page still ticks a row.
    readonly property var sound: {
        const hit = sounds.filter(x => x.id === UiConfig.notifSoundName)
        return hit.length ? hit[0] : sounds[0]
    }
    // The choices for how long, in seconds: 0.5 to 10 in half-second steps
    // (Ahaan, 2026-11-02; the first cut was 1.5/2.5/4/6/8/10). Strings as
    // ui.conf holds them — "1", "1.5" … — the same set ui-prefs.sh checks.
    readonly property var durations: Array.from({ length: 20 }, (_, i) => String((i + 1) / 2))
    readonly property string duration: durations.indexOf(UiConfig.notifDuration) >= 0 ? UiConfig.notifDuration : "2.5"

    // pw-play through execDetached: no pipe back to the shell, so nothing for
    // it to die of (the SIGPIPE rule). Throttled to one a second, so a chat
    // app catching up on twenty messages is one chime, not twenty.
    property real _lastChime: 0
    function play(s) {
        if (!s) return
        Quickshell.execDetached(["pw-play", s.file])
    }
    // ignoreDnd: a reminder coming due (RemindersState.sweep) — DND is for
    // other people's notifications, not the ones you set yourself.
    function chime(ignoreDnd) {
        if ((dnd && !ignoreDnd) || !soundOn) return
        const now = Date.now()
        if (now - _lastChime < 1000) return
        _lastChime = now
        play(sound)
    }

    // ui.conf, written the way Settings.setDockPref writes it: assigned here
    // first so every reader moves this frame, then persisted by ui-prefs.sh,
    // whose write UiConfig reads back as the same value.
    readonly property string _prefs: {
        const dir = String(Quickshell.shellDir || "").replace(/^file:\/\//, "")
        const cut = dir.lastIndexOf("/")
        return (cut > 0 ? dir.substring(0, cut) : (Quickshell.env("HOME") || "") + "/.config") + "/scripts/ui-prefs.sh"
    }
    readonly property var _keys: ({
        NOTIF_DND: "notifDnd", NOTIF_SOUND: "notifSound", NOTIF_SOUND_NAME: "notifSoundName",
        NOTIF_AUTODISMISS: "notifAutodismiss", NOTIF_DURATION: "notifDuration"
    })
    function setPref(key, val) {
        if (!_keys[key]) return
        UiConfig[_keys[key]] = val
        Quickshell.execDetached(["bash", _prefs, "set", key, val])
    }

    // Newest first. Bound by the bar to the daemon's trackedNotifications.
    property var items: []
    readonly property int count: items.length
    // id -> arrival epoch ms (a Notification carries no time of its own).
    property var times: ({})

    // ── the arrival announcement ────────────────────────────────────────
    // RemindersState.announce's, to the number: the island drops announceH
    // for announceMs, the text shows, the island goes back up. A second
    // notification inside that window takes over the text and restarts the
    // clock rather than queueing — a burst (a chat app catching up) would
    // otherwise hold the island down for 2.5 s apiece; `burst` says how many
    // the announcement stands for.
    property bool announcing: false
    property string announceTitle: ""
    property string announceBody: ""
    property int burst: 0
    readonly property real announceH: 64
    // 2.5 s until 2026-11-02; now the Settings page's "Show for".
    readonly property int announceMs: Math.round(parseFloat(duration) * 1000) || 2500
    property real announceAmount: announcing ? 1 : 0
    Behavior on announceAmount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    property var _announceTimer: Timer {
        interval: root.announceMs
        onTriggered: root.endAnnounce()
    }
    // A click on the drop puts it away, into the center — the only way a
    // drop ends with Auto-dismiss off, and an early out with it on.
    function endAnnounce() { _announceTimer.stop(); announcing = false; burst = 0 }
    // Auto-dismiss switched on under a drop that was staying: give it its
    // time from now, rather than leaving it stuck until clicked.
    onAutoDismissChanged: if (announcing) { if (autoDismiss) _announceTimer.restart(); else _announceTimer.stop() }
    // Same courtesy as a reminder's: only into an island nobody is using —
    // a panel, an EVE card, or a reminder's own announcement. Skipped ones
    // are not lost; they are in the list.
    function announce(title, body) {
        if (dnd) return
        if (open || JarvisState.expanded || TodoState.amount > 0.01 || GitaState.amount > 0.01
            || CalendarState.amount > 0.01 || RemindersState.amount > 0.01 || MusicState.amount > 0.01
            || NotesState.amount > 0.01 || RemindersState.announcing) return
        announceTitle = plain(title)
        announceBody = plain(body)
        burst = announcing ? burst + 1 : 1
        announcing = true
        if (autoDismiss) _announceTimer.restart(); else _announceTimer.stop()
    }
    // A body may carry markup (bodyMarkupSupported); one line of the island
    // has no room for it.
    function plain(s) {
        return String(s || "").replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
            .replace(/&amp;/g, "&").replace(/\s+/g, " ").trim()
    }

    // ── geometry, shared with the bar so the island grows to fit ─────────
    // The reminders' family: their padding and box height, a taller row for
    // a title over a body line.
    readonly property real pad: 16
    readonly property real rowH: 52
    readonly property int maxRows: 7
    readonly property real boxH: 38
    readonly property real emptyH: 64
    readonly property real listH: count > 0 ? Math.min(count, maxRows) * rowH + 8 : emptyH
    readonly property real wantHeight: 6 + listH + boxH + pad
    // Between the calendar and the todo list (Ahaan, 2026-10-26). The todo
    // list's reading width, up to 760, was "too wide"; the calendar's 402 —
    // which on screen left the island at its clock row's own ~428 — was
    // "no little wider". 520.
    readonly property real width: 520

    function toggleOpen() { open ? close() : show() }
    function show() {
        if (JarvisState.expanded) JarvisState.dismiss()
        announcing = false
        open = true
    }
    function close() { open = false }

    function dismiss(n) { if (n) n.dismiss() }
    function clearAll() {
        const list = items.slice()
        for (let i = 0; i < list.length; i++) list[i].dismiss()
    }
    // The app's default action if it offered one (a chat opens the chat),
    // then it is cleared, as the old card cleared on a click.
    function activate(n) {
        if (!n) return
        const acts = n.actions || []
        for (let i = 0; i < acts.length; i++)
            if (acts[i].identifier === "default") { acts[i].invoke(); break }
        n.dismiss()
    }

    // "02:32 PM" today, "Yesterday 02:32 PM", "Mon 02:32 PM" within the week,
    // "12 Oct 02:32 PM" past it. Bar.qml's notifTimeText, moved with the list.
    function timeText(ms) {
        if (!ms) return ""
        const d = new Date(ms), now = new Date()
        const day0 = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
        const t = Qt.formatDateTime(d, "hh:mm AP")
        if (ms >= day0) return t
        if (ms >= day0 - 86400000) return "Yesterday " + t
        if (ms >= day0 - 6 * 86400000) return Qt.formatDateTime(d, "ddd ") + t
        return Qt.formatDateTime(d, "d MMM ") + t
    }
    // A notification's picture: its own image, else its app's icon.
    function iconFor(n) {
        if (!n) return ""
        if (n.image && n.image !== "") return n.image
        try { if (n.appIcon && n.appIcon !== "") return Quickshell.iconPath(n.appIcon, "") } catch (e) {}
        return ""
    }
}
