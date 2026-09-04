pragma Singleton

import QtQuick

// Window-class -> icon path, layered on top of DesktopEntryCache.
//
// This used to carry its own copy of the whole .desktop/Papirus scanner (a
// near-duplicate of DesktopEntryCache, running a second full filesystem walk
// and holding a second copy of the resulting maps in memory). Since both the
// dock and the switcher now live in one process, that work is done once by
// DesktopEntryCache and this is just the switcher-specific lookup policy on
// top: class aliases, and the fallback chain for windows whose class does not
// appear in any desktop entry.
QtObject {
    id: root

    readonly property var _aliases: ({
        "org.gnome.diskutility": "gnome-disks",
        // Dolphin's icon over Nautilus's own for the Files app — matches
        // DockModel.qml's "Files" entry.
        "org.gnome.nautilus":    "org.kde.dolphin",
        "org.gnome.calendar":    "org.gnome.Calendar",
        "org.gnome.calculator":  "org.gnome.Calculator",
        "org.gnome.clocks":      "org.gnome.Clocks",
        "org.gnome.texteditor":  "org.gnome.TextEditor",
        "org.gnome.maps":        "org.gnome.Maps",
        "org.gnome.weather":     "org.gnome.Weather"
    })

    // The icon NAME this desktop prefers for a window class, or "" where it has
    // no opinion and the .desktop entry's own Icon= should win.
    //
    // A name and not a resolved path, because the dock stores this in a pin
    // (see Dock.qml's _pinRecord) and a path would freeze that pin to today's
    // icon theme — the exact bug the old absolute Papirus paths in DockModel
    // had. This is also the ONE place the table is read from now: the dock
    // resolved icons straight out of DesktopEntryCache and never consulted it,
    // so an unpinned Nautilus window drew Nautilus's own icon while the pinned
    // entry drew Dolphin's — and right-clicking to re-pin it, which rebuilds
    // the record from the .desktop entry, silently changed the icon.
    function aliasFor(wmClass) {
        if (!wmClass || wmClass === "") return ""
        const lc = wmClass.toLowerCase()
        // Papirus-Dark ships a real "zen-browser" icon — matches DockModel.qml.
        if (lc === "zen") return "zen-browser"
        return root._aliases[lc] ? root._aliases[lc] : ""
    }

    // Re-resolving must be cheap and must re-run once the shared cache is
    // populated — consumers bind to DesktopEntryCache.ready for that.
    function iconForClass(wmClass) {
        if (!wmClass || wmClass === "") return ""
        const alias = root.aliasFor(wmClass)
        if (alias !== "") return DesktopEntryCache.resolveIconPath(alias)
        return DesktopEntryCache.iconForClass(wmClass.toLowerCase())
    }

    function resolveForWindow(w) {
        const cls = w.class ?? ""

        // 1. Desktop entry cache
        let icon = iconForClass(cls)
        if (icon !== "") return icon

        // 2. Browser webapp stripping
        const browserPrefixes = ["brave-", "chrome-", "chromium-", "msedge-", "firefox-"]
        const genericSegments = new Set(["app", "www", "web", "mail", "m", "go", "get"])
        for (const p of browserPrefixes) {
            if (cls.startsWith(p)) {
                let s = cls.slice(p.length)
                s = s.replace(/__.*$/, "").replace(/[-_]+default$/i, "").toLowerCase()
                for (const part of s.split(".")) {
                    if (part && part.length >= 3 && !genericSegments.has(part))
                        return DesktopEntryCache.resolveIconPath(part)
                }
            }
        }

        // 3. Reverse-domain last segment
        const segs = cls.split(".")
        if (segs.length > 1) return DesktopEntryCache.resolveIconPath(segs[segs.length - 1].toLowerCase())

        return cls ? DesktopEntryCache.resolveIconPath(cls) : ""
    }
}
