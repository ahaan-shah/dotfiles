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
    property string mode: "default"   // "default" | "emoji" | "clipboard" | "powerprofiles" | "powermenu" | "wallpaper" | "settings"

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
    property var clipboardPreview: null   // {type:"image", source} for clipboard-mode image entries
    property var wallpaperPreview: null   // {type:"image", source} for wallpaper-mode entries

    // Unified preview object regardless of which mode/provider produced it.
    readonly property var effectivePreview: root.mode === "clipboard" ? root.clipboardPreview
        : root.mode === "wallpaper" ? root.wallpaperPreview
        : FileSearch.preview

    readonly property var _placeholders: ({
        "default":       "search applications",
        "emoji":         "Search emojis (e.g. smile, fire, heart)...",
        "clipboard":     "Search clipboard history...",
        "powerprofiles": "Select power profile...",
        "powermenu":     "Power menu...",
        "wallpaper":     "Search wallpapers...",
        "filesearch":    "Search files..."
    })

    // ── Open / close ─────────────────────────────────────────────────
    function openMode(m) {
        if (root.shown && root.mode === m) { close(); return }
        root.mode = m
        root.query = ""
        root.selectedIndex = 0
        root.displayResults = []
        root.shown = true
        if (m === "clipboard") ClipboardHistory.refresh()
        if (m === "emoji") root._rebuild()
        // powerprofiles/powermenu/wallpaper all list everything immediately
        // on open (type-to-filter OR scroll, per explicit request) rather
        // than starting blank like default-mode app search does.
        if (m === "powerprofiles") { PowerProfiles.refresh(); root._rebuild() }
        if (m === "powermenu") root._rebuild()
        if (m === "wallpaper") { Wallpapers.refresh(); root._rebuild() }
        if (m === "settings") {
            settingsPanel.reset()
            // Every listing is fetched up front, not on the page that shows it:
            // search reaches the whole subtree, so a font has to be findable
            // from the root without ever opening Fonts. They arrive one at a
            // time, so this does not hold up the panel appearing.
            Settings.prefetchAll()
            Settings.refreshState()
        }
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
                .map(p => ({
                    kind: "powerprofile", emojiGlyph: p.icon, title: p.label,
                    subtitle: p.value === PowerProfiles.current ? "current" : "",
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
        if (root.mode === "wallpaper") {
            const hits = Wallpapers.search(root.query, 50)
            root.displayResults = hits.map(w => ({
                kind: "wallpaper", icon: "file://" + w.path, emojiGlyph: "", title: w.name, subtitle: "", data: w
            }))
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
    // Same again for the wallpaper directory listing, and for the
    // `powerprofilesctl get` round-trip re-marking the "current" row once
    // it actually resolves (openMode's immediate _rebuild() runs before
    // either async call can have finished).
    Connections {
        target: Wallpapers
        function onWallpapersChanged() { if (root.mode === "wallpaper") root._rebuild() }
    }
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
            rows.push({ kind: "websearch", emojiGlyph: "", title: "Google", subtitle: "Search the web for \"" + q + "\"", data: q })
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
        root.wallpaperPreview = null
        const r = root.displayResults[root.selectedIndex]
        if (root.mode === "filesearch") {
            if (r && r.kind === "file" && !r.data.isDir) FileSearch.previewFor(r.data.path)
        } else if (root.mode === "clipboard") {
            if (r && r.kind === "clipboard" && r.data.kind === "image") {
                root.clipboardPreview = { type: "image", source: "file://" + r.data.path }
            }
        } else if (root.mode === "wallpaper") {
            if (r && r.kind === "wallpaper") {
                root.wallpaperPreview = { type: "image", source: "file://" + r.data.path }
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
            case "wallpaper":
                Wallpapers.apply(r.data.path)
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

    // ── Colors (pywal, live) ───────────────────────────────────────────
    readonly property color bgColor:     WalColors.color0 || WalColors.background
    readonly property color fgColor:     WalColors.color7 || WalColors.foreground
    readonly property color accentColor: WalColors.color8
    readonly property color errorBg:     WalColors.color1

    function _alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    function _lighter(c, f) { return Qt.lighter(c, f) }
    function _darker(c, f)  { return Qt.darker(c, f) }

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
        radius: 30
        color: root.bgColor
        border.width: 1
        border.color: root._darker(root.accentColor, 1.5)

        // Every mode that draws a card of its own has to be listed here. The
        // fingerprint box was added without it and the launcher sat lit up
        // behind the scan card for the whole enrolment — its input line and
        // its "↑↓ navigate" footer visible either side of it. Anything that
        // adds a mode with its own surface has to come back to this line.
        opacity: (root.shown && !root.settingsMode && !root.passwordMode && !root.fingerprintMode) ? 1 : 0
        scale: (root.shown && !root.settingsMode && !root.passwordMode && !root.fingerprintMode) ? 1 : 0.94
        visible: opacity > 0.001
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on scale   { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on color   { ColorAnimation { duration: 300 } }

        width: content.width + 40
        height: content.height + 40
        Behavior on width  { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Column {
            id: content
            x: 20; y: 20
            spacing: 10

            // ── Search input ──────────────────────────────────────────
            Rectangle {
                width: 644
                height: 44
                radius: 16
                color: root._lighter(root.bgColor, 1.35)

                TextInput {
                    id: input
                    anchors.fill: parent
                    anchors.margins: 10
                    verticalAlignment: TextInput.AlignVCenter
                    font.family: root.uiFont
                    font.pixelSize: 14
                    color: root.fgColor
                    clip: true
                    selectionColor: root._lighter(root.bgColor, 1.8)
                    onTextChanged: root.query = text
                    // The ONE Return handler for this list — see the note in
                    // root's Keys.onPressed above.
                    onAccepted: root.activate(root.selectedIndex)

                    Text {
                        anchors.fill: parent
                        text: root._placeholders[root.mode] || ""
                        color: root.fgColor
                        opacity: 0.5
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
                spacing: 10
                visible: root.displayResults.length > 0

                ListView {
                    id: listCol
                    width: 600
                    // Cap the list's own height and let it scroll instead of growing
                    // the whole window arbitrarily tall (e.g. the 50-row emoji listing).
                    height: Math.min(contentHeight, 420)
                    clip: true
                    spacing: 4
                    model: root.displayResults
                    currentIndex: root.selectedIndex
                    highlightMoveDuration: 100
                    highlightFollowsCurrentItem: true

                    delegate: Rectangle {
                        id: rowDelegate
                        required property var modelData
                        required property int index
                        width: listCol.width
                        height: rowContent.height + 16
                        radius: 10
                        color: index === root.selectedIndex ? root._alpha(root.accentColor, 0.25) : "transparent"
                        Behavior on color { ColorAnimation { duration: 100 } }

                            Row {
                                id: rowContent
                                x: 10; y: 8
                                spacing: 12
                                width: rowDelegate.width - 20

                                // Icon: emoji glyph, resolved app icon image (falls back to a
                                // Nerd Font glyph tile if it fails to load or the kind has no image).
                                Item {
                                    id: iconSlot
                                    width: 32; height: 32
                                    anchors.verticalCenter: parent.verticalCenter

                                    readonly property string kind: rowDelegate.modelData.kind
                                    readonly property bool _hasThumb: kind === "app" || kind === "wallpaper"
                                    readonly property bool hasAppImage: iconSlot._hasThumb && appIcon.status === Image.Ready
                                    // Power profile/menu icons are Nerd Font glyphs too (see
                                    // PowerProfiles.qml/PowerMenu.qml), same rendering path as emoji.
                                    readonly property bool _hasGlyph: kind === "emoji" || kind === "powerprofile" || kind === "powermenuitem"

                                    Text {
                                        anchors.centerIn: parent
                                        visible: iconSlot._hasGlyph
                                        text: rowDelegate.modelData.emojiGlyph || ""
                                        color: root.fgColor
                                        font.pixelSize: 24
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
                                        // The slot is 32x32; without a cap Qt decodes and keeps
                                        // each icon at its intrinsic size (2x for this display).
                                        sourceSize.width: 64
                                        sourceSize.height: 64
                                    }
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 6
                                        visible: !iconSlot._hasGlyph && !iconSlot.hasAppImage
                                        color: root._alpha(root.accentColor, 0.3)
                                        Text {
                                            anchors.centerIn: parent
                                            text: {
                                                const k = iconSlot.kind
                                                if (k === "app")          return rowDelegate.modelData.title.charAt(0).toUpperCase()
                                                if (k === "file")         return rowDelegate.modelData.data.isDir ? "" : ""
                                                if (k === "calc")         return ""
                                                if (k === "websearch")    return ""
                                                if (k === "clipboard")    return ""
                                                if (k === "wallpaper")    return rowDelegate.modelData.title.charAt(0).toUpperCase()
                                                return "?"
                                            }
                                            color: root.fgColor
                                            font.pixelSize: 14
                                            font.family: root.uiFont
                                        }
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: rowContent.width - 44
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        text: rowDelegate.modelData.title
                                        color: root.fgColor
                                        font.family: root.uiFont
                                        font.pixelSize: rowDelegate.modelData.kind === "calc" ? 24 : 14
                                    }
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        visible: text.length > 0
                                        text: rowDelegate.modelData.subtitle || ""
                                        color: root.fgColor
                                        opacity: 0.5
                                        font.family: root.uiFont
                                        font.pixelSize: 12
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
                    width: visible ? 380 : 0
                    height: Math.max(listCol.height, 200)
                    radius: 10
                    color: root._alpha(root.accentColor, 0.08)
                    border.width: 1
                    border.color: root._alpha(root.accentColor, 0.25)
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
                            color: root.fgColor
                            font.family: "monospace"
                            font.pixelSize: 12
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
                        // Previews are one-shot: a given wallpaper or clipboard
                        // image is shown while it is selected and then not again.
                        // Caching them means every image the selection passes over
                        // stays resident in Qt's pixmap cache for the life of the
                        // process, which is what made memory climb the longer
                        // finder stayed up.
                        cache: false
                    }
                }
            }

            // ── Keybind footer ────────────────────────────────────────
            Row {
                spacing: 14
                visible: root.shown
                topPadding: 6

                Text { text: "↑↓ navigate"; color: root.fgColor; opacity: 0.35; font.pixelSize: 12; font.family: root.uiFont }
                Text { text: "↵ select";     color: root.fgColor; opacity: 0.35; font.pixelSize: 12; font.family: root.uiFont }
                Text { text: "esc close";    color: root.fgColor; opacity: 0.35; font.pixelSize: 12; font.family: root.uiFont }
            }
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
    }

    // ── The password box ────────────────────────────────────────────────
    PasswordPrompt {
        id: passwordPrompt
        anchors.centerIn: parent
        shown: root.shown && root.passwordMode
        onFinished: ok => {
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
