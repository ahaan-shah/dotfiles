pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The settings menu's data: the page tree, the listings, and what activating a
// row actually does. SettingsPanel.qml is the view; nothing here draws.
//
// Structure mirrors settingsmenu.txt:
//
//   Install  -> Package / AUR / Web app
//   Remove   -> Package / Web app
//   Update
//   Setup    -> Monitors / Keybindings / Window titlebar (a switch) / Defaults
//   Fonts    -> every installed family
//   Icons    -> every installed icon theme
//   Theme    -> every installed GTK theme
//   About
//
// ── Where the work actually happens ───────────────────────────────────────
// Almost nothing is implemented here. Listing fonts, applying a theme,
// installing a package — all of it is a script in scripts/, for two reasons.
// It keeps this file a menu rather than a second copy of the system's logic,
// and it means every one of those operations can be run and debugged from a
// terminal without a running Quickshell. This file only decides what to offer
// and what to hand the scripts.
QtObject {
    id: root

    // The `scripts` dir BESIDE this shell config, never a fixed path — the same
    // rule (and the same reasoning) as the taskbar's sideScriptDir. From
    // ~/.config/finder that resolves to ~/.config/scripts; from
    // ~/projects/hyprahaan/finder it resolves to the repo's own scripts/. So a
    // second instance launched out of the repo exercises the repo's scripts,
    // which is exactly what step 2 of CLAUDE.md's workflow needs, with no
    // deploy and no path special-casing.
    readonly property string scriptDir: {
        var dir = String(Quickshell.shellDir || "").replace(/^file:\/\//, "")
        var cut = dir.lastIndexOf("/")
        return cut > 0 ? dir.substring(0, cut) + "/scripts"
                       : (Quickshell.env("HOME") || "") + "/.config/scripts"
    }

    // ── the tree ──────────────────────────────────────────────────────────
    // Keyed by path. "" is the root; a submenu's key is its parent's key plus
    // "/" plus the row id, which is how the panel builds the key as it descends
    // — so a row's id and its page's key are never able to drift apart.
    //
    // kind:  "menu"    descend into pages[key + "/" + id]
    //        "action"  run something and close
    //        "choice"  a value for the page's `pref`, applied via ui-prefs.sh
    //        "toggle"  a switch, read and written in place
    //
    // `sub` appears ONLY on rows that nest. Ahaan's rule: a subtitle earns its
    // place by telling you what is behind a door, and on a row that just does
    // the thing its label already says, it is noise. Search results are the one
    // exception and they do not use `sub` either — they carry the path in the
    // trailing slot instead.
    readonly property var pages: ({
        "": {
            title: "Settings", icon: "󰒓",
            rows: [
                { id: "install", icon: "󰏔", title: "Install", kind: "menu",   sub: "packages, AUR, web apps" },
                { id: "remove",  icon: "󰩺", title: "Remove",  kind: "menu",   sub: "packages, web apps" },
                { id: "update",  icon: "󰚰", title: "Update",  kind: "action" },
                { id: "setup",   icon: "󰒓", title: "Setup",   kind: "menu",   sub: "monitors, keys, titlebar, defaults" },
                { id: "fonts",   icon: "󰛖", title: "Fonts",   kind: "menu",   sub: "the font every shell draws with" },
                { id: "icons",   icon: "󰋩", title: "Icons",   kind: "menu",   sub: "icon theme" },
                { id: "theme",   icon: "󰏘", title: "Theme",   kind: "menu",   sub: "GTK theme" },
                { id: "about",   icon: "󰋼", title: "About",   kind: "action" }
            ]
        },

        "install": {
            title: "Install", icon: "󰏔",
            rows: [
                { id: "pkg",    icon: "󰏖", title: "Package", kind: "action" },
                { id: "aur",    icon: "󰣇", title: "AUR",     kind: "action" },
                { id: "webapp", icon: "󰖟", title: "Web App", kind: "action" }
            ]
        },

        "remove": {
            title: "Remove", icon: "󰩺",
            rows: [
                { id: "pkg",    icon: "󰏖", title: "Package", kind: "action" },
                { id: "webapp", icon: "󰖟", title: "Web App", kind: "action" }
            ]
        },

        "setup": {
            title: "Setup", icon: "󰒓",
            rows: [
                { id: "monitors",    icon: "󰍹", title: "Monitors",        kind: "action" },
                { id: "keybindings", icon: "󰌌", title: "Keybindings",     kind: "menu", sub: "every bind, searchable" },
                // A switch, not a submenu: there are only two states and the
                // page that used to hold them was three rows to express one
                // boolean. Flipping it also makes it the state used at the next
                // login — see _action("setup/titlebar").
                { id: "titlebar",    icon: "󰖯", title: "Window titlebar", kind: "toggle" },
                { id: "defaults",    icon: "󰀻", title: "Defaults",        kind: "menu", sub: "browser, terminal, editor" }
            ]
        },

        "setup/defaults": {
            title: "Defaults", icon: "󰀻",
            rows: [
                { id: "browser",  icon: "󰖟", title: "Browser",  kind: "menu", sub: "opens links and finder's web search" },
                { id: "terminal", icon: "󰆍", title: "Terminal", kind: "menu", sub: "SUPER+Q, and the settings menu's own tools" },
                { id: "editor",   icon: "󰏫", title: "Editor",   kind: "menu", sub: "$EDITOR" }
            ]
        },

        // ── the listings ──────────────────────────────────────────────────
        // `renderInOwnFont` is the Fonts page's whole point: a list of family
        // names set in the default font tells you nothing about how any of them
        // look. Each row is drawn in the family it names, so the list IS the
        // preview.
        "fonts":  { title: "Fonts",  icon: "󰛖", list: "fonts",  pref: "UI_FONT", renderInOwnFont: true, width: 560 },
        "icons":  { title: "Icons",  icon: "󰋩", list: "icons",  pref: "ICON_THEME" },
        "theme":  { title: "Theme",  icon: "󰏘", list: "themes", pref: "GTK_THEME", width: 560 },

        "setup/defaults/browser":  { title: "Browser",  icon: "󰖟", list: "browsers",  pref: "DEFAULT_BROWSER", showDetail: true },
        "setup/defaults/terminal": { title: "Terminal", icon: "󰆍", list: "terminals", pref: "DEFAULT_TERMINAL" },
        "setup/defaults/editor":   { title: "Editor",   icon: "󰏫", list: "editors",   pref: "DEFAULT_EDITOR" },

        // Wider than everything else: a bind is a combo AND what it does, and
        // at 430 the description had nowhere to go. list-keybinds.sh already
        // supplies it — the page just had no room to show it.
        "setup/keybindings": { title: "Keybindings", icon: "󰌌", list: "keybinds", width: 660 }
    })

    // Raised when a row needs root. Finder closes the menu and puts the
    // password box up in its place — see PasswordPrompt.qml. Terminal work
    // (update/install/remove) does NOT go through here: those open a terminal
    // anyway because the output is the point, so their password belongs in it.
    signal authRequired(string reason, string command)


    // ── grouping variants under one row ───────────────────────────────────
    // Ahaan: obsidian ships ~40 themes that are all one family; they belong
    // behind a single "Obsidian" row, not spread over forty.
    //
    // A variant is recognised by its NAME: an entry belongs to another entry
    // that is a prefix of it ending at a separator. The SHORTEST such prefix
    // wins, and that choice is the whole behaviour — "Obsidian-Amber" is
    // itself installed AND is a prefix of "Obsidian-Amber-Light", so taking the
    // longest would produce fourteen Obsidian-<colour> groups instead of the
    // one that was asked for.
    //
    // When nothing installed is a prefix — the catppuccin GTK themes are named
    // "catppuccin-mocha-<colour>-standard+default" with no bare base — the
    // fallback is the longest prefix that at least two entries share, which
    // gives "catppuccin-mocha".
    //
    // A group of one is not a group: it stays a plain row.
    readonly property var _seps: ["-", "_", "+", " "]

    function _prefixesOf(n) {
        const out = []
        for (let i = 1; i < n.length; i++)
            if (root._seps.indexOf(n.charAt(i)) >= 0) out.push(n.substring(0, i))
        return out
    }

    function _regroup(key) {
        const rows = root.lists[key] || []
        const page = root.pages[key] || ({})
        if (rows.length < 2) return { top: rows, byGroup: ({}) }

        const isName = ({})
        for (let i = 0; i < rows.length; i++) isName[rows[i].value] = true

        const shared = ({})
        // An entry that is itself the base of other entries — "BlexMono Nerd
        // Font" is a prefix of "…Font Mono" and "…Font Propo". Recording that
        // is what stops it being swept into a shared-prefix group of its own.
        const isHead = ({})
        for (let i = 0; i < rows.length; i++) {
            const ps = root._prefixesOf(rows[i].value)
            for (let j = 0; j < ps.length; j++) {
                shared[ps[j]] = (shared[ps[j]] || 0) + 1
                if (isName[ps[j]]) isHead[ps[j]] = true
            }
        }

        const groupOf = ({})
        for (let i = 0; i < rows.length; i++) {
            const n = rows[i].value
            const ps = root._prefixesOf(n)
            let g = ""
            for (let j = 0; j < ps.length; j++)                       // 1. shortest installed
                if (isName[ps[j]]) { g = ps[j]; break }
            // 2. I am the base of others, so I head my own group. Without this
            //    a base with no installed prefix of its own fell through to the
            //    shared-prefix fallback below and landed in a DIFFERENT group
            //    from its children: "BlexMono Nerd Font" grouped under
            //    "BlexMono Nerd" while "BlexMono Nerd Font Mono" grouped under
            //    "BlexMono Nerd Font", so the family appeared twice — once as a
            //    plain row and once as a group of the remaining two.
            if (g === "" && isHead[n]) g = n
            if (g === "")
                for (let j = 0; j < ps.length; j++)                   // 3. longest shared
                    if ((shared[ps[j]] || 0) >= 2 && ps[j].length > g.length) g = ps[j]
            groupOf[n] = (g === "") ? n : g
        }

        const members = ({})
        const order = []
        for (let i = 0; i < rows.length; i++) {
            const g = groupOf[rows[i].value]
            if (members[g] === undefined) { members[g] = []; order.push(g) }
            members[g].push(rows[i])
        }

        const top = []
        const byGroup = ({})
        for (let i = 0; i < order.length; i++) {
            const g = order[i]
            const ms = members[g]
            if (ms.length === 1) { top.push(ms[0]); continue }
            byGroup[g] = ms
            // A group carries the current mark when one of its members does, so
            // the theme in effect is findable without opening every group.
            let anyActive = false
            for (let j = 0; j < ms.length; j++) if (ms[j].active) anyActive = true
            top.push({
                id: g, icon: page.icon || "󰒓", title: g, kind: "menu",
                sub: ms.length + " variants" + (anyActive ? " · in use" : ""),
                // A font group's name is itself a family, so it previews too.
                font: (page.renderInOwnFont && isName[g]) ? g : ""
            })
        }
        return { top: top, byGroup: byGroup }
    }

    // key -> { top, byGroup }, rebuilt whenever the flat listing changes.
    property var grouped: ({})

    function _setGrouped(key, g) {
        const next = ({})
        for (const k in root.grouped) next[k] = root.grouped[k]
        next[key] = g
        root.grouped = next
    }

    // "icons/Obsidian" -> "icons", when the parent is a listing page. Group
    // pages are not in `pages` — they exist only as long as the listing does.
    function listPageKeyOf(key) {
        if (root.pages[key] && root.pages[key].list) return key
        const cut = key.lastIndexOf("/")
        if (cut < 0) return ""
        const parent = key.substring(0, cut)
        return (root.pages[parent] && root.pages[parent].list) ? parent : ""
    }

    function pageTitle(key) {
        if (root.pages[key]) return root.pages[key].title
        // A group page is titled after the group itself.
        const lk = root.listPageKeyOf(key)
        return (lk !== "" && lk !== key) ? key.substring(lk.length + 1) : "Settings"
    }
    function pageIcon(key) {
        if (root.pages[key]) return root.pages[key].icon || "󰒓"
        const lk = root.listPageKeyOf(key)
        return (lk !== "") ? (root.pages[lk].icon || "󰒓") : "󰒓"
    }
    function pageWidth(key) {
        const p = root.pages[key] || root.pages[root.listPageKeyOf(key)]
        return (p && p.width) ? p.width : Theme.cardWidth
    }

    // "Setup › Defaults › Browser". Each segment resolved through the tree
    // rather than title-cased from the path, so a page's crumb is the same
    // string as its own title.
    function crumb(key) {
        const parts = ["Settings"]
        let k = ""
        if (key !== "") {
            const segs = key.split("/")
            for (let i = 0; i < segs.length; i++) {
                k = (k === "") ? segs[i] : k + "/" + segs[i]
                parts.push(root.pageTitle(k))
            }
        }
        return parts
    }

    function rowsFor(key) {
        const p = root.pages[key]
        if (p && p.list) return (root.grouped[key] || ({})).top || []
        if (p) return p.rows.map(r => root._decorate(key, r))
        // A group page inside a listing.
        const lk = root.listPageKeyOf(key)
        if (lk === "" || lk === key) return []
        const g = root.grouped[lk] || ({})
        return (g.byGroup || ({}))[key.substring(lk.length + 1)] || []
    }

    // Adds the state a row cannot carry as a literal: whether a toggle is on.
    function _decorate(key, r) {
        if (r.kind !== "toggle") return r
        const on = (key === "setup" && r.id === "titlebar") ? root.barsLoaded : false
        return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                 sub: r.sub || "", active: on === true, pending: on === null }
    }

    // ── search across the whole subtree ───────────────────────────────────
    // Ahaan: searching should reach nested options and activate them directly.
    // Scoped to the CURRENT page and everything under it, which at the root is
    // the entire menu and inside Fonts is just fonts — so typing never returns
    // results from a part of the tree you have already navigated away from.
    //
    // Each hit carries the page it belongs to, so activating it runs exactly
    // what it would have run had you walked there by hand.
    function search(scopeKey, query) {
        const q = String(query).toLowerCase().trim()
        if (!q) return []
        // Searching inside a group searches the whole listing it belongs to —
        // the group page itself is not in `pages` and has nothing to scope to.
        const lk = root.listPageKeyOf(scopeKey)
        if (lk !== "" && lk !== scopeKey) scopeKey = lk
        const out = []
        for (const key in root.pages) {
            if (scopeKey !== "" && key !== scopeKey && key.indexOf(scopeKey + "/") !== 0) continue
            // The FLAT listing, not the grouped view: grouping hides variants
            // behind a menu row, and search skips menu rows — so searching for a
            // variant by name would have found nothing at all.
            const rows = (root.pages[key].list) ? (root.lists[key] || []) : root.rowsFor(key)
            for (let i = 0; i < rows.length; i++) {
                const r = rows[i]
                // A submenu row is not a result: its children are, and offering
                // both means "Fonts" and every font it contains in one list.
                if (r.kind === "menu") continue
                const hay = (r.title + " " + (r.sub || "") + " " + (r.detail || "")).toLowerCase()
                const at = hay.indexOf(q)
                if (at < 0) continue
                const path = (key === scopeKey) ? "" : root.crumb(key).slice(1).join(" › ")
                out.push({
                    id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                    value: r.value, detail: r.detail, active: r.active === true,
                    font: r.font, pageKey: key, trail: path,
                    // Title matches beat subtitle/detail matches, and an earlier
                    // match beats a later one — otherwise a 276-row font list
                    // buries an exact hit under everything that merely contains
                    // the letters.
                    _rank: (r.title.toLowerCase().indexOf(q) === 0 ? 0
                          : r.title.toLowerCase().indexOf(q) > 0 ? 1 : 2) * 1000 + at
                })
            }
        }
        out.sort((a, b) => a._rank - b._rank)
        return out.slice(0, 60)
    }

    // ── dynamic listings ──────────────────────────────────────────────────
    // pageKey -> rows. Fetched once per opening of the menu and cached, because
    // search wants every listing loaded whether or not the user ever walks to
    // that page, and fc-list over 276 families is not free enough to redo per
    // keystroke.
    property var lists: ({})
    property string _pending: ""
    property var _queue: []
    property string _buf: ""

    // Kick every listing off at open. They land one at a time (see _queue), so
    // search grows more complete over the first half-second rather than
    // blocking the panel from appearing.
    function prefetchAll() {
        root.lists = ({})
        root._queue = []
        for (const key in root.pages) {
            if (root.pages[key].list) root._queue.push(key)
        }
        root._pump()
    }

    function ensure(key) {
        // A group page has no listing of its own; its parent's is what matters,
        // and by the time a group is visible that has already loaded.
        const p = root.pages[key]
        if (!p || !p.list || root.lists[key] !== undefined) return
        // Jump the queue: a page the user is actually looking at should not
        // wait behind five listings they are not.
        root._queue = [key].concat(root._queue.filter(k => k !== key))
        root._pump()
    }

    function _pump() {
        // Process.running = true is a no-op while the process is already
        // running, so starting a second listing here would silently drop it.
        if (listProc.running || root._queue.length === 0) return
        const key = root._queue.shift()
        if (root.lists[key] !== undefined) { root._pump(); return }
        root._pending = key
        root._buf = ""
        const p = root.pages[key]
        const q = root._q(root.scriptDir)
        listProc.command = ["bash", "-c",
            (p.list === "keybinds" ? q + "/list-keybinds.sh"
                                   : q + "/ui-prefs.sh list " + p.list) + " 2>/dev/null"]
        listProc.running = true
    }

    property var _listProc: Process {
        id: listProc
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._buf += data
        }
    }

    property var _listConn: Connections {
        target: listProc
        function onRunningChanged() {
            if (listProc.running) return
            if (root._pending !== "") {
                const next = {}
                for (const k in root.lists) next[k] = root.lists[k]
                next[root._pending] = root._parseList(root._pending, root._buf)
                root.lists = next          // reassign: mutating in place emits nothing
                root._setGrouped(root._pending, root._regroup(root._pending))
            }
            root._pending = ""
            root._buf = ""
            root._pump()
        }
    }

    // value <TAB> label <TAB> detail <TAB> current  — the one format every
    // ui-prefs.sh listing prints, so this parser does not care which one it got.
    function _parseList(key, raw) {
        const p = root.pages[key]
        const out = []
        const lines = String(raw).split("\n")
        for (let i = 0; i < lines.length; i++) {
            if (!lines[i].trim()) continue
            const f = lines[i].split("\t")
            if (p.list === "keybinds") {
                // The description IS the point of this page — a list of combos
                // with nothing beside them says what is bound and not what any
                // of it does.
                out.push({ id: f[0], icon: "󰌌", title: f[0], sub: f[1] || "",
                           kind: "keybind", value: f[0], detail: f[1] || "" })
                continue
            }
            out.push({
                id: f[0], icon: p.icon, title: f[1] || f[0], sub: "",
                kind: "choice", value: f[0],
                detail: p.showDetail ? (f[2] || "") : "",
                // The current value is shown by filling the row, the way the
                // taskbar's panels mark a connected network — not by a "current"
                // subtitle, which would break the no-redundant-subtext rule and
                // read as a label rather than as state.
                active: (f[3] || "") === "current",
                font: p.renderInOwnFont ? f[0] : ""
            })
        }
        return out
    }

    // Re-fetch one listing: after a choice is applied the "current" marker has
    // moved, and the panel stays open on that page to show it.
    function refresh(key) {
        const next = {}
        for (const k in root.lists) if (k !== key) next[k] = root.lists[k]
        root.lists = next
        root.ensure(key)
    }

    // ── hyprbars state ────────────────────────────────────────────────────
    // null until asked, so the switch renders as pending rather than as a
    // confident "off" while the query is in flight.
    property var barsLoaded: null

    function refreshState() { barsProc.running = true }

    property var _barsProc: Process {
        id: barsProc
        // `hyprctl plugin list`, not `hyprpm list`: what matters is whether a
        // bar is being drawn on windows right now, not what hyprpm intends to do
        // at the next login. Same distinction hyprbars.sh draws between
        // is_loaded and is_enabled.
        command: ["bash", "-c", "hyprctl plugin list 2>/dev/null | grep -c hyprbars"]
        running: false
        stdout: StdioCollector {
            id: barsOut
            onStreamFinished: root.barsLoaded = parseInt(barsOut.text.trim(), 10) > 0
        }
    }

    // ── activation ────────────────────────────────────────────────────────
    // Returns true when the menu should close. A choice or a switch keeps it
    // open, so the change can be seen where it was made — picking a font and
    // watching the list redraw in it is the entire point of the Fonts page.
    function activate(key, row) {
        if (!row) return false

        if (row.kind === "choice") {
            // On a group page the key is "icons/Obsidian", which carries no
            // pref of its own — the listing page it belongs to does.
            const lk = root.listPageKeyOf(key)
            const pref = root.pages[lk === "" ? key : lk].pref
            // detail is the .desktop file name for browsers and empty for every
            // other key; ui-prefs.sh needs it to also point xdg-settings at the
            // same browser, so a link clicked in another app opens where
            // finder's own web search opens.
            root._sh(root._q(root.scriptDir + "/ui-prefs.sh") + " set " + pref +
                     " " + root._q(row.value) + " " + root._q(row.detail || ""))
            // Move the "current" mark in the CACHED listing rather than
            // re-running the script. Re-fetching emptied the ListView and
            // repopulated it a moment later, which read as the menu glitching
            // and reopening. Nothing else about the listing can have changed —
            // the only thing that moved is which row is in effect, and we are
            // the ones who moved it.
            const cur = root.lists[lk === "" ? key : lk]
            if (cur) {
                const lkey = (lk === "") ? key : lk
                const next = {}
                for (const k in root.lists) next[k] = root.lists[k]
                next[lkey] = cur.map(r => Object.assign({}, r, { active: r.value === row.value }))
                root.lists = next
                root._setGrouped(lkey, root._regroup(lkey))
            }
            return false
        }

        if (row.kind === "toggle") { root._toggle(key, row); return false }

        if (row.kind === "keybind") {
            root._sh("printf '%s' " + root._q(row.value) + " | wl-copy")
            return true
        }

        root._action(key === "" ? row.id : key + "/" + row.id)
        return true
    }

    function _toggle(key, row) {
        if (key === "setup" && row.id === "titlebar") {
            const want = (root.barsLoaded === true) ? "off" : "on"
            // --persist, so the switch also decides what happens at the next
            // login — Ahaan's "autosets to the default startup selection".
            // That half writes to root-owned /var/cache/hyprpm through hyprpm's
            // own sudo, which is why it needs a password at all; the runtime
            // half takes effect immediately either way.
            root.authRequired(
                (want === "on" ? "Enabling" : "Disabling") + " window title bars at login",
                root._q(root.scriptDir + "/hyprbars.sh") + " " + want + " --persist")
        }
    }

    // Called by the password box once the command has actually succeeded, so
    // the switch reflects what happened rather than what was asked for.
    function toggleSettled() { barsRecheck.restart() }

    property var _barsRecheck: Timer {
        id: barsRecheck
        interval: 2500
        repeat: false
        onTriggered: root.refreshState()
    }

    function _action(path) {
        switch (path) {
        // hold = true for the ones that exit the moment they finish. pacman
        // prints what it did and pkg-install.sh then returns, which closes the
        // window in the same frame — the output is never readable. The three
        // with hold = false end in a "press any key" of their own.
        case "install/pkg":     root._term("pkg-install",     "pkg-install.sh",     true);  break
        case "install/aur":     root._term("pkg-aur-install", "pkg-aur-install.sh", true);  break
        case "install/webapp":  root._term("webapp-install",  "webapp-install.sh",  false); break
        case "remove/pkg":      root._term("pkg-remove",      "pkg-remove.sh",      true);  break
        case "remove/webapp":   root._term("webapp-remove",   "webapp-remove.sh",   false); break
        case "update":          root._term("system-update",   "system-update.sh",   true);  break
        case "about":           root._term("about",           "about-system.sh",    false); break

        case "setup/monitors":
            // nwg-displays, not a panel of our own: it is what wrote the
            // monitors.lua the compositor is running, and it is the only thing
            // that writes that file. A second editor would be a second source of
            // truth for the same file.
            root._sh("nwg-displays")
            break
        }
    }

    // ── spawning ──────────────────────────────────────────────────────────
    function _q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // Every spawn goes out as  setsid <cmd> </dev/null >/dev/null 2>&1 &
    // Both halves are load-bearing, and this repo has paid for both:
    //   setsid … &   the child gets its own session, and this Process does not
    //                stay `running` for its whole life — Process.running = true
    //                is a no-op while already running, so a foreground spawn
    //                silently swallows every later one.
    //   </dev/null >/dev/null 2>&1
    //                the child must not inherit Quickshell's stdio pipe.
    //                Quickshell closes the read end when the command exits and
    //                the child dies on its next write, of SIGPIPE.
    // See AppIndex.launch() and the SIGPIPE section of the system map.
    //
    // cmd is passed as $1 rather than interpolated into the script text: it
    // already contains quoting of its own, and nesting three levels of it by
    // hand is how a spawn silently becomes a different command.
    function _sh(cmd) {
        shProc.command = ["bash", "-c",
            "setsid bash -c \"$1\" </dev/null >/dev/null 2>&1 &", "_", cmd]
        shProc.running = true
    }

    // A terminal window for the things that are genuinely interactive: an fzf
    // picker, a form, a sudo prompt, fastfetch. The title is what hyprland.lua's
    // window rules match on to size these windows, so it is not decoration.
    //
    // `--title X -e <cmd>` is the kitty/alacritty form; UiConfig.terminal is
    // whatever the user picked under Setup -> Defaults, so an exotic terminal
    // with different flags would need this line adjusted.
    function _term(title, script, hold) {
        var inner = root._q(root.scriptDir + "/" + script.split(" ")[0])
        const args = script.split(" ").slice(1)
        for (let i = 0; i < args.length; i++) inner += " " + root._q(args[i])
        if (hold) inner += "; printf '\\nPress any key to close… '; read -rsn1 _"
        root._sh(UiConfig.terminal + " --title " + root._q(title) +
                 " -e bash -c " + root._q(inner))
    }

    property var _shProc: Process { id: shProc; running: false }
}
