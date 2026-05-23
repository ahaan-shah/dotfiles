pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell.Io

Item {
    id: root

    property int screenWidth:  1920
    property int screenHeight: 1080

    // Use a custom property — never override `visible` (it's FINAL on Item)
    property bool shown: false

    property int  selectedIndex: 0
    property var  appList: []
    property bool _firstOpen: true

    // ── Pywal colors ─────────────────────────────────────────────
    // Edit these two property names to change what wal colors are used:
    //   _walBg     → pill fill   (currently color0, the darkest bg tone)
    //   _walAccent → pill border (currently color1, first accent)
    property string _walBg:     "#141414"   // fallback until file is read
    property string _walAccent: "#333333"
    property string _walBuf:    ""

    property var _walReader: Process {
        id: walReader
        command: ["bash", "-c", "cat ~/.cache/wal/colors.json"]
        running: true
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._walBuf += data
        }
    }
    property var _walConn: Connections {
        target: walReader
        function onRunningChanged() {
            if (walReader.running) return
            try {
                const j = JSON.parse(root._walBuf)
                // ← Change color0/color1 here to use a different wal color
                root._walBg     = j.colors?.color0 || j.special?.background || "#141414"
                root._walAccent = j.colors?.color7 || "#333333"
            } catch(e) {}
            root._walBuf = ""
        }
    }
    function _reloadWal() { root._walBuf = ""; walReader.running = true }

    // ── Public API ────────────────────────────────────────────────
    function next() {
        if (!shown) _open()
        else selectedIndex = (selectedIndex + 1) % appList.length
    }

    function prev() {
        if (!shown) _open()
        else selectedIndex = (selectedIndex - 1 + appList.length) % appList.length
    }

    function confirm() {
        if (!shown || appList.length === 0) return
        const w = appList[selectedIndex]
        focusProc.command = ["bash", "-c",
            "hyprctl dispatch movetoworkspace e+0,address:" + w.address +
            " && hyprctl dispatch focuswindow address:" + w.address +
            " && hyprctl dispatch bringactivetotop"]
        focusProc.running = true
        _close()
    }

    function dismiss() { _close() }

    function _open() {
        _reloadWal()
        root._firstOpen = true
        WindowList.refresh()  // async — list rebuilt by onWindowsChanged on completion
        shown = true
    }

    function _close() {
        shown = false
        selectedIndex = 0
    }

    function _buildList() {
        // WindowList already sorted MRU: index 0 = current, index 1 = previous
        const sorted = WindowList.windows
            .filter(w => !w.workspaceName.startsWith("special:"))
        root.appList = sorted.map(w => ({
            class:   w.class,
            title:   w.title || w.initialTitle || w.class,
            icon:    IconResolver.resolveForWindow(w),
            address: w.address
        }))
    }

    // Rebuild list when WindowList finishes async refresh — always fresh data
    property var _wlConn: Connections {
        target: WindowList
        function onWindowsChanged() {
            if (!root.shown) return
            root._buildList()
            if (root._firstOpen) {
                // Pre-select index 1 (previous app) so first Alt+Tab lands there
                root.selectedIndex = root.appList.length > 1 ? 1 : 0
                root._firstOpen = false
            } else if (root.selectedIndex >= root.appList.length) {
                root.selectedIndex = Math.max(0, root.appList.length - 1)
            }
        }
    }

    // ── IPC via socat ─────────────────────────────────────────────
    property var ipcProc: Process {
        id: ipcProc
        command: ["bash", "-c",
            "rm -f /tmp/macswitcher.sock && " +
            "socat UNIX-LISTEN:/tmp/macswitcher.sock,fork STDOUT"]
        running: true
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const cmd = data.trim()
                if      (cmd === "next")    root.next()
                else if (cmd === "prev")    root.prev()
                else if (cmd === "confirm") root.confirm()
                else if (cmd === "hide")    root.dismiss()
            }
        }
    }

    property var focusProc: Process {
        id: focusProc
        running: false
    }

    // ── Keyboard ──────────────────────────────────────────────────
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Tab) {
            if (event.modifiers & Qt.ShiftModifier) prev()
            else next()
            event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
            dismiss(); event.accepted = true
        } else if (event.key === Qt.Key_Return) {
            confirm(); event.accepted = true
        }
    }
    Keys.onReleased: event => {
        if ((event.key === Qt.Key_Alt || event.key === Qt.Key_AltGr) && shown) {
            confirm(); event.accepted = true
        }
    }

    // ── Scrim ─────────────────────────────────────────────────────
        MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    // ── Panel ─────────────────────────────────────────────────────
    Item {
        id: panel
        anchors.centerIn: parent

        readonly property int cardSize:   78
        readonly property int gap:        8
        readonly property int iconSize:   50
        readonly property int padH:       20
        readonly property int padV:       18
        readonly property int labelH:     20

        readonly property int count: root.appList.length
        readonly property int panelW: count * (cardSize + gap) - gap + padH * 2

        width:  Math.max(panelW, 160)
        height: cardSize + labelH + 10 + padV * 2

        opacity: root.shown ? 1 : 0
        scale:   root.shown ? 1 : 0.90
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on scale   { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        // Pill background
        Rectangle {
            anchors.fill: parent
            radius: 20
            // ── Pill color — driven by pywal ─────────────────
            // To override with a fixed color instead:
            //   color: Qt.rgba(0.08, 0.08, 0.10, 0.92)
            color: {
                const c = root._walBg
                const r = parseInt(c.slice(1,3),16)/255
                const g = parseInt(c.slice(3,5),16)/255
                const b = parseInt(c.slice(5,7),16)/255
                return Qt.rgba(r, g, b, 0.92)  // ← change last value for transparency
            }
            border.color: {
                const c = root._walAccent
                const r = parseInt(c.slice(1,3),16)/255
                const g = parseInt(c.slice(3,5),16)/255
                const b = parseInt(c.slice(5,7),16)/255
                return Qt.rgba(r, g, b, 0.55)  // ← change last value for border opacity
            }
            border.width: 1
            Behavior on color        { ColorAnimation { duration: 400 } }
            Behavior on border.color { ColorAnimation { duration: 400 } }

            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled:          true
                shadowColor:            Qt.rgba(0, 0, 0, 0.6)
                shadowBlur:             0.85
                shadowVerticalOffset:   10
            }
        }

        // Cards
        Row {
            anchors.centerIn: parent
            spacing: panel.gap

            Repeater {
                model: root.appList

                Item {
                    id: card
                    required property var modelData
                    required property int index

                    readonly property bool sel: root.selectedIndex === index

                    width:  panel.cardSize
                    height: panel.cardSize + panel.labelH + 10

                    // Selection box
                    Rectangle {
                        width:  panel.cardSize
                        height: panel.cardSize
                        radius: 14
                        color:        card.sel ? Qt.rgba(1,1,1,0.15) : "transparent"
                        border.color: card.sel ? Qt.rgba(1,1,1,0.35) : "transparent"
                        border.width: 1
                        Behavior on color        { ColorAnimation { duration: 100 } }
                        Behavior on border.color { ColorAnimation { duration: 100 } }
                    }

                    // Icon
                    Item {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: (panel.cardSize - panel.iconSize) / 2
                        width:  panel.iconSize
                        height: panel.iconSize
                        scale:  card.sel ? 1.10 : 1.0
                        Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                        Image {
                            id: img
                            anchors.fill: parent
                            source:   card.modelData.icon
                            fillMode: Image.PreserveAspectFit
                            smooth:   true
                            visible:  status === Image.Ready
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius: 12
                            visible: img.status !== Image.Ready
                            color:   Qt.rgba(0.25, 0.25, 0.30, 1)
                            Text {
                                anchors.centerIn: parent
                                text:  (card.modelData.class || "?").charAt(0).toUpperCase()
                                color: "white"
                                font.pixelSize: 22
                                font.weight:    Font.Bold
                            }
                        }
                    }

                    // Subtext — shown only for specific apps, hidden for all others
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        width:  panel.cardSize
                        height: panel.labelH
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight

                        readonly property string _cls:   card.modelData.class
                        readonly property string _title: card.modelData.title

                        text: {
                            // kitty        → running command (title = "nvim ~/foo")
                            // nautilus     → open directory  (title = "Documents")
                            // evince       → file name       (title = "report.pdf - …")
                            // text editor  → file name       (title = "main.py - …")
                            // everyone else → nothing
                            if (_cls.includes("kitty"))                return _title
                            if (_cls === "org.gnome.nautilus")         return _title
                            if (_cls === "org.gnome.evince")           return _title.split(" - ")[0]
                            if (_cls === "org.gnome.texteditor")       return _title.split(" - ")[0]
                            return ""
                        }

                        visible:         text !== ""
                        color:           card.sel ? "white" : Qt.rgba(1,1,1,0.55)
                        font.pixelSize:  14
                        font.family:     "Ubuntu Nerd Font"
                        font.weight:     card.sel ? Font.Medium : Font.Normal
                        Behavior on color { ColorAnimation { duration: 100 } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.selectedIndex = card.index; root.confirm() }
                    }
                }
            }
        }

        Text {
            anchors.centerIn: parent
            visible: root.appList.length === 0
            text:  "No windows open"
            color: Qt.rgba(1,1,1,0.8)
            font.family:    "Ubuntu Nerd Font"
            font.pixelSize: 14
        }
    }
}
