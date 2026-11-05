pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The dock's Downloads stack: the newest files in the user's download folder,
// and the state of the popup that lists them. A singleton for the same reason
// DockPreview is one: the dock icon (inside a Variants delegate in MacShell)
// and the popup (a PanelWindow in a second Variants block) cannot see each
// other's ids, and only one screen's popup is ever up at once.
QtObject {
    id: root

    // ── The folder ────────────────────────────────────────────────────────
    // `folder` is whatever xdg-user-dir says, read by the first poll (the
    // command below) — not a hardcoded path, which is the machine-specific
    // constant this repo keeps out of configs. `dir` is only what it holds for
    // the instant before that lands, and what the command itself falls back to
    // when xdg-user-dir is missing or prints nothing.
    readonly property string dir: Quickshell.env("HOME") + "/Downloads"
    property string folder: root.dir

    // ── Files ─────────────────────────────────────────────────────────────
    // [{ name, path, mtime (epoch seconds), image, icon }], newest first.
    // `icon` is the file's MIME-type icon as a file:// URL (downloads-list.sh
    // finds it), or "" when the theme has none.
    property var files: []
    // The clock the popup's "5m" / "3h" ages are read against. Bumped by every
    // poll, so the ages stay current without `files` being reassigned — which
    // would rebuild every row and the dock's fanned icons, and flash them.
    property real now: Date.now() / 1000
    // How many are newer than the last time the popup was opened. Starts at
    // the shell's own start, so files from before this session don't light a
    // badge nobody asked for.
    property real lastSeen: Date.now() / 1000
    readonly property int unseen: root.files.filter(f => f.mtime > root.lastSeen).length

    readonly property int maxFiles: 8

    // ── Recents ───────────────────────────────────────────────────────────
    // The files most recently opened anywhere, from GTK's recently-used.xbel
    // (downloads-list.sh reads it). Same shape as `files`, with `mtime` the
    // last-used time. The popup shows the top half as Recents and the bottom
    // as Downloads, `perSection` each — Ahaan's split, 2026-10-29.
    property var recents: []
    readonly property int perSection: 4
    // The downloads the popup lists: `files` minus anything already shown
    // under Recents, so an opened download doesn't take two rows. Only the
    // popup drops the overlap; the drawer and badge read `files` whole.
    readonly property var downloadRows: {
        const seen = {}
        root.recents.forEach(f => seen[f.path] = true)
        return root.files.filter(f => !seen[f.path]).slice(0, root.perSection)
    }

    // ── Popup state (written by Dock.qml, read by MacShell's popup window) ─
    property bool   visible:      false
    property real   globalX:      0
    property real   globalY:      0
    property real   dockHeight:   0
    property real   globalCY:     0      // the icon's centre y, for a side dock
    property var    activeScreen: null

    // Open until a click outside it, a file opened, or a drag finished — no
    // timer. It closed itself 2.5s after opening (0.4s after the pointer left
    // it) until 2026-10-29, which Ahaan found closed it out from under him:
    // "a click outside closes it instantly and no timer". The click-outside
    // is MacShell's full-screen catcher.
    function show(globalX, globalY, dockHeight, screen, globalCY) {
        root.globalX = globalX
        root.globalY = globalY
        root.dockHeight = dockHeight
        root.globalCY = globalCY ?? 0
        root.activeScreen = screen
        root.refresh()
        root.markSeen()
        root.visible = true
    }

    function toggle(globalX, globalY, dockHeight, screen, globalCY) {
        if (root.visible) root.hideNow()
        else root.show(globalX, globalY, dockHeight, screen, globalCY)
    }

    function markSeen() {
        if (root.files.length > 0) root.lastSeen = root.files[0].mtime
        else root.lastSeen = Date.now() / 1000
    }

    // A file being dragged out of the popup. Hiding the popup's surface
    // mid-drag destroys the drag's SOURCE and the compositor cancels the drag,
    // so nothing closes it while this is set; it closes when the drag ends.
    property bool dragging: false
    function endDrag() { root.dragging = false; root.hideNow() }

    function hideNow() { if (!root.dragging) root.visible = false }

    // ── Reading the folder ────────────────────────────────────────────────
    // downloads-list.sh does the work: one `find` over one directory, then a
    // `file --mime-type` and an icon lookup for each of the newest few. See its
    // header for the output format and what it skips.
    function refresh() { if (!listProc.running) listProc.running = true }

    property var _poll: Timer {
        interval: 15000
        running:  true
        repeat:   true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    readonly property string _script:
        String(Quickshell.shellDir || "").replace(/^file:\/\//, "") + "/downloads-list.sh"

    // The last output, so an unchanged folder assigns nothing (see `now`).
    property string _last: ""

    property var _listProc: Process {
        id: listProc
        command: ["bash", root._script, UiConfig.iconTheme, String(root.maxFiles), String(root.perSection)]
        stdout: StdioCollector {
            onStreamFinished: {
                root.now = Date.now() / 1000
                if (this.text === root._last) return
                root._last = this.text
                const out = [], rec = []
                let dir = root.dir
                this.text.split("\n").forEach(line => {
                    const f = line.split("\t")
                    if (f[0] === "D") { dir = f[1]; return }
                    if ((f[0] !== "F" && f[0] !== "R") || f.length < 4) return
                    // The name is everything after the third tab, in case a
                    // file name carries one of its own. An R line carries a
                    // full path, since recents live anywhere.
                    const rest = f.slice(3).join("\t")
                    if (f[0] === "R") {
                        const rname = rest.replace(/^.*\//, "")
                        rec.push({
                            name:  rname,
                            path:  rest,
                            mtime: parseFloat(f[1]),
                            image: /\.(png|jpe?g|gif|webp|bmp)$/i.test(rname),
                            icon:  f[2] ? "file://" + f[2] : ""
                        })
                        return
                    }
                    const name = rest
                    out.push({
                        name:  name,
                        path:  dir + "/" + name,
                        mtime: parseFloat(f[1]),
                        image: /\.(png|jpe?g|gif|webp|bmp)$/i.test(name),
                        icon:  f[2] ? "file://" + f[2] : ""
                    })
                })
                root.folder  = dir
                root.files   = out
                root.recents = rec
            }
        }
    }

    // The colour a file's type is shown in by the dock's drawer: one pywal
    // slot per kind, so the sheets are the palette Settings -> Theme sets and
    // change with it, like everything else on this desktop. They were fixed
    // hexes copied from the Papirus MIME icons (red PDF, blue Word...) until
    // 2026-10-29, which read as stickers on a palette-driven dock. Read off
    // the icon's file name, which IS the MIME type (application-pdf.svg).
    function tint(icon) {
        const n = String(icon).replace(/^.*\//, "")
        if (/pdf/.test(n))                                     return WalColors.color1
        if (/wordprocessing|msword|opendocument\.text|rtf/.test(n)) return WalColors.color4
        if (/spreadsheet|excel|csv/.test(n))                   return WalColors.color2
        if (/presentation|powerpoint/.test(n))                 return WalColors.color3
        if (/^video/.test(n))                                  return WalColors.color5
        if (/^audio/.test(n))                                  return WalColors.color5
        if (/^image/.test(n))                                  return WalColors.color6
        if (/html|xml|javascript|json/.test(n))                return WalColors.color6
        if (/zip|tar|gzip|7z|rar|compressed/.test(n))          return WalColors.color3
        return WalColors.color8
    }

    // A file's path as an Image source. encodeURI leaves # and ? alone, and
    // both are legal in a file name and fatal in a URL.
    function fileUrl(path) {
        return "file://" + encodeURI(path).replace(/#/g, "%23").replace(/\?/g, "%3F")
    }

    // ── Opening things ────────────────────────────────────────────────────
    // The path is an ARGUMENT ($1), never spliced into the command string: a
    // download's name is whatever the sender called it. The setsid wrapper is
    // the repo's SIGPIPE rule — see CLAUDE.md.
    property var _openProc: Process {
        id: openProc
        property string target: ""
        command: ["bash", "-c", "setsid xdg-open \"$1\" </dev/null >/dev/null 2>&1 &", "_", openProc.target]
        running: false
    }

    function open(path) {
        openProc.target = path
        openProc.running = false
        openProc.running = true
        root.hideNow()
    }

    function openFolder() { root.open(root.folder) }
}
