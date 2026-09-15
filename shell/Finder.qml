pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// Visual port of walker's "spotlight" theme (walker/themes/spotlight/*):
// dark rounded floating box, plain input, icon+title+subtitle result rows,
// a preview pane that appears next to the list for files, and a dim
// keybind-hint footer. Backed entirely by local tools (qalc, fd/fzf, .desktop
// parsing, wl-clipboard) instead of elephant/walker themselves.
Item {
    id: root

    property int screenWidth: 1920
    property int screenHeight: 1080

    property bool shown: false
    property string mode: "default"   // "default" | "emoji" | "clipboard" | "powerprofiles" | "powermenu" | "settings"

    // Settings is the one mode that does not use the result list below. It is a
    // control surface, not a search result, so it is drawn as one of the
    // taskbar's dropdown panels — see SettingsPanel.qml. Everything from the
    // input down is hidden for it and the panel owns its own input and keys.
    readonly property bool settingsMode: root.mode === "settings"

    // The password box takes the settings menu's place rather than sitting on
    // top of it: Ahaan asked for the menu to close when a password is needed,
    // and one card on screen at a time is also simply clearer about what is
    // being asked. Reached only from Settings.authRequired, never from IPC.
    readonly property bool passwordMode: root.mode === "password"

    // The fingerprint enrol box, which takes the same place for the same
    // reason. Reached only from Settings.fingerprintEnrollRequested, which is
    // itself only raised once the password box has verified a password.
    readonly property bool fingerprintMode: root.mode === "fingerprint"

    // What Settings.verified() should be told once the password box accepts a
    // password in its verify-only flow. Empty for every other flow.
    property string pendingVerify: ""
    property string query: ""
    property int selectedIndex: 0
    property var displayResults: []   // unified row list, see _rebuild()

    // One height for every row in the list, taken from the tallest kind the
    // current results actually contain. This is SettingsPanel's panel.rowH and
    // it is here for its reason: a height measured per ROW makes a mixed list
    // ragged, a height measured per LIST makes it read as one block. 44 is the
    // dense row — an app, an emoji, a power profile, all of which
    // are a word and a mark — and 58 is the one with a second line under it,
    // which now only a file path, a calculation and a clipboard hit ask for.
    readonly property int rowH: root.displayResults.some(r => (r.subtitle || "") !== "")
                                ? Theme.rowTall : Theme.rowHeight
    property var clipboardPreview: null   // {type:"image", source} for clipboard-mode image entries

    // Unified preview object regardless of which mode/provider produced it.
    //
    // There was a third: wallpaperPreview, which showed the image the selection
    // was on in wallpaper mode. That mode moved into the settings menu on
    // 2026-09-15 (Settings.qml, Theme -> Wallpapers), where the row draws its
    // own thumbnail and there is no pane to put a big one in.
    readonly property var effectivePreview: root.mode === "clipboard" ? root.clipboardPreview
        : FileSearch.preview

    // The settings card's prompt, in every mode: "Search <what this page
    // lists>…", sentence case, one ellipsis CHARACTER rather than three stops.
    // With the footer gone this line is the only text on an empty card, so it
    // is also the only thing that says which mode is open — the same job
    // SettingsPanel gives it ("Search settings…" at the root, "Search setup…"
    // inside Setup). They all filter as you type, including the two power
    // lists, so they all say Search.
    readonly property var _placeholders: ({
        "default":       "Search applications…",
        "emoji":         "Search emoji…",
        "clipboard":     "Search clipboard…",
        "powerprofiles": "Search power profiles…",
        "powermenu":     "Search power menu…",
        "filesearch":    "Search files…"
    })

    // ── Open / close ─────────────────────────────────────────────────
    // The modes anything may ask for over the socket. password and fingerprint
    // are deliberately absent: both are raised from inside this file once
    // something has been authorised, and anything running as this user can
    // write to /tmp/finder.sock — a password box opened on request is a
    // password box asked for by whatever wanted the password.
    readonly property var _openable: ["default", "emoji", "clipboard",
                                      "powerprofiles", "powermenu",
                                      "filesearch", "settings"]

    function openMode(m) {
        // A mode that no longer exists is the reason this guard is here:
        // "wallpaper" was one until 2026-09-15, and a hyprland.lua that has
        // not been reloaded since still sends it. Without this the card came
        // up on an empty list with a blank prompt — a surface that says
        // nothing and does nothing, which is worse than the keybind appearing
        // dead. Same class as the stale IPC path removed on 2026-09-14.
        if (root._openable.indexOf(m) < 0) {
            console.warn("finder: ignoring unknown open mode:", m)
            return
        }
        if (root.shown && root.mode === m) { close(); return }
        // There is no longer anything to measure here. Four consts used to
        // capture what was on screen BEFORE the mode changed — the size the
        // next card grew out of — and both halves of that morph are gone:
        // neither direction between the launcher box and the settings card
        // animates any more. See the settings branch below.
        root.mode = m
        root.query = ""
        root.selectedIndex = 0
        root.displayResults = []
        root.shown = true
        if (m === "clipboard") ClipboardHistory.refresh()
        // ensure() before _rebuild(), for the two indexes that are now built on
        // first use rather than at startup. Both are idempotent and both are
        // async, so this open draws an empty list for a frame and fills it from
        // the singleton's own change signal — the same path a query typed
        // during the very first scan has always taken.
        if (m === "emoji") { EmojiIndex.ensure(); root._rebuild() }
        if (m === "default" || m === "filesearch") AppIndex.ensure()
        // powerprofiles/powermenu both list everything immediately
        // on open (type-to-filter OR scroll, per explicit request) rather
        // than starting blank like default-mode app search does.
        if (m === "powerprofiles") { PowerProfiles.refresh(); root._rebuild() }
        if (m === "powermenu") root._rebuild()
        if (m === "settings") {
            settingsPanel.reset()
            // The box-becomes-card morph is gone from this direction.
            // settingsPanel.enterFrom() no longer exists: the settings card
            // appears complete, in one frame, and the launcher box is dropped
            // in that same frame rather than fading out behind it — see the
            // box's own opacity Behavior, which is disabled in settings mode
            // for exactly this. Two surfaces crossfading is the opposite of
            // what Ahaan pointed at in omarchy.
            //
            // Every listing is fetched up front, not on the page that shows it:
            // search reaches the whole subtree, so a font has to be findable
            // from the root without ever opening Fonts. They arrive one at a
            // time, so this does not hold up the panel appearing.
            Settings.prefetchAll()
            Settings.refreshState()
        }
        // And there is no `else if (fromSettings)` branch any more. It used to
        // pin the incoming launcher box to the outgoing settings card's size,
        // the mirror of the morph above. The settings card is gone on the frame
        // the mode changes rather than shrinking away at a size anything could
        // grow out of, so there is nothing left to grow out of; the box appears
        // at its own size with its own fade.
        inputFocusTimer.start()
    }

    function close() {
        root.shown = false
        root.query = ""
        FileSearch.preview = null
    }

    Timer {
        id: inputFocusTimer
        interval: 10
        onTriggered: root.passwordMode ? passwordPrompt.focusInput()
                   : root.fingerprintMode ? fingerprintPrompt.focusInput()
                   : root.settingsMode ? settingsPanel.focusInput()
                   : input.forceActiveFocus()
    }

    // ── IPC — persistent socket, toggled by hyprland.lua keybinds ────
    property var ipcProc: Process {
        id: ipcProc
        running: true
        command: ["bash", "-c",
            "rm -f /tmp/finder.sock && socat UNIX-LISTEN:/tmp/finder.sock,fork STDOUT"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const cmd = data.trim()
                if (cmd.startsWith("open:")) root.openMode(cmd.slice(5))
                else if (cmd === "close") root.close()
                // The polkit agent announcing a waiting request. The id is
                // all that travels on this socket — anything running as this
                // user can write here, so the request itself is fetched from
                // the agent over its own socket. See PolkitLink.qml.
                else if (cmd.startsWith("polkit:")) polkitLink.announce(cmd.slice(7))
            }
        }
    }

    // ── Query changes drive each provider ─────────────────────────────
    onQueryChanged: root._rebuild()

    function _rebuild() {
        root.selectedIndex = 0
        if (root.mode === "emoji") {
            const hits = EmojiIndex.search(root.query, 50)
            root.displayResults = hits.map(e => ({
                kind: "emoji", emojiGlyph: e.emoji, title: e.name, subtitle: "", data: e
            }))
            return
        }
        if (root.mode === "clipboard") {
            const hits = ClipboardHistory.search(root.query, 50)
            root.displayResults = hits.map(e => ({
                kind: "clipboard", emojiGlyph: "", title: e.preview, subtitle: "", data: e
            }))
            return
        }
        if (root.mode === "powerprofiles") {
            const q = root.query.toLowerCase()
            root.displayResults = PowerProfiles.items
                .filter(p => !q || p.label.toLowerCase().includes(q))
                // `active`, not a "current" subtitle. The settings card marks
                // the chosen one of a set with a tick in the accent (see its
                // choice rows) and says nothing else about it; a subtitle
                // saying "current" both repeated that mark in words and pushed
                // all three rows from 44 to 58 to carry one of them.
                .map(p => ({
                    kind: "powerprofile", emojiGlyph: p.icon, title: p.label,
                    subtitle: "", active: p.value === PowerProfiles.current,
                    data: p
                }))
            return
        }
        if (root.mode === "powermenu") {
            const q = root.query.toLowerCase()
            root.displayResults = PowerMenu.items
                .filter(p => !q || p.label.toLowerCase().includes(q))
                .map(p => ({ kind: "powermenuitem", emojiGlyph: p.icon, title: p.label, subtitle: "", data: p }))
            return
        }
        if (root.mode === "filesearch") {
            // Dedicated mode (ALT+F), not the old "/"-prefix — FileSearch
            // itself is already restricted to non-hidden files under $HOME
            // (fd's own defaults, see FileSearch.qml).
            if (root.query.length >= 2) {
                FileSearch.search(root.query, 15)
            } else if (FileSearch.results.length > 0) {
                // Guarded: unconditionally reassigning `[]` here would refire
                // onResultsChanged below on every call (a new array is never
                // considered equal to the old one), which calls _rebuild()
                // again, which clears it again — infinite synchronous
                // recursion (RangeError: Maximum call stack size exceeded),
                // confirmed live. Only clear when there's actually something
                // to clear, and route rendering through the non-recursive
                // _renderFileSearch() below rather than back through here.
                FileSearch.results = []
            }
            root._renderFileSearch()
            return
        }
        // default mode: app search + calculator, no file search here anymore
        // (moved to its own "filesearch" mode/keybind above).
        if (!root.query) { root.displayResults = []; return }

        Calc.evaluate(root.query)
        root._combineDefault()
    }

    // Render-only step for filesearch results — deliberately does not touch
    // FileSearch.results or call FileSearch.search(), so it's safe to call
    // from the onResultsChanged handler below without looping back into it.
    function _renderFileSearch() {
        root.displayResults = FileSearch.results.map(f => ({
            kind: "file", icon: "", title: f.name, subtitle: f.subtext, data: f
        }))
    }

    // A query counts as "doing math" once it has both a digit and an
    // operator — "12+" (still typing) as much as "12+3" (resolved). Used to
    // suppress app/file/websearch rows so the calculator result is the only
    // thing shown while the user is mid-calculation.
    function _looksLikeCalc(q) {
        return /[0-9]/.test(q) && /[+\-*/^%]/.test(q)
    }

    // Calc and FileSearch resolve async; recombine whenever either updates,
    // but only if the query hasn't moved on since we asked.
    Connections {
        target: Calc
        function onTokenChanged() { if (root.mode === "default" && root.query) root._combineDefault() }
    }
    Connections {
        target: FileSearch
        function onResultsChanged() { if (root.mode === "filesearch") root._renderFileSearch() }
    }
    // AppIndex's .desktop scan is also async (Process spawn latency), so the
    // very first query typed before it finishes would otherwise permanently
    // miss app results — same class of bug as the ClipboardHistory one below.
    Connections {
        target: AppIndex
        function onAppsChanged() { if (root.mode === "default" && root.query) root._combineDefault() }
    }
    // ClipboardHistory.refresh() (called from openMode()) is async — rebuild
    // once it resolves so an untyped clipboard-mode open shows history
    // immediately, matching walker's `empty = ["clipboard"]` behavior.
    Connections {
        target: ClipboardHistory
        function onEntriesChanged() { if (root.mode === "clipboard") root._rebuild() }
    }
    // Same async-load race as AppIndex above, for the emoji JSON.
    Connections {
        target: EmojiIndex
        function onEmojiChanged() { if (root.mode === "emoji") root._rebuild() }
    }
    // Same again for the `powerprofilesctl get` round-trip re-marking the
    // "current" row once it actually resolves (openMode's immediate _rebuild()
    // runs before the async call can have finished).
    Connections {
        target: PowerProfiles
        function onCurrentChanged() { if (root.mode === "powerprofiles") root._rebuild() }
    }

    function _combineDefault() {
        const q = root.query
        if (!q) { root.displayResults = []; return }

        const rows = []

        if (Calc.result && Calc.expression === q) {
            rows.push({ kind: "calc", emojiGlyph: "", title: Calc.result, subtitle: Calc.expression, data: null })
        }

        // Once the query reads as arithmetic (digit + operator), show only
        // the calculation — no apps/websearch cluttering the result for
        // what's clearly a math expression in progress.
        if (!root._looksLikeCalc(q)) {
            for (const a of AppIndex.search(q, 8)) {
                rows.push({ kind: "app", icon: a.iconPath, title: a.name, subtitle: "", data: a })
            }
            // The label used to be "Google" with the whole sentence under it
            // as a subtitle, which is the pattern the settings pass deleted
            // everywhere: a second line that restates the first at greater
            // length. The sentence IS the row, so it is the title, and the
            // default page keeps its dense 44px rows as long as no calculation
            // is on it.
            rows.push({ kind: "websearch", emojiGlyph: "", title: "Search the web for \"" + q + "\"", subtitle: "", data: q })
        }

        const prevSel = root.selectedIndex
        root.displayResults = rows
        root.selectedIndex = Math.min(prevSel, rows.length - 1)
    }

    // Load a preview whenever the selection lands on a file row (default
    // mode) or an image row (clipboard mode).
    function _maybePreview() {
        FileSearch.preview = null
        root.clipboardPreview = null
        const r = root.displayResults[root.selectedIndex]
        if (root.mode === "filesearch") {
            if (r && r.kind === "file" && !r.data.isDir) FileSearch.previewFor(r.data.path)
        } else if (root.mode === "clipboard") {
            if (r && r.kind === "clipboard" && r.data.kind === "image") {
                root.clipboardPreview = { type: "image", source: "file://" + r.data.path }
            }
        }
    }
    onSelectedIndexChanged: root._maybePreview()
    onDisplayResultsChanged: root._maybePreview()

    // ── Activation ────────────────────────────────────────────────────
    function activate(index) {
        const r = root.displayResults[index]
        if (!r) return
        switch (r.kind) {
            case "app":
                AppIndex.launch(r.data)
                break
            case "file":
                FileSearch.open(r.data.path, r.data.isDir)
                break
            case "calc":
                copyToClipboard(r.title)
                break
            case "websearch":
                // The browser chosen under Settings -> Defaults -> Browser, not
                // xdg-open's handler. This used to be a hardcoded "zen-browser";
                // it is UiConfig.browser now so that picking a browser in the
                // settings menu actually changes where finder searches.
                //
                // Through a shell, and detached, for two reasons: the value comes
                // from a .desktop Exec line so it may carry flags of its own
                // ("chromium --foo") which argv[0] cannot express, and a browser
                // launched on Quickshell's stdout pipe dies of SIGPIPE on its
                // first write once this Process exits. Same rule as
                // AppIndex.launch().
                openProc.command = ["bash", "-c",
                    "setsid " + UiConfig.browser + " \"$1\" </dev/null >/dev/null 2>&1 &",
                    "_", "https://www.google.com/search?q=" + encodeURIComponent(r.data)]
                openProc.running = true
                break
            case "emoji":
                EmojiIndex.copy(r.data.emoji)
                break
            case "clipboard":
                ClipboardHistory.copyBack(r.data)
                break
            case "powerprofile":
                PowerProfiles.set(r.data.value)
                break
            case "powermenuitem":
                PowerMenu.run(r.data.key)
                break
        }
        root.close()
    }

    function copyToClipboard(text) {
        clipProc.command = ["bash", "-c", "printf '%s' " + "'" + String(text).replace(/'/g, "'\\''") + "'" + " | wl-copy"]
        clipProc.running = true
    }
    property var clipProc: Process { id: clipProc; running: false }
    property var openProc: Process { id: openProc; running: false }

    function moveSelection(delta) {
        if (root.displayResults.length === 0) return
        let i = root.selectedIndex + delta
        if (i < 0) i = 0
        if (i >= root.displayResults.length) i = root.displayResults.length - 1
        root.selectedIndex = i
    }

    // ── Font (ui.conf, live) ───────────────────────────────────────────
    // One token for every label in this file, so the font picked under
    // Settings -> Fonts repaints finder in place — no restart, the same way
    // WalColors repaints it when the wallpaper changes.
    readonly property string uiFont: UiConfig.fontFamily

    // ── Colors ─────────────────────────────────────────────────────────
    // There is no local palette here any more. Four colours used to be mixed
    // in this file — color0 for the card, color7 for every label, color8
    // washed at 0.08/0.25/0.3 for the preview pane and the icon tiles — and
    // the settings card next door was already drawing bg/text/accent out of
    // Theme.qml, off DIFFERENT pywal slots (background and color15). So the
    // two cards were not the same colour, on any wallpaper. Everything below
    // reads Theme now, which is the whole reason Theme exists: "so the panel
    // and the password box cannot drift apart", and finder's own box is the
    // fourth surface in that set.
    //
    // _alpha/_lighter/_darker went with them — Theme.alpha is the one left,
    // and nothing washes the accent any more.

    // The width of the card's one column: the search line, and the results
    // list under it. Everything else in the card is measured from it.
    //
    // Theme.cardWidth — the settings card's 430, where this was 644. The two
    // surfaces open from neighbouring keybinds onto the same wallpaper, and a
    // launcher half again as wide as the settings menu was the loudest
    // difference left between them. The preview modes still widen past it (see
    // listCol and previewBox below), because a file path rendered in 430 points
    // is a path with its middle missing.
    //
    // Theme.cardWidth is the settings card's OUTSIDE width, padding included,
    // so the column inside it is that less the padding on both sides. Measured
    // against a screenshot of the two: taking cardWidth as the column made
    // finder's card 470 to the settings card's 430, which is exactly the 40
    // points of padding.
    readonly property int innerW: Theme.cardWidth - Theme.pad * 2

    // ── Scrim (click outside to dismiss) ───────────────────────────────
    MouseArea {
        anchors.fill: parent
        visible: root.shown
        onClicked: root.close()
    }

    // ── Keyboard ────────────────────────────────────────────────────
    Keys.onPressed: event => {
        if (!root.shown) return
        // SettingsPanel handles every key itself, including Escape (which backs
        // out of a page before it closes the menu).
        if (root.settingsMode || root.passwordMode || root.fingerprintMode) return
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
        else if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
        else if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
        // Return is deliberately NOT handled here — see input.onAccepted.
        //
        // It used to be, and the TextInput's own onAccepted handled it too, so
        // every Return called activate() TWICE. That was invisible while every
        // activation ended in close(): the second call just re-ran the same row.
        // A menu that descends without closing makes it visible immediately —
        // one Return opened a submenu AND activated its first row. Measured
        // 2026-09-04. Up/Down/Escape stay here because a single-line TextInput
        // ignores those, so they do bubble up; Return does not.
    }

    // ── Window box ──────────────────────────────────────────────────
    Rectangle {
        id: box
        anchors.centerIn: parent
        // The settings card's radius and the settings card's ground. 30 and
        // color0 were finder's own; see the Colors note above.
        radius: Theme.cardRadius
        color: Theme.bg
        // The taskbar's panel edge, not one of finder's own: 2px of
        // alpha(color7, 0.8) is what every dropdown in taskbar/shell.qml draws,
        // and Theme.line/Theme.cardBorder are where that pair lives now — the
        // settings card, the password box and the fingerprint box already read
        // from them, so all five surfaces cannot drift apart. This box used to
        // draw 1px of darker(color8), which on most wallpapers was no edge at
        // all.
        border.width: Theme.cardBorder
        border.color: Theme.line

        // Every mode that draws a card of its own has to be listed here. The
        // fingerprint box was added without it and the launcher sat lit up
        // behind the scan card for the whole enrolment — its input line and
        // its "↑↓ navigate" footer visible either side of it. Anything that
        // adds a mode with its own surface has to come back to this line.
        opacity: (root.shown && !root.settingsMode && !root.passwordMode && !root.fingerprintMode) ? 1 : 0
        scale: (root.shown && !root.settingsMode && !root.passwordMode && !root.fingerprintMode) ? 1 : 0.94
        // The box is DROPPED for settings, not faded out.
        //
        // The settings card appears complete in one frame now, and a box fading
        // out over 190ms underneath something already fully drawn is 190ms of
        // two cards on screen at once. Gating `visible` is what makes it go on
        // the same frame the card arrives — and it is gated HERE, on a plain
        // binding, rather than by disabling the Behavior below. Both would
        // read the same, but `enabled` on a Behavior is itself a binding, and
        // whether it re-evaluates before or after the opacity change it is
        // meant to govern is not something QML promises. This cannot race: the
        // moment settingsMode is true the box is not drawn, whatever its
        // opacity is doing underneath.
        //
        // The condition is settingsMode rather than "is settings involved":
        // closing finder FROM settings leaves mode at "settings" while shown
        // goes false, so the box stays undrawn there too, and every other close
        // still fades.
        visible: opacity > 0.001 && !root.settingsMode
        // Theme.motionPage, for the password and fingerprint cards — those ARE
        // replacements for this box and still read better as a crossfade.
        Behavior on opacity { NumberAnimation { duration: Theme.motionPage; easing.type: Easing.OutCubic } }
        Behavior on scale   { NumberAnimation { duration: Theme.motionPage; easing.type: Easing.OutCubic } }
        Behavior on color   { ColorAnimation { duration: 300 } }

        // heldW/heldH pin the box to the size of the card it is taking over
        // from for one frame, so the Behaviors below have somewhere to animate
        // from. Zero means "not holding", which is why neither can legitimately
        // be 0.
        //
        // Only the password and fingerprint cards use this now. The settings
        // card used to mirror it and no longer does — it neither morphs into
        // this box nor out of it.
        property real heldW: 0
        property real heldH: 0
        width:  box.heldW > 0 ? box.heldW : content.width + Theme.pad * 2
        height: box.heldH > 0 ? box.heldH : content.height + Theme.pad * 2
        Behavior on width  { NumberAnimation { duration: Theme.motionPage; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: Theme.motionPage; easing.type: Easing.OutCubic } }

        function enterFrom(w, h) {
            if (w <= 0 || h <= 0) return
            box.heldW = w
            box.heldH = h
            boxRelease.restart()
        }
        // One frame: long enough for the new mode's rows to exist, so the
        // animation starts from a known size towards a settled one rather than
        // at a moving goalpost.
        Timer { id: boxRelease; interval: 16; onTriggered: { box.heldW = 0; box.heldH = 0 } }

        Column {
            id: content
            x: Theme.pad; y: Theme.pad
            // 16 between the search line and the list, which is the settings
            // card's own gap (its RowLayout's Layout.bottomMargin). It was 10,
            // and it separated three things; there are two now.
            spacing: 16

            // ── Search: a line, not a box ─────────────────────────────
            // What was here was a 44px rounded rectangle filled with
            // lighter(bg, 1.35), i.e. a visible input widget. The settings card
            // draws its prompt as bare text with a caret — no fill, no icon, no
            // rule under it — and a box drawn around the only field on a card
            // that has nothing else on it is chrome naming a control instead of
            // being one. Same removal as that card's search icon.
            //
            // The Item survives the Rectangle because the width rule does, and
            // it is load-bearing: the search line and the list below it are ONE
            // column and have to end on the same line — Ahaan, looking at a
            // 644-wide input sitting over a 600-wide row. So neither number is
            // written twice. root.innerW is the column, the list takes all of
            // it, and when the preview pane is out this stretches to cover the
            // list AND the preview rather than floating short in a wider card.
            Item {
                width: Math.max(root.innerW, resultsRow.visible ? resultsRow.width : 0)
                // The settings card's search line, to the pixel.
                height: 26

                TextInput {
                    id: input
                    anchors.fill: parent
                    verticalAlignment: TextInput.AlignVCenter
                    font.family: root.uiFont
                    font.pixelSize: Theme.fsInput
                    color: Theme.text
                    clip: true
                    selectionColor: Theme.alpha(Theme.accent, 0.45)
                    onTextChanged: root.query = text
                    // The ONE Return handler for this list — see the note in
                    // root's Keys.onPressed above.
                    onAccepted: root.activate(root.selectedIndex)

                    Text {
                        anchors.fill: parent
                        text: root._placeholders[root.mode] || ""
                        color: Theme.dimmer
                        font: input.font
                        verticalAlignment: Text.AlignVCenter
                        visible: input.text.length === 0
                    }
                }
            }

            // Reset input text when mode/visibility resets query externally (e.g. openMode, close)
            Connections {
                target: root
                function onQueryChanged() { if (input.text !== root.query) input.text = root.query }
            }

            // ── Content row: list (+ preview) ─────────────────────────
            Row {
                id: resultsRow
                spacing: 10
                visible: root.displayResults.length > 0

                ListView {
                    id: listCol
                    // The column, in every mode, preview or not. It used to
                    // widen to 600 whenever a preview pane came out, which was
                    // the same inconsistency the card's own width had: a list
                    // that is one width for apps and another for files does not
                    // read as one design. The card still grows for the preview
                    // — it grows by exactly the preview.
                    width: root.innerW
                    // Cap the list's own height and let it scroll instead of growing
                    // the whole window arbitrarily tall (e.g. the 50-row emoji listing).
                    height: Math.min(contentHeight, 420)
                    clip: true
                    // 2, the settings list's gap. At 4 the rows read as
                    // separate cards rather than as one block, which is the
                    // same thing the row outlines used to do there.
                    spacing: 2
                    model: root.displayResults
                    currentIndex: root.selectedIndex
                    highlightFollowsCurrentItem: true

                    // One highlight item the view places, rather than a fill
                    // drawn by each delegate — the launcher used to blink
                    // between two crossfades a row apart, and this is still the
                    // fix for that. It also still takes its look from Theme, so
                    // apps, files, emoji, clipboard and the power
                    // menus mark a selection the way the settings menu does.
                    //
                    // What changed on 2026-09-12 is what Theme now says: a 10%
                    // wash and no outline, measured off omarchy's menu. The
                    // border lines that used to be here are gone with
                    // Theme.rowBorder and Theme.rowSelLine, which no longer
                    // exist.
                    highlight: Rectangle {
                        // The view sets y and height; width is ours, and binding
                        // it to the view keeps the mark the full width of a row
                        // rather than the width of whatever is in one.
                        width: listCol.width
                        radius: Theme.rowRadius
                        color: Theme.rowSel
                    }
                    // Zero, both of them, and that is not the same as leaving
                    // them unset: unset means highlightMoveVelocity's default of
                    // 400px/s takes over and the mark glides anyway. Duration 0
                    // WITH velocity -1 is what actually pins the highlight to
                    // the current row on the frame the selection changes.
                    //
                    // This used to be Theme.motion in both, to match the
                    // settings band. It still matches it — the settings band
                    // does not travel any more either.
                    highlightMoveDuration: 0
                    highlightResizeDuration: 0
                    // Velocity and duration are alternatives and velocity is the
                    // default; -1 is what hands the timing to the durations
                    // above.
                    highlightMoveVelocity: -1
                    highlightResizeVelocity: -1
                    // The list still scrolls itself to keep the selection in
                    // view, and ApplyRange is still how: it is the range that
                    // makes the view scroll the least it can, which is what
                    // stops a step past the bottom row jumping the whole list.
                    highlightRangeMode: ListView.ApplyRange
                    preferredHighlightBegin: 0
                    preferredHighlightEnd: listCol.height

                    // The settings card's row, with finder's icons in it: a
                    // mark on the left, a label, a second line only where the
                    // information is not in the label, and a tick on the right
                    // where one row of a set is the chosen one. Same margins
                    // (14), same gap (12), same sizes and same colours as
                    // SettingsPanel's delegate, because the two cards open from
                    // neighbouring keybinds onto the same wallpaper and had no
                    // reason to be two designs.
                    //
                    // An Item rather than a Rectangle: it drew "transparent",
                    // which is a fill Qt still has to consider. Its height is
                    // the page's rowH now rather than whatever its own contents
                    // measured, which is what makes a list of results a block
                    // instead of a ladder.
                    delegate: Item {
                        id: rowDelegate
                        required property var modelData
                        required property int index
                        width: listCol.width
                        height: root.rowH

                            Row {
                                id: rowContent
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 14
                                spacing: 12

                                // Icon: emoji glyph, resolved app icon image (falls back to a
                                // Nerd Font glyph tile if it fails to load or the kind has no image).
                                Item {
                                    id: iconSlot
                                    // Theme.iconSlot, 26, not 32. A 32px icon
                                    // in a 44px row is the row; the settings
                                    // card's mark sits inside its line rather
                                    // than setting its height.
                                    width: Theme.iconSlot; height: Theme.iconSlot
                                    anchors.verticalCenter: parent.verticalCenter

                                    readonly property string kind: rowDelegate.modelData.kind
                                    readonly property bool _hasThumb: kind === "app"
                                    readonly property bool hasAppImage: iconSlot._hasThumb && appIcon.status === Image.Ready
                                    // Power profile/menu icons are Nerd Font glyphs too (see
                                    // PowerProfiles.qml/PowerMenu.qml), same rendering path as emoji.
                                    readonly property bool _hasGlyph: kind === "emoji" || kind === "powerprofile" || kind === "powermenuitem"

                                    Text {
                                        anchors.centerIn: parent
                                        visible: iconSlot._hasGlyph
                                        text: rowDelegate.modelData.emojiGlyph || ""
                                        // Dimmer than the label, one strength on
                                        // every row, exactly as the settings
                                        // card draws its icons: the mark locates
                                        // the row, the label is what is read.
                                        // The exception is an emoji, which is
                                        // not a signifier for the row — it IS
                                        // the thing being picked — so it is
                                        // drawn at full strength and two points
                                        // larger.
                                        color: iconSlot.kind === "emoji" ? Theme.text
                                                                         : Theme.alpha(Theme.text, 0.65)
                                        font.pixelSize: iconSlot.kind === "emoji" ? 19 : 17
                                        font.family: root.uiFont
                                    }
                                    Image {
                                        id: appIcon
                                        anchors.fill: parent
                                        visible: iconSlot._hasThumb && status === Image.Ready
                                        source: iconSlot._hasThumb ? (rowDelegate.modelData.icon || "") : ""
                                        fillMode: Image.PreserveAspectFit
                                        smooth: true
                                        asynchronous: true
                                        // The slot is 26x26; without a cap Qt decodes and keeps
                                        // each icon at its intrinsic size (2x for this display).
                                        sourceSize.width: 52
                                        sourceSize.height: 52
                                    }
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 6
                                        visible: !iconSlot._hasGlyph && !iconSlot.hasAppImage
                                        // A plate ONLY under a letter standing
                                        // in for a thumbnail that would not
                                        // load. The other kinds below this line
                                        // resolve to a Nerd Font glyph, and a
                                        // glyph on a washed accent tile was the
                                        // loudest mark in the list — the
                                        // settings card draws its icons bare.
                                        // The wash that is left is the one the
                                        // selection uses, at less than it.
                                        color: iconSlot._hasThumb ? Theme.alpha(Theme.text, 0.08)
                                                                  : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: {
                                                const k = iconSlot.kind
                                                if (k === "app")          return rowDelegate.modelData.title.charAt(0).toUpperCase()
                                                if (k === "file")         return rowDelegate.modelData.data.isDir ? "" : ""
                                                if (k === "calc")         return ""
                                                if (k === "websearch")    return ""
                                                if (k === "clipboard")    return ""
                                                return "?"
                                            }
                                            color: Theme.alpha(Theme.text, 0.65)
                                            // A glyph is an icon and gets the
                                            // icon size; a letter is standing in
                                            // for a picture inside a plate and
                                            // has to leave room for the plate.
                                            font.pixelSize: iconSlot._hasThumb ? 13 : 17
                                            font.family: root.uiFont
                                        }
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    // Whatever the marks either side of it
                                    // leave. Written out rather than left at a
                                    // hardcoded 44 because the tick on the
                                    // right comes and goes with the mode, and
                                    // the label eliding into it is how the old
                                    // number would have failed.
                                    width: rowContent.width - Theme.iconSlot - rowContent.spacing
                                           - (tickSlot.visible ? tickSlot.width + rowContent.spacing : 0)
                                    // 1, the settings card's gap between a
                                    // label and its second line. Default
                                    // spacing is 0, which set the two solid.
                                    spacing: 1
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: rowDelegate.modelData.title
                                        color: Theme.text
                                        font.family: root.uiFont
                                        // Theme.fsRow, and the calculator's
                                        // answer is still the exception: it is
                                        // the result, not a label for one.
                                        font.pixelSize: rowDelegate.modelData.kind === "calc" ? 24 : Theme.fsRow
                                    }
                                    // The second line, which most rows no
                                    // longer have — the settings pass deleted
                                    // every subtitle that restated its label,
                                    // and the two finder had (the web search's
                                    // gloss, the power profile's "current")
                                    // went with them at the point they are
                                    // built. What is left is the same kind that
                                    // survived there: a line that is the only
                                    // place the information exists. A file's
                                    // path, and the expression a result came
                                    // from.
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        visible: text.length > 0
                                        text: rowDelegate.modelData.subtitle || ""
                                        color: Theme.dim
                                        font.family: root.uiFont
                                        font.pixelSize: Theme.fsSub
                                    }
                                }

                                // ── the chosen one of a set ────────────
                                // The settings card's mark for "this is the one
                                // that is on" (see its choice rows): a tick in
                                // the accent, at the right-hand end, and nothing
                                // in words. Only the power profiles have a set
                                // to be chosen from, so the slot is only
                                // reserved on that mode — an always-invisible
                                // 15px plus a 12px gap on every app, emoji and
                                // file row would shorten every label in finder
                                // for a mark none of them can ever draw.
                                Item {
                                    id: tickSlot
                                    visible: root.mode === "powerprofiles"
                                    width: 15; height: 15
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        anchors.centerIn: parent
                                        visible: rowDelegate.modelData.active === true
                                        text: "󰄬"
                                        color: Theme.accent
                                        font.family: root.uiFont
                                        font.pixelSize: 15
                                    }
                                }
                            }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: { root.selectedIndex = rowDelegate.index; root.activate(rowDelegate.index) }
                        }
                    }
                }

                // ── Preview pane ───────────────────────────────────────
                Rectangle {
                    id: previewBox
                    visible: root.effectivePreview !== null && root.effectivePreview.type !== "none"
                    // 340, down from 380. With the list no longer stretching
                    // to 600 beside it, the old pane made the card 1030 wide
                    // against the settings card's 430; this keeps the two
                    // comparable while still being a pane you can read a file
                    // in. It is a bounding box for the image either way — see
                    // sourceSize below.
                    width: visible ? 340 : 0
                    height: Math.max(listCol.height, 200)
                    // The row radius, and a wash under the selection's rather
                    // than an accent tint with an accent outline around it. It
                    // is a surface holding a picture, not a control: the only
                    // accent left on this card is the tick.
                    radius: Theme.rowRadius
                    color: Theme.alpha(Theme.text, 0.04)
                    border.width: 1
                    border.color: Theme.hairline
                    clip: true

                    Flickable {
                        anchors.fill: parent
                        anchors.margins: 10
                        contentWidth: width
                        contentHeight: previewText.visible ? previewText.height : height
                        visible: root.effectivePreview && root.effectivePreview.type === "text"

                        Text {
                            id: previewText
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: (root.effectivePreview && root.effectivePreview.type === "text") ? root.effectivePreview.text : ""
                            color: Theme.dim
                            font.family: "monospace"
                            font.pixelSize: Theme.fsSub
                        }
                    }

                    Image {
                        anchors.fill: parent
                        anchors.margins: 10
                        visible: root.effectivePreview && root.effectivePreview.type === "image"
                        source: (root.effectivePreview && root.effectivePreview.type === "image") ? root.effectivePreview.source : ""
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        asynchronous: true
                        // Bounding box, not a resize: previewing a full-resolution
                        // photo would otherwise decode every pixel of it into memory
                        // (a 6000x4000 shot is ~96 MB as a pixmap) to draw it in a
                        // pane 380 points wide. 800 covers that pane at 2x DPI.
                        sourceSize.width: 800
                        sourceSize.height: 800
                        // Previews are one-shot: a given clipboard image or
                        // file is shown while it is selected and then not again.
                        // Caching them means every image the selection passes over
                        // stays resident in Qt's pixmap cache for the life of the
                        // process, which is what made memory climb the longer
                        // finder stayed up.
                        cache: false
                    }
                }
            }

            // ── there is no footer ────────────────────────────────────
            // "↑↓ navigate  ↵ select  esc close" used to sit here, on every
            // mode, permanently. It went for the reason the settings card's
            // identical footer went: it documents three keys that every list
            // in every application on the machine already answers to, it is
            // the second-largest block of text on an empty card, and it is
            // the same three words whether you are picking an emoji or
            // shutting the machine down. The keys themselves are unchanged
            // and are handled in root's Keys.onPressed and input.onAccepted.
        }
    }

    // ── Settings (its own panel, in the taskbar's chrome) ───────────────
    // Declared after `box` so it sits above the dismiss-scrim MouseArea; it
    // carries a click-swallowing MouseArea of its own so clicking inside it
    // does not close the menu.
    SettingsPanel {
        id: settingsPanel
        anchors.centerIn: parent
        shown: root.shown && root.settingsMode
        onRequestClose: root.close()
        onRequestRebind: (declared, label, inForce) => keyCapture.begin(declared, label, inForce)
    }

    // ── Reassigning a keybind ───────────────────────────────────────────
    // Declared AFTER the settings panel so it draws on top of it, and it takes
    // the keyboard while it is up — which is the whole point, since the keys
    // being pressed are the input rather than a shortcut for anything.
    //
    // A dimming scrim of its own, rather than reusing finder's: this is a
    // modal over the menu, not a replacement for it, and the menu has to stay
    // visible behind it so you can see which row you are rebinding.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        visible: keyCapture.opacity > 0.001
        opacity: keyCapture.opacity
        MouseArea { anchors.fill: parent; onClicked: keyCapture.cancelled() }
    }

    KeyCapture {
        id: keyCapture
        anchors.centerIn: parent
        shown: root.shown && root.settingsMode && keyCapture.target !== ""

        onCommitted: combo => {
            const declared = keyCapture.target
            keyCapture.target = ""
            settingsPanel.focusInput()
            Settings.setKeybind(declared, combo)
        }
        onCancelled: {
            keyCapture.target = ""
            settingsPanel.focusInput()
        }
    }

    // ── The password box ────────────────────────────────────────────────
    PasswordPrompt {
        id: passwordPrompt
        anchors.centerIn: parent
        shown: root.shown && root.passwordMode
        onPolkitPassword: pw => polkitLink.sendPassword(pw)
        onFinished: ok => {
            // polkit's flow answers to the agent, not to Settings: there is no
            // toggle to settle and nothing was run from here.
            if (passwordPrompt.flow === "polkit") { root.close(); return }
            const pending = root.pendingVerify
            root.pendingVerify = ""
            if (ok && pending !== "") {
                // A verify-only password. Nothing ran; Settings decides what
                // it unlocked, and that raises whatever box comes next — so
                // this must NOT close, or the box it raises is torn down in
                // the frame it was created in. Same trap the change-password
                // row documents.
                Settings.verified(pending)
                return
            }
            // Let the switch re-read the compositor rather than assume the
            // command did what it was asked.
            if (ok) Settings.toggleSettled()
            root.close()
        }
        onCancelled: {
            // Esc on a polkit prompt is an answer, and the program waiting on
            // it is entitled to hear it: without this it would sit blocked on
            // an authentication that is never coming.
            if (passwordPrompt.flow === "polkit") {
                polkitLink.cancel()
                root.close()
                return
            }
            // Read it BEFORE clearing it — the first version of this cleared
            // first and then tested the cleared value, so the branch below was
            // dead and a cancelled verify always closed finder.
            const wasVerify = root.pendingVerify !== ""
            root.pendingVerify = ""
            // A cancelled verify goes BACK to the menu rather than closing
            // finder outright: Fingerprints is three pages in, and changing
            // your mind about a password should not cost that walk. The other
            // flows keep the behaviour they had — they were raised from a row
            // that acts and is done.
            if (wasVerify) root.returnToSettings()
            else root.close()
        }
    }

    // ── polkit's prompts, in the same box ───────────────────────────────
    // This is the only way into the password box that does not start with the
    // user asking for something: the request comes from whatever program went
    // looking for a privilege. So it takes the window over whatever finder was
    // doing — a half-typed search is worth less than an answer to the thing
    // now waiting on it, and polkit will wait indefinitely for one.
    PolkitLink {
        id: polkitLink
        onRequested: (message, user, isSelf) => {
            root.pendingVerify = ""
            root.query = ""          // or a stale search reappears behind the box
            root.mode = "password"
            root.shown = true
            passwordPrompt.beginPolkit(message, user, isSelf)
            inputFocusTimer.start()
        }
        onFailed:   passwordPrompt.polkitFailed()
        onAccepted: passwordPrompt.polkitAccepted()
        // polkitd withdrew the request (the caller gave up), or the agent went
        // away. Nothing is listening for a password any more, so the box goes
        // — but only if it is still the polkit one, since the user may have
        // cancelled it and opened something else in the meantime.
        onWithdrawn: if (root.passwordMode && passwordPrompt.flow === "polkit") root.close()
    }

    // ── The fingerprint enrol box ───────────────────────────────────────
    FingerprintPrompt {
        id: fingerprintPrompt
        anchors.centerIn: parent
        shown: root.shown && root.fingerprintMode
        // Either way the listing and the counts have to be re-read: enrolling
        // filled a slot, and abandoning one may still have left the sensor in
        // a different state than the page last saw.
        onFinished: ok => { Settings.refresh("security/fingerprints/delete")
                            Settings.refreshFingerprints()
                            root.returnToSettings() }
        onCancelled: { Settings.refreshFingerprints(); root.returnToSettings() }
    }

    // Back to the settings menu on the page it was left on. settingsPanel.reset()
    // is only ever called from openMode(), so its pageKey has survived the trip
    // through the password and fingerprint boxes and the user lands where they
    // were — looking at the list they just changed.
    function returnToSettings() {
        root.mode = "settings"
        inputFocusTimer.start()
    }

    Connections {
        target: Settings
        function onAuthRequired(reason, command) {
            root.pendingVerify = ""
            root.mode = "password"
            passwordPrompt.begin("", reason, command)
            inputFocusTimer.start()
        }
        // Same box, three steps instead of one — Ahaan's "universal
        // authenticate password box design for all this".
        function onChangePasswordRequested() {
            root.pendingVerify = ""
            root.mode = "password"
            passwordPrompt.beginChangePassword()
            inputFocusTimer.start()
        }
        // Same box again, verifying only — see PasswordPrompt's flow notes.
        function onVerifyRequired(reason, action) {
            root.pendingVerify = action
            root.mode = "password"
            passwordPrompt.beginVerify(reason)
            inputFocusTimer.start()
        }
        function onFingerprintEnrollRequested() {
            root.mode = "fingerprint"
            fingerprintPrompt.begin()
            inputFocusTimer.start()
        }
    }
}
