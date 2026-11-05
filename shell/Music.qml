// Music.qml — the music player in the bar's centre island (SUPER+SHIFT+M, or a
// click on the mpris chip).
//
// The island grows down for it as for the todo list (Bar.qml sizes it from
// MusicState); this window draws what is in it, on a full-screen catcher, for
// the reason Todo.qml gives: the bar's surface never takes the keyboard and an
// OnDemand layer that maps does. A click outside the island closes it.
//
// Left, the cover as a disc that spins while playing (Vinyl.qml — the control
// centre's). Right, the title and artist, the transport, a seek bar.
//
// Keys: Space play/pause · Ctrl+Left / Ctrl+Right previous / next track · Left / Right (or Tab) other player · S shuffle ·
// R repeat (off -> all -> track) · 
// Esc closes.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.Mpris

Scope {
    id: scope

    // `qs -p <shell> ipc call music <fn>` — `toggle` is what SUPER+SHIFT+M
    // fires; the rest let a repo instance be exercised with no keyboard
    // (CLAUDE.md step 2).
    IpcHandler {
        target: "music"
        function toggle(): void { MusicState.toggleOpen() }
        function open(): void { MusicState.show() }
        function close(): void { MusicState.close() }
        function playpause(): void { MusicState.playPause() }
        function next(): void { MusicState.next() }
        function prev(): void { MusicState.previous() }
        function shuffle(): void { MusicState.toggleShuffle() }
        function repeat(): void { MusicState.cycleRepeat() }
        function state(): string {
            const p = MusicState.player
            if (!p) return "(no player)"
            return p.identity + " | " + p.trackTitle + " - " + p.trackArtist
                 + " | playing=" + p.isPlaying + " shuffle=" + p.shuffle + " loop=" + p.loopState + " shown=" + MusicState.loopShown
        }
    }

    PanelWindow {
        id: win
        // Kept mapped while the island is still closing, so the content fades
        // out with it.
        visible: MusicState.open || MusicState.amount > 0.01
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-music"
        // OnDemand, never Exclusive — the todo list's measurement: Hyprland
        // routes every click to an Exclusive layer whatever its mask says.
        WlrLayershell.keyboardFocus: MusicState.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        mask: Region { item: MusicState.open ? everywhere : nothing }
        Item { id: everywhere; anchors.fill: parent }
        Item { id: nothing; width: 0; height: 0 }

        MouseArea { anchors.fill: parent; onClicked: MusicState.close() }

        // A layer surface is not reliably focusable on the frame it maps; retry
        // as the todo list does.
        Connections {
            target: MusicState
            function onOpenChanged() {
                if (!MusicState.open) return
                focusTimer.tries = 0
                focusTimer.start()
            }
        }
        Timer {
            id: focusTimer
            property int tries: 0
            interval: 40; repeat: true
            onTriggered: {
                keys.forceActiveFocus()
                if (keys.activeFocus || ++tries > 12) stop()
            }
        }

        function fmt(s) {
            if (!s || s < 0) return "0:00"
            const m = Math.floor(s / 60), sec = Math.floor(s % 60)
            return m + ":" + (sec < 10 ? "0" : "") + sec
        }

        // The part of the island under its clock row, in this window's
        // coordinates — the bar sits at the screen's top-left like this one.
        Item {
            id: area
            readonly property var isl: MusicState.island
            // The player being drawn. It trails MusicState.player by half a
            // slide when the player is swapped (see swap below); everything
            // else reads this, so the old player's cover and title stay on
            // screen while they slide out.
            property var p: null
            Component.onCompleted: p = MusicState.player
            property real slide: 0     // px offset of the content, 0 at rest
            property real fade: 1
            property int slideDir: 1
            property var pending: null
            function swap() {
                if (!MusicState.open || MusicState.amount < 0.9 || !p || !MusicState.player) {
                    seq.stop(); slide = 0; fade = 1; p = MusicState.player; return
                }
                pending = MusicState.player
                slideDir = MusicState.cycleDir
                seq.restart()
            }
            Connections { target: MusicState; function onPlayerChanged() { area.swap() } }
            SequentialAnimation {
                id: seq
                ParallelAnimation {
                    NumberAnimation { target: area; property: "slide"; to: -area.slideDir * 48; duration: 130; easing.type: Easing.InCubic }
                    NumberAnimation { target: area; property: "fade"; to: 0; duration: 130 }
                }
                ScriptAction { script: { area.p = area.pending; area.slide = area.slideDir * 48 } }
                ParallelAnimation {
                    NumberAnimation { target: area; property: "slide"; to: 0; duration: 220; easing.type: Easing.OutCubic }
                    NumberAnimation { target: area; property: "fade"; to: 1; duration: 220 }
                }
            }
            // The island's grown part, wherever the bar is (Island.areaX/Y/W/H
            // in Bar.qml): under the row on a top bar, beside the column on a
            // side one. The bar's surface starts at the screen's top-left on
            // every edge, so its coordinates are this window's.
            x: isl ? isl.areaX : 0
            y: isl ? isl.areaY : 0
            width: isl ? isl.areaW : 0
            height: isl ? isl.areaH : 0
            clip: true
            opacity: Math.max(0, (MusicState.amount - 0.35) / 0.65)

            // Clicks inside the island but on nothing keep the keyboard here.
            MouseArea { anchors.fill: parent; onPressed: keys.forceActiveFocus() }

            Item {
                id: keys
                focus: true
                Keys.onEscapePressed: MusicState.close()
                Keys.onPressed: event => {
                    event.accepted = true
                    if (event.modifiers & (Qt.AltModifier | Qt.MetaModifier)) { event.accepted = false; return }
                    // Previous / next are Ctrl+Left / Ctrl+Right (Ahaan); a bare
                    // arrow switches player. The letters and Space are bare,
                    // so with Ctrl held only the arrows count.
                    const ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                    if (ctrl && event.key !== Qt.Key_Left && event.key !== Qt.Key_Right) { event.accepted = false; return }
                    switch (event.key) {
                    case Qt.Key_Space: MusicState.playPause(); break
                    case Qt.Key_Left: ctrl ? MusicState.previous() : MusicState.cyclePlayer(-1); break
                    case Qt.Key_Right: ctrl ? MusicState.next() : MusicState.cyclePlayer(1); break
                    case Qt.Key_S: MusicState.toggleShuffle(); break
                    case Qt.Key_R: MusicState.cycleRepeat(); break
                    // bare Left / Right walk the players (youtube, spotify, ...)
                    case Qt.Key_Tab: MusicState.cyclePlayer(1); break
                    case Qt.Key_Backtab: MusicState.cyclePlayer(-1); break
                    default: event.accepted = false
                    }
                }
            }

            // The content is laid out once, at the island's final size, and
            // the island's clip uncovers it as it grows — nothing here is
            // resized during the open, which is what keeps it smooth.
            Item {
                id: body
                readonly property real pad: 26
                width: MusicState.targetWidth
                height: MusicState.wantHeight
                x: parent.width / 2 - width / 2 + area.slide
                opacity: area.fade

                Vinyl {
                    id: disc
                    x: body.pad; anchors.verticalCenter: parent.verticalCenter
                    width: 164; height: 164
                    art: area.p ? (area.p.trackArtUrl || "") : ""
                    spinning: area.p ? area.p.isPlaying : false
                }

                Text {
                    visible: !area.p
                    x: disc.x + disc.width + 28
                    width: body.width - x - body.pad
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: "Nothing playing"
                    // same face as a track title
                    color: Theme.text; font.family: Theme.font
                    font.pixelSize: Theme.fsInput + 2; font.bold: true
                }

                // Title, artist and transport, centred on the right half of the
                // player (Ahaan: "shift the name/title to the center").
                Column {
                    id: col
                    visible: !!area.p
                    x: disc.x + disc.width + 28
                    width: body.width - x - body.pad
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        visible: Mpris.players.values.length > 1
                        text: area.p ? (area.p.identity || "") : ""
                        color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: area.p ? (area.p.trackTitle || "") : ""
                        color: Theme.text; font.family: Theme.font
                        font.pixelSize: Theme.fsInput + 2; font.bold: true
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: area.p ? (area.p.trackArtist || "") : ""
                        color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fsRow
                        elide: Text.ElideRight
                    }

                    Item { width: 1; height: 8 }

                    // ── transport: the todo box's buttons ──────────────
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 12
                        height: 54
                        Btn {
                            anchors.verticalCenter: parent.verticalCenter
                            glyph: "\uf074"
                            lit: !!area.p && area.p.shuffle
                            dead: !area.p || !area.p.shuffleSupported
                            onClicked: MusicState.toggleShuffle()
                        }
                        Btn {
                            anchors.verticalCenter: parent.verticalCenter
                            glyph: "\uf048"
                            dead: !area.p || !area.p.canGoPrevious
                            onClicked: MusicState.previous()
                        }
                        Btn {
                            anchors.verticalCenter: parent.verticalCenter
                            big: true
                            glyph: (area.p && area.p.isPlaying) ? "\uf04c" : "\uf04b"
                            dead: !area.p || !area.p.canTogglePlaying
                            onClicked: MusicState.playPause()
                        }
                        Btn {
                            anchors.verticalCenter: parent.verticalCenter
                            glyph: "\uf051"
                            dead: !area.p || !area.p.canGoNext
                            onClicked: MusicState.next()
                        }
                        Btn {
                            anchors.verticalCenter: parent.verticalCenter
                            glyph: "\uf01e"
                            lit: !!area.p && MusicState.loopShown !== MprisLoopState.None
                            // A faint ring on repeat-track: a lit glyph alone cannot
                            // say "all" from "one" (a "1" on the corner was tried
                            // and Ahaan did not like it).
                            ringed: !!area.p && MusicState.loopShown === MprisLoopState.Track
                            dead: !area.p || !area.p.loopSupported
                            onClicked: MusicState.cycleRepeat()
                        }
                    }

                    Item { width: 1; height: 6 }

                    // ── seek bar: the calendar's "Through the year" ────
                    // Times above it, elapsed left and total right, in the same
                    // sizes and tints; a 6 px bar, faint track, 75% fill. The
                    // fill does not ease: it follows a once-a-second position
                    // and an eased one would trail it.
                    Item {
                        id: seek
                        width: parent.width
                        height: seekTimes.implicitHeight + 8 + 6
                        readonly property real len: area.p ? (area.p.length || 0) : 0
                        property bool seeking: false
                        property real seekPos: 0
                        // position is not pushed every frame; pulse it once a
                        // second while playing (the notification center's rule).
                        readonly property real shown: seeking ? seekPos : (area.p ? area.p.position : 0)
                        readonly property real frac: len > 0 ? Math.max(0, Math.min(1, shown / len)) : 0
                        visible: len > 0
                        Timer {
                            interval: 1000; repeat: true
                            running: MusicState.open && !!area.p && area.p.isPlaying && !seek.seeking
                            onTriggered: if (area.p) area.p.positionChanged()
                        }
                        Item {
                            id: seekTimes
                            width: parent.width
                            implicitHeight: elapsed.implicitHeight
                            Text {
                                id: elapsed
                                text: win.fmt(seek.shown)
                                font.family: Theme.font
                                font.pixelSize: Theme.fsSub + 1
                                color: Theme.alpha(Theme.text, 0.8)
                            }
                            Text {
                                anchors.right: parent.right
                                text: win.fmt(seek.len)
                                font.family: Theme.font
                                font.pixelSize: Theme.fsSub + 1
                                color: Theme.dim
                            }
                        }
                        Rectangle {
                            id: track
                            y: seekTimes.implicitHeight + 8
                            width: parent.width; height: 6; radius: 3
                            color: Theme.alpha(Theme.text, 0.08)
                            Rectangle {
                                width: seek.frac > 0 ? Math.max(6, parent.width * seek.frac) : 0
                                height: parent.height; radius: 3
                                color: Theme.alpha(Theme.text, 0.75)
                            }
                        }
                        MouseArea {
                            x: 0; y: track.y - 8
                            width: parent.width; height: track.height + 16
                            preventStealing: true
                            cursorShape: Qt.PointingHandCursor
                            function frac(mx) { return Math.max(0, Math.min(1, mx / track.width)) }
                            onPressed: e => { seek.seeking = true; seek.seekPos = frac(e.x) * seek.len }
                            onPositionChanged: e => { if (pressed) seek.seekPos = frac(e.x) * seek.len }
                            onReleased: {
                                const p = area.p
                                if (p && p.canSeek && p.positionSupported) p.position = seek.seekPos
                                seek.seeking = false
                            }
                        }
                    }
                }
            }
        }
    }

    // Black or white on a filled circle, whatever the wallpaper made the
    // accent (the calendar's rule).
    function onFill(c) { return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? "black" : "white" }

    // A transport button, in the calendar's day circles (Ahaan: "make them
    // like this"): a faint neutral disc, brighter under the pointer. `big` is
    // play/pause, which is the "today" circle — the accent itself, ringed in
    // the text colour. `lit` is a toggle that is on (shuffle, repeat), the
    // calendar's accent wash.
    component Btn: Rectangle {
        id: b
        property string glyph
        property bool ringed: false     // a faint ring round the button
        property bool big: false
        property bool lit: false
        property bool dead: false
        signal clicked()
        width: big ? 54 : 40; height: width
        radius: width / 2
        color: big ? Theme.accent
             : hover.hovered ? Theme.alpha(Theme.text, 0.14)
             : lit ? Theme.alpha(Theme.accent, 0.32)
             : Theme.alpha(Theme.col7, 0.08)
        border.width: (big || ringed) ? 1.5 : 0
        border.color: big ? Theme.text : Theme.alpha(Theme.text, 0.35)
        opacity: dead ? 0.35 : 1
        Behavior on color { ColorAnimation { duration: 120 } }
        Text {
            anchors.centerIn: parent
            // the play triangle sits optically left of its box
            anchors.horizontalCenterOffset: b.big && b.glyph === "\uf04b" ? 1 : 0
            text: b.glyph
            color: b.big ? scope.onFill(Theme.accent) : b.lit ? Theme.accent : Theme.text
            font.family: Theme.font; font.pixelSize: b.big ? 17 : 14
        }
        HoverHandler { id: hover; cursorShape: b.dead ? Qt.ArrowCursor : Qt.PointingHandCursor }
        TapHandler { onTapped: if (!b.dead) b.clicked() }
    }
}
