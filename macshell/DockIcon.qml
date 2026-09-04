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
    // Whether this slot survives the app being quit. Only right-click reads it,
    // to decide which way the toggle goes; nothing about the icon is drawn
    // differently, exactly as on macOS.
    property bool   isPinned:    false

    // Right-click. Handled by the parent Dock, which owns the pin store and the
    // slot order the store is written from.
    signal pinToggleRequested()

    // magnification state fed by parent Dock
    property real dockHoverX: -1          // mouse X in dock-row coords, –1 = no hover
    property int  baseSize:   48
    property int  maxSize:    72
    property int  magnRadius: 140

    // ── Running / active state (queried from WindowTracker) ───────
    readonly property var   matchedWindows: WindowTracker.windowsFor(windowClass, "")
    readonly property bool  isRunning:      matchedWindows.length > 0
    readonly property bool  isActive:       matchedWindows.length > 0 &&
                                            matchedWindows.some(w => w.address === WindowTracker.activeAddress)

    // ── Geometry ──────────────────────────────────────────────────
    // Centre of this icon in the row (used by parent to feed dockHoverX back)
    readonly property real iconCenterX: x + width / 2

    readonly property real _dist: dockHoverX < 0
                                  ? magnRadius + 1
                                  : Math.abs(iconCenterX - dockHoverX)

    // Clamp the falloff radius to half of this icon's own (fixed) cell width.
    // Cells sit edge-to-edge with no spacing, so width/2 is exactly the
    // distance to the boundary with the next cell over — capping the radius
    // there guarantees magnFactor hits 0 at that boundary and never bleeds
    // into a neighboring icon, regardless of where within this icon's own
    // cell the mouse is. Previously magnRadius (45) exceeded the cell pitch
    // (42), so a mouse near either edge of one icon was still close enough
    // to partially magnify the icon next to it.
    readonly property real _effRadius: Math.min(magnRadius, width / 2)

    readonly property real _magnFactor: _dist >= _effRadius
                                        ? 0
                                        : Math.cos((_dist / _effRadius) * (Math.PI / 2))

    readonly property real targetSize: baseSize + (maxSize - baseSize) * _magnFactor

    property real currentSize: baseSize
    Behavior on currentSize {
        NumberAnimation { duration: 40; easing.type: Easing.OutCubic }
    }
    onTargetSizeChanged: currentSize = targetSize

    // Cell width is fixed (based on baseSize, not the animated currentSize) so
    // hovering never reflows the parent Row. Magnification is applied purely
    // as a visual scale transform below — if width tracked currentSize here,
    // every hovered-icon growth tick shifted every later icon's Row-assigned
    // x, which fed back into their own iconCenterX-based magnFactor calc and
    // produced a per-frame wobble in icons that weren't even being hovered.
    width:  separator ? 18 : baseSize + 8
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

        width:  root.baseSize
        height: root.baseSize

        // Sits on the bottom of the cell; leaves room for the running dot
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom:           parent.bottom
        anchors.bottomMargin:     11

        // Magnification is a pure visual transform (not a layout resize),
        // scaled from the bottom so it grows upward in place and can overlap
        // neighboring cells the way real dock magnification does, without
        // ever changing this item's actual width/height/x.
        transformOrigin: Item.Bottom
        scale: (root.currentSize / root.baseSize) * (mouseArea.pressed ? 0.88 : 1.0)
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
                    font.family:     UiConfig.fontFamily
                    font.pixelSize:  parent.width * 0.45
                    font.weight:     Font.Medium
                }
            }
        }


    }

    // ── Running indicator dot(s) ──────────────────────────────────
    Row {
        visible: root.isRunning && !root.separator && root.matchedWindows.length <= 3
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

    // 4 or more instances: collapse the dots into a single thin rounded
    // line, the same width the 3-dot row above occupies (3×4 + 2×2 = 16px),
    // so there's no layout jump switching between the two representations.
    Rectangle {
        visible: root.isRunning && !root.separator && root.matchedWindows.length >= 4
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom:           parent.bottom
        anchors.bottomMargin:     3
        width:  16
        height: 4
        radius: 2
        color:  root.isActive ? "white" : Qt.rgba(1, 1, 1, 0.50)

        Behavior on color { ColorAnimation { duration: 150 } }
    }

    // ── Mouse ─────────────────────────────────────────────────────
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

        onClicked: mouse => {
            if (root.separator) return

            if (mouse.button === Qt.RightButton) {
                // Pin an app that is only in the dock because it is open, or
                // unpin one that is here permanently. No context menu: the dock
                // is a masked layer-shell strip 68px tall, so a popup would
                // have to be a whole second surface with its own input region
                // for one item's worth of choice.
                root.pinToggleRequested()
                return
            }

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
                const w = wins[0]
                focusAddr.addr        = w.address
                focusAddr.isSpecial   = (w.workspaceName ?? "").startsWith("special:")
                focusAddr.workspaceId = w.workspaceId ?? 0
                focusAddr.running     = true
            } else {
                // Cycle: use first window's workspace info
                const w = wins[0]
                cycleClass.isSpecial   = (w.workspaceName ?? "").startsWith("special:")
                cycleClass.workspaceId = w.workspaceId ?? 0
                cycleClass.running     = true
            }
        }
    }

    // ── Processes ─────────────────────────────────────────────────
    Process {
        id: launchProc
        // Fire-and-forget launch. Both halves of the wrapper are load-bearing:
        //   setsid ... &disown      — own session/process group, so destroying
        //                             this delegate doesn't group-kill the app.
        //   </dev/null >/dev/null 2>&1 — the app must NOT inherit Quickshell's
        //                             stdout/stderr pipe. Quickshell closes the
        //                             read end when the launcher exits, and the
        //                             app's next write then dies on SIGPIPE.
        // The second one is why Spotify (chatty at startup) wouldn't launch
        // while quiet apps did. See CLAUDE.md 2026-08-22 for the full history.
        command: root.command !== ""
            ? ["bash", "-c", "setsid " + root.command + " </dev/null >/dev/null 2>&1 &disown"]
            : ["true"]
        running: false
    }

    // hyprctl dispatch is shorthand for `eval 'hl.dispatch(...)'` since 0.55 —
    // it takes a single Lua expression string, not the old positional
    // "dispatchname arg1,arg2" form. Each dispatch below is quoted as its own
    // hl.dsp.* call rather than the old bare dispatcher-name + comma-args.
    Process {
        id: focusAddr
        property string addr:        ""
        property bool   isSpecial:   false
        property int    workspaceId: 0
        command: ["bash", "-c",
            isSpecial
                ? "hyprctl dispatch \"hl.dsp.window.move({ workspace = 'e+0', window = 'address:" + addr + "' })\""
                  + " && hyprctl dispatch \"hl.dsp.focus({ window = 'address:" + addr + "' })\""
                  + " && hyprctl dispatch \"hl.dsp.window.bring_to_top()\""
                : "hyprctl dispatch \"hl.dsp.focus({ workspace = " + workspaceId + " })\""
                  + " && hyprctl dispatch \"hl.dsp.focus({ window = 'address:" + addr + "' })\""
                  + " && hyprctl dispatch \"hl.dsp.window.bring_to_top()\""]
        running: false
    }

    Process {
        id: cycleClass
        property bool   isSpecial:   false
        property int    workspaceId: 0
        command: ["bash", "-c",
            isSpecial
                ? "hyprctl dispatch \"hl.dsp.window.move({ workspace = 'e+0', window = 'class:" + root.windowClass + "' })\""
                  + " && hyprctl dispatch \"hl.dsp.focus({ window = 'class:" + root.windowClass + "' })\""
                  + " && hyprctl dispatch \"hl.dsp.window.bring_to_top()\""
                : "hyprctl dispatch \"hl.dsp.focus({ workspace = " + workspaceId + " })\""
                  + " && hyprctl dispatch \"hl.dsp.focus({ window = 'class:" + root.windowClass + "' })\""
                  + " && hyprctl dispatch \"hl.dsp.window.bring_to_top()\""]
        running: false
    }
}
