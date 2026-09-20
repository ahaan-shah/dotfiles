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
    // ~/.config/shell that resolves to ~/.config/scripts; from
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

    // ── Is a recording running? ───────────────────────────────────────────
    // The same state file the bar's indicator watches. Two readers, one
    // writer, no polling anywhere.
    //
    // FLAT in $XDG_RUNTIME_DIR, not in a screenrecord/ subdirectory. That is
    // not cosmetic: a FileView arms its inotify watch on the PARENT DIRECTORY,
    // so a missing file is fine but a missing DIRECTORY is permanent deafness
    // — and the subdirectory this used to live in was created by the first
    // recording, always after the shell had armed this watch. Measured, with
    // the full account, in the state block of scripts/screenrecord.sh.
    //
    // It is read here so _decorate can turn the Screenrecord row into a Stop
    // row, which is the menu half of "three ways to stop" — the bind, the bar
    // dot, and this.
    readonly property bool recording: root._recState === "recording"
    property string _recState: "idle"
    property var _recFile: FileView {
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/screenrecord.state"
        watchChanges: true
        // Does not exist until the first recording; onLoadFailed handles that,
        // and an ENOENT on every startup is noise. Same as Bar.qml's copy.
        printErrors: false
        onFileChanged: reload()
        // Missing file is the normal state before the first ever recording, and
        // FileView reports that as a load failure rather than as empty text.
        onLoadFailed: root._recState = "idle"
        onLoaded: root._recState = (text() || "idle").trim()
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
                // Above Setup, and the split between them is the point: Setup
                // changes how the desktop BEHAVES and the change persists;
                // everything under Tools is a thing you reach for, does its
                // work now, and leaves no setting behind.
                { id: "tools",   icon: "󱁤", title: "Tools",   kind: "menu",   sub: "screenshot, screen recording, colour picker, OCR" },
                { id: "setup",   icon: "󰒓", title: "Setup",   kind: "menu",   sub: "monitors, keys, window rules, defaults" },
                { id: "theme",   icon: "󰏘", title: "Theme",   kind: "menu",   sub: "palette, wallpaper, GTK theme, icons, fonts" },
                { id: "security", icon: "󰒃", title: "Security", kind: "menu",  sub: "firewall, fingerprints, password" },
                // Last, deliberately, and the only row here that is not about
                // configuring the desktop: everything behind it acts on the
                // MACHINE — what it is, how hard it runs, and turning it off.
                // About moved in here from the root for that reason; it was
                // the one root row that answered a question rather than
                // changing something.
                { id: "system",  icon: "󰘚", title: "System",  kind: "menu",   sub: "power menu, power profile, about" }
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

        // ── Tools ─────────────────────────────────────────────────────────
        // Four things that were already on keybinds and had no other way in:
        // screenshot (F11 / Print / ALT+Print), screen recording (SUPER+Print),
        // the colour picker (ALT+C) and OCR (ALT+F11). The keybinds are not
        // going anywhere — this is the discoverable copy of them, for the ones
        // nobody remembers, and for screen recording it is the only place the
        // target and the soundtrack can actually be CHOSEN. The bind takes the
        // defaults.
        //
        // Every row under here shows the user something over the whole screen —
        // a slurp box, a hyprpicker freeze — and this menu is itself a
        // full-screen overlay layer. The scripts all wait for the "finder"
        // namespace to unmap before they draw anything; see the
        // wait_for_menu_gone comment in scripts/screenrecord.sh for why that is
        // a poll on hyprctl layers and not a sleep.
        "tools": {
            title: "Tools", icon: "󱁤",
            rows: [
                { id: "capture",     icon: "󰄀", title: "Capture",       kind: "menu",
                  sub: "screenshot, screen recording" },
                { id: "colorpicker", icon: "󰈋", title: "Colour picker", kind: "action" },
                { id: "ocr",         icon: "󰗊", title: "OCR scan",      kind: "action" }
            ]
        },

        "tools/capture": {
            title: "Capture", icon: "󰄀",
            rows: [
                { id: "screenshot",  icon: "󰹑", title: "Screenshot",   kind: "menu",
                  sub: "portion of screen, window, full screen" },
                // _decorate rewrites this row into a "Stop recording" ACTION
                // while a recording is running. A menu row that descended into
                // the target picker mid-recording would be offering a choice
                // that cannot be taken — gsr is already running and the only
                // thing left to do with it is stop it.
                { id: "screenrecord", icon: "󰕧", title: "Screenrecord", kind: "menu",
                  sub: "full screen, portion of screen, window" }
            ]
        },

        "tools/capture/screenshot": {
            title: "Screenshot", icon: "󰹑",
            rows: [
                { id: "region",     icon: "󰩭", title: "Portion of screen", kind: "action" },
                { id: "window",     icon: "󰖯", title: "Window",            kind: "action" },
                { id: "fullscreen", icon: "󰍹", title: "Full screen",       kind: "action" }
            ]
        },

        // Target first, soundtrack second, because the target is the choice you
        // always have to make and the soundtrack is usually the same one twice
        // running. Nine leaves rather than one page with two independent
        // controls: this menu has no widget for "pick one of these AND one of
        // those", and inventing one for a page reached twice a week is worse
        // than two taps.
        "tools/capture/screenrecord": {
            title: "Screenrecord", icon: "󰕧",
            rows: [
                { id: "full",   icon: "󰍹", title: "Full screen",       kind: "menu", sub: "audio options" },
                { id: "region", icon: "󰩭", title: "Portion of screen", kind: "menu", sub: "audio options" },
                { id: "window", icon: "󰖯", title: "Window",            kind: "menu", sub: "audio options" }
            ]
        },

        "tools/capture/screenrecord/full": {
            title: "Full screen", icon: "󰍹",
            rows: [
                { id: "none",    icon: "󰕧", title: "Only video",            kind: "action" },
                { id: "desktop", icon: "󰕾", title: "Video + audio",         kind: "action" },
                { id: "both",    icon: "󰍬", title: "Video + audio + mic",   kind: "action" }
            ]
        },

        "tools/capture/screenrecord/region": {
            title: "Portion of screen", icon: "󰩭",
            rows: [
                { id: "none",    icon: "󰕧", title: "Only video",            kind: "action" },
                { id: "desktop", icon: "󰕾", title: "Video + audio",         kind: "action" },
                { id: "both",    icon: "󰍬", title: "Video + audio + mic",   kind: "action" }
            ]
        },

        // The one with a caveat, and the row says so rather than the user
        // finding out after the take: gsr's kms backend records a RECTANGLE,
        // not a window, so a window that moves mid-recording leaves the frame.
        // See select_window in scripts/screenrecord.sh.
        "tools/capture/screenrecord/window": {
            title: "Window", icon: "󰖯",
            rows: [
                { id: "none",    icon: "󰕧", title: "Only video",          kind: "action",
                  trail: "fixed rectangle" },
                { id: "desktop", icon: "󰕾", title: "Video + audio",       kind: "action",
                  trail: "fixed rectangle" },
                { id: "both",    icon: "󰍬", title: "Video + audio + mic", kind: "action",
                  trail: "fixed rectangle" }
            ]
        },

        "setup": {
            title: "Setup", icon: "󰒓",
            rows: [
                { id: "monitors",    icon: "󰍹", title: "Monitors",        kind: "action" },
                { id: "keybindings", icon: "󰌌", title: "Keybindings",     kind: "menu", sub: "every bind, searchable" },
                { id: "windowrules", icon: "󰖯", title: "Window rules",    kind: "menu", sub: "borders, gaps, rounding, opacity, blur, animation" },
                { id: "defaults",    icon: "󰀻", title: "Defaults",        kind: "menu", sub: "browser, terminal, editor, PDFs" }
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
                { id: "editor",   icon: "󰏫", title: "Editor",   kind: "menu", sub: "$EDITOR" },
                // The odd one out, and the subtitle says so: the three above
                // are commands this desktop runs itself, while this one is a
                // mime association — nothing here opens a PDF, xdg-open does,
                // and the setting is which .desktop it hands it to. Which
                // also means it is the only default on this page that other
                // apps obey without being told.
                { id: "pdf",      icon: "󰈦", title: "PDF viewer", kind: "menu", sub: "what xdg-open hands a .pdf to" }
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
                { id: "palette", icon: "󰸌", title: "Palette", kind: "menu", sub: "the colours every surface reads" },
                // Directly under Palette because the two are one decision made
                // twice over: under the "pywal" palette the wallpaper IS the
                // colours (palette.sh wallpaper-changed), and under a chosen
                // palette it is the ground those colours were picked to sit on.
                { id: "wallpaper", icon: "󰸉", title: "Wallpapers", kind: "menu", sub: "the image behind everything" },
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
        // ── Palette ───────────────────────────────────────────────────────
        // The whole colour scheme: pywal's sixteen slots, which every surface
        // on this desktop already reads. scripts/palette.sh is the back end and
        // carries the reasoning; adding a palette is adding a file to
        // scripts/palettes/, so nothing here names a theme.
        //
        // `swatch` is this page's version of the Fonts page's own trick. A
        // font list is unreadable set in one face, and a list of 23 colour
        // schemes is unreadable with no colour in it — so each row draws the
        // three colours this desktop actually assigns a role to: the ground,
        // the accent that marks every selection, and the text.
        //
        // noGroup, for the reason the keybindings page sets it: grouping folds
        // VARIANTS of one thing, and two palettes sharing a leading word is a
        // coincidence of naming rather than a relationship. Without it
        // "catppuccin" and "catppuccin-latte" — a dark theme and a light one —
        // collapse behind one door in a list short enough to read whole.
        "theme/palette": { title: "Palette", icon: "󰸌", list: "palettes",
                           pref: "PALETTE", noGroup: true, swatch: true },

        // ── Wallpapers ────────────────────────────────────────────────────
        // This was finder's own wallpaper MODE until 2026-09-15 — ALT+W, its
        // own full-screen result list with a preview pane beside it. It is a
        // settings page now, on Ahaan's instruction, and the keybind is gone
        // with it (hyprland.lua). Nothing about picking a wallpaper was
        // search-shaped: it is a choice out of a fixed set of images, which is
        // what every other listing on this card already is.
        //
        // Two pages rather than one list, because the question has two forms
        // and they want different answers. "By palette" is the set Ahaan sorted
        // into the palette in force; "All" is everything, for when the palette
        // is about to change anyway or the answer is simply "that one".
        //
        // They read two different COLLECTIONS, and that is Ahaan's call rather
        // than an implementation detail. Everything lives under
        // ~/Pictures/wallpapers since 2026-09-19; his own sit flat at the top
        // and show under "All" only, and each palette has a <theme>/ directory
        // beside them that "By palette" shows and nothing else.
        //
        // "By palette" is a DIRECTORY, not a match. It used to be a colour
        // score — every image ranked against the palette background in CIE Lab
        // and cut at a tuned distance — because 92 downloaded backgrounds had
        // to be sorted by something and nothing recorded what suited what.
        // Ahaan sorts his own into the theme directories by hand now, so the
        // answer is stated rather than estimated, and the estimate was deleted.
        // His words: "if i am on vantablack palette, wallpapers -> by-palette
        // shows only ones in the vantablack folder."
        //
        // A palette with an empty directory therefore shows an EMPTY PAGE, and
        // so does "pywal", which is not a theme and has no directory. Both are
        // correct answers and not gaps to fill — anything put there would be a
        // wallpaper Ahaan did not choose for that palette.
        //
        // scripts/wallpapers.sh is the whole back end and carries which
        // directory is which. This file knows nothing about where an image is.
        "theme/wallpaper": {
            title: "Wallpapers", icon: "󰸉",
            rows: [
                { id: "palette", icon: "󰸌", title: "By palette", kind: "menu",
                  sub: "the ones you sorted into the palette in force" },
                { id: "all",     icon: "󰋫", title: "All",        kind: "menu",
                  sub: "your own, then every themed one" }
            ]
        },

        // `thumbs`: the row draws the file itself. Same decision as the Fonts
        // page's renderInOwnFont and the Palette page's swatch — a list of
        // filenames is a list of smudges, and the one thing anybody is
        // choosing between here is what the images LOOK like.
        //
        // noGroup, for the reason the palette page sets it: grouping folds
        // VARIANTS of one thing behind a text door, and two files sharing a
        // leading word is a coincidence of naming. Behind a door is also
        // exactly the wrong place for a picture.
        //
        // noSearch on the by-palette page ONLY, and it is about duplicates
        // rather than about reach: by-palette lists a strict SUBSET of "All"
        // (the palette's own directory, which "All" also walks), so without it
        // every wallpaper sorted into the current theme answered a root search
        // twice, once per page. "All" holds every one of them, so nothing
        // becomes unfindable.
        "theme/wallpaper/palette": { title: "By palette", icon: "󰸌", list: "wallpapers-by-palette",
                                     thumbs: true, noGroup: true, noSearch: true, width: 520 },
        "theme/wallpaper/all":     { title: "All", icon: "󰋫", list: "wallpapers",
                                     thumbs: true, noGroup: true, width: 520 },

        // ── System ────────────────────────────────────────────────────────
        // The power menu and the power profiles were two finder MODES of their
        // own and they still are — SUPER+Escape and SUPER+B open them without
        // going through this card, which Ahaan asked to keep. What is new is
        // that they are also reachable by walking here, which is where anyone
        // looks for them who does not already know the key.
        //
        // Both pages' rows come from PowerMenu.items / PowerProfiles.items
        // rather than being written out again, so the settings page and the
        // keybind surface cannot list different things — the same rule the
        // rest of this file keeps by leaving listings to scripts.
        "system": {
            title: "System", icon: "󰘚",
            rows: [
                { id: "power",        icon: "󰐥", title: "Power menu",    kind: "menu",
                  sub: "sleep, hibernate, shut down, reboot, log out" },
                { id: "powerprofile", icon: "󰾅", title: "Power profile", kind: "menu",
                  sub: "how hard the machine is allowed to run" },
                { id: "about",        icon: "󰋼", title: "About",         kind: "action" }
            ]
        },

        "system/power": {
            title: "Power menu", icon: "󰐥",
            rows: PowerMenu.items.map(p => ({ id: p.key, icon: p.icon, title: p.label, kind: "action" }))
        },

        // "choice" and not "action": one of the three is always in force, and
        // that is what the tick on a choice row says. _decorate is what marks
        // it, from PowerProfiles.current.
        "system/powerprofile": {
            title: "Power profile", icon: "󰾅",
            rows: PowerProfiles.items.map(p => ({ id: p.value, icon: p.icon, title: p.label, kind: "choice" }))
        },

        "theme/fonts": { title: "Fonts",     icon: "󰛖", list: "fonts",  pref: "UI_FONT", renderInOwnFont: true, width: 560 },
        "theme/icons": { title: "Icons",     icon: "󰋩", list: "icons",  pref: "ICON_THEME" },
        "theme/gtk":   { title: "GTK theme", icon: "󰏘", list: "themes", pref: "GTK_THEME", width: 560 },

        "setup/defaults/browser":  { title: "Browser",  icon: "󰖟", list: "browsers",  pref: "DEFAULT_BROWSER", showDetail: true },
        "setup/defaults/terminal": { title: "Terminal", icon: "󰆍", list: "terminals", pref: "DEFAULT_TERMINAL" },
        "setup/defaults/editor":   { title: "Editor",   icon: "󰏫", list: "editors",   pref: "DEFAULT_EDITOR" },
        // No showDetail, unlike Browser: there the row's value is a command and
        // the .desktop name is the only thing that identifies it, so it earns a
        // subtitle. Here the value IS the .desktop name and the label is the
        // app's own Name= — a subtitle would repeat the row.
        "setup/defaults/pdf":      { title: "PDF viewer", icon: "󰈦", list: "pdf", pref: "DEFAULT_PDF" },

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
                // The trailing slot, not a subtitle: this is a menu row, and
                // menu rows draw no second line. Same move as _decorate's.
                trail: ms.length + " variants" + (anyActive ? " · in use" : ""),
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
    //
    // Every one of these used to be written into `sub`, and as of 2026-09-12
    // they go into `trail` instead — the right-aligned slot. The panel draws no
    // subtitle under a menu row any more (Ahaan: remove "the subtext in each
    // category"), and these are all menu rows, so writing them to `sub` would
    // simply lose them. `trail` is the right home regardless: this is live
    // STATE, not a description of the label, which is exactly the distinction
    // the trailing slot was introduced for.
    //
    // Note that the rows which are NOT decorated still carry their descriptive
    // `sub` in the page definitions above, and still should — SEARCH reads it
    // (see root.search), which is how "privacy" finds the Security page. It is
    // only never drawn.
    function _decorate(key, r) {
        // Mid-recording the only useful thing this row can do is stop, so it
        // stops being a door and becomes the button. kind goes menu -> action,
        // which routes it to _action("tools/capture/screenrecord") below
        // instead of descending into the target picker.
        if (key === "tools/capture" && r.id === "screenrecord" && root.recording)
            return { id: r.id, icon: "󰝤", title: "Stop recording", kind: "action",
                     trail: "recording" }

        if (key === "security/firewall" && r.kind === "menu") {
            const fw = root.fwState
            if (r.id === "zone" && fw.ZONE)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         trail: fw.ZONE + (fw.IFACE ? " on " + fw.IFACE : "") }
            if (r.id === "services" && fw.ALLOWED !== undefined)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         trail: fw.ALLOWED + " allowed"
                               + (fw.BLOCKED !== "0" ? ", " + fw.BLOCKED + " blocked" : "") }
            return r
        }
        // The Security row and the Fingerprints page both say how many are
        // enrolled rather than restating what a fingerprint is.
        if (key === "security" && r.id === "fingerprints") {
            const st = root.fpState
            if (st.AVAILABLE === "no")
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         trail: st.REASON || "no reader" }
            if (st.COUNT !== undefined)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         trail: st.COUNT === "0" ? "none enrolled"
                            : st.COUNT === "1" ? "1 enrolled"
                            : st.COUNT + " enrolled" }
            return r
        }
        if (key === "security/fingerprints") {
            const st = root.fpState
            if (r.id === "delete" && st.COUNT !== undefined)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         trail: st.COUNT === "0" ? "nothing enrolled yet"
                            : st.COUNT + " enrolled" }
            // Only worth saying when it is about to stop working.
            if (r.id === "add" && st.FREE === "0")
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         trail: "all ten slots are full" }
            return r
        }
        // Which of the three is in force. Read straight from PowerProfiles
        // rather than cached here, so the tick is right even when something
        // else moved the profile — the battery panel's own switcher does, and
        // powerprofilesctl from a terminal does too.
        if (key === "system/powerprofile")
            return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                     value: r.id, active: r.id === PowerProfiles.current }

        // And the row above it says which, so the page only has to be opened
        // to CHANGE the profile rather than to find out what it is.
        if (key === "system" && r.id === "powerprofile") {
            const hit = PowerProfiles.items.filter(p => p.value === PowerProfiles.current)
            if (hit.length > 0)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         sub: r.sub, trail: hit[0].label }
            return r
        }

        // How many the palette actually keeps — the one thing that says whether
        // the shortlist is worth opening.
        //
        // A bare count and NOT "9 of 110", which is what this used to say. The
        // two pages read different collections now, so the "All" total is not
        // the set this page chose from — it includes Ahaan's own images, which
        // are never ranked. A denominator that is not the denominator is worse
        // than none. The listing has to have landed; until it does the row says
        // nothing rather than a wrong number.
        if (key === "theme/wallpaper" && r.id === "palette") {
            const hit = root.lists["theme/wallpaper/palette"]
            if (hit !== undefined && hit.length > 0)
                return { id: r.id, icon: r.icon, title: r.title, kind: r.kind,
                         sub: r.sub, trail: hit.length === 1 ? "1 match"
                                                            : hit.length + " matches" }
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
            // A page that holds the same rows as another one answers nothing
            // extra and doubles every hit — see the by-palette wallpaper page.
            // Only ever skipped as a NEIGHBOUR, never as the scope: typing on
            // that page has to search that page, or the one list on this card
            // you cannot filter would be the longest one.
            if (key !== scopeKey && root.pages[key].noSearch) continue
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
                    id: r.id, icon: r.icon, iconFont: r.iconFont || "",
                    title: r.title, kind: r.kind,
                    value: r.value, detail: r.detail, active: r.active === true,
                    font: r.font, pageKey: key,
                    // The trailing slot is the page a hit lives on — except on
                    // a wallpaper, where the row's own trail is its THEME and
                    // that is the only thing separating one hit from another.
                    // Searching "omarchy" matches twenty-two files all named
                    // omarchy, one per theme; with the path there instead they
                    // came back as twenty-two identical rows, and inside the
                    // page (where the path is empty, being the scope) as
                    // twenty-two rows with no annotation at all. Measured on
                    // screen, which is the only way this was ever going to be
                    // noticed. Ahaan's own images carry no theme, so they fall
                    // back to the path and still say where they are.
                    trail: ((r.thumb || "") !== "" && (r.trail || "") !== "") ? r.trail : path,
                    // A wallpaper hit keeps its picture, for the reason the
                    // palette hit below keeps its dots: the thumbnail is the
                    // row's identity, not secondary text competing with the
                    // trailing slot.
                    thumb: r.thumb || "",
                    // A palette hit keeps its three dots. The rule one line
                    // below — results carry no subtitle, the trailing slot is
                    // the page they live on — is about two kinds of secondary
                    // TEXT competing; the swatch is the row's identity, the
                    // same way `font` renders a font hit in its own face, and
                    // searching "gruv" from the root should not return a
                    // colourless row.
                    swatch: r.swatch || [],
                    // Results carry no subtitle as a rule — they use the
                    // trailing slot for the page they live on instead, and a
                    // subtitle there would be two kinds of secondary text on
                    // one row. A keybind is the exception, because its
                    // subtitle is not description, it is the ANSWER: searching
                    // "lock" and being shown a bare "SUPER + L" tells you what
                    // is bound and not what it does, which is the whole reason
                    // this page parses the config instead of asking hyprctl.
                    // (The example used to be "wall" / "ALT + W"; that bind is
                    // gone — the wallpaper picker is a page on this card now.)
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
        // Listings marked `defer` go to the BACK of the queue rather than
        // being skipped. NOTHING is marked that way any more, and the flag is
        // kept because the next expensive listing will want it.
        //
        // The two wallpaper pages were the only ones. The reason was a cold
        // cache: wallpapers.sh quantised every image the first time it saw it
        // (~3s), _pump runs one listing at a time, and queued in tree order
        // that stall sat in front of the fonts listing, which is the one search
        // actually needs early. On 2026-09-19 the colour scorer was deleted
        // outright — "By palette" is one directory read now — and both pages
        // became two find(1) calls. Measured over the 57-image set: 19ms for
        // "All", 21ms for "By palette", against 519ms and a 3s cold scan
        // before. Nothing that costs 19ms deserves to be queued last.
        const deferred = []
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
            if (!pg.list || pg.fw || pg.fprint) continue
            if (pg.defer) deferred.push(key)
            else          root._queue.push(key)
        }
        root._queue = root._queue.concat(deferred)
        root._pump()
    }

    function ensure(key) {
        // Entering the firewall page re-reads it, so a change made elsewhere
        // (or by the previous visit) is reflected rather than remembered.
        if (key === "security/firewall") root.refreshFirewall()
        if (key === "security" || key === "security/fingerprints") root.refreshFingerprints()
        // Same reason: the battery panel's own switcher and powerprofilesctl
        // from a terminal both move this behind our back, so the page reads it
        // rather than trusting what it last saw.
        if (key === "system" || key === "system/powerprofile") PowerProfiles.refresh()
        // The by-palette wallpaper page is the one listing that goes stale
        // while the menu is OPEN: the palette can be changed a few rows away,
        // on Theme -> Palette, and the page IS that palette's directory — so
        // changing it does not reorder the page, it replaces the page. Dropped
        // from the cache on the way in and re-read, rather than trusted from
        // whenever it was last fetched.
        //
        // Both keys, because both are entered and both show a stale answer:
        // the page itself, and the door above it, whose row carries the COUNT
        // in its trailing slot. Two fetches when walking through the door into
        // the page, and that is the whole cost — one find(1) over one
        // directory, measured at 21ms.
        if (key === "theme/wallpaper" || key === "theme/wallpaper/palette") {
            const k = "theme/wallpaper/palette"
            if (root.lists[k] !== undefined) {
                const next = ({})
                for (const kk in root.lists) if (kk !== k) next[kk] = root.lists[kk]
                root.lists = next
            }
            // Falls through to the queue below, which picks it up because the
            // entry is gone now. Deliberately NOT root.refresh(k), which calls
            // straight back into ensure() and would recurse.
            if (key !== k) { root._queue = [k].concat(root._queue.filter(q => q !== k)); root._pump() }
        }
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
                  : (p.list === "wallpapers")      ? q + "/wallpapers.sh list all"
                  : (p.list === "wallpapers-by-palette") ? q + "/wallpapers.sh list by-palette"
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

    // ── what a listing row is drawn with ──────────────────────────────────
    // A glyph per row where a font has one, and the page's own glyph where none
    // does. Glyphs and not the apps' own icons, which this briefly did instead:
    // an icon is a themed PNG that ignores the palette, and Ahaan's call is that
    // every mark in this menu should take the pywal accent and fade with the
    // selection like the rest of the column. A glyph is text, so it does.
    //
    // The table is here and not in ui-prefs.sh for the same reason every other
    // glyph in this file is here — which codepoint stands for a thing is a
    // drawing decision, and the scripts stay drawing-free.
    //
    // Unmapped is not a gap to fill with an approximation. nano, helix, micro,
    // zed, gedit and kate have no mark in any installed font, Zen Browser has
    // none either, and no terminal emulator does — the page's own pencil,
    // globe and console say what those rows are honestly, where a borrowed logo
    // would say something false. Ahaan asked for exactly that for nano, Zen and
    // the terminals. (The Nerd Font does carry U+E838 "dev-nano", but it draws
    // a screw, not GNU nano.)
    //
    // `font` is the family the glyphs in that table live in. The editors come
    // out of the Nerd Font every shell already draws with, so they need none.
    // The browsers do not: Brave's mark exists only in Font Awesome Brands, at
    // U+E63C — which in JetBrainsMono Nerd Font is "seti-bsl", a different icon
    // entirely — so naming the family is what stops the row drawing the wrong
    // thing. Chrome's mark is in both and is taken from Font Awesome too, so the
    // two browser rows are one family and one weight.
    readonly property var _glyphs: ({
        "editors": ({
            "vim":    "",   // custom-vim
            "nvim":   "",   // custom-neovim
            "codium": "",   // dev-vscodium
            "code":   "",   // dev-vscode
            "emacs":  ""    // custom-emacs
        }),
        // Keyed on the COMMAND's basename, not the command: a browser's value is
        // whatever its .desktop puts in Exec=, which is "brave" on one machine
        // and "/usr/bin/brave-browser" on the next. The basename is the part
        // that identifies it.
        "browsers": ({
            "brave":           "",   // fa-brands brave
            "brave-browser":   "",
            "chromium":        "",   // fa-brands chrome
            "chrome":          "",
            "google-chrome":   "",
            "google-chrome-stable": ""
        })
    })

    readonly property var _glyphFonts: ({ "browsers": "Font Awesome 7 Brands" })

    function _rowGlyph(page, value) {
        const t = root._glyphs[page.list]
        if (!t) return ""
        const base = String(value).substring(String(value).lastIndexOf("/") + 1)
        return t[base] || ""
    }

    function _rowGlyphFont(page, value) {
        return root._rowGlyph(page, value) === "" ? "" : (root._glyphFonts[page.list] || "")
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
                // The page's glyph is the FALLBACK, not the rule: a list of
                // editors under one pencil says the same thing four times and
                // nothing about which row is which. _rowGlyph answers for the
                // ones a font can name and leaves the rest to the page.
                id: f[0], icon: root._rowGlyph(p, f[0]) || p.icon,
                iconFont: root._rowGlyphFont(p, f[0]),
                title: f[1] || f[0], sub: "",
                // "multi" is the firewall's allowed-services list: more than one
                // row is marked at a time and activating one toggles it, rather
                // than moving a single selection.
                kind: p.multi ? "multi" : "choice", value: f[0],
                detail: p.showDetail ? (f[2] || "") : "",
                // The palette page's preview: the same third column every other
                // listing puts a subtitle in, holding "#bg,#accent,#fg". Split
                // here rather than in the panel so the view is handed colours
                // and never a format — and empty everywhere else, which is what
                // keeps the delegate's swatch row out of the layout entirely.
                swatch: p.swatch ? String(f[2] || "").split(",").filter(c => c !== "") : [],
                // The wallpaper pages' preview, and it is the row's own value:
                // wallpapers.sh lists absolute paths, which is both what
                // apply-wallpaper.sh takes and what Qt can draw directly.
                // Empty everywhere else, which is what keeps the delegate's
                // Image out of the other listings entirely — a Loader gated on
                // this rather than an invisible Image per row on a 276-family
                // font list.
                thumb: p.thumbs ? (f[0] || "") : "",
                // The third column is the THEME on a wallpaper page, and it
                // goes to the trailing slot rather than to `detail`, which
                // nothing draws. It is the one thing the filename cannot say:
                // four themes ship a background called "omarchy" and nine name
                // their first one "1-<something>", so without it the list has
                // repeated labels and no way to tell them apart. Empty for
                // Ahaan's own images, which belong to no theme.
                trail: p.thumbs ? (f[2] || "") : "",
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
        // Cheap for the same reason (one `powerprofilesctl get`), and the
        // System page's own row names the profile in force.
        PowerProfiles.refresh()
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
            // A wallpaper is not a ui-prefs preference either: it is a state
            // file plus a whole colour pipeline, and apply-wallpaper.sh has
            // always been the one thing that runs it. Wallpapers.qml is the
            // caller, exactly as it was from finder's wallpaper mode — this
            // page replaced that mode's list, not its plumbing.
            if (fp && fp.thumbs) {
                Wallpapers.apply(row.value)
                root._markWallpaper(row.value)
                return false
            }
        }

        // No script and no re-read: PowerProfiles.set() moves `current` itself,
        // and _decorate reads the tick straight off it — so the mark lands in
        // the same frame as the press.
        if (row.kind === "choice" && key === "system/powerprofile") {
            PowerProfiles.set(row.value || row.id)
            return false
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

    // ── the wallpaper that is up ──────────────────────────────────────────
    // Moves the "current" mark in BOTH cached wallpaper listings rather than
    // re-running the script, for the reason the choice rows above patch in
    // place: re-fetching empties the ListView and repopulates it a moment
    // later, which reads as the menu glitching. Nothing else about either
    // listing can have changed yet — the only thing that moved is which image
    // is up, and we are the ones who moved it.
    //
    // Re-ranking the by-palette page is NOT done here, and deliberately not.
    // Under the "pywal" palette a new wallpaper re-derives the colours, which
    // rewrites ~/.cache/wal/colors.json — so _paletteChanged below sees it and
    // re-reads the page off the real event. Under a chosen palette the colours
    // do not move, the shortlist cannot have changed, and the only thing that
    // needed updating is the "current" mark this function just patched.
    readonly property var _wallKeys: ["theme/wallpaper/all", "theme/wallpaper/palette"]

    function _markWallpaper(path) {
        const next = ({})
        for (const k in root.lists) next[k] = root.lists[k]
        for (let i = 0; i < root._wallKeys.length; i++) {
            const k = root._wallKeys[i]
            if (next[k] === undefined) continue
            next[k] = next[k].map(r => Object.assign({}, r, { active: r.value === path }))
        }
        root.lists = next
        for (let j = 0; j < root._wallKeys.length; j++)
            if (root.lists[root._wallKeys[j]] !== undefined)
                root._setGrouped(root._wallKeys[j], root._regroup(root._wallKeys[j]))
    }

    // ── the shortlist follows the palette ────────────────────────────────
    // "By palette" is computed by wallpapers.sh from two inputs — the colours
    // in ~/.cache/wal/colors.json, which the ranking is measured against, and
    // the chosen palette NAME in ui.conf, which decides whose backgrounds
    // lead. Both move when the palette changes, and the page is a LISTING
    // rather than a binding, so nothing repaints it.
    //
    // Reported: changing the palette left the page showing the previous
    // palette's shortlist until the whole menu was closed and reopened,
    // because prefetchAll() on open was the only thing that ever re-ran the
    // script. The fix is in ensure() — the page is re-read when it is ENTERED.
    //
    // An earlier cut watched instead: a revision counter on WalColors for the
    // colours, a new UiConfig.palette for the name, two Connections and a
    // timer to coalesce them, so the page updated the instant the palette
    // moved. It worked, and it is gone. Ahaan did not need instant — "it can
    // refresh by the time i go out of palettes and into wallpapers" — and
    // re-reading on entry is the better answer even so: it reads both inputs
    // at the moment of use, where watching them meant being right about two
    // separate signals. Testing the watched version found exactly that bug,
    // with the colours already changed and only the name still to move.

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
        // Sleep, hibernate, shut down, reboot, log out. Matched by PREFIX and
        // not by five cases in the switch below, because the five are
        // PowerMenu.items — writing them out here would be the second copy of
        // that list this page exists to avoid, and a sixth action added there
        // would arrive as a row that does nothing.
        //
        // PowerMenu.run() is the same call SUPER+Escape makes through finder's
        // powermenu mode, because it IS that mode's back end. Closing the menu
        // afterwards is right for all five: four end the session, and the
        // fifth leaves nothing to come back to.
        if (path.indexOf("system/power/") === 0) {
            PowerMenu.run(path.substring("system/power/".length))
            return true
        }

        // The nine screenrecord leaves — three targets x three soundtracks —
        // matched by PREFIX rather than written out as nine cases. The path
        // segments ARE the script's two flags (full|region|window and
        // none|desktop|both), which is why the page ids were chosen to spell
        // them: the row a user pressed and the command that runs are the same
        // two words, so the two cannot drift apart the way nine hand-written
        // cases would.
        //
        // BEFORE the switch, not inside it. It was written inside the switch
        // body but under no `case` label, which JavaScript accepts and never
        // executes — every one of the nine rows silently did nothing, while the
        // screenshot rows beside them (real `case` labels) worked, which is
        // exactly what made it look like a screen-recording problem rather than
        // a placement one. The system/power/ handler above is the model.
        if (path.indexOf("tools/capture/screenrecord/") === 0) {
            const seg = path.substring("tools/capture/screenrecord/".length).split("/")
            if (seg.length === 2)
                root._capture("screenrecord.sh", "start --target=" + seg[0] + " --audio=" + seg[1])
            return true
        }

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
        case "system/about":    root._term("about",           "about-system.sh",    false); break

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

        // ── Tools ─────────────────────────────────────────────────────────
        // All four shell out, and all four run the SAME command the keybind
        // runs — not a second copy of it. hyprpicker is the one that is a bare
        // binary rather than a script in scriptDir, exactly as ALT+C has it, so
        // it is wrapped by hand instead of going through _capture.
        case "tools/colorpicker":
            root._sh(root._q(root.scriptDir + "/capture-wait.sh") + " hyprpicker -a")
            break
        case "tools/ocr":         root._capture("ocr-region.sh", ""); break

        case "tools/capture/screenshot/region":     root._capture("screenshot.sh", "region"); break
        case "tools/capture/screenshot/window":     root._capture("screenshot.sh", "window"); break
        case "tools/capture/screenshot/fullscreen": root._capture("screenshot.sh", "output"); break

        // The decorated Stop row. No wait-for-menu wrapper: stopping draws
        // nothing on screen, so there is nothing for the menu to be in front of.
        case "tools/capture/screenrecord":
            root._sh(root._q(root.scriptDir + "/screenrecord.sh") + " stop")
            break

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

    // A capture tool, launched THROUGH capture-wait.sh so it does not draw its
    // picker over a settings menu that has not finished unmapping. Every row
    // under Tools goes out this way; see that script's header for the
    // measurement. args is a pre-split flag string, not user input — each word
    // is quoted separately so a flag never arrives as one argument.
    function _capture(script, args) {
        var cmd = root._q(root.scriptDir + "/capture-wait.sh") + " " +
                  root._q(root.scriptDir + "/" + script)
        const parts = String(args || "").split(" ").filter(a => a !== "")
        for (let i = 0; i < parts.length; i++) cmd += " " + root._q(parts[i])
        root._sh(cmd)
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
