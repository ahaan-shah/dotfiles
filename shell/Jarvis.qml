// Jarvis.qml — the pill, and the flight from the pill to the bar.
//
// SUPER+SPACE (ipc call jarvis fresh) raises the pill on the focused monitor:
// the launcher's own card, to the pixel — Theme.cardWidth, Theme.bg,
// Theme.cardRadius, the 2px Theme.line edge, the 26px search line — because
// Ahaan's spec is that it looks like the app search (2026-10-05), with the
// jarvis orb where a search card would have nothing. It is placed where the
// launcher's card is placed: centred in the screen BELOW the bar's 44px zone,
// the same spot finder's window (which honours that zone) centres it in.
//
// Enter does three things in one motion, and the order is the design:
//   1. the card folds into a circle around the orb (320 ms) — the text goes
//      first, then the edges come in, then the card itself fades, leaving the
//      orb, a little bigger than it sat in the pill;
//   2. the orb flies to its slot in the bar's centre island (560 ms), up
//      first and then across — a quadratic curve whose control point sits
//      above the start, so it rises off the card rather than sliding at the
//      bar — shrinking to the bar's size on the way;
//   3. it lands on the slot's CURRENT position, read every frame, because
//      the slot is still opening while the orb is in the air: the island
//      widens around it, symmetrically, from the moment the flight begins.
//
// This window is ExclusionMode.Ignore — the whole output — because the flight
// ends inside the bar's zone, which a zone-respecting surface cannot draw in.
// While the orb flies it takes no input and no keyboard: whatever jarvis is
// about to do (a screenshot, an app opening) must find the desktop as it was.
//
// Sessions (2026-10-20, when EVE became Claude): SUPER+SPACE (ipc `fresh`)
// starts a new conversation, SUPER+ALT+SPACE (ipc `open`) carries on the
// current one — the other way round for its first few hours.
// Down grows the pill to list EVE's conversations — "New chat" first, then
// newest first — Up/Down walk it, Enter switches, Esc or Up past the top
// closes it. Switching does not send. (A session name on the pill's right
// came and went the same day: Ahaan didn't want it there.)
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io

