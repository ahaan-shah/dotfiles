//============================================================//
//  Quickshell bar — 1:1 port of the Waybar config            //
//  Target: Quickshell 0.3.0 (Arch)                           //
//                                                            //
//  Install: put this file at  ~/.config/quickshell/shell.qml //
//  Run:      qs      (or `quickshell`)                       //
//  Autostart (hyprland.lua): hl.exec_cmd("qs")               //
//                                                            //
//  Interactions (clicks/scrolls) reuse your EXACT waybar     //
//  commands, and volume/brightness reuse your existing       //
//  scripts, so behaviour is identical.                       //
//                                                            //
//  >>> TO VERIFY ON YOUR MACHINE (search VERIFY)             //
//      1. homeDir (below) if your user isn't "ahaan"         //
//      2. Bluetooth property names (BluetoothDevice.*)       //
//      wifi essid/signal tooltip reads it via `nmcli` — needs //
//      NetworkManager running (icon works regardless).       //
//============================================================//

import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import Quickshell.Bluetooth
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects

Scope {
    id: root

    // ---- VERIFY: home directory (used for pywal colors + scripts) -------------
    property string homeDir: "/home/ahaan"
    property string scriptsDir: homeDir + "/.config/waybar/scripts"

    // ---- fonts (from style.css: 15px, CodeNewRoman Nerd Font Propo) -----------
    readonly property string fontFamily: "CodeNewRoman Nerd Font Propo"
    readonly property int fontSize: 16

    // ---- pywal palette (parsed from ~/.cache/wal/colors-waybar.css) -----------
    // style.css did:  @import '../../.cache/wal/colors-waybar.css'
    // We parse its @define-color lines instead, and reload live when pywal runs.
    property var palette: ({})
    readonly property color colBg:   palette["background"] !== undefined ? palette["background"] : "#1e1e1e"
    readonly property color colFg:   palette["foreground"] !== undefined ? palette["foreground"] : "#dddddd"
    readonly property color colText: palette["text"]       !== undefined ? palette["text"]       : colFg
    readonly property color col7:    palette["color7"]     !== undefined ? palette["color7"]     : "#ffffff"
    readonly property color col9:    palette["color9"]     !== undefined ? palette["color9"]     : "#9aa0a6"
    readonly property color col15:   palette["color15"]    !== undefined ? palette["color15"]    : colFg

    // ---- notification-center theme (mirrors your swaync style.css) ------------
    //   text=@color15 · bg=alpha(bg,.93) · bg-strong=alpha(bg,.95)
    //   mycolor=@color9 · border-color=alpha(@color7,.8)
    readonly property color ncText:   col15
    readonly property color ncBg:     alpha(colBg, 0.93)
    readonly property color ncBgStrong: alpha(colBg, 0.95)
    readonly property color ncAccent: col9
    readonly property color ncBorder: alpha(col7, 0.8)
    readonly property string ncFont: "UbuntuMono Nerd Font"

    // control center open/closed (toggled by the arch button in the bar)
    property bool ccVisible: false

    // calendar dropdown open/closed (toggled by the clock in the bar), and
    // which month it's currently showing (independent of "today")
    property bool calVisible: false
    property int calYear: new Date().getFullYear()
    property int calMonth: new Date().getMonth()          // 0 = January
    readonly property var monthNames: ["January", "February", "March", "April",
        "May", "June", "July", "August", "September", "October", "November", "December"]

    function calDaysInMonth(y, m) { return new Date(y, m + 1, 0).getDate(); }
    function calFirstWeekday(y, m) { return new Date(y, m, 1).getDay(); }   // 0 = Sunday
    function calPrevMonth() { if (calMonth === 0) { calMonth = 11; calYear--; } else calMonth--; }
    function calNextMonth() { if (calMonth === 11) { calMonth = 0; calYear++; } else calMonth++; }
    // pick black/white text for a filled circle so "today" stays legible
    // regardless of how light/dark the current wallpaper's accent color is
    function contrastText(c) { return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? "black" : "white"; }

    // Drives calCells' re-evaluation across midnight. `new Date()` inside a
    // QML property binding is NOT a dependency the binding engine can see, so
    // without reading an actual QML property here, calCells only ever
    // recomputed when calYear/calMonth changed (i.e. month nav) — the "today"
    // dot would silently go stale for the rest of the day the machine stayed
    // up. Minutes precision is cheap and gets the day rollover within a
    // minute of midnight instead of requiring a month-nav round trip.
    SystemClock { id: dayClock; precision: SystemClock.Minutes }

    // 6 weeks x 7 days, including muted leading/trailing days from adjacent
    // months so the grid is always a full rectangle. Recomputes whenever
    // calYear/calMonth change since it reads them directly, and whenever
    // dayClock ticks so the "today" highlight follows a real day rollover.
    readonly property var calCells: {
        var first = calFirstWeekday(calYear, calMonth);
        var days = calDaysInMonth(calYear, calMonth);
        var prevDays = calDaysInMonth(calMonth === 0 ? calYear - 1 : calYear, calMonth === 0 ? 11 : calMonth - 1);
        var today = dayClock.date;
        var cells = [];
        for (var i = 0; i < 42; i++) {
            var dayNum = i - first + 1;
            var inMonth = dayNum >= 1 && dayNum <= days;
            var num = dayNum < 1 ? prevDays + dayNum : (dayNum > days ? dayNum - days : dayNum);
            var isToday = inMonth && num === today.getDate()
                          && calMonth === today.getMonth() && calYear === today.getFullYear();
            cells.push({ num: num, inMonth: inMonth, weekday: i % 7, isToday: isToday });
        }
        return cells;
    }

    // battery hard-coded colours (these were literal hex in style.css)
    readonly property color colCharging: "#26A65B"
    readonly property color colWarning:  "#ffbe61"
    readonly property color colCritical: "#f53c3c"

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    function run(cmd) { Quickshell.execDetached(["sh", "-c", cmd]); }

    // Launches `cmd` pinned to whichever workspace is focused right now, via
    // Hyprland's exec_cmd window-rule (PID-tracked at spawn time) rather than
    // relying on it landing on "whatever's active when the window maps" —
    // that's what let wiremix/bluetui/impala sometimes pop up on a different
    // workspace than the one the user was actually on when they clicked.
    // Confirmed live: forcing { workspace = N } via hl.dsp.exec_cmd placed a
    // freshly spawned kitty window on workspace N even while a different
    // workspace was active at spawn time.
    function runOnCurrentWorkspace(cmd) {
        var ws = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1;
        root.run("hyprctl dispatch \"hl.dsp.exec_cmd('" + cmd + "', { workspace = " + ws + " })\"");
    }

    FileView {
        id: walColors
        path: root.homeDir + "/.cache/wal/colors-waybar.css"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            var css = walColors.text();
            var map = {};
            var re = /@define-color\s+([A-Za-z0-9_]+)\s+([^;]+);/g;
            var m;
            while ((m = re.exec(css)) !== null) { map[m[1]] = m[2].trim(); }
            root.palette = map;
        }
    }

    //========================================================================//
    //  NOTIFICATION BACKEND  (replaces the swaync daemon)                    //
    //========================================================================//
    // This owns org.freedesktop.Notifications. swaync MUST be disabled or it
    // will fight for the same D-Bus name (see the switch-over steps).
    NotificationServer {
        id: notifServer
        keepOnReload: false
        // advertise the same capabilities swaync did (config.json)
        bodySupported: true
        bodyMarkupSupported: true
        bodyImagesSupported: true
        imageSupported: true
        actionsSupported: true
        actionIconsSupported: true
        persistenceSupported: true      // notifications stay in the center as history
        inlineReplySupported: true      // config: notification-inline-replies

        // new notification -> show a transient popup (history is kept automatically
        // in trackedNotifications, mirroring swaync's control center).
        onNotification: (notif) => {
            notif.tracked = true;                       // keep in history
            if (root.dnd) return;                       // Do Not Disturb: no popup, history only
            var timeout = notif.urgency === NotificationUrgency.Critical ? root.tCritical
                        : notif.urgency === NotificationUrgency.Low      ? root.tLow
                        : root.tNormal;
            root.pushPopup(notif, timeout);
        }
    }

    // Do Not Disturb (toggled from the control center)
    property bool dnd: false

    // per-urgency popup timeouts, in ms (config.json: timeout / -low / -critical, seconds)
    readonly property int tNormal:   2000
    readonly property int tLow:      6000
    readonly property int tCritical: 1000

    // live popup list (separate from history). Reassigned so bindings update.
    property var popupList: []
    function pushPopup(n, ms) { popupList = popupList.concat([{ notif: n, ms: ms }]); }
    function dropPopup(n) { popupList = popupList.filter(function (e) { return e.notif !== n; }); }

    function clearAllNotifs() {
        var list = notifServer.trackedNotifications.values;
        for (var i = list.length - 1; i >= 0; i--) list[i].dismiss();
    }

    // active player for the control-center mpris widget (prefer one that's playing)
    readonly property var mprisPlayer: {
        var ps = Mpris.players.values;
        var first = null;
        for (var i = 0; i < ps.length; i++) {
            if (!first) first = ps[i];
            if (ps[i].isPlaying) return ps[i];
        }
        return first;
    }

    // ---- volume / backlight state for the control-center sliders -------------
    // polled only while the center is open; written on drag (reuses pactl/brightnessctl).
    property int volumePercent: 0
    property int brightPercent: 0
    Process {
        id: volRead
        command: ["bash", "-c", "pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}' | tr -d '%' | head -1"]
        stdout: StdioCollector { onStreamFinished: {
            var v = parseInt((this.text || "").trim()); if (!isNaN(v)) root.volumePercent = v; } }
    }
    Process {
        id: brightRead
        command: ["bash", "-c", "echo $(( $(brightnessctl get) * 100 / $(brightnessctl max) ))"]
        stdout: StdioCollector { onStreamFinished: {
            var v = parseInt((this.text || "").trim()); if (!isNaN(v)) root.brightPercent = v; } }
    }
    Timer {
        interval: 500; repeat: true; running: root.ccVisible; triggeredOnStart: true
        onTriggered: { volRead.running = true; brightRead.running = true; }
    }

    //========================================================================//
    //  OSD BACKEND  (replaces swayosd)                                       //
    //========================================================================//
    // Triggered from your keybinds via `qs ipc call osd <volume|brightness|mic>`.
    // Each call reads the current value fresh (so it reflects the change the
    // keybind just made) and shows the pill for ~1.2s.
    property string osdMode: ""          // "volume" | "brightness" | "mic"
    property int  osdValue: 0
    property bool osdMuted: false
    property bool osdShown: false

    Timer { id: osdHideTimer; interval: 1200; onTriggered: root.osdShown = false }
    function osdPresent(mode) { root.osdMode = mode; root.osdShown = true; osdHideTimer.restart(); }

    Process {
        id: osdVolRead
        command: ["bash", "-c",
            "v=$(pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}' | tr -d '%' | head -1); " +
            "m=$(pactl get-sink-mute @DEFAULT_SINK@ | grep -q yes && echo 1 || echo 0); echo \"$v|$m\""]
        stdout: StdioCollector { onStreamFinished: {
            var p = (this.text || "").trim().split("|");
            root.osdValue = Math.min(100, parseInt(p[0]) || 0);
            root.osdMuted = p[1] === "1";
            root.osdPresent("volume");
        } }
    }
    Process {
        id: osdBrightRead
        command: ["bash", "-c", "echo $(( $(brightnessctl get) * 100 / $(brightnessctl max) ))"]
        stdout: StdioCollector { onStreamFinished: {
            root.osdValue = parseInt((this.text || "").trim()) || 0;
            root.osdMuted = false;
            root.osdPresent("brightness");
        } }
    }
    Process {
        id: osdMicRead
        command: ["bash", "-c", "pactl get-source-mute @DEFAULT_SOURCE@ | grep -q yes && echo 1 || echo 0"]
        stdout: StdioCollector { onStreamFinished: {
            root.osdMuted = (this.text || "").trim() === "1";
            root.osdPresent("mic");
        } }
    }

    IpcHandler {
        target: "osd"
        function volume(): void { osdVolRead.running = true; }
        function brightness(): void { osdBrightRead.running = true; }
        function mic(): void { osdMicRead.running = true; }
    }

    //========================================================================//
    //  REUSABLE PIECES                                                       //
    //========================================================================//

    // Text label with the standard hover colour transition (0.3s ease).
    // Emits signals for the actions; wire them up per-module.
    component BarLabel: Text {
        id: lbl
        property color baseColor: root.col7
        property color hoverColor: root.col9
        property bool hoverable: true
        property string tip: ""                 // tooltip text ("" = none)
        signal leftClicked()
        signal rightClicked()
        signal scrolledUp()
        signal scrolledDown()

        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        verticalAlignment: Text.AlignVCenter
        leftPadding: 5; rightPadding: 5          // style.css: padding 0 5px
        color: (hoverable && hover.hovered) ? hoverColor : baseColor
        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }

        HoverHandler { id: hover }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: false
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (e) => e.button === Qt.RightButton ? lbl.rightClicked() : lbl.leftClicked()
            onWheel: (w) => w.angleDelta.y > 0 ? lbl.scrolledUp() : lbl.scrolledDown()
        }

        Tooltip { target: lbl; text: lbl.tip; shown: hover.hovered && lbl.tip !== "" }
    }

    // Waybar-style tooltip: separate popup surface, styled like `tooltip{}`.
    component Tooltip: PopupWindow {
        id: ttip
        required property Item target
        property alias text: ttext.text
        property bool shown: false

        anchor.window: target ? target.QsWindow.window : null
        anchor.rect.x: target ? target.mapToItem(null, 0, 0).x + target.width / 2 - ttip.width / 2 : 0
        anchor.rect.y: target ? target.height + 6 : 0
        visible: shown && text !== ""
        implicitWidth: ttext.implicitWidth + 16
        implicitHeight: ttext.implicitHeight + 10
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            radius: 8
            color: root.colBg                    // tooltip { background:@background }
            Text {
                id: ttext
                anchors.centerIn: parent
                color: root.col7                 // tooltip { color:@color7 }
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
            }
        }
    }

    // An island (one of .modules-left / -center / -right)
    component Island: Rectangle {
        default property alias content: rowInner.data
        radius: 10                               // border-radius:10px
        color: root.alpha(root.colBg, 0.7)       // background: alpha(@background,.7)
        implicitWidth: rowInner.implicitWidth + 14   // padding:7px  (7*2)
        implicitHeight: rowInner.implicitHeight + 14

        // box-shadow: 0 0 2px rgba(0,0,0,.5)
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowBlur: 0.25
            shadowColor: Qt.rgba(0, 0, 0, 0.5)
            shadowVerticalOffset: 0
            shadowHorizontalOffset: 0
        }

        RowLayout {
            id: rowInner
            anchors.centerIn: parent
            spacing: 0
        }
    }

    // returns an image source for a notification (image, else themed app icon)
    function iconFor(n) {
        if (!n) return "";
        if (n.image && n.image !== "") return n.image;
        try { if (n.appIcon && n.appIcon !== "") return Quickshell.iconPath(n.appIcon, ""); } catch (e) {}
        return "";
    }

    // A notification card — used for both the floating popup and the history list.
    // Mirrors .notification in your style.css (bg, 1px border, radius 12, padding 10).
    component NotifCard: Rectangle {
        id: card
        property var notif
        signal closed()
        implicitHeight: cardRow.implicitHeight + 20
        radius: 12
        color: root.ncBg
        border.width: 2
        border.color: root.ncBorder

        RowLayout {
            id: cardRow
            anchors.fill: parent
            anchors.margins: 10                 // .notification-content { padding:10px }
            spacing: 10

            Image {
                source: root.iconFor(card.notif)
                visible: source != ""
                Layout.preferredWidth: visible ? 40 : 0    // notification-icon-size 40
                Layout.preferredHeight: 40
                Layout.alignment: Qt.AlignTop
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 40; sourceSize.height: 40
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: card.notif ? card.notif.summary : ""
                    color: root.ncText
                    font.family: root.ncFont
                    font.pixelSize: 15; font.weight: Font.Medium   // .summary 0.95rem/500
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: card.notif && card.notif.body !== ""
                    text: card.notif ? card.notif.body : ""
                    color: root.ncText
                    font.family: root.ncFont
                    font.pixelSize: 13                              // .body 0.85rem
                    textFormat: Text.StyledText                     // pango-ish markup
                    wrapMode: Text.WordWrap
                    maximumLineCount: 5
                    elide: Text.ElideRight
                }
            }

            Text {                                                  // .close-button
                Layout.alignment: Qt.AlignTop
                text: "\u00d7"
                color: root.ncText
                font.pixelSize: 18
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    onClicked: { if (card.notif) card.notif.dismiss(); card.closed(); }
                }
            }
        }
    }

    // A media transport button (white glyph).
    component MediaBtn: Text {
        property string glyph
        signal clicked()
        text: glyph
        color: "white"
        font.family: root.ncFont
        font.pixelSize: 20
        MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: parent.clicked() }
    }

    // Circular album cover that spins while `spinning` is true (freezes when paused).
    component Vinyl: Item {
        id: v
        property string art: ""
        property bool spinning: false

        Item {
            id: disc
            anchors.fill: parent

            // circular album art (masked into a circle)
            Image {
                id: vLabel
                anchors.fill: parent
                source: v.art
                visible: false
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 300; sourceSize.height: 300
            }
            MultiEffect {
                anchors.fill: parent
                source: vLabel
                maskEnabled: true
                maskSource: vMask
                visible: v.art !== ""
            }
            Item {
                id: vMask
                anchors.fill: parent
                layer.enabled: true
                visible: false
                Rectangle { anchors.fill: parent; radius: width / 2; color: "black" }
            }

            // fallback when there's no cover art
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                visible: v.art === ""
                color: "#3a3a3a"
                Text {
                    anchors.centerIn: parent
                    text: "\uf001"
                    color: Qt.rgba(1, 1, 1, 0.5)
                    font.family: root.ncFont
                    font.pixelSize: parent.width * 0.3
                }
            }

            // Keep the animation always running and pause it instead of stopping,
            // so resuming continues from the current angle (not back to 0).
            NumberAnimation on rotation {
                from: 0; to: 360
                duration: 10000
                loops: Animation.Infinite
                running: true
                paused: !v.spinning
            }
        }

        // static rim
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.color: "white"
            border.width: 1.5 
        }
    }

    // format seconds -> M:SS
    function fmtTime(s) {
        if (!s || s < 0) return "0:00";
        var m = Math.floor(s / 60); var sec = Math.floor(s % 60);
        return m + ":" + (sec < 10 ? "0" : "") + sec;
    }

    // Slider styled like your swaync trough/highlight (accent = @color9).
    // Custom slider (handles its own mouse events so nothing can swallow the drag).
    // Styled like your swaync trough/highlight (accent = @color9).
    component ThemedSlider: Item {
        id: sl
        property real from: 0
        property real to: 100
        property real value: 0
        property bool pressed: slMouse.pressed
        signal moved()

        implicitHeight: 18
        Layout.preferredHeight: 18

        function frac() { return (sl.to > sl.from) ? (sl.value - sl.from) / (sl.to - sl.from) : 0; }

        Rectangle {                                         // trough
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width; height: 6; radius: 3
            color: root.alpha(root.col7, 0.2)
            Rectangle {                                     // highlight
                width: track.width * sl.frac(); height: parent.height
                radius: 3; color: root.ncAccent
            }
        }
        Rectangle {                                         // handle
            width: 16; height: 16; radius: 8; color: root.ncAccent
            anchors.verticalCenter: parent.verticalCenter
            x: (sl.width - width) * sl.frac()
        }
        MouseArea {
            id: slMouse
            anchors.fill: parent
            preventStealing: true
            function apply(mx) {
                var f = Math.max(0, Math.min(1, mx / sl.width));
                sl.value = sl.from + f * (sl.to - sl.from);
                sl.moved();
            }
            onPressed: (e) => apply(e.x)
            onPositionChanged: (e) => { if (pressed) apply(e.x); }
        }
    }

    // Small round nav button for the calendar header (prev/next month/year).
    component CalNavBtn: Rectangle {
        id: navBtn
        signal clicked()
        property string glyph: ""
        Layout.preferredWidth: 28
        Layout.preferredHeight: 28
        radius: 10
        color: navHover.hovered ? root.alpha(root.ncAccent, 0.2) : "transparent"
        HoverHandler { id: navHover }
        Text {
            anchors.centerIn: parent
            text: navBtn.glyph
            color: root.ncText
            font.family: root.ncFont
            font.pixelSize: 13
        }
        MouseArea { anchors.fill: parent; onClicked: navBtn.clicked() }
    }

    //========================================================================//
    //  THE BAR (one per monitor)                                             //
    //========================================================================//
    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            color: "transparent"                 // window#waybar { all:unset }
            anchors { top: true; left: true; right: true }
            implicitHeight: 44
            exclusiveZone: 44                    // waybar "exclusive": true

            //--------------------------------------------------------------//
            //  LEFT ISLAND : custom/notification , hyprland/workspaces      //
            //--------------------------------------------------------------//
            Island {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 5            // margin:5px

                // custom/notification  →  "󰣇"  →  toggles the Quickshell control center
                BarLabel {
                    text: "󰣇"
                    onLeftClicked: { root.calVisible = false; root.ccVisible = !root.ccVisible; }
                }

                // hyprland/workspaces  (persistent 1..4, click to activate)
                Row {
                    id: wsRow
                    Layout.alignment: Qt.AlignVCenter
                    leftPadding: 5; rightPadding: 5     // #workspaces { padding:0 5px }

                    // union of persistent {1,2,3,4} and any live workspace ids
                    property var ids: {
                        var base = [1, 2, 3, 4];
                        var live = Hyprland.workspaces.values.map(w => w.id);
                        for (var i = 0; i < live.length; i++)
                            if (live[i] > 0 && base.indexOf(live[i]) === -1) base.push(live[i]);
                        return base.sort((a, b) => a - b);
                    }

                    Repeater {
                        model: wsRow.ids
                        delegate: Text {
                            required property var modelData
                            property var hws: Hyprland.workspaces.values.find(w => w.id === modelData)
                            property bool isActive: Hyprland.focusedWorkspace
                                                    && Hyprland.focusedWorkspace.id === modelData
                            property bool isEmpty: hws === undefined      // not tracked => no windows

                            text: modelData                              // format-icons map number->number
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            leftPadding: 6; rightPadding: 6              // button padding-left/right:3px
                            verticalAlignment: Text.AlignVCenter

                            // active -> @color7 ; empty -> transparent-ish ; else -> @text
                            color: isActive ? root.col7
                                   : (isEmpty ? Qt.rgba(0, 0, 0, 0.2) : root.colText)
                            Behavior on color { ColorAnimation { duration: 100; easing.type: Easing.InOutQuad } }

                            MouseArea {
                                anchors.fill: parent
                                // Hyprland.dispatch() sends a raw "workspace N" style string over
                                // the IPC socket, which used the same positional dispatcher syntax
                                // hyprctl dispatch used pre-0.55. That protocol now expects a Lua
                                // expression (hl.dsp...), so route this through hyprctl instead of
                                // relying on Quickshell's own (unverified against 0.55) dispatch call.
                                onClicked: root.run("hyprctl dispatch \"hl.dsp.focus({ workspace = " + parent.modelData + " })\"")
                            }
                        }
                    }
                }

                // focused window (macOS-style) — the currently focused app, e.g. "[ kitty ]"
                // ToplevelManager.activeToplevel comes from Quickshell.Wayland (already imported).
                BarLabel {
                    property var toplevel: ToplevelManager.activeToplevel
                    property string appName: {
                        if (!toplevel || !toplevel.appId) return "";
                        var id = toplevel.appId;
                        // Chrome/Chromium/Brave webapps (appId like "chrome-claude.ai__new-Default"):
                        // match the .desktop file by its StartupWMClass and show its Name ("Claude").
                        // "__" is the tell-tale sign of a browser webapp window, so normal apps
                        // (kitty, org.gnome.Text-Editor, ...) skip this and keep the cleaned name below.
                        if (id.indexOf("__") !== -1) {
                            var entry = DesktopEntries.heuristicLookup(id);
                            if (entry && entry.name) return entry.name;
                        }
                        // Everything else: clean reverse-DNS ids, e.g. org.gnome.Text-Editor -> text-editor
                        var parts = id.split(".");
                        return parts[parts.length - 1].toLowerCase();
                    }
                    hoverable: false
                    baseColor: root.col7
                    visible: appName !== ""       // hides when nothing is focused (empty workspace)
                    text: "[ " + appName + " ]"
                }
            }

            //--------------------------------------------------------------//
            //  CENTER ISLAND : clock , mpris                                //
            //--------------------------------------------------------------//
            Island {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter

                // clock  →  {:%a %d %B | %I:%M %p}  →  click: dropdown calendar
                BarLabel {
                    // %a=ddd  %d=dd  %B=MMMM  %I=hh(12h w/ AP)  %M=mm  %p=AP
                    text: Qt.formatDateTime(clock.date, "ddd dd MMMM | hh:mm AP")
                    onLeftClicked: {
                        root.ccVisible = false;
                        if (!root.calVisible) {
                            // always reopen on the current month, not wherever
                            // a previous session left month-nav pointed
                            var d = new Date();
                            root.calYear = d.getFullYear();
                            root.calMonth = d.getMonth();
                        }
                        root.calVisible = !root.calVisible;
                    }
                    SystemClock { id: clock; precision: SystemClock.Seconds }
                }

                // mpris  (spotify)  →  "[   {status_icon} | {dynamic} ]"
                BarLabel {
                    id: mpris
                    // pick the spotify player
                    property var player: {
                        var ps = Mpris.players.values;
                        for (var i = 0; i < ps.length; i++) {
                            var name = (ps[i].identity || "") + " " + (ps[i].dbusName || "");
                            if (name.toLowerCase().indexOf("spotify") !== -1) return ps[i];
                        }
                        return null;
                    }
                    property int st: player ? player.playbackState : MprisPlaybackState.Stopped
                    // status-icons from your config: playing=\uf04c paused=\uf04b stopped=\uf04d
                    property string statusIcon: st === MprisPlaybackState.Playing ? "\uf04c"
                                              : st === MprisPlaybackState.Paused  ? "\uf04b" : "\uf04d"
                    property string title: player ? (player.trackTitle || "").substring(0, 50) : ""

                    // hidden when no player / stopped  (format-stopped / -disconnected = "")
                    visible: player !== null && st !== MprisPlaybackState.Stopped
                    // format: "[ \uf001  {status_icon} | {dynamic} ]"  (\uf001 = music note)
                    text: "[ \uf001  " + statusIcon + " | " + title + " ]"
                    // left-click = play/pause (waybar mpris default), right-click = next
                    onLeftClicked: if (player) player.isPlaying = !player.isPlaying
                    onRightClicked: if (player && player.canGoNext) player.next()
                }
            }

            //--------------------------------------------------------------//
            //  RIGHT ISLAND : group/expand , bluetooth , network , battery //
            //--------------------------------------------------------------//
            Island {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: 5

                //=== group/expand : hover reveals volume+brightness (600ms) ===
                // transition-to-left: revealed items slide out to the LEFT of
                // the  handle. click-to-reveal:false => reveal on hover.
                Item {
                    id: expandGroup
                    implicitHeight: expandInner.implicitHeight
                    implicitWidth: expandInner.implicitWidth
                    property bool expanded: grpHover.hovered
                    HoverHandler { id: grpHover }

                    RowLayout {
                        id: expandInner
                        spacing: 0

                        // ---- drawer (hidden until hover) ----
                        Item {
                            id: drawer
                            clip: true
                            implicitHeight: drawerRow.implicitHeight
                            Layout.preferredWidth: expandGroup.expanded ? drawerRow.implicitWidth : 0
                            opacity: expandGroup.expanded ? 1 : 0
                            Behavior on Layout.preferredWidth { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                            Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }

                            RowLayout {
                                id: drawerRow
                                anchors.right: parent.right   // grow leftward from the handle
                                spacing: 0

                                // custom/volume  (reuses volume.sh + your pactl cmds)
                                BarLabel {
                                    id: volWidget
                                    property string icon: ""
                                    text: icon
                                    tip: volTip
                                    property string volTip: ""
                                    // click -> wiremix ; right-click -> mute ; scroll -> volume
                                    onLeftClicked:   root.runOnCurrentWorkspace("kitty --title wiremix zsh -i -c wiremix")
                                    onRightClicked:  root.run("pactl set-sink-mute @DEFAULT_SINK@ toggle")
                                    onScrolledUp:    root.run("pactl set-sink-volume @DEFAULT_SINK@ +5%")
                                    onScrolledDown:  root.run("pactl set-sink-volume @DEFAULT_SINK@ -5%")

                                    // read volume + mute inline (no external volume.sh dependency)
                                    Process {
                                        id: volProc
                                        command: ["bash", "-c",
                                            "v=$(pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}' | tr -d '%' | head -1); " +
                                            "m=$(pactl get-sink-mute @DEFAULT_SINK@ | grep -q yes && echo 1 || echo 0); echo \"$v|$m\""]
                                        stdout: StdioCollector {
                                            onStreamFinished: {
                                                var p = (this.text || "").trim().split("|");
                                                var muted = p[1] === "1";
                                                volWidget.icon = muted ? "\uf026" : "\uf028";   //  /
                                                volWidget.volTip = muted ? "Muted"
                                                    : ("Volume: " + Math.min(100, parseInt(p[0]) || 0) + "%");
                                            }
                                        }
                                    }
                                    Timer { interval: 1000; running: true; repeat: true; triggeredOnStart: true
                                            onTriggered: volProc.running = true }
                                }

                                // custom/brightness (format is literal 󰃠; tooltip from brightness.sh)
                                BarLabel {
                                    id: brightness
                                    text: "󰃠"
                                    tip: brTip
                                    property string brTip: ""
                                    onScrolledUp:   root.run("brightnessctl set +5%")
                                    onScrolledDown: root.run("brightnessctl set 5%-")

                                    // read brightness inline (no external brightness.sh dependency)
                                    Process {
                                        id: brProc
                                        command: ["bash", "-c", "echo $(( $(brightnessctl get) * 100 / $(brightnessctl max) ))"]
                                        stdout: StdioCollector {
                                            onStreamFinished: {
                                                brightness.brTip = "Brightness: " + (parseInt((this.text || "").trim()) || 0) + "%";
                                            }
                                        }
                                    }
                                    Timer { interval: 1000; running: true; repeat: true; triggeredOnStart: true
                                            onTriggered: brProc.running = true }
                                }

                                // custom/endpoint : the subtle "|" divider
                                // (#custom-endpoint: color transparent + dark text-shadow)
                                Text {
                                    text: "|"
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize
                                    verticalAlignment: Text.AlignVCenter
                                    color: "#FFFFFF"
                                    styleColor: Qt.rgba(0, 0, 0, 1)
                                }
                            }
                        }

                        // ---- handle : custom/expand  "" ----
                        // #custom-expand: color alpha(@foreground,.2); hover: white .2
                        BarLabel {
                            text: ""
                            hoverable: false
                            color: grpHover.hovered ? Qt.rgba(1, 1, 1, 0.2) : root.alpha(root.colFg, 0.2)
                            styleColor: grpHover.hovered ? Qt.rgba(1, 1, 1, 0.5) : Qt.rgba(0, 0, 0, 0.7)
                            style: Text.Outline
                            Behavior on color { ColorAnimation { duration: 300 } }
                        }
                    }
                }

                //=== bluetooth =================================================
                // format:"󰂯"  format-disabled:" 󰂲"  format-connected:"{alias} 󰂯"
                BarLabel {
                    id: bt
                    // VERIFY: Bluetooth.defaultAdapter / .enabled, device.connected / .name
                    property var adapter: Bluetooth.defaultAdapter
                    property bool btOn: adapter ? adapter.enabled : false
                    property var connDev: {
                        var ds = Bluetooth.devices ? Bluetooth.devices.values : [];
                        for (var i = 0; i < ds.length; i++) if (ds[i].connected) return ds[i];
                        return null;
                    }
                    text: !btOn ? " 󰂲"
                          : connDev ? (connDev.name + " 󰂯")
                          : "󰂯"
                    onLeftClicked: root.runOnCurrentWorkspace("kitty --title bluetui zsh -i -c bluetui")
                }

                //=== network ==================================================
                // format-wifi:"\uf1eb"  format-ethernet:"\uef09"  format-disconnected:"\ueb01"
                // Detected by reading /sys/class/net so it works with iwd (impala),
                // NetworkManager, or anything else — no dependency on a specific stack.
                BarLabel {
                    id: net
                    // NB: 'state' and 'signal' are reserved in QML, so use safe names.
                    property string netState: "disconnected"   // "wifi" | "ethernet" | "disconnected"
                    property string essid: ""
                    property string signalPct: ""

                    text: netState === "wifi" ? "\uf1eb"
                          : netState === "ethernet" ? "\uef09" : "\ueb01"

                    // tooltip-format-wifi: "{essid} ({signalStrength}%)" ; ethernet: "{ifname} 🖧" ; else "Error"
                    tip: netState === "wifi"
                            ? (essid + (signalPct !== "" ? " (" + signalPct + "%)" : ""))
                         : netState === "ethernet" ? (essid + " 🖧")
                         : "Error"

                    onLeftClicked: root.runOnCurrentWorkspace("kitty --title impala zsh -i -c impala")

                    Process {
                        id: netProc
                        command: ["bash", "-c",
                            "for i in /sys/class/net/*; do ifc=${i##*/}; [ \"$ifc\" = lo ] && continue; " +
                            "[ \"$(cat \"$i/operstate\" 2>/dev/null)\" = up ] || continue; " +
                            "if [ -d \"$i/wireless\" ] || [ -e \"$i/phy80211\" ]; then " +
                            "  e=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1==\"yes\"{print $2; exit}'); " +
                            "  q=$(awk -v d=\"$ifc:\" '$1==d{s=$3;sub(/\\./,\"\",s);print int(s*100/70)}' /proc/net/wireless 2>/dev/null); " +
                            "  echo \"wifi|$e|$q\"; exit 0; " +
                            "fi; echo \"ethernet|$ifc|\"; exit 0; done; echo 'disconnected||'"]
                        stdout: StdioCollector {
                            onStreamFinished: {
                                var parts = (this.text || "").trim().split("|");
                                net.netState  = parts[0] || "disconnected";
                                net.essid     = parts[1] || "";
                                net.signalPct = parts[2] || "";
                            }
                        }
                    }
                    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true
                            onTriggered: netProc.running = true }
                }

                //=== battery ==================================================
                BarLabel {
                    id: battery
                    property var dev: UPower.displayDevice
                    property int cap: dev ? Math.round(dev.percentage * 100) : 0
                    property bool charging: dev && dev.state === UPowerDeviceState.Charging
                    property var icons: ["󰁻", "󰁼", "󰁾", "󰂀", "󰂂", "󰁹"]
                    property string icon: icons[Math.min(icons.length - 1, Math.max(0, Math.floor(cap / (100 / icons.length))))]

                    // format:"{capacity}% {icon}"  format-charging:"{capacity}% 󰂄"
                    text: charging ? (cap + "% 󰂄") : (cap + "% " + icon)
                    hoverColor: baseColor        // battery colour is state-driven, keep it on hover
                    baseColor: charging ? root.colCharging
                               : cap <= 20 ? root.colCritical
                               : cap <= 30 ? root.colWarning
                               : root.col7

                    // #battery.critical:not(.charging) blink (0.5s alternate)
                    property bool critical: cap <= 20 && !charging
                    SequentialAnimation on opacity {
                        running: battery.critical
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.3; duration: 500 }
                        NumberAnimation { from: 0.3; to: 1.0; duration: 500 }
                    }
                    // Reset on the critical->false transition itself, not on
                    // opacity changes — the animation's `running: critical`
                    // binding just freezes opacity wherever it was mid-fade
                    // when critical flips false, and that freeze doesn't
                    // necessarily fire another opacityChanged for this handler
                    // to catch, so plugging in mid-dim left it stuck dim.
                    onCriticalChanged: if (!critical) opacity = 1
                }
            }
        }
    }

    //========================================================================//
    //  FLOATING NOTIFICATION POPUPS  (top-left, like swaync)                 //
    //========================================================================//
    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            required property var modelData
            screen: modelData
            visible: root.popupList.length > 0
            color: "transparent"
            anchors { top: true; left: true }
            margins { top: 10; left: 10 }
            implicitWidth: 260                       // notification-window-width 250
            implicitHeight: Math.max(1, popupCol.implicitHeight)
            exclusiveZone: 0
            WlrLayershell.layer: WlrLayer.Overlay    // config: "layer": "overlay"
            WlrLayershell.namespace: "quickshell-notifications"

            Column {
                id: popupCol
                width: parent.width
                spacing: 8
                Repeater {
                    model: root.popupList
                    delegate: NotifCard {
                        required property var modelData
                        required property int index
                        width: popupCol.width
                        notif: modelData.notif
                        onClosed: root.dropPopup(modelData.notif)

                        // appear animation
                        opacity: 0
                        Component.onCompleted: opacity = 1
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        // auto-dismiss after the per-urgency timeout (history is kept)
                        Timer {
                            interval: modelData.ms; running: true; repeat: false
                            onTriggered: root.dropPopup(modelData.notif)
                        }
                    }
                }
            }
        }
    }

    //========================================================================//
    //  CONTROL CENTER  (the panel from the screenshot)                       //
    //========================================================================//
    PanelWindow {
        id: ccWin
        visible: root.ccVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }   // full-screen catcher
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top                              // control-center-layer: top
        WlrLayershell.namespace: "quickshell-control-center"
        WlrLayershell.keyboardFocus: root.ccVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // click anywhere outside the panel -> close
        MouseArea { anchors.fill: parent; onClicked: root.ccVisible = false }

        Rectangle {
            id: ccPanel
            width: 320
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.topMargin: 10                    // control-center-margin-top
            anchors.leftMargin: 10                   // control-center-margin-left
            height: Math.min(600, ccWin.height - 20) // control-center-height 600
            radius: 14
            color: root.ncBgStrong
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }       // swallow clicks (don't close)

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                // ---------- MPRIS widget (cover on top, info/controls below) ----------
                // ===== To restyle the whole media box: border/color/radius are on
                // ===== THIS Rectangle (id: mpBox). Fonts use root.ncFont; text sizes
                // ===== are the font.pixelSize values on each Text below.
                Rectangle {
                    id: mpBox
                    Layout.fillWidth: true
                    Layout.preferredHeight: 300
                    visible: root.mprisPlayer !== null && root.mprisPlayer !== undefined
                    radius: 12
                    clip: true
                    color: "#20000000"
                    // border: uncomment / edit these two lines to frame the box
                    border.width: 2
                    border.color: "white"

                    property real trackLen: root.mprisPlayer ? (root.mprisPlayer.length || 0) : 0
                    // live position: bound to the player; the timer below keeps it ticking
                    property real curPos: root.mprisPlayer ? root.mprisPlayer.position : 0
                    property bool seeking: false
                    property real seekPos: 0
                    readonly property real shownPos: seeking ? seekPos : curPos

                    // Quickshell doesn't emit positionChanged every frame (to save CPU);
                    // pulse it once a second while playing so curPos re-reads the position.
                    Timer {
                        interval: 1000; repeat: true
                        running: root.ccVisible && root.mprisPlayer !== null && root.mprisPlayer !== undefined
                                 && root.mprisPlayer.isPlaying && !mpBox.seeking
                        onTriggered: if (root.mprisPlayer) root.mprisPlayer.positionChanged()
                    }

                    // blurred album-art background
                    Image {
                        anchors.fill: parent
                        source: root.mprisPlayer ? (root.mprisPlayer.trackArtUrl || "") : ""
                        visible: source != ""
                        fillMode: Image.PreserveAspectCrop
                        layer.enabled: true
                        layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 48 }
                    }
                    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.6) }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 6

                        // spinning circular cover on top
                        Vinyl {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: 4
                            Layout.preferredWidth: 118
                            Layout.preferredHeight: 118
                            art: root.mprisPlayer ? (root.mprisPlayer.trackArtUrl || "") : ""
                            spinning: root.mprisPlayer ? root.mprisPlayer.isPlaying : false
                        }

                        Text {                                            // title
                            Layout.fillWidth: true; Layout.topMargin: 6
                            horizontalAlignment: Text.AlignHCenter
                            text: root.mprisPlayer ? (root.mprisPlayer.trackTitle || "") : ""
                            color: "white"; font.family: root.ncFont
                            font.pixelSize: 18; font.bold: true; elide: Text.ElideRight
                        }
                        Text {                                            // album
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            visible: text !== ""
                            text: root.mprisPlayer ? (root.mprisPlayer.trackAlbum || "") : ""
                            color: Qt.rgba(1, 1, 1, 0.6); font.family: root.ncFont
                            font.pixelSize: 13; elide: Text.ElideRight
                        }
                        Text {                                            // artist
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: root.mprisPlayer ? (root.mprisPlayer.trackArtist || "") : ""
                            color: Qt.rgba(1, 1, 1, 0.75); font.family: root.ncFont
                            font.pixelSize: 14; elide: Text.ElideRight
                        }

                        Item { Layout.fillHeight: true }   // push controls + progress toward the bottom

                        // controls (play/pause pill in the middle)
                        RowLayout {
                            Layout.alignment: Qt.AlignHCenter
                            spacing: 18
                            MediaBtn {                                    // shuffle
                                glyph: "\uf074"; font.pixelSize: 16
                                color: (root.mprisPlayer && root.mprisPlayer.shuffle) ? root.ncAccent : "white"
                                onClicked: if (root.mprisPlayer) root.mprisPlayer.shuffle = !root.mprisPlayer.shuffle
                            }
                            MediaBtn {                                    // previous
                                glyph: "\uf048"; font.pixelSize: 16
                                onClicked: if (root.mprisPlayer && root.mprisPlayer.canGoPrevious) root.mprisPlayer.previous()
                            }
                            Rectangle {                                   // play / pause pill
                                Layout.preferredWidth: 48; Layout.preferredHeight: 32
                                radius: height / 2
                                color: Qt.rgba(1, 1, 1, 0.92)
                                Text {
                                    anchors.centerIn: parent
                                    text: (root.mprisPlayer && root.mprisPlayer.isPlaying) ? "\uf04c" : "\uf04b"
                                    color: "#1a1a1a"; font.family: root.ncFont; font.pixelSize: 16
                                }
                                MouseArea { anchors.fill: parent
                                    onClicked: if (root.mprisPlayer) root.mprisPlayer.isPlaying = !root.mprisPlayer.isPlaying }
                            }
                            MediaBtn {                                    // next
                                glyph: "\uf051"; font.pixelSize: 16
                                onClicked: if (root.mprisPlayer && root.mprisPlayer.canGoNext) root.mprisPlayer.next()
                            }
                            MediaBtn {                                    // repeat / loop
                                glyph: "\uf01e"; font.pixelSize: 16
                                color: (root.mprisPlayer && root.mprisPlayer.loopState !== MprisLoopState.None) ? root.ncAccent : "white"
                                onClicked: {
                                    if (!root.mprisPlayer) return;
                                    var s = root.mprisPlayer.loopState;
                                    root.mprisPlayer.loopState = s === MprisLoopState.None ? MprisLoopState.Playlist
                                                               : s === MprisLoopState.Playlist ? MprisLoopState.Track
                                                               : MprisLoopState.None;
                                }
                            }
                        }

                        // draggable seek bar
                        Rectangle {
                            id: seekTrack
                            Layout.fillWidth: true
                            Layout.topMargin: 10
                            implicitHeight: 5
                            radius: 3
                            visible: mpBox.trackLen > 0
                            color: Qt.rgba(1, 1, 1, 0.2)

                            Rectangle {                                   // filled portion
                                height: parent.height; radius: 3
                                width: parent.width * Math.max(0, Math.min(1, mpBox.shownPos / mpBox.trackLen))
                                color: "white"
                            }
                            Rectangle {                                   // drag handle
                                width: 12; height: 12; radius: 6; color: "white"
                                y: parent.height / 2 - height / 2
                                x: Math.max(0, Math.min(parent.width - width,
                                       parent.width * (mpBox.shownPos / mpBox.trackLen) - width / 2))
                                visible: mpBox.seeking || handleHover.hovered
                                HoverHandler { id: handleHover }
                            }

                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -8          // easier to grab
                                preventStealing: true
                                enabled: mpBox.trackLen > 0
                                function frac(mx) { return Math.max(0, Math.min(1, mx / seekTrack.width)); }
                                onPressed: (e) => { mpBox.seeking = true; mpBox.seekPos = frac(e.x) * mpBox.trackLen; }
                                onPositionChanged: (e) => { if (pressed) mpBox.seekPos = frac(e.x) * mpBox.trackLen; }
                                onReleased: (e) => {
                                    if (root.mprisPlayer && root.mprisPlayer.canSeek && root.mprisPlayer.positionSupported)
                                        root.mprisPlayer.position = mpBox.seekPos;
                                    mpBox.seeking = false;
                                }
                            }
                        }
                        Text {                                            // time
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: 3
                            visible: mpBox.trackLen > 0
                            text: root.fmtTime(mpBox.shownPos) + " / " + root.fmtTime(mpBox.trackLen)
                            color: Qt.rgba(1, 1, 1, 0.7); font.family: root.ncFont; font.pixelSize: 12
                        }
                    }
                }

                // ---------- title + DND + clear-all ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: "Notification Center"           // title widget text
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 20
                    }
                    // Do Not Disturb toggle (bell / bell-slash, accent when on)
                    Rectangle {
                        Layout.preferredWidth: 46; Layout.preferredHeight: 34
                        radius: 10
                        color: root.dnd ? root.alpha(root.ncAccent, 0.25)
                               : (dndHover.hovered ? root.alpha(root.ncAccent, 0.2) : "transparent")
                        HoverHandler { id: dndHover }
                        Text {
                            anchors.centerIn: parent
                            text: root.dnd ? "\uf1f6" : "\uf0f3"   // bell-slash when on, bell when off
                            color: root.dnd ? root.ncAccent : root.ncText
                            font.family: root.ncFont; font.pixelSize: 16
                        }
                        MouseArea { anchors.fill: parent; onClicked: root.dnd = !root.dnd }
                    }
                    // clear all
                    Rectangle {
                        Layout.preferredWidth: 46; Layout.preferredHeight: 34
                        radius: 10
                        color: clearHover.hovered ? root.alpha(root.ncAccent, 0.2) : "transparent"
                        HoverHandler { id: clearHover }
                        Text {
                            anchors.centerIn: parent
                            text: "󰆴"                          // title button-text
                            color: root.ncText; font.family: root.ncFont; font.pixelSize: 16
                        }
                        MouseArea { anchors.fill: parent; onClicked: root.clearAllNotifs() }
                    }
                }

                // ---------- notifications / empty state ----------
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ColumnLayout {
                        anchors.centerIn: parent
                        visible: notifServer.trackedNotifications.values.length === 0
                        spacing: 8
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "\uf0f3"                     // bell (empty state)
                            color: root.alpha(root.ncText, 0.35)
                            font.family: root.ncFont; font.pixelSize: 64
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "No Notifications"
                            color: root.alpha(root.ncText, 0.5)
                            font.family: root.ncFont; font.pixelSize: 18
                        }
                    }

                    ListView {
                        anchors.fill: parent
                        visible: count > 0
                        model: notifServer.trackedNotifications
                        spacing: 8
                        clip: true
                        delegate: NotifCard {
                            required property var modelData
                            width: ListView.view.width
                            notif: modelData
                        }
                    }
                }

                // ---------- volume slider ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text { text: "\uf028"; color: root.ncText; font.family: root.ncFont; font.pixelSize: 20 }   // volume label
                    ThemedSlider {
                        id: volSlider
                        Layout.fillWidth: true
                        Component.onCompleted: value = root.volumePercent
                        Connections {
                            target: root
                            function onVolumePercentChanged() { if (!volSlider.pressed) volSlider.value = root.volumePercent; }
                        }
                        onMoved: root.run("pactl set-sink-volume @DEFAULT_SINK@ " + Math.round(value) + "%")
                    }
                }

                // ---------- backlight slider ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text { text: "󰃠"; color: root.ncText; font.family: root.ncFont; font.pixelSize: 20 }         // backlight label
                    ThemedSlider {
                        id: brightSlider
                        Layout.fillWidth: true
                        Component.onCompleted: value = root.brightPercent
                        Connections {
                            target: root
                            function onBrightPercentChanged() { if (!brightSlider.pressed) brightSlider.value = root.brightPercent; }
                        }
                        onMoved: root.run("brightnessctl set " + Math.round(value) + "%")
                    }
                }
            }
        }
    }

    //========================================================================//
    //  CALENDAR  (dropdown from the clock — same chrome as the control       //
    //  center: rounded ncBgStrong card, ncBorder outline, ncFont/ncText)     //
    //========================================================================//
    PanelWindow {
        id: calWin
        visible: root.calVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }   // full-screen catcher
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-calendar"
        WlrLayershell.keyboardFocus: root.calVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // click anywhere outside the panel -> close
        MouseArea { anchors.fill: parent; onClicked: root.calVisible = false }

        Rectangle {
            id: calPanel
            width: 300
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: 10                   // matches control-center-margin-top
            implicitHeight: calCol.implicitHeight + 28
            radius: 14
            // deliberately more opaque than ncBgStrong (control center's bg) —
            // requested less see-through specifically for the calendar
            color: root.alpha(root.colBg, 0.98)
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }      // swallow clicks (don't close)

            ColumnLayout {
                id: calCol
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                // ---------- month/year nav ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    CalNavBtn { glyph: ""; onClicked: root.calYear--       }  // «  prev year
                    CalNavBtn { glyph: ""; onClicked: root.calPrevMonth()  }  // ‹  prev month
                    Text {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: root.monthNames[root.calMonth] + " " + root.calYear
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 16
                        font.weight: Font.Medium
                    }
                    CalNavBtn { glyph: ""; onClicked: root.calNextMonth()  }  // ›  next month
                    CalNavBtn { glyph: ""; onClicked: root.calYear++       }  // »  next year
                }

                // ---------- weekday header ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Repeater {
                        model: ["S", "M", "T", "W", "T", "F", "S"]
                        delegate: Text {
                            required property string modelData
                            Layout.preferredWidth: 32
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData
                            color: root.alpha(root.ncText, 0.5)
                            font.family: root.ncFont
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                        }
                    }
                }

                // ---------- day grid ----------
                GridLayout {
                    Layout.fillWidth: true
                    columns: 7
                    rowSpacing: 4
                    columnSpacing: 4

                    Repeater {
                        model: root.calCells
                        delegate: Rectangle {
                            required property var modelData
                            Layout.preferredWidth: 32
                            Layout.preferredHeight: 32
                            radius: 16
                            // weekends get a faint accent tint, today is a solid
                            // accent fill, everything else a subtle neutral tint —
                            // all derived from the live wal palette, not hardcoded
                            color: !modelData.inMonth ? "transparent"
                                   : modelData.isToday ? root.ncAccent
                                   : (modelData.weekday === 0 || modelData.weekday === 6) ? root.alpha(root.ncAccent, 0.15)
                                   : root.alpha(root.col7, 0.08)
                            Text {
                                anchors.centerIn: parent
                                text: modelData.num
                                font.family: root.ncFont
                                font.pixelSize: 13
                                color: !modelData.inMonth ? root.alpha(root.ncText, 0.3)
                                       : modelData.isToday ? root.contrastText(root.ncAccent)
                                       : root.ncText
                            }
                        }
                    }
                }
            }
        }
    }

    //========================================================================//
    //  OSD PILL  (the swayosd-style popup)                                   //
    //========================================================================//
    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            required property var modelData
            screen: modelData
            // drive visibility off the root flag (not off a child, which may not
            // exist while the window is hidden -> it could never become visible)
            visible: root.osdShown
            color: "transparent"
            // anchoring only to bottom centers it horizontally (layer-shell behaviour)
            anchors { bottom: true }
            margins { bottom: 80 }         // sits above your dock; tweak to taste
	    implicitWidth: 300
            implicitHeight: 64
            exclusiveZone: 0
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "quickshell-osd"

            Rectangle {
                id: pill
                anchors.fill: parent
                anchors.margins: 2
                radius: height / 2                       // style.css border-radius 40 -> pill
                color: root.alpha(root.colBg, 0.8)       // window { background: alpha(@background,.8) }
                opacity: root.osdShown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }

                property string icon: {
                    if (root.osdMode === "brightness") return "󰃠";
                    if (root.osdMode === "mic")        return root.osdMuted ? "\uf131" : "\uf130";
                    return root.osdMuted ? "\uf026" : "\uf028";     // volume off / on
                }
                property bool showBar: root.osdMode === "volume" || root.osdMode === "brightness"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 26
                    anchors.rightMargin: 26
                    spacing: 16

                    Text {                               // image { color:@color7 }
                        text: pill.icon
                        color: root.col7
                        font.family: "Ubuntu Nerd Font"
                        font.pixelSize: 24
                    }

                    Rectangle {                          // trough
                        Layout.fillWidth: true
                        visible: pill.showBar
                        implicitHeight: 6
                        radius: 10
                        color: Qt.rgba(1, 1, 1, 0.15)    // trough background
                        Rectangle {                      // progress
                            width: parent.width * (root.osdValue / 100)
                            height: parent.height
                            radius: 10
                            color: root.col7             // progress { background:@color7 }
                        }
                    }
                    // for mic, there's no bar — let the label take the middle
                    Item { Layout.fillWidth: true; visible: !pill.showBar }

                    Text {                               // label { color:@color7 }
                        text: root.osdMode === "mic" ? (root.osdMuted ? "Muted" : "On")
                                                     : (root.osdValue + "%")
                        color: root.col7
                        font.family: "Ubuntu Nerd Font"
                        font.pixelSize: 18
                        font.weight: Font.Medium
                    }
                }
            }
        }
    }
}
