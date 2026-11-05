pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Sigil.js" as Sigil

// Settings → System → About: the machine drawn as a sigil, every ring one fact
// about it, the list beside it saying what each ring is. Hover a ring or a row
// (or ↑/↓) to pick it out. Upstream's footer caption saying what the picked
// ring's dots stand for was cut at Ahaan's call (2026-10-21).
//
// Ahaan's ask (2026-10-21), from a recording of erikrjohansson's
// omarchy-machine-mark: "I just want the concentric circles thing, not when it
// unfolds open" — so upstream's strip and the knead into it are gone, and
// with them the per-frame canvas that drew the knead. What is left is the
// resting state upstream draws most cheaply: each ring painted ONCE into its
// own canvas, and the canvases turned by the scene graph. Nothing runs per
// frame in JS; a live reading repaints only the rings whose facts moved.
//
// Not fastfetch: it prints once and has no hover, no motion and no layout
// beyond a logo and lines. It is still where most facts come from — through
// scripts/machine-mark.sh, which is upstream's helper retuned for this
// machine (see its header for the dGPU, which is the one thing it must not
// wake).
//
// A real window (2026-10-21, Ahaan: "make it a real window"), as upstream's
// is: it moves, stacks under other windows, Alt-Tabs, shows in the dock and
// closes with SUPER+W. It was a full-screen Overlay layer at first, like the
// other cards, and sat over everything. hyprland.lua's `about-sigil` rule
// centres it and gives it this size — the global-float rule would otherwise
// put every new window at 1080x675 top-left.
Scope {
    id: root

    readonly property string scriptDir: {
        var dir = String(Quickshell.shellDir || "").replace(/^file:\/\//, "")
        var cut = dir.lastIndexOf("/")
        return cut > 0 ? dir.substring(0, cut) + "/scripts"
                       : (Quickshell.env("HOME") || "") + "/.config/scripts"
    }

    // The last full reading, kept across closes: the next opening draws at
    // once from it and the fresh reading lands a beat later.
    property var machine: null
    property real readAt: 0
    property string loadError: ""

    readonly property var pal: Sigil.palette({
        color15: WalColors.color15, background: WalColors.background,
        color9: WalColors.color9, color4: WalColors.color4,
        color3: WalColors.color3, color5: WalColors.color5 })

    IpcHandler {
        target: "about"
        function open(): void   { AboutState.open() }
        function close(): void  { AboutState.close() }
        function toggle(): void { AboutState.toggle() }
    }

    Connections {
        target: AboutState
        function onShownChanged() { if (AboutState.shown) root.read() }
    }

    function read() { if (!reader.running) reader.running = true }

    Process {
        id: reader
        command: [root.scriptDir + "/machine-mark.sh"]
        stdout: StdioCollector { id: readerOut }
        stderr: StdioCollector { id: readerErr }
        onExited: function(code) {
            var m = null
            try { m = JSON.parse(readerOut.text) } catch (e) {}
            if (code === 0 && m && m.cpu && m.memory) {
                root.loadError = ""
                root.readAt = Date.now()
                root.machine = m
            } else if (!root.machine) {
                root.loadError = "Couldn't read this machine: " + (readerErr.text.trim().split("\n")[0] || "machine-mark.sh failed")
            }
        }
    }

    // While open: memory, battery, uptime and the dGPU's power state every
    // 4 s, from /proc and sysfs only (the helper's `live` mode).
    Timer {
        interval: 4000; repeat: true
        running: AboutState.shown && !!root.machine
        onTriggered: if (!live.running) live.running = true
    }
    Process {
        id: live
        command: [root.scriptDir + "/machine-mark.sh", "live"]
        stdout: StdioCollector { id: liveOut }
        onExited: function(code) {
            var v = null
            try { v = JSON.parse(liveOut.text) } catch (e) {}
            if (code !== 0 || !v || !root.machine || v.now < root.machine.now) return
            var m = JSON.parse(JSON.stringify(root.machine))
            m.memory = v.memory; m.battery = v.battery; m.dgpu = v.dgpu
            m.uptime = v.uptime; m.now = v.now
            root.readAt = Date.now()
            root.machine = m
        }
    }

    // Built only while open: closing frees every ring's canvas.
    LazyLoader {
        active: AboutState.shown

        FloatingWindow {
            id: win
            title: "About"
            color: Theme.bg
            // Opens at 980x550: the height the card had WITH its footer
            // caption, so the rings keep the size they had then (Ahaan: the
            // footer's removal made them "a little too big"). Resizable and
            // tileable since the same day ("allow that too as well as
            // tiling") — it was min = max, which Hyprland treats as a window
            // that cannot be resized. The floor keeps the list's 360 px and a
            // sigil beside it.
            implicitWidth: 980
            implicitHeight: 550
            minimumSize: Qt.size(720, 420)
            // SUPER+W (or any close from outside) unmaps it: follow.
            onVisibleChanged: if (!visible) AboutState.close()

            Card {
                anchors.fill: parent
                dpr: win.screen ? win.screen.devicePixelRatio : 1
            }
        }
    }

    component Card: Rectangle {
        id: card
        property real dpr: 1

        readonly property var m: root.machine
        readonly property var pal: root.pal
        property var geo: null
        property var shown: m ? Sigil.present(m) : []
        // The ring under the pointer or picked with the arrows; -1 for none.
        property int hi: -1
        // Seconds since the reading; ticks so uptime and "updated" move.
        property real elapsed: 0
        readonly property var facts: m ? Sigil.facts(m, elapsed) : null
        readonly property var ss: m && geo ? { machine: m, facts: facts, geo: geo, pal: pal } : null

        // The window's own border and rounding are Hyprland's.
        color: Theme.bg
        focus: true
        Component.onCompleted: forceActiveFocus()

        Keys.onEscapePressed: AboutState.close()
        Keys.onUpPressed:   card.step(-1)
        Keys.onDownPressed: card.step(1)
        function step(d) {
            var n = Sigil.RINGS.length, i = card.hi < 0 ? (d > 0 ? -1 : n) : card.hi
            do { i = (i + d + n) % n } while (!card.shown[i])
            card.hi = i
        }

        Timer {
            interval: 30000; repeat: true; running: true
            onTriggered: card.elapsed = (Date.now() - root.readAt) / 1000
        }
        Connections {
            target: root
            function onReadAtChanged() { card.elapsed = 0 }
        }

        // Seconds since the card opened, stepped at 30 Hz. The rings turn at
        // 2-7.5 deg/s, a fraction of a pixel per 120 Hz frame at the rim, and
        // a NumberAnimation on each made the whole 2880x1620 surface render
        // every one of those frames: measured 17% of a core with the card
        // open. Stepping one clock at 30 Hz renders a quarter as often and the
        // motion still moves under a pixel a step.
        property real clock: 0
        Timer {
            interval: 33; repeat: true; running: true
            property real t0: Date.now()
            onTriggered: card.clock = (Date.now() - t0) / 1000
        }

        // A new shape only when the hardware or history does; live readings
        // keep it and repaint the rings whose facts moved.
        property string geoKey: ""
        onMChanged: {
            if (!m) return
            var key = [m.host, m.cpu.name, m.cpu.threads, m.installed, m.packages.pacman, m.upgrades, m.wallpapers.count, m.palettes.count].join("|")
            if (key !== geoKey) { geoKey = key; geo = Sigil.geometry(m) }
        }

        // ── header ────────────────────────────────────────────────────────
        Item {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 64
            Text {
                id: logo
                anchors { left: parent.left; leftMargin: Theme.pad; verticalCenter: parent.verticalCenter }
                text: ""   // nf-linux-archlinux
                color: card.pal.accent
                font { family: Theme.font; pixelSize: 30 }
            }
            Column {
                anchors { left: logo.right; leftMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 2
                Text {
                    text: card.m ? card.m.host : "About"
                    color: Theme.text
                    font { family: Theme.font; pixelSize: Theme.fsRow; bold: true }
                }
                Text {
                    text: card.m ? card.m.os + " · " + card.m.wm.name + " " + card.m.wm.version + " · Linux " + card.m.kernel : ""
                    color: Theme.dim
                    font { family: Theme.font; pixelSize: Theme.fsSub }
                }
            }
        }
        Rectangle {
            anchors { top: header.bottom; left: parent.left; right: parent.right }
            height: 1; color: Theme.hairline
        }

        // ── sigil ─────────────────────────────────────────────────────────
        Item {
            id: body
            anchors { top: header.bottom; bottom: parent.bottom; left: parent.left; right: parent.right }

            readonly property real listW: 360
            readonly property real cx: (width - listW) / 2 + 6
            readonly property real cy: height / 2
            readonly property real rad: Math.max(40, Math.floor(Math.min(width - listW - 24, height - 24) / 2))

            // The radius the canvases were last PAINTED at. A drag-resize
            // changes rad every frame, and repainting fifteen canvases each
            // time is a stutter; so during a resize the painted rings are
            // scaled (sig.scale below) and repainted sharp 150 ms after the
            // size stops moving.
            property real paintRad: rad
            onRadChanged: settle.restart()
            Timer { id: settle; interval: 150; onTriggered: body.paintRad = body.rad }

            // Everything drawn, centred on (cx, cy): a zero-size item, so its
            // scale pivots on the sigil's centre.
            Item {
                id: sig
                x: body.cx; y: body.cy
                scale: body.rad / body.paintRad

            // The centre dot and the two dividers, painted once.
            Canvas {
                id: deco
                readonly property real side: Math.ceil(body.paintRad * 2 + 8)
                width: side * card.dpr; height: side * card.dpr
                x: -width / 2; y: -height / 2
                onSideChanged: requestPaint()
                scale: 1 / card.dpr
                opacity: card.hi < 0 ? 1 : 0.5
                Behavior on opacity { NumberAnimation { duration: 140 } }
                onPaint: {
                    var c = getContext("2d"); c.reset()
                    Sigil.paintDeco(c, width, body.paintRad * card.dpr, card.dpr, card.pal)
                }
                Connections {
                    target: card
                    function onPalChanged() { deco.requestPaint() }
                }
            }

            Repeater {
                model: Sigil.RINGS.length
                delegate: Canvas {
                    id: ring
                    required property int index
                    readonly property var spec: Sigil.RINGS[index]
                    readonly property real side: Math.ceil(body.paintRad * spec.r[1] * 2 + 10)
                    visible: !!card.shown[index]
                    width: side * card.dpr; height: side * card.dpr
                    x: -width / 2; y: -height / 2
                    scale: 1 / card.dpr
                    // The rings build in one by one from the centre when the
                    // card opens (upstream's 45 ms stagger, 420 ms each).
                    property real build: 0
                    opacity: build * (card.hi < 0 || card.hi === index ? 1 : Sigil.DIM_RING)
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    SequentialAnimation {
                        running: !!card.ss
                        PauseAnimation { duration: ring.index * 45 }
                        NumberAnimation { target: ring; property: "build"; to: 1; duration: 420; easing.type: Easing.InOutCubic }
                    }

                    // Turned by the scene graph off card.clock; the dials
                    // (Updated, Uptime) stand still with 0 at 12 o'clock.
                    readonly property real rate: card.facts ? Sigil.degPerSec(index, card.facts) : 0
                    readonly property real start: card.geo && !spec.fixed ? card.geo.offC[index] * 360 : 0
                    rotation: (start + rate * card.clock) % 360

                    // What this ring's marks depend on. A repaint only when
                    // it changes — a live reading moves three or four rings.
                    readonly property string paintKey: {
                        var m = card.m, f = card.facts
                        if (!m || !card.geo) return ""
                        var k = spec.k, v = ""
                        if (k === "mem") v = Math.round(f.mem * 400)
                        else if (k === "bat") v = m.battery ? m.battery.capacity + "/" + m.battery.status : ""
                        else if (k === "gpu") v = m.dgpu + "/" + m.gpus.map(function(g) { return g.cores }).join(",")
                        else if (k === "up") v = Math.floor(f.upSec / 600)
                        else if (k === "since") v = Math.floor(f.sinceH * 4)
                        else if (k === "disk") v = Math.round(f.disk * 400)
                        return card.geoKey + "|" + body.paintRad + "|" + card.dpr + "|" + JSON.stringify(card.pal) + "|" + v
                    }
                    onPaintKeyChanged: if (paintKey) requestPaint()
                    onPaint: {
                        var c = getContext("2d"); c.reset()
                        if (!card.ss) return
                        Sigil.paintRing(c, index, width, body.paintRad * card.dpr, card.dpr * body.paintRad / 200, card.dpr, card.ss)
                    }
                }
            }
            }

            // Which ring the pointer is over, by distance from the centre.
            MouseArea {
                x: body.cx - body.rad; y: body.cy - body.rad
                width: body.rad * 2; height: body.rad * 2
                hoverEnabled: true
                onPositionChanged: function(e) {
                    var d = Math.sqrt(Math.pow(e.x - body.rad, 2) + Math.pow(e.y - body.rad, 2)) / body.rad, hit = -1
                    for (var i = 0; i < Sigil.RINGS.length; i++) {
                        var r = Sigil.RINGS[i].r
                        if (card.shown[i] && d >= r[0] - 0.01 && d < r[1] + 0.005) { hit = i; break }
                    }
                    card.hi = hit
                }
                onExited: card.hi = -1
            }

            Text {
                visible: !card.m
                anchors.centerIn: parent
                text: root.loadError || "Reading this machine…"
                color: Theme.dim
                font { family: Theme.font; pixelSize: Theme.fsRow }
            }

            // ── the list ──────────────────────────────────────────────────
            Column {
                id: list
                visible: !!card.m
                anchors { right: parent.right; rightMargin: Theme.pad; verticalCenter: parent.verticalCenter }
                width: body.listW - Theme.pad
                readonly property real rowH: Math.min(26, (body.height - 16) / 18)

                Repeater {
                    model: Sigil.RINGS.length
                    delegate: Column {
                        id: entry
                        required property int index
                        readonly property var spec: Sigil.RINGS[index]
                        readonly property bool firstOfCat: index === 0 || Sigil.RINGS[index - 1].cat !== spec.cat
                        width: list.width
                        visible: !!card.shown[index]

                        // Section head: the name in its colour, then a rule.
                        Item {
                            visible: entry.firstOfCat
                            width: parent.width; height: list.rowH
                            Text {
                                id: catName
                                anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                                text: Sigil.CAT_NAME[entry.spec.cat]
                                color: card.pal.cat[entry.spec.cat]
                                font { family: Theme.font; pixelSize: Theme.fsSub; bold: true }
                            }
                            Rectangle {
                                anchors { left: catName.right; leftMargin: 10; right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                height: 1; color: card.pal.cat[entry.spec.cat]; opacity: 0.3
                            }
                        }

                        Rectangle {
                            width: parent.width; height: list.rowH
                            radius: 6
                            readonly property bool picked: card.hi === entry.index
                            color: picked ? Theme.rowSel : "transparent"
                            opacity: card.hi < 0 || picked ? 1 : 0.55
                            Behavior on opacity { NumberAnimation { duration: 140 } }

                            Canvas {
                                id: ic
                                width: 18 * card.dpr; height: 12 * card.dpr
                                scale: 1 / card.dpr
                                x: 6 - (width - 18) / 2; anchors.verticalCenter: parent.verticalCenter
                                readonly property string key: card.ss ? Sigil.value(entry.spec.k, card.m, card.facts) + JSON.stringify(card.pal) + card.m.dgpu : ""
                                onKeyChanged: requestPaint()
                                onPaint: {
                                    var c = getContext("2d"); c.reset()
                                    if (!card.ss) return
                                    c.scale(card.dpr, card.dpr)
                                    Sigil.icon(c, entry.spec.k, 1, 6, Sigil.ringColor(entry.spec.k, card.pal), card.ss)
                                }
                            }
                            Text {
                                x: 34; anchors.verticalCenter: parent.verticalCenter
                                text: entry.spec.name
                                color: parent.picked ? Theme.text : Theme.dim
                                font { family: Theme.font; pixelSize: Theme.fsSub + 1; bold: parent.picked }
                            }
                            Text {
                                x: 132; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - x - 6
                                elide: Text.ElideRight
                                text: card.m ? Sigil.value(entry.spec.k, card.m, card.facts) : ""
                                color: Theme.text
                                font { family: Theme.font; pixelSize: Theme.fsSub + 1 }
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: card.hi = entry.index
                                onExited: if (card.hi === entry.index) card.hi = -1
                            }
                        }
                    }
                }
            }
        }
    }
}
