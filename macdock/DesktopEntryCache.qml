pragma Singleton

import QtQuick
import Quickshell.Io

QtObject {
    id: root

    property var _byWmClass: ({})
    property var _byName:    ({})

    // ── Public API ────────────────────────────────────────────────
    function iconForClass(wmClass) {
        if (!wmClass || wmClass === "") return ""
        const lc = wmClass.toLowerCase()

        // 1. Exact match
        if (root._byWmClass[lc]) return root._byWmClass[lc]

        // 2. Reverse-domain walk: "org.gnome.Calendar" → try "calendar", "gnome", "org"
        const dots = lc.split(".")
        if (dots.length > 1) {
            for (let i = dots.length - 1; i >= 0; i--) {
                if (dots[i] && root._byWmClass[dots[i]])
                    return root._byWmClass[dots[i]]
            }
        }

        // 3. Partial substring — minimum 4 chars to avoid "r", "go" etc matching everything
        const keys = Object.keys(root._byWmClass)
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i]
            if (k.length < 4) continue
            if (lc.includes(k) || k.includes(lc)) return root._byWmClass[k]
        }

        // 4. Name map fallback
        if (root._byName[lc]) return root._byName[lc]

        return ""
    }

    // ── Internal ──────────────────────────────────────────────────
    property string _buf: ""

    property var _proc: Process {
        id: findProc
        command: ["bash", "-c",
            // First: an index of Papirus app icons (name -> path). Papirus-Dark is
            // listed first and by size so the earliest match is a sensible one.
            "echo '---PAPIRUS_INDEX_START---'; " +
            "for sz in 64x64 48x48 128x128 32x32 24x24; do " +
            "  find /usr/share/icons/Papirus-Dark/$sz/apps /usr/share/icons/Papirus/$sz/apps " +
            "       -name '*.svg' 2>/dev/null; done; " +
            // Then: the desktop files, as before.
            "echo '---DESKTOP_FILES_START---'; " +
            "find /usr/share/applications ~/.local/share/applications " +
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

            const resolved = _resolveIconPath(icon)

            // Index by StartupWMClass (most reliable)
            if (wmClass) byWm[wmClass.toLowerCase()] = resolved

            // Index by the full Icon= value (e.g. "org.gnome.Calendar")
            byWm[icon.toLowerCase()] = resolved

            // Index by last dot-segment of Icon= (e.g. "calendar" from "org.gnome.Calendar")
            const iconDots = icon.split(".")
            if (iconDots.length > 1) {
                const lastSeg = iconDots[iconDots.length - 1].toLowerCase()
                if (lastSeg.length >= 3) byWm[lastSeg] = resolved
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
                            byWm[part] = resolved
                            break
                        }
                    }
                }
            }

            // Index by Exec basename
            if (exec) {
                const base = exec.split(" ")[0].split("/").pop().toLowerCase()
                if (base && base.length >= 3) byWm[base] = resolved
            }

            if (name) byName[name.toLowerCase()] = resolved
        })

        root._byWmClass = byWm
        root._byName    = byName
    }

    // Papirus name -> file path index, built in _parse()
    property var _papirusIndex: ({})

    function _resolveIconPath(icon) {
        if (icon.startsWith("/"))       return "file://" + icon
        if (icon.startsWith("file://")) return icon
        // Force Papirus: map the icon name to a Papirus file so we don't depend
        // on Quickshell's Qt icon theme. Fall back to the theme provider only if
        // Papirus doesn't have this icon.
        if (root._papirusIndex[icon])               return root._papirusIndex[icon]
        if (root._papirusIndex[icon.toLowerCase()]) return root._papirusIndex[icon.toLowerCase()]
        return "image://icon/" + icon
    }

    Component.onCompleted: {
        root._buf = ""
        findProc.running = true
    }
}
