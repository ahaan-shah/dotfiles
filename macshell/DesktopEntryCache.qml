pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The single .desktop / icon-theme scanner for this shell. Both the dock
// (DockIcon, Dock) and the switcher (via IconResolver) read from here; before
// the merge each process ran its own near-identical copy of this walk.
QtObject {
    id: root

    property var _byWmClass: ({})
    property var _byName:    ({})
    // The same two indexes again, holding the whole entry rather than just the
    // resolved icon path. Built in the same pass — see entryForClass().
    property var _entryByWmClass: ({})
    property var _entryByName:    ({})
    // Flips once _parse() has actually run — the async find/cat Process can
    // still be in flight when a window (e.g. one already open at macdock's
    // own startup) first asks for its icon, same race documented for
    // finder's AppIndex/EmojiIndex/ClipboardHistory singletons. Consumers
    // should listen for this and re-resolve rather than caching a premature
    // empty-cache fallback guess.
    property bool ready: false
    // Bumped every time the index is rebuilt. `ready` cannot serve here: it
    // goes true once and stays true, so a rescan after an icon-theme change
    // emitted no signal and the dock kept drawing the icons it had resolved at
    // startup.
    property int revision: 0

    // ── Public API ────────────────────────────────────────────────
    function iconForClass(wmClass) {
        const v = root._lookup(root._byWmClass, root._byName, wmClass)
        return v ? v : ""
    }

    // The .desktop entry behind a window class — { icon, exec, name }, each
    // raw as it appears in the file, or null. Pinning a running app by
    // right-clicking it needs more than an icon: a pin has to carry the
    // command that relaunches the app after it has been quit, and Exec= is the
    // only reliable source for that. The raw Icon= name matters too — storing
    // the resolved path instead would freeze that pin to today's icon theme,
    // which is the exact bug the old absolute Papirus paths in DockModel had.
    function entryForClass(wmClass) {
        const v = root._lookup(root._entryByWmClass, root._entryByName, wmClass)
        return v ? v : null
    }

    // The lookup policy, shared by both index pairs so they can never disagree
    // about which .desktop file a class belongs to.
    function _lookup(byWm, byName, wmClass) {
        if (!wmClass || wmClass === "") return null
        const lc = wmClass.toLowerCase()

        // 1. Exact match
        if (byWm[lc]) return byWm[lc]

        // 2. Reverse-domain walk: "org.gnome.Calendar" → try "calendar", "gnome", "org"
        const dots = lc.split(".")
        if (dots.length > 1) {
            for (let i = dots.length - 1; i >= 0; i--) {
                if (dots[i] && byWm[dots[i]])
                    return byWm[dots[i]]
            }
        }

        // 3. Partial substring — minimum 4 chars to avoid "r", "go" etc matching everything
        const keys = Object.keys(byWm)
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i]
            if (k.length < 4) continue
            if (lc.includes(k) || k.includes(lc)) return byWm[k]
        }

        // 4. Name map fallback
        if (byName[lc]) return byName[lc]

        return null
    }

    // Exec= carries .desktop field codes (%u, %F, %i …) that are meant to be
    // substituted by the launcher and are nonsense to a shell — "%U" reaches
    // chromium as a literal argument and it opens a tab for a file called %U.
    //
    // Dropping the code can leave the flag that introduced it dangling, which
    // is worse than the code was: spotify.desktop is "spotify --uri=%U", and
    // stripping alone yields "spotify --uri=" — an empty URI handed to an app
    // that was asked to open one. Anything ending in "=" after the strip was
    // only ever there to carry a field code, so it goes too. A real argument
    // ("--app=https://…") does not end in "=" and survives.
    function _cleanExec(exec) {
        if (!exec) return ""
        return String(exec).replace(/%[a-zA-Z]/g, "")
                           .split(/\s+/)
                           .filter(t => t !== "" && t.charAt(t.length - 1) !== "=")
                           .join(" ")
                           .trim()
    }

    // ── Internal ──────────────────────────────────────────────────
    property string _buf: ""


    // The `scripts` dir BESIDE this shell config, never a fixed path — same
    // rule as Settings.qml and the taskbar's sideScriptDir, so a repo instance
    // runs the repo's copy.
    readonly property string _scriptDir: {
        var dir = String(Quickshell.shellDir || "").replace(/^file:\/\//, "")
        var cut = dir.lastIndexOf("/")
        return cut > 0 ? dir.substring(0, cut) + "/scripts"
                       : (Quickshell.env("HOME") || "") + "/.config/scripts"
    }
    function _q(v) { return "'" + String(v).replace(/'/g, "'\\''") + "'" }

    property var _proc: Process {
        id: findProc
        command: ["bash", "-c",
            // First: an index of Papirus app icons (name -> path). Papirus-Dark is
            // listed first and by size so the earliest match is a sensible one.
            "echo '---PAPIRUS_INDEX_START---'; " +
            // The application-icon index, in preference order: the theme chosen
            // in the settings menu, what it inherits, Papirus as the backstop,
            // then the flatpak exports. First match wins when the map is built
            // below.
            //
            // scripts/icon-index.sh does the finding. It used to be an inline
            // `find` over a hardcoded <size>/apps list here, which silently
            // produced NOTHING for any theme not laid out exactly like Papirus
            // — see that script's header for the two ways it was wrong.
            root._q(root._scriptDir + "/icon-index.sh") + "; " +
            "echo '---DESKTOP_FILES_START---'; " +
            "find /usr/share/applications ~/.local/share/applications " +
            "     /var/lib/flatpak/exports/share/applications " +
            "     ~/.local/share/flatpak/exports/share/applications " +
            "-name '*.desktop' 2>/dev/null | while read f; do " +
            "echo '---DESKTOP_FILE_START---'; cat \"$f\"; done"]
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._buf += data
        }
    }

    property var _conn: Connections {
        target: findProc
        function onRunningChanged() {
            if (findProc.running) return
            root._parse(root._buf)
        }
    }

    function _parse(raw) {
        // Split the Papirus-index section from the desktop-file section.
        const _parts     = raw.split("---DESKTOP_FILES_START---")
        const papirusRaw = (_parts[0] || "").replace("---PAPIRUS_INDEX_START---", "")
        const desktopRaw = _parts[1] || ""

        // name -> "file://…" Papirus path. First match wins (Papirus-Dark, larger
        // sizes first, per the find order). Both exact-case and lowercase keys.
        const pidx = {}
        papirusRaw.split("\n").forEach(p => {
            p = p.trim(); if (!p) return
            const base = p.split("/").pop().replace(/\.(svg|png)$/i, "")
            if (!(base in pidx))            pidx[base]            = "file://" + p
            const lc = base.toLowerCase()
            if (!(lc in pidx))              pidx[lc]              = "file://" + p
        })
        root._papirusIndex = pidx

        const byWm   = {}
        const byName = {}
        // Same keys, same policy, different payload — see entryForClass().
        const byWmEntry   = {}
        const byNameEntry = {}
        const genericSegments = new Set(["app", "www", "web", "mail", "m", "go", "get"])
        const browserPrefixes = ["brave-", "chrome-", "chromium-", "msedge-", "firefox-"]

        const files = desktopRaw.split("---DESKTOP_FILE_START---")
        files.forEach(block => {
            if (!block.trim()) return

            let icon    = ""
            let wmClass = ""
            let name    = ""
            let exec    = ""

            block.split("\n").forEach(line => {
                const l = line.trim()
                if (l.startsWith("Icon=")           && !icon)    icon    = l.slice(5).trim()
                if (l.startsWith("StartupWMClass=") && !wmClass) wmClass = l.slice(15).trim()
                if (l.startsWith("Name=")           && !name)    name    = l.slice(5).trim()
                if (l.startsWith("Exec=")           && !exec)    exec    = l.slice(5).trim()
            })

            if (!icon) return

            const resolved = root.resolveIconPath(icon)
            const entry    = { icon: icon, exec: root._cleanExec(exec), name: name }
            // Every key written to byWm gets the same key in byWmEntry.
            const put      = k => { byWm[k] = resolved; byWmEntry[k] = entry }

            // Index by StartupWMClass (most reliable)
            if (wmClass) put(wmClass.toLowerCase())

            // Index by the full Icon= value (e.g. "org.gnome.Calendar")
            put(icon.toLowerCase())

            // Index by last dot-segment of Icon= (e.g. "calendar" from "org.gnome.Calendar")
            const iconDots = icon.split(".")
            if (iconDots.length > 1) {
                const lastSeg = iconDots[iconDots.length - 1].toLowerCase()
                if (lastSeg.length >= 3) put(lastSeg)
            }

            // For browser webapps: index by the brand segment of Icon=
            // e.g. "chrome-www.primevideo.com__region_eu_storefront-Default" → "primevideo"
            for (const p of browserPrefixes) {
                if (icon.toLowerCase().startsWith(p)) {
                    let s = icon.slice(p.length)
                    s = s.replace(/__.*$/, "").replace(/[-_]+default$/i, "").toLowerCase()
                    const parts = s.split(".")
                    for (const part of parts) {
                        if (part && part.length >= 3 && !genericSegments.has(part)) {
                            put(part)
                            break
                        }
                    }
                }
            }

            // Index by Exec basename. Browser binaries are excluded: they are
            // the Exec line of every chromium/firefox webapp .desktop, so
            // indexing them would map "chromium" to whichever webapp happened
            // to be parsed last (this exclusion came from the switcher's own
            // copy of this parser, which had it and the dock's did not).
            if (exec) {
                const base = exec.split(" ")[0].split("/").pop().toLowerCase()
                const browserBins = new Set(["chromium", "chromium-browser", "chrome",
                    "google-chrome", "google-chrome-stable", "brave", "brave-browser",
                    "firefox", "librewolf", "msedge"])
                if (base && base.length >= 3 && !browserBins.has(base))
                    put(base)
            }

            if (name) {
                byName[name.toLowerCase()]      = resolved
                byNameEntry[name.toLowerCase()] = entry
            }
        })

        root._byWmClass    = byWm
        root._byName       = byName
        root._entryByWmClass = byWmEntry
        root._entryByName    = byNameEntry
        root.ready = true
        root.revision = root.revision + 1
    }

    // Papirus name -> file path index, built in _parse()
    property var _papirusIndex: ({})

    function resolveIconPath(icon) {
        if (icon.startsWith("/"))       return "file://" + icon
        if (icon.startsWith("file://")) return icon
        // Force Papirus: map the icon name to a Papirus file so we don't depend
        // on Quickshell's Qt icon theme. Fall back to the theme provider only if
        // Papirus doesn't have this icon.
        if (root._papirusIndex[icon])               return root._papirusIndex[icon]
        if (root._papirusIndex[icon.toLowerCase()]) return root._papirusIndex[icon.toLowerCase()]
        return "image://icon/" + icon
    }

    // Rebuild the whole index when the icon theme changes.
    //
    // Without this the theme picked in the settings menu did nothing to any
    // shell: the scan runs once at startup and the map it produces is what
    // every icon lookup reads for the life of the process, so a new theme only
    // appeared after a restart. GTK apps updated immediately (they follow
    // gsettings) which is exactly why it looked like the setting was being
    // ignored by the shells specifically.
    //
    // Cheap enough to do on the signal: the scan is a `find` over a handful of
    // theme directories, and the theme changes when a person picks one.
    property var _themeConn: Connections {
        target: UiConfig
        function onIconThemeChanged() {
            // running = true is a no-op while already running, so a change that
            // lands mid-scan would otherwise be dropped silently.
            if (findProc.running) return
            root._buf = ""
            findProc.running = true
        }
    }

    Component.onCompleted: {
        root._buf = ""
        findProc.running = true
    }
}
