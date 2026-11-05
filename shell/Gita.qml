// Gita.qml — Bhagavad-gītā As It Is in the bar's centre island.
//
// Opened from the book glyph in the right island's hover drawer, beside volume
// and display (Bar.qml), or `ipc call gita toggle`. The island grows down for
// it as it does for the todo list, and for the same reason this window draws
// what is in it: the bar's surface never takes the keyboard. GitaState.qml has
// the data and the history of the design.
//
// One verse per page (Ahaan, 2026-10-21): the verse label on top, the verse
// romanised, then the translation, with who speaks set apart as a label of
// its own. The Devanagari was on the page too, briefly; on seeing it he
// pointed at the romanised verse and translation: "I just want this part".
// Simple, and no vim keys:
//   ← →          previous / next verse (on across chapter ends)
//   ↑ ↓          scroll a page that is taller than the island
//   Tab          the overview: chapters, then that chapter's verses (also
//                the verse label, clicked)
//   K            search
//   R            a verse at random, from anywhere in the book
//   T            the reading record (counts, streak, heatmap) — was R until
//                R went to the random verse (Ahaan, 2026-10-22)
//   S / P        the synonyms / the purport under the translation, on
//                request — read from their own file only then
//   PgUp PgDn    scroll a long page (a purport) by most of a screen
//   Esc          back to the page, and from the page closes
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

