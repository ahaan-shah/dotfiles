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
//   Setup    -> Monitors / Keybindings / Window rules / Defaults
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
                { id: "setup",   icon: "󰒓", title: "Setup",   kind: "menu",   sub: "monitors, keys, window rules, defaults" },
                { id: "theme",   icon: "󰏘", title: "Theme",   kind: "menu",   sub: "GTK theme, icons, fonts" },
                { id: "security", icon: "󰒃", title: "Security", kind: "menu",  sub: "firewall, fingerprints, password" },
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
                { id: "windowrules", icon: "󰖯", title: "Window rules",    kind: "menu", sub: "borders, gaps, rounding, opacity, blur, animation" },
                { id: "defaults",    icon: "󰀻", title: "Defaults",        kind: "menu", sub: "browser, terminal, editor" }
            ]
        },

        "security": {
            title: "Security", icon: "󰒃",
            state: "fingerprints",
            rows: [
                { id: "firewall",     icon: "󰞀", title: "Firewall",        kind: "menu", sub: "firewalld — zone and allowed services" },
                { id: "fingerprints", icon: "󰈷", title: "Fingerprints",    kind: "menu", sub: "what unlocks the lock screen" },
                { id: "passwd",       icon: "󰌾", title: "Change password", kind: "action" }
            ]
        },

        // ── Fingerprints ──────────────────────────────────────────────────
        // fprintd holds ten fixed finger slots and no names; scripts/
        // fingerprint.sh keeps the names and picks the slot. Adding one is
        // gated behind the password box, deleting one is not — see _action
        // and _fpDelete below for why they differ.
        "security/fingerprints": {
            title: "Fingerprints", icon: "󰈷",
            rows: [
                { id: "add",    icon: "󰐕", title: "Add fingerprint",     kind: "action" },
                { id: "delete", icon: "󰆴", title: "Delete fingerprints", kind: "menu" }
            ]
        },

        // No showDetail and no grouping, and both are the same decision: what
        // identifies a fingerprint here is the NAME it was given, not the
        // fprintd slot it happens to occupy. The slot is chosen by the script
        // from whatever is free, so it carries no meaning worth showing — and
        // showing it invited the page to organise itself around it.
        //
        // Grouping did exactly that. It keys on `value`, which is the slot, so
        // "right-thumb" and "right-index-finger" share the prefix "right" and
        // the page folded them behind a "right" row. Hands are not a category
        // anyone chose; a list of names is.
        "security/fingerprints/delete": {
            title: "Delete fingerprints", icon: "󰆴",
            list: "fingerprints", fprint: "delete", noGroup: true, width: 480
        },

        "security/firewall": {
            title: "Firewall", icon: "󰞀",
            state: "firewall",
            rows: [
                // Every one of these needs root, and every one of them goes
                // through finder's own password box — never polkit's. See
                // scripts/firewall.sh for why writes avoid firewall-cmd.
                { id: "enabled",  icon: "󰞀", title: "Firewall",         kind: "toggle" },
                { id: "zone",     icon: "󰒙", title: "Zone",             kind: "menu", sub: "the profile applied to new connections" },
                { id: "services", icon: "󰖟", title: "Allowed services", kind: "menu", sub: "what may reach this machine" }
            ]
        },

        "security/firewall/zone":     { title: "Zone",             icon: "󰒙", list: "fw-zones",    fw: "set-zone" },
        "security/firewall/services": { title: "Allowed services", icon: "󰖟", list: "fw-services", fw: "service", multi: true, width: 520 },

        "setup/defaults": {
            title: "Defaults", icon: "󰀻",
            rows: [
                { id: "browser",  icon: "󰖟", title: "Browser",  kind: "menu", sub: "opens links and finder's web search" },
                { id: "terminal", icon: "󰆍", title: "Terminal", kind: "menu", sub: "SUPER+Q, and the settings menu's own tools" },
                { id: "editor",   icon: "󰏫", title: "Editor",   kind: "menu", sub: "$EDITOR" }
            ]
        },

        // ── Theme ─────────────────────────────────────────────────────────
        // One door for the three preferences that decide how everything LOOKS,
        // where the root menu used to spend three of its nine rows on them —
        // Fonts, Icons and Theme sat as siblings of Install and Security, which
        // put "which typeface" at the same level as "install a package". They
        // are one subject, so they are one row now.
        //
        // The GTK listing keeps its own page rather than being this page's
        // listing, so all three read the same way: a row that opens a list.
        // "Theme" as a title would then have meant two different things one
        // level apart, hence "GTK theme" on the row it actually names.
        "theme": {
            title: "Theme", icon: "󰏘",
            rows: [
                { id: "gtk",   icon: "󰏘", title: "GTK theme", kind: "menu", sub: "widget style for GTK apps" },
                { id: "icons", icon: "󰋩", title: "Icons",     kind: "menu", sub: "icon theme" },
                { id: "fonts", icon: "󰛖", title: "Fonts",     kind: "menu", sub: "the font every shell draws with" }
            ]
        },

        // ── the listings ──────────────────────────────────────────────────
        // `renderInOwnFont` is the Fonts page's whole point: a list of family
        // names set in the default font tells you nothing about how any of them
        // look. Each row is drawn in the family it names, so the list IS the
        // preview.
        "theme/fonts": { title: "Fonts",     icon: "󰛖", list: "fonts",  pref: "UI_FONT", renderInOwnFont: true, width: 560 },
        "theme/icons": { title: "Icons",     icon: "󰋩", list: "icons",  pref: "ICON_THEME" },
        "theme/gtk":   { title: "GTK theme", icon: "󰏘", list: "themes", pref: "GTK_THEME", width: 560 },

        "setup/defaults/browser":  { title: "Browser",  icon: "󰖟", list: "browsers",  pref: "DEFAULT_BROWSER", showDetail: true },
        "setup/defaults/terminal": { title: "Terminal", icon: "󰆍", list: "terminals", pref: "DEFAULT_TERMINAL" },
        "setup/defaults/editor":   { title: "Editor",   icon: "󰏫", list: "editors",   pref: "DEFAULT_EDITOR" },

        // Wider than everything else: a bind is a combo AND what it does, and
        // at 430 the description had nowhere to go. list-keybinds.sh already
        // supplies it — the page just had no room to show it.
        // noGroup, and it is the only listing that sets it. Grouping exists to
        // collapse VARIANTS of one thing — 36 Obsidian icon themes behind one
        // Obsidian row — and a modifier is not a variant: "SUPER +" is a
        // prefix shared by 34 unrelated binds, so grouping on it produced a
        // "SUPER + · 34 variants" door with nothing in common behind it and
        // buried every bind one level down. A list of binds wants to be a flat
        // list of binds.
        "setup/keybindings": { title: "Keybindings", icon: "󰌌", list: "keybinds", width: 660, noGroup: true },

        // ── Window rules ──────────────────────────────────────────────────
        // The only page whose rows are EDITED rather than chosen. Every other
        // listing here is "pick one of these"; this one is "here is a number,
        // type a different one", so its rows carry a kind of their own —
        // "value" — that the panel renders as a box.
        //
        // noGroup because grouping collapses variants of ONE thing and these
        // are thirteen unrelated settings. Wider than the default because each
        // row is a label, a description, a box and a unit on one line.
        //
        // window-rules.sh is the whole back end, which is the same contract
        // every other page here keeps: this file decides what to offer and
        // knows none of the hyprctl option paths, none of the bounds, and
        // nothing about how a value is applied or made to persist.
        "setup/windowrules": { title: "Window rules", icon: "󰖯", list: "winrules",
                               width: 620, noGroup: true }
    })

    // Raised when a row needs root. Finder closes the menu and puts the
    // password box up in its place — see PasswordPrompt.qml. Terminal work
    // (update/install/remove) does NOT go through here: those open a terminal
    // anyway because the output is the point, so their password belongs in it.
    signal authRequired(string reason, string command)

    // Raised by Privacy → Change password. Finder puts the same box up in the
    // three-step flow rather than the one-step one.
    signal changePasswordRequested()

    // Same box again, but in its verify-only flow: PAM checks the password and
    // then nothing is handed to privileged-run.sh, because what follows must
    // run as THIS USER and not as root. Enrolling a fingerprint is exactly
    // that — `fprintd-enroll` as root would be claiming another user's device,
    // which is the setusername action and is auth_admin_keep, so sudo would
    // make the thing harder rather than easier. `action` says what to do once
    // the password is accepted; see verified() below.
    signal verifyRequired(string reason, string action)

    // Raised once a verified password has been accepted for "fp-enroll".
    signal fingerprintEnrollRequested()

    function notify(title, body) {
        root._sh("command -v notify-send >/dev/null && notify-send -a Settings " +
                 root._q(title) + " " + root._q(body || ""))
    }


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
        if (page.noGroup) return { top: rows, byGroup: ({}) }
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

    // Adds the state a row cannot carry as a literal: whether a toggle is on,
    // and what the firewall rows currently read.
    function _decorate(key, r) {
        if (key === "security/firewall" && r.kind === "menu") {
            // These two nest, so they keep a subtitle — and the useful subtitle
            // is the live value, not a restatement of the label.
            const fw = root.fwState
            if (r.id === "zone" && fw.ZONE)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         sub: fw.ZONE + (fw.IFACE ? " on " + fw.IFACE : "") }
            if (r.id === "services" && fw.ALLOWED !== undefined)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         sub: fw.ALLOWED + " allowed"
                               + (fw.BLOCKED !== "0" ? ", " + fw.BLOCKED + " blocked" : "") }
            return r
        }
        // The Security row and the Fingerprints page both say how many are
        // enrolled rather than restating what a fingerprint is — the same rule
        // the firewall rows follow: the useful subtitle is the live value.
        if (key === "security" && r.id === "fingerprints") {
            const st = root.fpState
            if (st.AVAILABLE === "no")
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         sub: st.REASON || "no reader" }
            if (st.COUNT !== undefined)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         sub: st.COUNT === "0" ? "none enrolled"
                            : st.COUNT === "1" ? "1 enrolled"
                            : st.COUNT + " enrolled" }
            return r
        }
        if (key === "security/fingerprints") {
            const st = root.fpState
            if (r.id === "delete" && st.COUNT !== undefined)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         sub: st.COUNT === "0" ? "nothing enrolled yet"
                            : st.COUNT + " enrolled" }
            // Only worth a subtitle when it is about to stop working.
            if (r.id === "add" && st.FREE === "0")
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         sub: "all ten slots are full" }
            return r
        }
        if (r.kind !== "toggle") return r
        const on = (key === "security/firewall" && r.id === "enabled")
                     ? (root.fwState.AVAILABLE === undefined ? null
                        : root.fwState.RUNNING === "yes")
                 : false
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
                // Submenu rows ARE results. They used to be skipped on the
                // theory that their children stood for them — but that made
                // whole sections unreachable by name: searching "security" or
                // "privacy" found nothing at all, because the only thing
                // carrying that word was the menu row itself.
                const hay = (r.title + " " + (r.sub || "") + " " + (r.detail || "")).toLowerCase()
                const at = hay.indexOf(q)
                if (at < 0) continue
                const path = (key === scopeKey) ? "" : root.crumb(key).slice(1).join(" › ")
                out.push({
                    id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                    value: r.value, detail: r.detail, active: r.active === true,
                    font: r.font, pageKey: key, trail: path,
                    // Results carry no subtitle as a rule — they use the
                    // trailing slot for the page they live on instead, and a
                    // subtitle there would be two kinds of secondary text on
                    // one row. A keybind is the exception, because its
                    // subtitle is not description, it is the ANSWER: searching
                    // "wall" and being shown a bare "ALT + W" tells you what is
                    // bound and not what it does, which is the whole reason
                    // this page parses the config instead of asking hyprctl.
                    sub: r.kind === "keybind" ? (r.sub || "") : "",
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
            const pg = root.pages[key]
            // The firewall listings are NOT prefetched. They are only meaningful
            // on their own page, 265 services would swamp a root search, and
            // fetching them at open is what made three firewall.sh calls happen
            // every single time the menu was raised.
            // Neither the firewall nor the fingerprint listings are
            // prefetched. Both are only meaningful on their own page, and
            // both cost a subprocess that talks to a daemon — fetching them
            // at open is what made three firewall.sh calls happen every
            // single time the menu was raised.
            if (pg.list && !pg.fw && !pg.fprint) root._queue.push(key)
        }
        root._pump()
    }

    function ensure(key) {
        // Entering the firewall page re-reads it, so a change made elsewhere
        // (or by the previous visit) is reflected rather than remembered.
        if (key === "security/firewall") root.refreshFirewall()
        if (key === "security" || key === "security/fingerprints") root.refreshFingerprints()
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
        const cmd = (p.list === "winrules")        ? q + "/window-rules.sh list"
                  : (p.list === "keybinds")        ? q + "/list-keybinds.sh"
                  : (p.list === "fw-zones")        ? q + "/firewall.sh zones"
                  : (p.list === "fw-services")     ? q + "/firewall.sh services"
                  : (p.list === "fingerprints")    ? q + "/fingerprint.sh list"
                  :                                  q + "/ui-prefs.sh list " + p.list
        listProc.command = ["bash", "-c", cmd + " 2>/dev/null"]
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
            if (p.list === "winrules") {
                // key  label  description  kind  value  unit  min  max  step
                //
                // The description stays a SUBTITLE here, against this file's
                // rule that a subtitle only earns its place on a row that
                // nests. That rule holds where the label already says what the
                // row does — "Fonts", "Remove" — and "Blur passes" does not:
                // the number means nothing without knowing it costs GPU per
                // pass. This is the one page where the subtitle is the
                // documentation.
                const kind = f[3] || "int"
                out.push({
                    id: f[0], icon: "", title: f[1] || f[0], sub: f[2] || "",
                    kind: kind === "bool" ? "toggle" : "value",
                    value: f[4] || "", unit: f[5] || "",
                    min: f[6] || "", max: f[7] || "", step: f[8] || "",
                    // A toggle reads its state from `active`, like every other
                    // toggle in this file, rather than from the string.
                    active: f[4] === "true"
                })
                continue
            }
            if (p.list === "keybinds") {
                // declared <TAB> in force <TAB> description <TAB> the call
                //
                // The DESCRIPTION is the title. A list of combos reads as a
                // list of keys, and what anyone is actually scanning for is the
                // thing they want to do — the combo is the answer, so it goes
                // where an answer goes, in a box on the right.
                //
                // `id` is the DECLARED combo and never the one in force: it is
                // the identity keybinds.conf keys an override on, so a bind that
                // has already been reassigned once is still reassigned against
                // the same name rather than against its own last answer.
                out.push({ id: f[0], icon: "󰌌",
                           title: f[2] || f[0], sub: "",
                           // f[1] EXACTLY, never `f[1] || f[0]`. An empty combo
                           // in force is a bind whose key was taken by
                           // something else, and falling back to the declared
                           // one there showed a key that is no longer bound —
                           // the row said SUPER + Q while SUPER + Q did nothing.
                           kind: "keybind", value: f[1] === undefined ? "" : f[1],
                           detail: f[3] || "",
                           // set when the combo in force is not the declared
                           // one, which is what the page marks as changed
                           rebound: (f[1] || "") !== "" && f[1] !== f[0] })
                continue
            }
            out.push({
                id: f[0], icon: p.icon, title: f[1] || f[0], sub: "",
                // "multi" is the firewall's allowed-services list: more than one
                // row is marked at a time and activating one toggles it, rather
                // than moving a single selection.
                kind: p.multi ? "multi" : "choice", value: f[0],
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

    function refreshState() {
        root.refreshFirewall()
        // Cheap (fprintd-list over D-Bus, no authorisation) and the Security
        // row's subtitle is a live count, so it has to be known before the
        // user ever walks into that page.
        root.refreshFingerprints()
    }

    // KEY="value" lines from firewall.sh status — every one of them an
    // UNPRIVILEGED read, so the page renders its true state without asking for
    // a password. Only changing something needs one.
    property var fwState: ({})
    function refreshFirewall() {
        if (fwProc.running) return
        fwProc.running = true
    }

    // KEY="value" lines from fingerprint.sh status. Every read here is
    // unprivileged (fprintd-list needs no authorisation), so the page renders
    // its true state without asking for anything.
    property var fpState: ({})
    function refreshFingerprints() {
        if (fpProc.running) return
        fpProc.running = true
    }

    property var _fpStatProc: Process {
        id: fpProc
        command: ["bash", "-c", root._q(root.scriptDir + "/fingerprint.sh") + " status 2>/dev/null"]
        running: false
        stdout: StdioCollector {
            id: fpOut
            onStreamFinished: root.fpState = root._parseKv(fpOut.text)
        }
    }

    property var _fwProc: Process {
        id: fwProc
        command: ["bash", "-c", root._q(root.scriptDir + "/firewall.sh") + " status 2>/dev/null"]
        running: false
        // StdioCollector, not SplitParser + a Connections on running: the
        // latter spawned the process and produced the output, but the buffer
        // was still empty when `running` went false.
        // The SplitParser version spawned the process and produced the output,
        // but the buffer was still empty by the time `running` went false, so
        // fwState stayed `{}` and the switch rendered as not-yet-known.
        stdout: StdioCollector {
            id: fwOut
            onStreamFinished: root._parseFw(fwOut.text)
        }
    }

    // firewall.sh and fingerprint.sh print the same KEY="value" shape, so the
    // parser is shared rather than written twice.
    function _parseKv(raw) {
        const out = ({})
        const lines = String(raw).split("\n")
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].match(/^([A-Z_]+)="(.*)"$/)
            if (m) out[m[1]] = m[2]
        }
        return out
    }
    function _parseFw(raw) { root.fwState = root._parseKv(raw) }

    // ── activation ────────────────────────────────────────────────────────
    // Returns true when the menu should close. A choice or a switch keeps it
    // open, so the change can be seen where it was made — picking a font and
    // watching the list redraw in it is the entire point of the Fonts page.
    function activate(key, row) {
        if (!row) return false

        // A firewall listing is not a ui-prefs preference: it is a root-only
        // change to the system firewall, so it goes through the password box.
        if (row.kind === "choice" || row.kind === "multi") {
            const fk = root.listPageKeyOf(key)
            const fp = root.pages[fk === "" ? key : fk]
            if (fp && fp.fw === "set-zone") {
                root._fwAuth("Setting the firewall zone to " + row.value,
                             "set-zone " + root._q(row.value))
                return false
            }
            // "Can delete right there", as asked — no confirmation step. It
            // is not gated behind the password box either, and that asymmetry
            // is deliberate: ENROLLING adds a credential that unlocks the
            // screen, which is why add is gated; deleting one only removes
            // access, and the worst case is enrolling the finger again.
            if (fp && fp.fprint === "delete") {
                root._fpDelete(row)
                return false
            }
            if (fp && fp.fw === "service") {
                const allow = !row.active
                root._fwAuth((allow ? "Allowing " : "Blocking ") + row.value + " through the firewall",
                             (allow ? "allow " : "block ") + root._q(row.value))
                return false
            }
        }

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

        // A "value" row is EDITED, not activated: Enter opens its box and the
        // panel owns everything after that. Returning here rather than falling
        // through matters — the fallthrough is _action(), which would be asked
        // to run "setup/windowrules/WIN_ROUNDING" as if it were a command.
        if (row.kind === "value") return false

        // A keybind row is reassigned, not activated. Enter opens the capture
        // box, exactly as it opens the editor on a window-rules row — the panel
        // owns that, so nothing happens here. Copying the combo to the clipboard
        // is what this used to do and it is gone: it was the only thing the row
        // could do, and it is not what anyone opens this page for.
        if (row.kind === "keybind") return false

        // _action answers whether the menu should close. Change password must
        // NOT: it raises the password box in this same window, and closing here
        // tore the box down in the same frame it was created — which is why the
        // row appeared to do nothing at all.
        return root._action(key === "" ? row.id : key + "/" + row.id)
    }

    // Called by the password box once PAM has accepted the password in its
    // verify-only flow. Nothing was run as root; this is where what the
    // password was FOR actually happens.
    function verified(action) {
        if (action === "fp-enroll") root.fingerprintEnrollRequested()
    }

    // Deleting runs as this user, not through privileged-run.sh — see the
    // verifyRequired comment above. 2>&1 so a refusal (which is what a missing
    // polkit rule looks like) can be reported rather than vanishing.
    property string _fpDeleting: ""
    function _fpDelete(row) {
        if (fpDelProc.running) return
        root._fpDeleting = row.title
        fpDelProc.command = ["bash", "-c",
            root._q(root.scriptDir + "/fingerprint.sh") + " delete " + root._q(row.value) + " 2>&1"]
        fpDelProc.running = true
    }

    property var _fpDelProc: Process {
        id: fpDelProc
        running: false
        // Collected rather than dropped: without a reader for the pipe a
        // chatty child blocks on its 64K buffer and onExited never fires —
        // the same trap PasswordPrompt's authProc documents.
        stdout: StdioCollector { id: fpDelOut }
        onExited: (code, status) => {
            if (code === 0) {
                root.notify("Fingerprint deleted", root._fpDeleting)
            } else {
                const why = String(fpDelOut.text || "").trim()
                console.warn("fingerprint delete failed:", why)
                root.notify("Could not delete that fingerprint",
                            why !== "" ? why : "fprintd refused")
            }
            root._fpDeleting = ""
            // Re-read both: the listing the user is looking at, and the counts
            // the pages above it show.
            root.refresh("security/fingerprints/delete")
            root.refreshFingerprints()
        }
    }

    function _fwAuth(reason, args) {
        root.authRequired(reason, root._q(root.scriptDir + "/firewall.sh") + " " + args)
    }

    function _toggle(key, row) {
        if (key === "security/firewall" && row.id === "enabled") {
            // on/off, never enable/disable: the unit must always come back at
            // boot, so nothing here is allowed to disable it. `on` re-enables
            // as well, so a machine that ended up disabled is corrected.
            const want = (root.fwState.RUNNING === "yes") ? "off" : "on"
            root._fwAuth(want === "on" ? "Turning the firewall on"
                                       : "Turning the firewall off", want)
            return
        }
        if (key === "setup/windowrules") {
            // A window rule needs no password: everything it touches is this
            // user's own compositor and this user's own config file.
            root.setWindowRule(row.id, row.active === true ? "false" : "true")
        }
    }

    // ── window rules ──────────────────────────────────────────────────────
    // One entry point for both kinds of row — the toggles above and the boxes
    // in the panel — because both are the same operation: hand a key and a
    // value to the script and re-read the page from what it reports back.
    //
    // The page is refreshed rather than patched in place. window-rules.sh
    // REFUSES an out-of-range value instead of clamping it, and it reports the
    // live figure rather than the one it was given, so re-reading is what makes
    // a rejected edit snap back to what is actually in force — a box that keeps
    // showing a number the compositor never accepted is the failure worth
    // designing against here.
    property string winError: ""

    // ── window rules ──────────────────────────────────────────────────────
    // The cached listing IS the state. A set patches the affected row in place
    // and the script runs behind it; nothing re-reads the page on the way
    // through. That replaces an optimistic-value map plus a re-run of
    // `window-rules.sh list` per step, and it is both simpler and a whole
    // subprocess cheaper on every press.
    //
    // The page is only ever re-read on a REFUSAL, where the row has to snap
    // back to what is actually in force, and on a reset, where the values come
    // from re-parsing hyprland.lua and this side cannot predict them.
    //
    // In-flight requests are QUEUED and coalesced, never dropped: the
    // intermediate values of a held-down key are not worth a subprocess each,
    // but the one it stops on always is.
    readonly property string winKey: "setup/windowrules"

    property string _winQueuedKey: ""
    property string _winQueuedVal: ""

    function setWindowRule(key, value) {
        root.winError = ""
        root._patchWinRow(key, value)
        if (winProc.running) {
            root._winQueuedKey = key
            root._winQueuedVal = value
            return
        }
        root._runWindowRule(key, value)
    }

    function _runWindowRule(key, value) {
        root._winWasReset = false
        winProc.command = ["bash", "-c",
            root._q(root.scriptDir + "/window-rules.sh") + " set " + root._q(key) + " " + root._q(value)
            + " 2>&1 >/dev/null"]
        winProc.running = true
    }

    // One row, one field. Rebuilding the whole listing from the script is what
    // made the selection jump: reassigning the model resets the ListView, and
    // for the frame in which its delegates are being rebuilt currentItem is
    // null — which sent the selection band to the top of the list and then back
    // down again. The band holds its place through that now, and this keeps the
    // rebuild down to the one row that actually changed.
    function _patchWinRow(key, value) {
        const cur = root.lists[root.winKey]
        if (!cur) return
        const next = ({})
        for (const k in root.lists) next[k] = root.lists[k]
        next[root.winKey] = cur.map(function (r) {
            if (r.id !== key) return r
            const c = ({})
            for (const f in r) c[f] = r[f]
            c.value = value
            c.active = (value === "true")
            return c
        })
        root.lists = next
        root._setGrouped(root.winKey, root._regroup(root.winKey))
    }

    // ── keybinds ──────────────────────────────────────────────────────────
    // Nothing optimistic here, unlike the window rules. A reassignment ends in
    // `hyprctl reload`, which re-parses the whole config — the listing has to
    // be re-read afterwards because that is the only thing that knows what the
    // compositor came back with, and patching a row in place would just be
    // overwritten by it a moment later.
    readonly property string kbKey: "setup/keybindings"
    property string kbError: ""
    // Separate from kbError because it is not a failure: the reassignment
    // HAPPENED, and something else lost its key as a result. keybinds.sh marks
    // it with a `warn:` prefix on the same stream, since a command has only the
    // two, and the prefix is what tells them apart.
    property string kbWarn: ""

    function setKeybind(declared, combo) {
        if (kbProc.running) return
        root.kbError = ""
        root.kbWarn = ""
        kbProc.command = ["bash", "-c",
            root._q(root.scriptDir + "/keybinds.sh") + " set " + root._q(declared)
            + " " + root._q(combo) + " 2>&1 >/dev/null"]
        kbProc.running = true
    }

    function resetKeybind(declared) {
        if (kbProc.running) return
        root.kbError = ""
        root.kbWarn = ""
        kbProc.command = ["bash", "-c",
            root._q(root.scriptDir + "/keybinds.sh") + " reset " + root._q(declared)
            + " 2>&1 >/dev/null"]
        kbProc.running = true
    }

    property var _kbProc: Process {
        id: kbProc
        running: false
        stdout: StdioCollector {
            id: kbOut
            onStreamFinished: {
                const raw = (kbOut.text || "").trim()
                if (raw.indexOf("warn:") === 0) {
                    root.kbWarn = raw.replace(/^warn:\s*/, "")
                    root.kbError = ""
                } else {
                    root.kbError = raw.replace(/^keybinds:\s*/, "")
                    root.kbWarn = ""
                }
                // 300ms: keybinds.sh ends in `hyprctl reload`, and the config is
                // not re-parsed the instant the command returns. Re-reading too
                // early lists the binds from before the change and the page
                // looks like it refused.
                kbSettle.restart()
            }
        }
    }

    property var _kbSettle: Timer {
        id: kbSettle
        interval: 300
        repeat: false
        onTriggered: root.refresh(root.kbKey)
    }

    property bool _winWasReset: false
    function resetWindowRules() {
        if (winProc.running) return
        root.winError = ""
        root._winWasReset = true
        winProc.command = ["bash", "-c",
            root._q(root.scriptDir + "/window-rules.sh") + " reset --all 2>&1 >/dev/null"]
        winProc.running = true
    }

    property var _winProc: Process {
        id: winProc
        running: false
        // stderr only — the script prints the resulting value on stdout and its
        // complaint on stderr, and the command sends stdout to /dev/null, so
        // anything arriving here is a refusal worth showing.
        stdout: StdioCollector {
            id: winOut
            onStreamFinished: {
                root.winError = (winOut.text || "").trim().replace(/^window-rules:\s*/, "")

                // A queued press goes now; its own completion decides what
                // happens after. So a burst costs one subprocess per press and
                // no page reads at all.
                if (root._winQueuedKey !== "") {
                    const k = root._winQueuedKey, v = root._winQueuedVal
                    root._winQueuedKey = ""; root._winQueuedVal = ""
                    root._runWindowRule(k, v)
                    return
                }
                // A refusal leaves the patched row showing a value that was
                // never applied, and a reset produces values only hyprland.lua
                // knows. Both need the page read back; nothing else does.
                if (root.winError !== "" || root._winWasReset) winSettle.restart()
            }
        }
    }

    property var _winSettleTimer: Timer {
        id: winSettle
        // A reset re-parses hyprland.lua, and the values that produces are not
        // readable until it has. 250ms is one reload on this machine with room
        // to spare; re-reading earlier showed the old numbers and made the reset
        // look like it had failed. A refusal needs no wait at all, but one timer
        // with the longer interval is simpler than two.
        interval: 250
        repeat: false
        onTriggered: root.refresh(root.winKey)
    }

    // Called by the password box once the command has actually succeeded, so
    // the switch reflects what happened rather than what was asked for.
    function toggleSettled() { root.refreshFirewall() }

    // Returns true when the menu should close after the action.
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

        case "security/passwd":
            root.changePasswordRequested()
            return false

        case "security/fingerprints/add":
            if (root.fpState.AVAILABLE === "no") {
                root.notify("No fingerprint reader",
                            root.fpState.REASON || "Nothing to enrol against")
                return false
            }
            if (root.fpState.FREE === "0") {
                root.notify("No free slots",
                            "All ten fingers are enrolled — delete one first")
                return false
            }
            // The password box first, then the enrol box. Same reason the
            // firewall rows go through it: adding a fingerprint changes what
            // unlocks this machine, so it should cost a password — and it
            // should cost OUR password box rather than polkit's.
            root.verifyRequired("Adding a fingerprint", "fp-enroll")
            return false

        case "setup/monitors":
            // nwg-displays, not a panel of our own: it is what wrote the
            // monitors.lua the compositor is running, and it is the only thing
            // that writes that file. A second editor would be a second source of
            // truth for the same file.
            root._sh("nwg-displays")
            break
        }
        return true
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
    // kitty, HARDCODED — deliberately not UiConfig.terminal. These are the
    // desktop's own panels, not the user's shell: hyprland.lua floats and sizes
    // every one of them with a rule that matches `class = "^(kitty)$"` plus the
    // title below, and about-float's size is derived from kitty's measured cell
    // (9.14 x 21 px at this font). Both halves break under any other terminal:
    //
    //   • the class no longer matches, so no rule fires and the window comes up
    //     at the compositor default — measured under ghostty as an About panel
    //     too narrow for fastfetch's 112 columns, wrapping every line onto the
    //     next and garbling the whole page.
    //   • `--title X` is the kitty/alacritty spelling. ghostty's parser wants
    //     `--title=X` and rejects the separated form outright: it pops a
    //     "Configuration Errors" dialog reading `cli:1:title: value required`
    //     / `cli:2:about: invalid field` over the broken window.
    //
    // Setup -> Defaults offers eight terminals and each has its own flag
    // spelling, its own window class and its own cell size, so honouring the
    // preference here would mean a flag table AND a re-measured window rule per
    // terminal. AppIndex.launch() and hyprland.lua's F12 btop bind already
    // resolved this the same way for the same reason; this was the one place
    // that still leaked the preference into a window the desktop owns.
    // UiConfig.terminal stays what it is for: SUPER+Q and $TERMINAL.
    function _term(title, script, hold) {
        var inner = root._q(root.scriptDir + "/" + script.split(" ")[0])
        const args = script.split(" ").slice(1)
        for (let i = 0; i < args.length; i++) inner += " " + root._q(args[i])
        if (hold) inner += "; printf '\\nPress any key to close… '; read -rsn1 _"
        root._sh("kitty --title " + root._q(title) +
                 " -e bash -c " + root._q(inner))
    }

    property var _shProc: Process { id: shProc; running: false }
}
