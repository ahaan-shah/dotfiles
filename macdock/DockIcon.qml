pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Io

Item {
    id: root

    // ── Inputs ────────────────────────────────────────────────────
    property string appName:     ""
    property string iconPath:    ""
    property string command:     ""
    property bool   separator:   false
    property string windowClass: ""

    // magnification state fed by parent Dock
    property real dockHoverX: -1          // mouse X in dock-row coords, –1 = no hover
    property int  baseSize:   48
    property int  maxSize:    72
    property int  magnRadius: 140

    // ── Running / active state (queried from WindowTracker) ───────
    readonly property var   matchedWindows: WindowTracker.windowsFor(windowClass, appName)
    readonly property bool  isRunning:      matchedWindows.length > 0
    readonly property bool  isActive:       matchedWindows.length > 0 &&
                                            matchedWindows.some(w => w.address === WindowTracker.activeAddress)

    // ── Geometry ──────────────────────────────────────────────────
    // Centre of this icon in the row (used by parent to feed dockHoverX back)
    readonly property real iconCenterX: x + width / 2

    readonly property real _dist: dockHoverX < 0
                                  ? magnRadius + 1
                                  : Math.abs(iconCenterX - dockHoverX)

    readonly property real _magnFactor: _dist >= magnRadius
                                        ? 0
                                        : Math.cos((_dist / magnRadius) * (Math.PI / 2))

    readonly property real targetSize: baseSize + (maxSize - baseSize) * _magnFactor

    property real currentSize: baseSize
    Behavior on currentSize {
        NumberAnimation { duration: 80; easing.type: Easing.OutCubic }
    }
    onTargetSizeChanged: currentSize = targetSize

    // Width tracks animated size; height is fixed so the pill doesn't resize
    width:  separator ? 18 : Math.round(currentSize) + 8
    height: maxSize + 24     // constant: icon bottom + dot clearance

    // Smooth fade in/out when dynamic icons appear or disappear
    opacity: 1
    Behavior on opacity {
        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
    }
    Component.onCompleted: { opacity = 0; opacity = 1 }

    // ── Separator bar ─────────────────────────────────────────────
    Rectangle {
        visible: root.separator
        anchors.centerIn: parent
        width:  1
        height: root.baseSize * 0.65
        color:  Qt.rgba(1, 1, 1, 0.30)
    }

    // ── Icon container ────────────────────────────────────────────
    Item {
        id: iconItem
        visible: !root.separator

        width:  root.currentSize
        height: root.currentSize

        // Sits on the bottom of the cell; leaves room for the running dot
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom:           parent.bottom
        anchors.bottomMargin:     11


        // Press scale
        scale: mouseArea.pressed ? 0.88 : 1.0
        Behavior on scale { NumberAnimation { duration: 70 } }

        // ── App icon image ────────────────────────────────────────
        Image {
            id: iconImg
            anchors.fill: parent
            source:       root.iconPath
            sourceSize.width:  root.maxSize * 2
            sourceSize.height: root.maxSize * 2
            smooth:      true
            mipmap:      true
            fillMode:    Image.PreserveAspectFit

            // Fallback coloured tile with initial letter
            Rectangle {
                visible: iconImg.status === Image.Error
                         || iconImg.status === Image.Null
                         || (iconImg.status === Image.Ready && iconImg.paintedWidth <= 0)
                anchors.fill: parent
                radius: parent.width * 0.22
                color:  "#5A72D8"

                Text {
                    anchors.centerIn: parent
                    text:       root.appName.length > 0 ? root.appName[0].toUpperCase() : "?"
                    color:      "white"
                    font.pixelSize:  parent.width * 0.45
                    font.weight:     Font.Medium
                }
            }
        }


    }

    // ── Running indicator dot(s) ──────────────────────────────────
    Row {
        visible: root.isRunning && !root.separator
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom:           parent.bottom
        anchors.bottomMargin:     3
        spacing: 2

        // Dot 1 — always shown when running
        Rectangle {
            width:  4
            height: 4
            radius: 2
            color:  root.isActive ? "white" : Qt.rgba(1, 1, 1, 0.50)
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 150 } }
        }
        // Dot 2 — shown when 2 windows open
        Rectangle {
            visible: root.matchedWindows.length >= 2
            width:  4; height: 4; radius: 2
            color:  Qt.rgba(1, 1, 1, 0.55)
            anchors.verticalCenter: parent.verticalCenter
        }
        // Dot 3 — shown when 3 windows open
        Rectangle {
            visible: root.matchedWindows.length >= 3
            width:  4; height: 4; radius: 2
            color:  Qt.rgba(1, 1, 1, 0.55)
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // ── Tooltip ───────────────────────────────────────────────────
    ToolTip {
        id: toolTip
        visible:  mouseArea.containsMouse && !root.separator
        text:     root.appName
        delay:    400
        timeout:  3000

        contentItem: Text {
            text:            toolTip.text
            color:           "white"
            font.pixelSize:  13
            font.weight:     Font.Medium
        }

        background: Rectangle {
            color:  Qt.rgba(0.1, 0.1, 0.1, 0.85)
            radius: 8
            border.color: Qt.rgba(1, 1, 1, 0.15)
            border.width: 1
        }
    }

    // ── Mouse ─────────────────────────────────────────────────────
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton

        onClicked: mouse => {
            if (root.separator) return

            if (mouse.button === Qt.MiddleButton) {
                // Middle-click: always launch a fresh instance
                if (root.command !== "") {
                    launchProc.running = true
                }
                return
            }

            // Left-click
            const wins = root.matchedWindows
            if (wins.length === 0) {
                // Nothing running → launch
                if (root.command !== "") {
                    launchProc.running = true
                }
            } else if (wins.length === 1) {
                focusAddr.addr = wins[0].address
                focusAddr.running = true
            } else {
                // Cycle: focus the next window of this class
                cycleClass.running = true
            }
        }
    }

    // ── Processes ─────────────────────────────────────────────────
    Process {
        id: launchProc
        command: root.command !== "" ? ["bash", "-c", root.command] : ["true"]
        running: false
    }

    Process {
        id: focusAddr
        property string addr: ""
        command: ["bash", "-c",
            "hyprctl dispatch focuswindow address:" + addr +
            " && hyprctl dispatch bringactivetotop"]
        running: false
    }

    Process {
        id: cycleClass
        command: ["bash", "-c",
            "hyprctl dispatch focuswindow class:" + root.windowClass +
            " && hyprctl dispatch bringactivetotop"]
        running: false
    }
}