Scope {
    id: scope

    // `qs -p <shell> ipc call gita <fn>` — toggle is the bar button's; the rest
    // let a repo instance be exercised with no keyboard (CLAUDE.md step 2).
    IpcHandler {
        target: "gita"
        function toggle(): void { GitaState.toggleOpen() }
        function open(): void { GitaState.show() }
        function close(): void { GitaState.close() }
        function view(name: string): void { GitaState.view = name }
        function next(): void { GitaState.step(1) }
        function prev(): void { GitaState.step(-1) }
        function random(): string { GitaState.random(); GitaState.view = "read"; return GitaState.verses[GitaState.vi].id }
        function go(ref: string): string {
            const p = GitaState.find(ref)
            if (!p) return "no such verse: " + ref
            GitaState.goTo(p[0], p[1]); GitaState.view = "read"
            return GitaState.verses[GitaState.vi].id
        }
        function search(q: string): string {
            const r = GitaState.search(q, 5)
            return r.total + " | " + r.hits.map(h => h.ref).join(" ")
        }
        function where(): string {
            return GitaState.loaded ? GitaState.verses[GitaState.vi].id + " (" + GitaState.view + ")" : "no text"
        }
        function syn(): void { GitaState.toggleSyn() }
        function pp(): void { GitaState.togglePp() }
        function status(): string {
            return JSON.stringify({ loaded: GitaState.loaded, missing: GitaState.missing,
                                    chapters: GitaState.chapters.length, data: GitaState.dataPath,
                                    extrasRead: Object.keys(GitaState.extras).length,
                                    syn: GitaState.showSyn, pp: GitaState.showPp })
        }
    }

    // Glyphs from codepoints, as Bar.qml's table does and for its reason (a
    // pasted Material glyph is a surrogate pair tools mangle). Read out of
    // JetBrainsMonoNerdFontPropo-Regular.ttf's cmap by name.
    readonly property string gSearch: String.fromCodePoint(0xf0349)    // md-magnify
    readonly property string gActivity: String.fromCodePoint(0xf00ef)  // md-calendar_check

    // A header button: a glyph or a word, dim, lit while its view is up.
    // No key hints on them: they sat off the text's baseline at every size
    // tried, Tab's worst (Ahaan, 2026-10-21: "remove the hint").
    component HeadBtn: Rectangle {
        id: hb
        property string glyph
        property bool on: false
        property int size: Theme.fsRow + 2
        signal clicked()
        width: Math.max(30, hbText.implicitWidth + 16); height: 30; radius: 8
        color: on ? Theme.alpha(Theme.text, 0.12)
                  : hbHover.hovered ? Theme.alpha(Theme.text, 0.06) : "transparent"
        Text {
            id: hbText
            anchors.centerIn: parent
            text: hb.glyph
            font.family: Theme.font
            font.pixelSize: hb.size
            color: hb.on || hbHover.hovered ? Theme.text : Theme.dim
        }
        HoverHandler { id: hbHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: hb.clicked() }
    }

    // Who speaks: small, spaced capitals in the accent colour, so it reads as
    // a label and never as the first words of the verse.
    component Speaker: Text {
        property string who
        visible: who !== ""
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: (who + " said").toUpperCase()
        font.family: Theme.font
        font.pixelSize: Theme.fsSub
        font.letterSpacing: 1.6
        color: Theme.accent
    }

    // A part of the page shown on request: a spaced caption, then paragraphs.
    // It opens and closes as EVE's island does — 300 ms OutCubic, sliding
    // open while it fades in (Ahaan: "make it nicely smoothly come into place
    // in the panel when enabled"). Only `amount` is animated, never the
    // height itself, so a page turn with it on swaps the text at once instead
    // of easing between two verses' heights.
    component Section: Item {
        id: sec
        property string title
        property var body: []
        property bool shown: false
        property real amount: shown ? 1 : 0
        Behavior on amount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        width: parent ? parent.width : 0
        height: col.implicitHeight * amount
        visible: amount > 0.001
        clip: true
        opacity: amount

        Column {
            id: col
            width: sec.width
            spacing: 10
            topPadding: 8
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 40; height: 1
                color: Theme.hairline
            }
            Text {
                width: sec.width
                horizontalAlignment: Text.AlignHCenter
                text: sec.title.toUpperCase()
                font.family: Theme.font
                font.pixelSize: Theme.fsSub
                font.letterSpacing: 1.6
                color: Theme.dimmer
            }
            Repeater {
                model: sec.body
                Text {
                    required property string modelData
                    width: sec.width
                    wrapMode: Text.Wrap
                    text: modelData
                    font.family: Theme.font
                    font.pixelSize: Theme.fsRow
                    lineHeight: 1.4
                    color: Theme.alpha(Theme.text, 0.75)
                }
            }
        }
    }

    component Hint: Text {
        font.family: Theme.font
        font.pixelSize: Theme.fsSub
        color: Theme.dimmer
    }

    PanelWindow {
        id: win
        // Mapped while the island is still closing, so the text fades with it.
        visible: GitaState.open || GitaState.amount > 0.01
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-gita"
        // OnDemand, never Exclusive — the reason is in Todo.qml.
        WlrLayershell.keyboardFocus: GitaState.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        mask: Region { item: GitaState.open ? everywhere : nothing }
        Item { id: everywhere; anchors.fill: parent }
        Item { id: nothing; width: 0; height: 0 }

        MouseArea { anchors.fill: parent; onClicked: GitaState.close() }

        Connections {
            target: GitaState
            function onOpenChanged() {
                if (!GitaState.open) return
                win.focusNow()
                dwell.restart()
            }
            function onViewChanged() {
                if (GitaState.view === "search") { search.text = ""; win.results = { total: 0, hits: [] }; win.rsel = 0 }
                if (GitaState.view === "go") { win.goCi = GitaState.ci; win.goVi = GitaState.vi; win.goSide = "ch" }
                if (GitaState.view === "read") dwell.restart()
                win.focusNow()
            }
            function onViChanged() { page.contentY = 0; dwell.restart() }
            function onCiChanged() { page.contentY = 0 }
        }

        function focusNow() { focusTimer.tries = 0; focusTimer.start() }
        // A layer surface is not reliably focusable on the frame it maps; the
        // todo list, the pill and the launcher all retry, and so does this.
        Timer {
            id: focusTimer
            property int tries: 0
            interval: 40; repeat: true
            onTriggered: {
                const t = GitaState.view === "search" ? search : keys
                t.forceActiveFocus()
                if (t.activeFocus || ++tries > 12) stop()
            }
        }

        // A verse counts as read after its page has been up four seconds —
        // the time to read a translation, not to page past one. Restarted,
        // never bound: restart() on a Timer whose `running` is bound breaks
        // the binding, so the conditions are checked on firing.
        Timer {
            id: dwell
            interval: 4000
            onTriggered: {
                if (!GitaState.open || GitaState.view !== "read" || !GitaState.loaded) return
                const v = GitaState.verses[GitaState.vi]
                if (v) GitaState.markRead(v.id)
            }
        }

        // ── picker selection ────────────────────────────────────────────
        property int goCi: 0
        property int goVi: 0
        property string goSide: "ch"          // "ch" | "v"
        readonly property var goVerses: GitaState.chapters[goCi] ? GitaState.chapters[goCi].verses : []

        // ── search results ──────────────────────────────────────────────
        property var results: ({ total: 0, hits: [] })
        property int rsel: 0
        Timer {
            id: searchDelay
            interval: 140
            onTriggered: { win.results = GitaState.search(search.text, 200); win.rsel = 0; hits.positionViewAtBeginning() }
        }
        function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/\n/g, " ") }

        // ── keys: arrows, Enter, Esc ────────────────────────────────────
        Item {
            id: keys
            focus: true
            Keys.onPressed: event => {
                const v = GitaState.view, k = event.key
                if (k === Qt.Key_Escape) { v === "read" ? GitaState.close() : (GitaState.view = "read"); event.accepted = true; return }
                if (!GitaState.loaded) return
                // The views' keys, from any view but search's box: Tab the
                // overview, K search, T the reading record (Ahaan's choice of
                // letters; each toggles back to the page). R is a random
                // verse, and lands on the page from whichever view it is hit.
                const toggle = to => { GitaState.view = v === to ? "read" : to; event.accepted = true }
                if (k === Qt.Key_Tab) return toggle("go")
                if (k === Qt.Key_K) return toggle("search")
                if (k === Qt.Key_T) return toggle("activity")
                if (k === Qt.Key_R) { GitaState.random(); GitaState.view = "read"; event.accepted = true; return }
                if (v === "read") {
                    if (k === Qt.Key_Right) GitaState.step(1)
                    else if (k === Qt.Key_Left) GitaState.step(-1)
                    else if (k === Qt.Key_S) GitaState.toggleSyn()
                    else if (k === Qt.Key_P) GitaState.togglePp()
                    else if (k === Qt.Key_Down || k === Qt.Key_Up || k === Qt.Key_PageDown || k === Qt.Key_PageUp) {
                        // A page taller than the island scrolls — a purport
                        // nearly always is. Arrows by a few lines, PgUp/PgDn
                        // by most of a screen.
                        const step = (k === Qt.Key_PageDown || k === Qt.Key_PageUp) ? page.height * 0.85 : 60
                        const d = (k === Qt.Key_Down || k === Qt.Key_PageDown ? 1 : -1) * step
                        page.contentY = Math.max(0, Math.min(page.contentY + d, page.contentHeight - page.height))
                    }
                    else return
                } else if (v === "go") win.goKey(event)
                else return
                event.accepted = true
            }
        }
        function goKey(event) {
            const k = event.key
            const enter = k === Qt.Key_Return || k === Qt.Key_Enter
            if (goSide === "ch") {
                if (k === Qt.Key_Down) { goCi = Math.min(goCi + 1, GitaState.chapters.length - 1); goVi = 0 }
                else if (k === Qt.Key_Up) { goCi = Math.max(goCi - 1, 0); goVi = 0 }
                else if (k === Qt.Key_Right || enter) goSide = "v"
                chList.positionViewAtIndex(goCi, ListView.Contain)
            } else {
                const cols = grid.cols
                if (k === Qt.Key_Right) goVi = Math.min(goVi + 1, goVerses.length - 1)
                else if (k === Qt.Key_Left) { if (goVi % cols === 0) goSide = "ch"; else goVi-- }
                else if (k === Qt.Key_Down) goVi = Math.min(goVi + cols, goVerses.length - 1)
                else if (k === Qt.Key_Up) goVi = Math.max(goVi - cols, 0)
                else if (enter) { GitaState.goTo(goCi, goVi); GitaState.view = "read" }
            }
        }

        // How tall the island should be: the page's own height while reading
        // (so a two-line verse is a small island), the full reach otherwise.
        // The reach itself, never a number for the bar to cap: it was 100000,
        // and the height animation raced towards that and hit the cap within
        // a frame or two — the overview snapped open (Ahaan: "the panel sizes
        // abruptly").
        Binding {
            target: GitaState
            property: "wantHeight"
            value: !GitaState.loaded ? 260
                 : GitaState.view === "read" ? Math.min(GitaState.reach, header.height + 6 + 14 + pageCol.implicitHeight + 34)
                 : GitaState.reach
        }

        // ── the island's body ───────────────────────────────────────────
        // `area` is the island below its clock row as it is THIS frame, and
        // only clips; `sheet` inside it is the page at the island's final
        // size, centred, so the open and close reveal it without reflowing
        // a line (GitaState.targetWidth has the measurement behind that).
        Item {
            id: area
            readonly property var isl: GitaState.island
            // The island's grown part, wherever the bar is (Island.areaX/Y/W/H
            // in Bar.qml): under the row on a top bar, beside the column on a
            // side one. The bar's surface starts at the screen's top-left on
            // every edge, so its coordinates are this window's.
            x: isl ? isl.areaX : 0
            y: isl ? isl.areaY : 0
            width: isl ? isl.areaW : 0
            height: isl ? isl.areaH : 0
            clip: true
            // In from 35% of the opening, as EVE's card is (JarvisCard in
            // Bar.qml), so the words land as the island settles.
            opacity: Math.max(0, (GitaState.amount - 0.35) / 0.65)

            // Inside the island but on nothing: take the keyboard back.
            MouseArea { anchors.fill: parent; onPressed: win.focusNow() }

            Item {
                id: sheet
                width: GitaState.targetWidth
                height: Math.min(GitaState.reach, GitaState.wantHeight)
                x: Math.round((area.width - width) / 2)

                readonly property real pad: 20

                // ── header: ‹ label ›, the chapter's title; search, activity ──
                Item {
                    id: header
                    x: sheet.pad; y: 6
                    width: sheet.width - sheet.pad * 2
                    height: 40

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        HeadBtn {
                            glyph: "‹"
                            size: Theme.fsInput + 2
                            visible: GitaState.loaded
                            onClicked: { GitaState.view = "read"; GitaState.step(-1) }
                        }
                        // The verse label: also the way to the picker.
                        HeadBtn {
                            glyph: GitaState.loaded ? "Bg " + GitaState.verses[GitaState.vi].id.replace("-", "–") : "Bhagavad-gītā"
                            size: Theme.fsInput
                            on: GitaState.view === "go"
                            onClicked: GitaState.view = GitaState.view === "go" ? "read" : "go"
                        }
                        HeadBtn {
                            glyph: "›"
                            size: Theme.fsInput + 2
                            visible: GitaState.loaded
                            onClicked: { GitaState.view = "read"; GitaState.step(1) }
                        }
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        visible: GitaState.loaded
                        // The two optional parts of a page, lit while shown.
                        HeadBtn {
                            visible: GitaState.view === "read"
                            glyph: "Synonyms"
                            size: Theme.fsSub + 1
                            on: GitaState.showSyn
                            onClicked: { GitaState.toggleSyn(); win.focusNow() }
                        }
                        HeadBtn {
                            visible: GitaState.view === "read"
                            glyph: "Purport"
                            size: Theme.fsSub + 1
                            on: GitaState.showPp
                            onClicked: { GitaState.togglePp(); win.focusNow() }
                        }
                        HeadBtn {
                            glyph: scope.gSearch
                            on: GitaState.view === "search"
                            onClicked: GitaState.view = GitaState.view === "search" ? "read" : "search"
                        }
                        HeadBtn {
                            glyph: scope.gActivity
                            on: GitaState.view === "activity"
                            onClicked: GitaState.view = GitaState.view === "activity" ? "read" : "activity"
                        }
                    }
                }
                Rectangle {
                    id: rule
                    x: sheet.pad; width: sheet.width - sheet.pad * 2
                    y: header.y + header.height + 6
                    height: 1
                    color: Theme.hairline
                }

                Item {
                    id: body
                    x: sheet.pad
                    y: rule.y + 14
                    width: sheet.width - sheet.pad * 2
                    height: sheet.height - y - 12

                    // ── no text yet ─────────────────────────────────────────
                    // Only once a read has failed — not while the text is still
                    // loading, which flashed "isn't on this machine" on first open.
                    Column {
                        visible: GitaState.missing && !GitaState.loaded
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 20
                        width: Math.min(parent.width, 460)
                        spacing: 10
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: "The text isn't on this machine yet."
                            font.family: Theme.font; font.pixelSize: Theme.fsInput
                            color: Theme.text
                        }
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            text: "Build it once from a PDF of Bhagavad-gītā As It Is:"
                            font.family: Theme.font; font.pixelSize: Theme.fsSub + 1
                            color: Theme.dim
                        }
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: cmd.implicitWidth + 24; height: 32; radius: 9
                            color: Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
                            border.width: 1; border.color: Theme.hairline
                            Text {
                                id: cmd
                                anchors.centerIn: parent
                                text: GitaState.buildCmd
                                font.family: Theme.font; font.pixelSize: Theme.fsSub + 1
                                color: Theme.text
                            }
                        }
                    }

                    // ── read: one verse ─────────────────────────────────────
                    Flickable {
                        id: page
                        anchors.fill: parent
                        opacity: GitaState.view === "read" && GitaState.loaded ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        visible: opacity > 0.01
                        clip: true
                        contentHeight: pageCol.implicitHeight
                        boundsBehavior: Flickable.StopAtBounds
                        readonly property var v: GitaState.loaded ? GitaState.verses[GitaState.vi] : null
                        // This page's synonyms and purport, once S or P has
                        // had them read.
                        readonly property var extra: v ? GitaState.extras[v.id] : null

                        Column {
                            id: pageCol
                            // A reading measure, not the island's full width.
                            width: Math.min(page.width, 640)
                            x: (page.width - width) / 2
                            spacing: 16

                            Hint {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: GitaState.chapter ? "CHAPTER " + GitaState.chapter.n + "  ·  "
                                      + GitaState.chapter.title.toUpperCase() : ""
                                elide: Text.ElideRight
                                font.letterSpacing: 1.2
                            }
                            // The verse, romanised — with who speaks it set apart
                            // above, never run into it (Ahaan: "clear distinction
                            // from the actual text and the 'arjuna said' thing").
                            // Every page has one: the builder carries the speaker
                            // forward from the last "… uvāca". Where a text
                            // changes speaker partway (13.1-2), each part has its own.
                            Repeater {
                                model: page.v ? page.v.roman : []
                                Column {
                                    id: rpart
                                    required property var modelData
                                    width: pageCol.width
                                    spacing: 8
                                    Speaker { width: parent.width; who: rpart.modelData.who }
                                    Text {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        wrapMode: Text.Wrap
                                        text: rpart.modelData.t
                                        font.family: Theme.font
                                        font.pixelSize: Theme.fsRow + 1
                                        font.italic: true
                                        lineHeight: 1.3
                                        color: Theme.dim
                                    }
                                }
                            }
                            Rectangle {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 40; height: 1
                                color: Theme.hairline
                            }
                            // The translation, with "Arjuna said:" lifted out of
                            // it. A label here only where there is more than one
                            // speaker; otherwise the one above says it.
                            Repeater {
                                model: page.v ? page.v.tr : []
                                Column {
                                    id: tpart
                                    required property var modelData
                                    width: pageCol.width
                                    spacing: 8
                                    Speaker {
                                        width: parent.width
                                        who: page.v && page.v.tr.length > 1 ? tpart.modelData.who : ""
                                    }
                                    Text {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        wrapMode: Text.Wrap
                                        text: tpart.modelData.t
                                        font.family: Theme.font
                                        font.pixelSize: Theme.fsInput
                                        lineHeight: 1.35
                                        color: Theme.text
                                    }
                                }
                            }

                            // S and P: the verse word for word, and the
                            // purport, under the translation and quieter than
                            // it — left-aligned, since they are read as prose,
                            // not as verse. GitaState has how they load.
                            Section {
                                title: "Synonyms"
                                shown: GitaState.showSyn && !!page.extra
                                body: page.extra ? [page.extra.syn] : []
                            }
                            Section {
                                title: "Purport"
                                shown: GitaState.showPp && !!page.extra
                                // The book has none for some texts (1.5, …).
                                body: page.extra ? (page.extra.pp.length ? page.extra.pp : ["No purport to this text."]) : []
                            }
                        }
                    }
                    // The scroll position, a hairline thumb as the jarvis reply has —
                    // only once the island is fully open, so it never shows ahead
                    // of the page it belongs to.
                    Rectangle {
                        visible: page.visible && GitaState.amount > 0.99 && page.contentHeight > page.height + 1
                        x: body.width + 8; width: 3; radius: 1.5
                        y: page.visibleArea.yPosition * page.height
                        height: Math.max(20, page.visibleArea.heightRatio * page.height)
                        color: Theme.alpha(Theme.text, 0.25)
                    }

                    // ── the picker: chapters, then verses ───────────────────
                    Item {
                        anchors.fill: parent
                        opacity: GitaState.view === "go" && GitaState.loaded ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        visible: opacity > 0.01

                        ListView {
                            id: chList
                            width: Math.min(340, parent.width * 0.45)
                            height: parent.height
                            clip: true
                            model: GitaState.chapters
                            currentIndex: win.goCi
                            boundsBehavior: Flickable.StopAtBounds
                            highlightMoveDuration: 0
                            highlightResizeDuration: 0
                            highlight: Rectangle {
                                radius: Theme.rowRadius
                                color: win.goSide === "ch" ? Theme.rowSel : Theme.alpha(Theme.text, 0.05)
                            }
                            delegate: Item {
                                id: crow
                                required property var modelData
                                required property int index
                                width: chList.width
                                height: 36
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: { win.goCi = crow.index; win.goVi = 0; win.goSide = "ch"; win.focusNow() } }
                                Text {
                                    x: 10; width: 22
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: crow.modelData.n
                                    font.family: Theme.font; font.pixelSize: Theme.fsSub + 1
                                    color: Theme.dimmer
                                }
                                Text {
                                    x: 36; width: parent.width - 46
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.verticalCenterOffset: -2
                                    elide: Text.ElideRight
                                    text: crow.modelData.title
                                    font.family: Theme.font; font.pixelSize: Theme.fsRow
                                    color: crow.index === win.goCi ? Theme.text : Theme.alpha(Theme.text, 0.8)
                                }
                                // How much of it has been read — only once some
                                // of it has: a track under every row read as a
                                // list of underlines (first look, 2026-10-21).
                                Rectangle {
                                    visible: GitaState.chapterRead(crow.index) > 0
                                    x: 36; y: parent.height - 9
                                    width: parent.width - 46; height: 2; radius: 1
                                    color: Theme.alpha(Theme.text, 0.06)
                                    Rectangle {
                                        width: parent.width * GitaState.chapterRead(crow.index)
                                        height: parent.height; radius: 1
                                        color: Theme.dim
                                    }
                                }
                            }
                        }

                        Flickable {
                            id: gridFlick
                            x: chList.width + 18
                            width: parent.width - x
                            height: parent.height
                            clip: true
                            contentHeight: gridCol.implicitHeight
                            boundsBehavior: Flickable.StopAtBounds
                            Column {
                                id: gridCol
                                width: gridFlick.width
                                spacing: 10
                                Hint {
                                    text: GitaState.chapters[win.goCi]
                                          ? "CHAPTER " + GitaState.chapters[win.goCi].n + "  ·  " + win.goVerses.length + " TEXTS"
                                          : ""
                                    font.letterSpacing: 1.2
                                }
                                Grid {
                                    id: grid
                                    readonly property real cell: 58
                                    readonly property int cols: Math.max(1, Math.floor((gridCol.width + 6) / (cell + 6)))
                                    columns: cols
                                    spacing: 6
                                    Repeater {
                                        model: win.goVerses
                                        Rectangle {
                                            id: cellR
                                            required property var modelData
                                            required property int index
                                            readonly property bool sel: win.goSide === "v" && index === win.goVi
                                            readonly property bool here: win.goCi === GitaState.ci && index === GitaState.vi
                                            width: grid.cell; height: 30; radius: 8
                                            color: sel ? Theme.rowSel
                                                 : cellHover.hovered ? Theme.alpha(Theme.text, 0.06) : "transparent"
                                            border.width: here ? 1 : 0
                                            border.color: Theme.hairline
                                            Text {
                                                anchors.centerIn: parent
                                                text: cellR.modelData.n.replace("-", "–")
                                                font.family: Theme.font
                                                font.pixelSize: Theme.fsSub + 1
                                                color: cellR.sel || cellR.here ? Theme.text
                                                     : GitaState.readSet[cellR.modelData.id] ? Theme.alpha(Theme.text, 0.8) : Theme.dim
                                            }
                                            HoverHandler { id: cellHover; cursorShape: Qt.PointingHandCursor }
                                            TapHandler {
                                                onTapped: { GitaState.goTo(win.goCi, cellR.index); GitaState.view = "read" }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── search ──────────────────────────────────────────────
                    Item {
                        anchors.fill: parent
                        opacity: GitaState.view === "search" && GitaState.loaded ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        visible: opacity > 0.01

                        Rectangle {
                            id: box
                            width: parent.width
                            height: 38
                            radius: 11
                            color: Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
                            border.width: 1.5
                            border.color: Theme.hairline
                            TextInput {
                                id: search
                                x: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - x - count.width - 24
                                font.family: Theme.font
                                font.pixelSize: Theme.fsRow
                                color: Theme.text
                                clip: true
                                selectionColor: Theme.alpha(Theme.accent, 0.45)
                                onTextEdited: searchDelay.restart()
                                Keys.onEscapePressed: GitaState.view = "read"
                                Keys.onTabPressed: GitaState.view = "go"
                                Keys.onDownPressed: { win.rsel = Math.min(win.rsel + 1, win.results.hits.length - 1); hits.positionViewAtIndex(win.rsel, ListView.Contain) }
                                Keys.onUpPressed: { win.rsel = Math.max(win.rsel - 1, 0); hits.positionViewAtIndex(win.rsel, ListView.Contain) }
                                onAccepted: {
                                    searchDelay.stop()
                                    const h = win.results.hits[win.rsel]
                                    if (!h) { win.results = GitaState.search(text, 200); return }
                                    GitaState.goTo(h.c, h.v)
                                    GitaState.view = "read"
                                }
                                Text {
                                    anchors.fill: parent
                                    verticalAlignment: Text.AlignVCenter
                                    visible: search.text.length === 0
                                    text: "Search the Gītā — \"exact phrase\", -exclude"
                                    font: search.font
                                    color: Theme.dimmer
                                }
                            }
                            Hint {
                                id: count
                                anchors.right: parent.right; anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: search.text.trim() === "" ? "" : win.results.total > win.results.hits.length
                                      ? win.results.hits.length + " of " + win.results.total : String(win.results.total)
                            }
                        }
                        ListView {
                            id: hits
                            y: box.height + 10
                            width: parent.width
                            height: parent.height - y
                            clip: true
                            model: win.results.hits
                            currentIndex: win.rsel
                            boundsBehavior: Flickable.StopAtBounds
                            highlightMoveDuration: 0
                            highlightResizeDuration: 0
                            highlight: Rectangle { radius: Theme.rowRadius; color: Theme.rowSel }
                            delegate: Item {
                                id: hrow
                                required property var modelData
                                required property int index
                                width: hits.width
                                height: hcol.implicitHeight + 16
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: { GitaState.goTo(hrow.modelData.c, hrow.modelData.v); GitaState.view = "read" } }
                                Column {
                                    id: hcol
                                    x: 12; y: 8
                                    width: parent.width - 24
                                    spacing: 3
                                    Text {
                                        text: "Bg " + hrow.modelData.ref.replace("-", "–")
                                        font.family: Theme.font; font.pixelSize: Theme.fsSub + 1; font.bold: true
                                        color: Theme.text
                                    }
                                    Text {
                                        width: parent.width
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                        textFormat: Text.StyledText
                                        text: win.esc(hrow.modelData.snip.pre) + "<b>" + win.esc(hrow.modelData.snip.hit)
                                              + "</b>" + win.esc(hrow.modelData.snip.post)
                                        font.family: Theme.font; font.pixelSize: Theme.fsSub + 2
                                        color: Theme.alpha(Theme.text, 0.75)
                                    }
                                }
                            }
                        }
                    }

                    // ── activity ────────────────────────────────────────────
                    Flickable {
                        anchors.fill: parent
                        opacity: GitaState.view === "activity" && GitaState.loaded ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        visible: opacity > 0.01
                        clip: true
                        contentHeight: act.implicitHeight
                        boundsBehavior: Flickable.StopAtBounds

                        // The record, laid out to the sheet's full width now
                        // the tracking switch is gone (Ahaan, 2026-10-21: "make
                        // the tracker more easy to read … let it take more
                        // space"). It was a 20-week grid of 12 px squares in
                        // the left half, unlabelled, captions at `dimmer`.
                        Column {
                            id: act
                            width: parent.width
                            spacing: 22

                            Hint {
                                text: "READING ACTIVITY" + (GitaState.stats.since ? "   since " + win.fmtDay(GitaState.stats.since, false) : "")
                                font.letterSpacing: 1.2
                                color: Theme.dim
                            }

                            // Four equal columns across the width. Each had a
                            // line under its label saying what it counts ("of
                            // 657 in the Gita" …); Ahaan had them removed.
                            Row {
                                id: statRow
                                width: parent.width
                                Repeater {
                                    model: [
                                        { n: GitaState.stats.verses, l: "verses read" },
                                        { n: GitaState.stats.streak, l: "day streak" },
                                        { n: GitaState.stats.week, l: "this week" },
                                        { n: GitaState.stats.activeDays, l: "active days" },
                                    ]
                                    Column {
                                        required property var modelData
                                        width: statRow.width / 4
                                        spacing: 3
                                        Text {
                                            text: parent.modelData.n
                                            font.family: Theme.font; font.pixelSize: Theme.fsInput + 11; font.bold: true
                                            color: Theme.text
                                        }
                                        Text {
                                            text: parent.modelData.l
                                            font.family: Theme.font; font.pixelSize: Theme.fsRow
                                            color: Theme.alpha(Theme.text, 0.8)
                                        }
                                    }
                                }
                            }

                            // How far through the book, as one bar the width of
                            // the sheet — the same measure as the overview's
                            // per-chapter lines, summed.
                            Column {
                                id: prog
                                width: parent.width
                                spacing: 8
                                readonly property real frac: GitaState.totalVerses ? GitaState.stats.verses / GitaState.totalVerses : 0
                                Item {
                                    width: parent.width
                                    height: progLabel.implicitHeight
                                    Text {
                                        id: progLabel
                                        text: "Through the Gita"
                                        font.family: Theme.font; font.pixelSize: Theme.fsRow
                                        color: Theme.alpha(Theme.text, 0.8)
                                    }
                                    Text {
                                        anchors.right: parent.right
                                        // Under 1% but not none still says so.
                                        text: { const f = prog.frac; return f > 0 && f < 0.01 ? "<1%" : Math.round(f * 100) + "%" }
                                        font.family: Theme.font; font.pixelSize: Theme.fsRow
                                        color: Theme.dim
                                    }
                                }
                                Rectangle {
                                    width: parent.width; height: 6; radius: 3
                                    color: Theme.alpha(Theme.text, 0.08)
                                    Rectangle {
                                        // A sliver, not nothing, once a verse is read.
                                        width: prog.frac > 0 ? Math.max(6, parent.width * prog.frac) : 0
                                        height: parent.height; radius: 3
                                        color: Theme.alpha(Theme.text, 0.75)
                                    }
                                }
                            }

                            // 26 weeks, Monday at the top, this week on the
                            // right; every day named on the left. Hovering a
                            // square names it and its count in the line under
                            // the grid. Squares sized to fill the width (~22 px
                            // at 760); fixed 16 px and centred was tried and
                            // reverted at Ahaan's word (2026-10-21).
                            Column {
                                width: parent.width
                                spacing: 10

                                Text {
                                    text: "Last six months"
                                    font.family: Theme.font; font.pixelSize: Theme.fsRow
                                    color: Theme.alpha(Theme.text, 0.8)
                                }

                                Item {
                                    id: heat
                                    readonly property int weeks: 26
                                    readonly property real gap: 4
                                    readonly property real labelW: 36
                                    readonly property real sq: Math.floor((width - labelW - (weeks - 1) * gap) / weeks)
                                    readonly property real step: sq + gap
                                    readonly property var cells: win.heatCells(weeks)
                                    // The square under the pointer, for its
                                    // border — follows at once. `shown` is the
                                    // one the line below names, and lags it:
                                    // crossing the 4 px gap between two squares
                                    // cleared the hover, so the line flashed
                                    // back to "Today" between every pair
                                    // (Ahaan: "changes … too quickly"). A new
                                    // square lands after 120 ms of rest; leaving
                                    // the grid reverts after 300.
                                    property var hot: null
                                    property var shown: null
                                    onHotChanged: { settle.interval = hot ? 120 : 300; settle.restart() }
                                    Timer { id: settle; onTriggered: heat.shown = heat.hot }
                                    width: parent.width
                                    height: 7 * step + 20
                                    Repeater {
                                        model: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                                        Hint {
                                            required property var modelData
                                            required property int index
                                            y: index * heat.step + (heat.sq - height) / 2
                                            text: modelData
                                            color: Theme.dim
                                        }
                                    }
                                    Repeater {
                                        model: heat.cells
                                        Rectangle {
                                            id: cell
                                            required property var modelData
                                            x: heat.labelW + modelData.w * heat.step
                                            y: modelData.d * heat.step
                                            width: heat.sq; height: heat.sq; radius: 4
                                            visible: !modelData.future
                                            color: Theme.alpha(Theme.text, win.heatAlpha(modelData.n))
                                            readonly property bool hot: heat.hot !== null && heat.hot.k === modelData.k
                                            border.width: modelData.today || hot ? 1.5 : 0
                                            border.color: hot ? Theme.text : Theme.dim
                                            HoverHandler {
                                                onHoveredChanged: {
                                                    if (hovered) heat.hot = cell.modelData
                                                    else if (cell.hot) heat.hot = null
                                                }
                                            }
                                        }
                                    }
                                    Repeater {
                                        model: heat.cells.filter(c => c.d === 0 && c.month !== "")
                                        Hint {
                                            required property var modelData
                                            x: heat.labelW + modelData.w * heat.step
                                            y: 7 * heat.step + 4
                                            text: modelData.month
                                            color: Theme.dim
                                        }
                                    }
                                }

                                // The hovered day, or today; the key on the right.
                                Item {
                                    width: parent.width
                                    height: dayLine.implicitHeight
                                    Text {
                                        id: dayLine
                                        // Swapped at the bottom of a quick fade
                                        // rather than cut, for the same reason
                                        // `shown` lags.
                                        property var c: null
                                        Connections {
                                            target: heat
                                            function onShownChanged() { swap.restart() }
                                        }
                                        SequentialAnimation {
                                            id: swap
                                            NumberAnimation { target: dayLine; property: "opacity"; to: 0; duration: 90; easing.type: Easing.InCubic }
                                            ScriptAction { script: dayLine.c = heat.shown }
                                            NumberAnimation { target: dayLine; property: "opacity"; to: 1; duration: 160; easing.type: Easing.OutCubic }
                                        }
                                        readonly property int n: c ? c.n : GitaState.stats.today
                                        text: (c ? win.fmtDay(c.k, true) + (c.today ? "  (today)" : "")
                                                 : "Today  ·  " + win.fmtDay(GitaState.dayKey(new Date()), true))
                                              + "  ·  " + n + (n === 1 ? " verse" : " verses")
                                        font.family: Theme.font; font.pixelSize: Theme.fsRow
                                        color: Theme.alpha(Theme.text, 0.8)
                                    }
                                    Row {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 4
                                        Hint { text: "less"; color: Theme.dim; anchors.verticalCenter: parent.verticalCenter }
                                        Item { width: 2; height: 1 }
                                        // One square per shade heatAlpha draws.
                                        Repeater {
                                            model: [0, 1, 3, 6, 12]
                                            Rectangle {
                                                required property int modelData
                                                width: 12; height: 12; radius: 3
                                                anchors.verticalCenter: parent.verticalCenter
                                                color: Theme.alpha(Theme.text, win.heatAlpha(modelData))
                                            }
                                        }
                                        Item { width: 2; height: 1 }
                                        Hint { text: "more verses"; color: Theme.dim; anchors.verticalCenter: parent.verticalCenter }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // "2026-10-21" -> "Oct 21", or "Wed Oct 21".
        function fmtDay(k, weekday) {
            const p = k.split("-").map(Number)
            const d = new Date(p[0], p[1] - 1, p[2])
            return Qt.formatDate(d, weekday ? "ddd MMM d" : "MMM d")
        }
        // A day's shade by verses read: five steps rather than a ramp, so the
        // key under the grid can show every shade there is.
        function heatAlpha(n) {
            return n === 0 ? 0.06 : n < 3 ? 0.28 : n < 6 ? 0.48 : n < 12 ? 0.68 : 0.9
        }
        // [{ w, d, k, n, today, future, month }] for the last `weeks` weeks.
        function heatCells(weeks) {
            const today = new Date()
            const todayKey = GitaState.dayKey(today)
            const start = new Date(today)
            start.setDate(start.getDate() - ((start.getDay() + 6) % 7) - (weeks - 1) * 7)
            const out = []
            let lastMonth = -1
            for (let w = 0; w < weeks; w++) {
                for (let d = 0; d < 7; d++) {
                    const day = new Date(start)
                    day.setDate(start.getDate() + w * 7 + d)
                    const k = GitaState.dayKey(day)
                    let month = ""
                    if (d === 0 && day.getMonth() !== lastMonth) {
                        month = Qt.formatDate(day, "MMM")
                        lastMonth = day.getMonth()
                    }
                    out.push({ w: w, d: d, k: k, n: (GitaState.days[k] || []).length,
                               today: k === todayKey, future: k > todayKey, month: month })
                }
            }
            // A month that only shows its last few days in the first column
            // printed "Apr May" on top of each other (first look at the 26-week
            // grid): a label with the next one under three weeks on loses it.
            const lab = out.filter(c => c.month !== "")
            for (let i = 0; i + 1 < lab.length; i++)
                if (lab[i + 1].w - lab[i].w < 3) lab[i].month = ""
            return out
        }
    }
}