Scope {
    id: scope

    IpcHandler {
        target: "jarvis"
        function open(): void { JarvisState.open(false, false) }
        function fresh(): void { JarvisState.open(false, true) }
        // SUPER+A: JarvisState.listen says what each press does.
        function voice(): void { JarvisState.listen() }
        function close(): void { JarvisState.prompting ? JarvisState.cancel() : JarvisState.dismiss() }
        function peek(): void { JarvisState.orbClicked() }
        // SUPER+ALT+E: the selected text into a new conversation.
        function selection(): void { JarvisState.sendSelection() }
        // For driving it with no keyboard — which is how a repo instance gets
        // exercised before anything is deployed (CLAUDE.md step 2).
        function ask(text: string): void { JarvisState.open(false, false); askTimer.text = text; askTimer.restart() }
        function allow(): void { JarvisState.allow() }
        function deny(): void { JarvisState.deny() }
        function interrupt(): void { JarvisState.interrupt() }
        function state(): string {
            return JSON.stringify({ phase: JarvisState.phase, prompting: JarvisState.prompting,
                                    mood: JarvisState.mood, queue: JarvisState.queue,
                                    card: JarvisState.card, expanded: JarvisState.expanded,
                                    interactive: JarvisState.interactive,
                                    hidden: JarvisState.hidden, resting: JarvisState.resting,
                                    orb: JarvisState.orbVisible,
                                    session: JarvisState.sessionId, title: JarvisState.sessionTitle,
                                    model: JarvisState.model, sessions: JarvisState.sessions.length })
        }
    }
    Timer {
        id: askTimer
        property string text: ""
        interval: 350
        onTriggered: JarvisState.submit(text)
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property ShellScreen modelData
            screen: modelData

            readonly property bool onThisScreen:
                !Hyprland.focusedMonitor || Hyprland.focusedMonitor.name === modelData.name
            readonly property bool prompting: JarvisState.prompting
            // The motion itself, not the phase: a QUEUED request flies into
            // the orb too, while the phase still belongs to the one running.
            readonly property bool flying: morph.running || flight.running

            anchors { top: true; left: true; right: true; bottom: true }
            exclusionMode: ExclusionMode.Ignore
            visible: onThisScreen && (prompting || flying)
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "jarvis"
            // OnDemand, not Exclusive. Exclusive took every key with nothing able
            // to give them back, so going into an app mid-typing left the pill
            // stuck on screen and Ahaan had to reboot (2026-10-06). OnDemand
            // still gets keys (Esc) and lets focus move; the full-screen mask
            // below makes a click anywhere outside the card a cancel, as on
            // every card here, and a click on the card takes the keyboard back.
            WlrLayershell.keyboardFocus: prompting ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
            // Input everywhere while the pill is up; none at all once it is flying.
            // An explicit full-size item, not `null`: a Region with no item is
            // EMPTY, and under Exclusive that never showed because Exclusive
            // ignored the mask — under OnDemand every click fell through to
            // the apps and the pill never cancelled (measured with a uinput
            // click, 2026-10-06).
            mask: Region { item: win.prompting ? everywhere : noInput }
            Item { id: noInput; width: 0; height: 0 }
            Item { id: everywhere; anchors.fill: parent }

            // ── geometry ────────────────────────────────────────────────
            readonly property real zone: 42   // Bar.qml's root.barZone
            readonly property real pillW: Theme.cardWidth
            readonly property real pillH: 26 + Theme.pad * 2
            // Centred in the screen less the bar's zone, on whichever edge
            // the bar is (UiConfig.barEdge, Settings -> Shell -> Bar).
            // Always hide reserves nothing: centred on the whole screen then.
            readonly property string barEdge: UiConfig.barAutohide === "on" ? "none" : UiConfig.barEdge
            readonly property real cx: barEdge === "left"  ? zone + (width - zone) / 2
                                     : barEdge === "right" ? (width - zone) / 2 : width / 2
            readonly property real cy: barEdge === "top" ? zone + (height - zone) / 2 : height / 2
            readonly property real orbInPill: 20               // the orb's size sitting in the pill
            readonly property real orbBall: 30                 // and once the card has folded round it
            readonly property real circle: 46                  // the folded card's diameter
            readonly property point orbStart: Qt.point(cx - pillW / 2 + Theme.pad + orbInPill / 2, cy)

            // A different greeting each time the pill opens (Ahaan, 2026-10-06:
            // "hey ahaan, wassup? or how can i help you or whats on your
            // mind?"), never the same one twice running. The name is the login
            // name, capitalised, the way the lock screen's "Hello ahaan" gets
            // it — so nothing personal is written into the shell.
            readonly property string who: {
                const u = Quickshell.env("USER") || ""
                return u ? u.charAt(0).toUpperCase() + u.slice(1) : ""
            }
            readonly property var hints: [
                "Hey " + who + ", wassup?",
                "How can I help?",
                "What's on your mind?",
                "What should I do?",
                "Need a hand" + (who ? ", " + who : "") + "?",
                "Tell me what you need",
                "Ready when you are",
            ]
            property string hint: hints[0]
            function newHint() {
                let h = hint
                while (h === hint) h = hints[Math.floor(Math.random() * hints.length)]
                hint = h
            }

            property real m: 0          // morph 0..1
            property real f: 0          // flight 0..1

            function lerp(a, b, t) { return a + (b - a) * t }
            function clamp01(x) { return Math.max(0, Math.min(1, x)) }

            // Where the bar's slot is right now, in this window's coordinates.
            // The bar's window sits at the screen's top-left like this one, so
            // its scene coordinates are already ours.
            function slotCenter() {
                const s = JarvisState.slot
                if (!s) return Qt.point(width / 2, 22)
                const p = s.mapToItem(null, s.width / 2, s.height / 2)
                return Qt.point(p.x, p.y)
            }

            MouseArea {
                anchors.fill: parent
                enabled: win.prompting
                onClicked: JarvisState.cancel()
            }

            // ── the card ────────────────────────────────────────────────
            Rectangle {
                id: card
                readonly property real w: win.lerp(win.pillW, win.circle, win.m)
                readonly property real h: win.lerp(win.pillH, win.circle, win.m)
                // Folds toward the orb, not toward its own centre: the orb is
                // the thing that survives, so the card closes around it.
                readonly property real ccx: win.lerp(win.cx, win.orbStart.x, win.m)
                x: ccx - w / 2
                // The top edge holds still and the session list grows the
                // card DOWN (Ahaan, 2026-10-20: "make the pill expand for this
                // instead of a new pill"); the list is shut before a send, so
                // the fold still starts from the plain pill.
                y: win.cy - h / 2
                width: w; height: h + win.listH
                radius: win.lerp(Theme.cardRadius, win.circle / 2, win.m)
                color: Theme.bg
                border.width: Theme.cardBorder
                border.color: Theme.line
                // The card goes in the last third of the fold, so what is left
                // at the end is the orb alone.
                opacity: (win.prompting || win.flying) ? 1 - win.clamp01((win.m - 0.62) / 0.38) : 0
                visible: opacity > 0.001
                // A click on the pill takes the keyboard back, to resume typing.
                MouseArea { anchors.fill: parent; onPressed: input.forceActiveFocus() }
                // Files dropped on the pill go with the message
                // (JarvisState.attachments); a dragged link goes in as text.
                DropArea {
                    anchors.fill: parent
                    enabled: win.prompting
                    onEntered: drag => { drag.accepted = drag.hasUrls || drag.hasText }
                    onDropped: drop => {
                        const files = (drop.urls || []).map(String).filter(u => u.startsWith("file://"))
                        if (files.length) JarvisState.attach(files)
                        else if (drop.hasUrls && drop.urls.length) input.insert(input.cursorPosition, String(drop.urls[0]))
                        else if (drop.hasText) input.insert(input.cursorPosition, drop.text)
                        input.forceActiveFocus()
                    }
                }
                // What is attached, at the pill's right end; the text gives
                // way to it.
                EveAttachments {
                    id: pillAttach
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.pad
                    y: (card.h - height) / 2
                    maxW: win.pillW * 0.45
                    maxChips: 2
                    opacity: input.opacity
                }

                TextInput {
                    id: input
                    x: Theme.pad + win.orbInPill + 12
                    y: (card.h - height) / 2
                    width: win.pillW - x - Theme.pad - (pillAttach.visible ? pillAttach.width + 10 : 0)
                    height: 26
                    verticalAlignment: TextInput.AlignVCenter
                    font.family: Theme.font
                    font.pixelSize: Theme.fsInput
                    color: Theme.text
                    clip: true
                    selectionColor: Theme.alpha(Theme.accent, 0.45)
                    opacity: 1 - win.clamp01(win.m / 0.3)
                    // A voice request is held until voxtype has finished
                    // typing it in; see waitVoice below.
                    onAccepted: win.listOpen ? win.pick(win.listSel) : win.send()
                    Keys.onEscapePressed: win.listOpen ? (win.listOpen = false) : JarvisState.cancel()
                    // Ctrl+V: a copied image or file attaches, text pastes
                    // (JarvisState.paste). Backspace on empty drops the last.
                    Keys.onPressed: event => {
                        if (event.matches(StandardKey.Paste)) { JarvisState.paste(input); event.accepted = true }
                        else if (event.key === Qt.Key_Backspace && input.text === "" && JarvisState.attachments.length) {
                            JarvisState.detach(-1); event.accepted = true
                        }
                    }
                    Keys.onDownPressed: {
                        if (!win.listOpen) {
                            JarvisState.listSessions()
                            const i = JarvisState.sessions.findIndex(x => x.id === JarvisState.sessionId)
                            win.listSel = i >= 0 ? i + 1 : 0
                            win.listOpen = true
                        } else win.listSel = Math.min(win.listRows - 1, win.listSel + 1)
                    }
                    Keys.onUpPressed: {
                        if (!win.listOpen) return
                        if (win.listSel === 0) win.listOpen = false
                        else win.listSel--
                    }

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        font: input.font
                        color: Theme.dimmer
                        visible: input.text.length === 0
                        text: !JarvisState.voice ? win.hint
                            : JarvisState.voxOff ? "Voice typing is off (Settings, Tools)"
                            : JarvisState.voxState === "recording" ? "Listening…"
                            : JarvisState.voxState === "transcribing" ? "Writing it down…"
                            : win.hint
                    }
                }
            }

            // ── the session list ────────────────────────────────────────
            // Inside the pill, under a hairline: "New chat", then EVE's
            // conversations newest first. The selection is the launcher's —
            // one Theme.rowSel wash the view places, the full width of the
            // row, no outline (Ahaan: the outlined one "looks cheap").
            property bool listOpen: false
            property int listSel: 0
            readonly property int listRows: JarvisState.sessions.length + 1
            readonly property real rowH: 38
            readonly property real listMax: Math.min(listRows, 7) * rowH + 2 * 8 + 1
            property real listH: listOpen ? listMax : 0
            Behavior on listH { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
            function pick(i) {
                JarvisState.useSession(i === 0 ? null : JarvisState.sessions[i - 1])
                listOpen = false
            }
            function ago(t) {
                const s = Math.max(0, Date.now() / 1000 - t)
                return s < 60 ? "now" : s < 3600 ? Math.floor(s / 60) + "m"
                     : s < 86400 ? Math.floor(s / 3600) + "h" : Math.floor(s / 86400) + "d"
            }
            Item {
                id: list
                parent: card
                y: win.pillH
                width: card.width
                height: win.listH
                clip: true
                visible: height > 0.5
                Rectangle {
                    x: Theme.pad; width: parent.width - Theme.pad * 2
                    height: 1
                    color: Theme.hairline
                }
                ListView {
                    id: listView
                    x: 8; y: 9
                    width: parent.width - 16
                    height: win.listMax - 17
                    clip: true
                    model: win.listRows
                    currentIndex: win.listSel
                    boundsBehavior: Flickable.StopAtBounds
                    // The launcher's highlight settings, and its reasons
                    // (Finder.qml): pinned to the row on the frame it changes,
                    // the list scrolling the least it can to keep it in view.
                    highlight: Rectangle {
                        width: listView.width
                        radius: Theme.rowRadius
                        color: Theme.rowSel
                    }
                    highlightFollowsCurrentItem: true
                    highlightMoveDuration: 0
                    highlightResizeDuration: 0
                    highlightMoveVelocity: -1
                    highlightResizeVelocity: -1
                    highlightRangeMode: ListView.ApplyRange
                    preferredHighlightBegin: 0
                    preferredHighlightEnd: height
                    delegate: Item {
                        id: row
                        required property int index
                        readonly property var s: index > 0 ? JarvisState.sessions[index - 1] : null
                        readonly property bool here: !!s && s.id === JarvisState.sessionId
                        width: listView.width
                        height: win.rowH
                        Text {
                            id: rowIcon
                            x: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18
                            text: row.s ? (row.here ? "󰍩" : "󰍪") : "󰐕"
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow
                            color: row.here ? Theme.text : Theme.dim
                        }
                        Text {
                            id: rowAgo
                            anchors.right: parent.right; anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.s ? win.ago(row.s.updated) : ""
                            font.family: Theme.font; font.pixelSize: Theme.fsSub
                            color: Theme.dimmer
                        }
                        Text {
                            anchors.left: rowIcon.right; anchors.leftMargin: 10
                            anchors.right: rowAgo.left; anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.s ? row.s.title : "New chat"
                            elide: Text.ElideRight
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow - 1
                            color: row.index === win.listSel || row.here ? Theme.text : Theme.alpha(Theme.text, 0.75)
                        }
                        TapHandler { onTapped: { win.pick(row.index); input.forceActiveFocus() } }
                    }
                }
            }

            // ── the orb ─────────────────────────────────────────────────
            JarvisOrb {
                id: orb
                headSize: 16
                mood: win.flying ? "think" : (JarvisState.voice && JarvisState.voxState === "recording" ? "ask" : "idle")
                readonly property point from: win.orbStart
                readonly property point to: win.f > 0 ? win.slotCenter() : win.orbStart
                // Up first, then across: the control point is above the start,
                // level with the bar.
                readonly property point ctl: Qt.point(from.x + (to.x - from.x) * 0.15, to.y + 30)
                readonly property real t: win.f
                readonly property real px: (1 - t) * (1 - t) * from.x + 2 * (1 - t) * t * ctl.x + t * t * to.x
                readonly property real py: (1 - t) * (1 - t) * from.y + 2 * (1 - t) * t * ctl.y + t * t * to.y
                x: px - width / 2
                y: py - height / 2
                // 20 in the pill, 30 when the card has folded, 16 in the bar.
                scale: win.f > 0 ? win.lerp(win.orbBall, 16, win.f) / 16
                                 : win.lerp(win.orbInPill, win.orbBall, win.m) / 16
                visible: win.prompting || win.flying
            }

            // ── the motion ──────────────────────────────────────────────
            NumberAnimation {
                id: morph
                target: win; property: "m"; from: 0; to: 1
                duration: 320; easing.type: Easing.InOutCubic
                onFinished: flight.start()
            }
            NumberAnimation {
                id: flight
                target: win; property: "f"; from: 0; to: 1
                duration: 560; easing.type: Easing.InOutCubic
                onFinished: { JarvisState.landed(); win.m = 0; win.f = 0 }
            }

            Connections {
                target: JarvisState
                function onLaunched() { if (win.onThisScreen) { orb.blinkNow(); win.m = 0; win.f = 0; morph.start() } }
            }

            // ── focus, and voice ────────────────────────────────────────
            // A layer surface is not reliably focusable on the frame it maps;
            // the launcher and the reminder prompt both retry, and so does this.
            onPromptingChanged: {
                // A draft is "Continue on the web"'s request, put here to be
                // read and sent by hand (JarvisState.continueOnWeb).
                if (prompting) { input.text = JarvisState.draft; JarvisState.draft = ""; input.cursorPosition = input.text.length
                                 newHint(); m = 0; f = 0; focusTimer.tries = 0; focusTimer.start() }
                listOpen = false
            }
            Timer {
                id: focusTimer
                property int tries: 0
                interval: 40; repeat: true
                onTriggered: {
                    input.forceActiveFocus()
                    if (input.activeFocus || ++tries > 12) {
                        stop()
                        // voxtype types into whatever holds the keyboard, so it
                        // only starts once the pill demonstrably does. There is
                        // one of these per screen, and only this screen's counts.
                        if (JarvisState.voice && win.onThisScreen && input.activeFocus) JarvisState.startVoice()
                    }
                }
            }

            property bool waitVoice: false
            function send() {
                if (JarvisState.voice && JarvisState.voxState !== "idle") {
                    waitVoice = true
                    JarvisState.stopVoice()
                    return
                }
                JarvisState.submit(input.text)
            }
            // Enter while still listening: stop, wait for voxtype to go idle,
            // then a beat for the last characters to land, then send.
            Connections {
                target: JarvisState
                function onVoxStateChanged() {
                    if (win.waitVoice && JarvisState.voxState === "idle") voiceSettle.restart()
                    // Dictating onto words already in the pill: voxtype would
                    // type the new ones hard against the last.
                    if (JarvisState.voice && JarvisState.voxState === "recording" && win.onThisScreen
                            && input.text !== "" && !/\s$/.test(input.text))
                        input.insert(input.cursorPosition, " ")
                }
            }
            Timer {
                id: voiceSettle
                interval: 250
                onTriggered: { win.waitVoice = false; JarvisState.submit(input.text) }
            }
        }
    }
}
