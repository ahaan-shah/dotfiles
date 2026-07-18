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
    property string mode: "default"   // "default" | "emoji" | "clipboard" | "powerprofiles" | "powermenu" | "wallpaper"
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
        "wallpaper":     "Search wallpapers..."
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
        inputFocusTimer.start()
    }

    function close() {
        root.shown = false
        root.query = ""
        FileSearch.preview = null
    }

    Timer { id: inputFocusTimer; interval: 10; onTriggered: input.forceActiveFocus() }

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
                    kind: "powerprofile", emojiGlyph: "", title: p.label,
                    subtitle: p.value === PowerProfiles.current ? "current" : "",
                    data: p
                }))
            return
        }
        if (root.mode === "powermenu") {
            const q = root.query.toLowerCase()
            root.displayResults = PowerMenu.items
                .filter(p => !q || p.label.toLowerCase().includes(q))
                .map(p => ({ kind: "powermenuitem", emojiGlyph: "", title: p.label, subtitle: "", data: p }))
            return
        }
        if (root.mode === "wallpaper") {
            const hits = Wallpapers.search(root.query, 50)
            root.displayResults = hits.map(w => ({
                kind: "wallpaper", icon: "file://" + w.path, emojiGlyph: "", title: w.name, subtitle: "", data: w
            }))
            return
        }
        // default mode
        if (!root.query) { root.displayResults = []; return }

        if (root._isFileQuery(root.query)) {
            // "/"-prefixed: file search only. Backspacing the "/" away drops
            // straight back into normal app search via the branch below, no
            // extra state to unwind — _combineDefault() re-derives everything
            // from root.query on every rebuild.
            const fq = root.query.slice(1)
            if (fq.length >= 2) FileSearch.search(fq, 10)
            else FileSearch.results = []
            root._combineDefault()
            return
        }

        Calc.evaluate(root.query)
        if (root._looksLikeCalc(root.query)) {
            // Query reads as an in-progress arithmetic expression (e.g. "12*",
            // "5+3") — don't bother launching a file search for it, and clear
            // any stale results from before the user started typing math.
            FileSearch.results = []
        } else {
            FileSearch.results = []   // file search only runs under the "/" prefix now
        }
        root._combineDefault()
    }

    // A "/"-prefixed query is file-search mode; everything else is app
    // search (plus calc/websearch). Matches the footer hint shown to the user.
    function _isFileQuery(q) {
        return q.startsWith("/")
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
        function onResultsChanged() { if (root.mode === "default" && root.query) root._combineDefault() }
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

        if (root._isFileQuery(q)) {
            for (const f of FileSearch.results) {
                rows.push({ kind: "file", icon: "", title: f.name, subtitle: f.subtext, data: f })
            }
            const prevSel = root.selectedIndex
            root.displayResults = rows
            root.selectedIndex = Math.min(prevSel, Math.max(rows.length - 1, 0))
            return
        }

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
        if (root.mode === "default") {
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
                FileSearch.open(r.data.path)
                break
            case "calc":
                copyToClipboard(r.title)
                break
            case "websearch":
                // zen-browser specifically, not xdg-open's default handler —
                // zen (class "zen") is the user's actual browser.
                openProc.command = ["zen-browser", "https://www.google.com/search?q=" + encodeURIComponent(r.data)]
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
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
        else if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
        else if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.selectedIndex); event.accepted = true
        }
    }

    // ── Window box ──────────────────────────────────────────────────
    Rectangle {
        id: box
        anchors.centerIn: parent
        radius: 30
        color: root.bgColor
        border.width: 1
        border.color: root._darker(root.accentColor, 1.5)

        opacity: root.shown ? 1 : 0
        scale: root.shown ? 1 : 0.94
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
                    font.family: "Hack Nerd Font Propo"
                    font.pixelSize: 14
                    color: root.fgColor
                    clip: true
                    selectionColor: root._lighter(root.bgColor, 1.8)
                    onTextChanged: root.query = text
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

                                    Text {
                                        anchors.centerIn: parent
                                        visible: iconSlot.kind === "emoji"
                                        text: rowDelegate.modelData.emojiGlyph || ""
                                        font.pixelSize: 24
                                    }
                                    Image {
                                        id: appIcon
                                        anchors.fill: parent
                                        visible: iconSlot._hasThumb && status === Image.Ready
                                        source: iconSlot._hasThumb ? (rowDelegate.modelData.icon || "") : ""
                                        fillMode: Image.PreserveAspectFit
                                        smooth: true
                                        asynchronous: true
                                    }
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 6
                                        visible: iconSlot.kind !== "emoji" && !iconSlot.hasAppImage
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
                                                if (k === "powerprofile")  return rowDelegate.modelData.title.charAt(0).toUpperCase()
                                                if (k === "powermenuitem") return rowDelegate.modelData.title.charAt(0)
                                                if (k === "wallpaper")     return rowDelegate.modelData.title.charAt(0).toUpperCase()
                                                return "?"
                                            }
                                            color: root.fgColor
                                            font.pixelSize: 14
                                            font.family: "Hack Nerd Font Propo"
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
                                        font.family: "Hack Nerd Font Propo"
                                        font.pixelSize: rowDelegate.modelData.kind === "calc" ? 24 : 14
                                    }
                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        visible: text.length > 0
                                        text: rowDelegate.modelData.subtitle || ""
                                        color: root.fgColor
                                        opacity: 0.5
                                        font.family: "Hack Nerd Font Propo"
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
                    }
                }
            }

            // ── Keybind footer ────────────────────────────────────────
            Row {
                spacing: 14
                visible: root.shown
                topPadding: 6

                Text { text: "↑↓ navigate"; color: root.fgColor; opacity: 0.35; font.pixelSize: 12; font.family: "Hack Nerd Font Propo" }
                Text { text: "↵ select";     color: root.fgColor; opacity: 0.35; font.pixelSize: 12; font.family: "Hack Nerd Font Propo" }
                Text {
                    text: "/ files"
                    visible: root.mode === "default"
                    color: root.fgColor; opacity: 0.35; font.pixelSize: 12; font.family: "Hack Nerd Font Propo"
                }
                Text { text: "esc close";    color: root.fgColor; opacity: 0.35; font.pixelSize: 12; font.family: "Hack Nerd Font Propo" }
            }
        }
    }
}
