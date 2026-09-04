pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Parses .desktop files once at startup and exposes a fuzzy-searchable app list.
// Launching goes through `gio launch <path>` rather than hand-parsing Exec=,
// since gio already handles %U/%f field-code substitution, Terminal=true
// wrapping, and StartupNotify the way a real app launcher would.
QtObject {
    id: root

    property var apps: []   // [{name, comment, icon, iconPath, path, flatpakId}]

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

    property var _proc: Process {
        id: findProc
        command: ["bash", "-c",
            // Same Papirus-Dark-first index as the dock's DesktopEntryCache,
            // so app icons match macdock instead of falling through to
            // whatever Qt's default icon theme provider resolves.
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
            Sys.quote(root._scriptDir + "/icon-index.sh") + "; " +
            "echo '---DESKTOP_FILES_START---'; " +
            "find /usr/share/applications ~/.local/share/applications " +
            "     /var/lib/flatpak/exports/share/applications " +
            "     ~/.local/share/flatpak/exports/share/applications " +
            "-name '*.desktop' 2>/dev/null | while read f; do " +
            "echo '---DESKTOP_FILE_START---'; echo \"PATH=$f\"; cat \"$f\"; done"]
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
            root._buf = ""
        }
    }

    // Papirus name -> file path index, built in _parse()
    property var _papirusIndex: ({})

    function _resolveIconPath(icon) {
        if (icon.startsWith("/"))       return "file://" + icon
        if (icon.startsWith("file://")) return icon
        // Force Papirus (Papirus-Dark first), same as macdock's
        // DesktopEntryCache, so icons match across the launcher/dock/switcher.
        if (root._papirusIndex[icon])               return root._papirusIndex[icon]
        if (root._papirusIndex[icon.toLowerCase()]) return root._papirusIndex[icon.toLowerCase()]
        return "image://icon/" + icon
    }

    function _parse(raw) {
        const _parts     = raw.split("---DESKTOP_FILES_START---")
        const papirusRaw = (_parts[0] || "").replace("---PAPIRUS_INDEX_START---", "")
        const desktopRaw = _parts[1] || ""

        const pidx = {}
        papirusRaw.split("\n").forEach(p => {
            p = p.trim(); if (!p) return
            const base = p.split("/").pop().replace(/\.(svg|png)$/i, "")
            if (!(base in pidx))            pidx[base]            = "file://" + p
            const lc = base.toLowerCase()
            if (!(lc in pidx))              pidx[lc]              = "file://" + p
        })
        root._papirusIndex = pidx

        const files = desktopRaw.split("---DESKTOP_FILE_START---")
        const list = []
        files.forEach(block => {
            if (!block.trim()) return

            let path = "", name = "", comment = "", icon = "", noDisplay = false, inDesktopEntry = false, flatpakId = "", exec = "", terminal = false

            block.split("\n").forEach(line => {
                const l = line.trim()
                if (l.startsWith("PATH=")) { path = l.slice(5); return }
                if (l === "[Desktop Entry]") { inDesktopEntry = true; return }
                if (l.startsWith("[") && l !== "[Desktop Entry]") { inDesktopEntry = false; return }
                if (!inDesktopEntry) return
                if (l.startsWith("Name=") && !name)          name = l.slice(5).trim()
                if (l.startsWith("Comment=") && !comment)    comment = l.slice(8).trim()
                if (l.startsWith("Icon=") && !icon)          icon = l.slice(5).trim()
                if (l.startsWith("Exec=") && !exec)          exec = l.slice(5).trim()
                if (l.startsWith("Terminal=true"))           terminal = true
                if (l.startsWith("NoDisplay=true"))          noDisplay = true
                // Flatpak-exported .desktop files carry this; launching via
                // `flatpak run <id>` directly (bypassing the Exec= line's
                // --branch/--arch/--command/--file-forwarding flags added by
                // the export) is what's confirmed stable — going through
                // `gio launch` on the .desktop file's Exec= line was crashing
                // JASP as soon as it did any real work, `flatpak run
                // org.jaspstats.JASP` plain was not.
                if (l.startsWith("X-Flatpak=") && !flatpakId) flatpakId = l.slice(10).trim()
            })

            if (!name || noDisplay || !path) return
            // Avahi's discovery tool and hwloc's lstopo viewer are system
            // utilities the user never wants surfaced in finder at all.
            if (/avahi/i.test(name) || /avahi/i.test(path)) return
            if (/lstopo/i.test(name) || /lstopo/i.test(path)) return

            let iconPath = icon ? root._resolveIconPath(icon) : ""
            // Prefer the Dolphin icon over Nautilus's own for the Files app —
            // matches macdock/DockModel.qml's "Files" entry.
            if (icon === "org.gnome.Nautilus") iconPath = root._resolveIconPath("org.kde.dolphin")
            // Papirus-Dark ships a real "zen-browser" icon now (as of the theme
            // update that added it) — matches macdock/DockModel.qml.
            if (icon === "zen-browser") iconPath = root._resolveIconPath("zen-browser")
            // wiremix.desktop ships no Icon= line at all (blank icon in the
            // list), so map it explicitly to Papirus-Dark's "musique" (music
            // note) icon, per explicit user request.
            if (!icon && name === "Wiremix") iconPath = root._resolveIconPath("musique")

            list.push({ name, comment, icon, iconPath, path, flatpakId, exec, terminal })
        })

        // De-dupe by name, keep first occurrence (local overrides system since
        // ~/.local/share/applications is listed second in `find` args above,
        // but find's actual traversal order can vary — sort so local wins by
        // re-ordering: entries whose path includes the home dir go first).
        list.sort((a, b) => {
            const aLocal = a.path.includes("/.local/share/") ? 0 : 1
            const bLocal = b.path.includes("/.local/share/") ? 0 : 1
            return aLocal - bLocal
        })
        const byName = {}
        const deduped = []
        list.forEach(a => {
            const key = a.name.toLowerCase()
            if (byName[key]) return
            byName[key] = true
            deduped.push(a)
        })
        deduped.sort((a, b) => a.name.localeCompare(b.name))
        root.apps = deduped
    }

    // ── Fuzzy-ish search: case-insensitive substring on name, then comment ──
    function search(query, limit) {
        if (!query) return []
        const q = query.toLowerCase()
        const nameHits = []
        const commentHits = []
        for (const a of root.apps) {
            const n = a.name.toLowerCase()
            if (n.includes(q)) {
                nameHits.push(a)
                continue
            }
            if (a.comment && a.comment.toLowerCase().includes(q)) {
                commentHits.push(a)
            }
        }
        // Prefix matches on name rank above pure substring matches
        nameHits.sort((a, b) => {
            const an = a.name.toLowerCase(), bn = b.name.toLowerCase()
            const ap = an.startsWith(q) ? 0 : 1
            const bp = bn.startsWith(q) ? 0 : 1
            if (ap !== bp) return ap - bp
            return an.localeCompare(bn)
        })
        return nameHits.concat(commentHits).slice(0, limit || 8)
    }

    function launch(app) {
        // Every branch below launches via
        //   bash -c "setsid <cmd> </dev/null >/dev/null 2>&1 &"
        // Both halves are load-bearing:
        //   setsid ... &   — own session/process group, and keeps launchProc
        //                    from staying `running` for the app's whole life
        //                    (Process.running = true is a no-op while already
        //                    running, so a foreground launch silently swallows
        //                    every later launch() call).
        //   </dev/null >/dev/null 2>&1 — the app must NOT inherit Quickshell's
        //                    stdout/stderr pipe. Quickshell closes the read end
        //                    when the launcher (`gio`) exits, and the app's next
        //                    write then dies on SIGPIPE.
        // The second one is why Spotify (chatty at startup) wouldn't launch
        // while quiet apps did. See CLAUDE.md 2026-08-22 for the full history.

        // Terminal=true entries (btop, wiremix, ...) are TUI apps with no GUI
        // window of their own — `gio launch` on them falls through to GLib's
        // own Terminal=true handling, which tries `xterm` (not installed here)
        // and silently does nothing. Route these through kitty explicitly
        // instead, matching the exact "kitty --title <cmd> -e zsh -i -c <cmd>"
        // convention hyprland.lua's own F12 btop bind already uses, so the
        // title-matched kitty-tools-float window rule still floats them.
        if (app.terminal && !app.flatpakId) {
            const cmd = app.exec.split(/\s+/)[0]
            launchProc.command = ["bash", "-c",
                "setsid kitty --title \"$1\" -e zsh -i -c \"$1\" </dev/null >/dev/null 2>&1 &",
                "_", cmd]
            launchProc.running = true
            return
        }
        // Flatpak-exported entries launch via `flatpak run <id>` directly
        // rather than gio launch on the export's Exec= line — its
        // --branch/--arch/--command/--file-forwarding flags were crashing JASP
        // as soon as it did any real work, plain `flatpak run` was not.
        if (app.flatpakId) {
            launchProc.command = ["bash", "-c",
                "setsid flatpak run \"$1\" </dev/null >/dev/null 2>&1 &",
                "_", app.flatpakId]
            launchProc.running = true
            return
        }
        launchProc.command = ["bash", "-c",
            "setsid gio launch \"$1\" </dev/null >/dev/null 2>&1 &",
            "_", app.path]
        launchProc.running = true
    }

    property var launchProc: Process { id: launchProc; running: false }

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
