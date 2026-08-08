pragma Singleton

import QtQuick
import Quickshell.Io

// Parses .desktop files once at startup and exposes a fuzzy-searchable app list.
// Launching goes through `gio launch <path>` rather than hand-parsing Exec=,
// since gio already handles %U/%f field-code substitution, Terminal=true
// wrapping, and StartupNotify the way a real app launcher would.
QtObject {
    id: root

    property var apps: []   // [{name, comment, icon, iconPath, path, flatpakId}]

    property string _buf: ""

    property var _proc: Process {
        id: findProc
        command: ["bash", "-c",
            // Same Papirus-Dark-first index as the dock's DesktopEntryCache,
            // so app icons match macdock instead of falling through to
            // whatever Qt's default icon theme provider resolves.
            "echo '---PAPIRUS_INDEX_START---'; " +
            "for sz in 64x64 48x48 128x128 32x32 24x24; do " +
            "  find /usr/share/icons/Papirus-Dark/$sz/apps /usr/share/icons/Papirus/$sz/apps " +
            "       -name '*.svg' 2>/dev/null; done; " +
            // Flatpak apps' own icons (hicolor theme, not Papirus) live under
            // its export dirs — indexed the same way so _resolveIconPath can
            // find them before falling through to the image://icon/ provider.
            "for sz in 64x64 48x48 128x128 32x32 24x24 scalable; do " +
            "  find /var/lib/flatpak/exports/share/icons/hicolor/$sz/apps " +
            "       ~/.local/share/flatpak/exports/share/icons/hicolor/$sz/apps " +
            "       -name '*.svg' -o -name '*.png' 2>/dev/null; done; " +
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

            let path = "", name = "", comment = "", icon = "", noDisplay = false, inDesktopEntry = false, flatpakId = ""

            block.split("\n").forEach(line => {
                const l = line.trim()
                if (l.startsWith("PATH=")) { path = l.slice(5); return }
                if (l === "[Desktop Entry]") { inDesktopEntry = true; return }
                if (l.startsWith("[") && l !== "[Desktop Entry]") { inDesktopEntry = false; return }
                if (!inDesktopEntry) return
                if (l.startsWith("Name=") && !name)          name = l.slice(5).trim()
                if (l.startsWith("Comment=") && !comment)    comment = l.slice(8).trim()
                if (l.startsWith("Icon=") && !icon)          icon = l.slice(5).trim()
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
            // Zen has no Papirus icon at all (falls through to the generic
            // image://icon/ provider) — use the same custom svg as
            // macdock/DockModel.qml instead.
            if (icon === "zen-browser") iconPath = root._resolveIconPath("/home/ahaan/.local/share/icons/webapps/zen-browser.svg")

            list.push({ name, comment, icon, iconPath, path, flatpakId })
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
        // `gio launch` forks and returns immediately (fire-and-forget), but
        // `flatpak run` blocks in the foreground for the launched app's
        // entire lifetime — since launchProc is reused for every launch and
        // Process.running = true is a no-op while already running (same
        // class of stale-Process bug documented for FileSearch.qml), that
        // left launchProc permanently "running" for as long as the flatpak
        // app stayed open, silently swallowing every subsequent launch()
        // call for any other app. `setsid … &` under a wrapping shell
        // detaches flatpak run the same way gio launch already detaches,
        // so launchProc goes back to not-running almost immediately.
        launchProc.command = app.flatpakId
            ? ["bash", "-c", "setsid flatpak run '" + app.flatpakId + "' </dev/null >/dev/null 2>&1 &"]
            : ["gio", "launch", app.path]
        launchProc.running = true
    }

    property var launchProc: Process { id: launchProc; running: false }

    Component.onCompleted: {
        root._buf = ""
        findProc.running = true
    }
}
