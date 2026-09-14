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

    // ── Reorder drag ──────────────────────────────────────────────
    // All of the state lives in the parent Dock and is fed back down here,
    // deliberately: this delegate is destroyed and recreated whenever the
    // window list changes shape, so anything held locally would evaporate
    // mid-gesture. Only the two things that cannot outlive one press — where
    // the press landed, and whether it turned into a drag — are local.
    property real targetX:  0       // where the layout wants this cell
    property bool armed:    false   // double-clicked, ready to be moved
    property bool dragging: false
    property real dragX:    0       // pointer x in row coords, while dragging

    signal armRequested()
    signal armCancelled()
    signal dragStartRequested()
    signal dragMoved(real rowX)
    signal dragFinished(bool committed)

    property real _pressRowX:    0
    property bool _suppressClick: false

    // The cell follows the layout, except while it is being carried, when it
    // follows the pointer. Everything else slides because its targetX changed
    // underneath this same Behavior.
    x: root.dragging ? root.dragX - width / 2 : root.targetX
    Behavior on x {
        enabled: !root.dragging     // the carried icon must not lag the pointer
        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
    }

    // The carried icon passes over its neighbours, not under them.
    z: root.dragging ? 2 : (root.armed ? 1 : 0)

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
        // Lifts off the row while armed or carried, which together with the
        // jiggle below is the whole of the "you can move me now" affordance.
        anchors.bottomMargin:     11 + ((root.armed || root.dragging) ? 7 : 0)
        Behavior on anchors.bottomMargin {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        // Magnification is a pure visual transform (not a layout resize),
        // scaled from the bottom so it grows upward in place and can overlap
        // neighboring cells the way real dock magnification does, without
        // ever changing this item's actual width/height/x.
        transformOrigin: Item.Bottom
        scale: (root.currentSize / root.baseSize)
               * ((mouseArea.pressed && !root.dragging) ? 0.88 : 1.0)
               * (root.dragging ? 1.18 : (root.armed ? 1.08 : 1.0))
        Behavior on scale { NumberAnimation { duration: 70 } }

        // A plain value, not a binding, so the animation below can drive it.
        rotation: 0
        SequentialAnimation {
            running: root.armed && !root.dragging
            loops:   Animation.Infinite
            // Stopping mid-cycle would otherwise leave the icon frozen at
            // whatever angle it had reached.
            onStopped: iconItem.rotation = 0
            NumberAnimation { target: iconItem; property: "rotation"; from:  0;   to: -3.5; duration: 100 }
            NumberAnimation { target: iconItem; property: "rotation"; from: -3.5; to:  3.5; duration: 200 }
            NumberAnimation { target: iconItem; property: "rotation"; from:  3.5; to:  0;   duration: 100 }
        }

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
        // While armed, no ancestor gets to take the grab out from under a drag
        // that is about to start.
        preventStealing: root.armed || root.dragging

        // root.x is this cell's position in row coordinates and mouse.x is
        // measured from the cell, so the sum is the pointer in row coordinates
        // — and it stays true once the cell starts following the pointer,
        // because the two move by equal and opposite amounts.
        function _rowX(mx) { return root.x + mx }

        onPressed: mouse => {
            root._pressRowX     = _rowX(mouse.x)
            root._suppressClick = false
        }

        // Press and hold to pick an icon up. This was a double-click, and a
        // double-click cannot be made free: nothing can know a second click is
        // coming without delaying EVERY single click by the double-click
        // interval, so the first one launched or focused the app on the way
        // into a rearrange — and switched workspace with it when the app was
        // on another one. A hold has no first click to leak.
        //
        // 450ms rather than the 800ms default, which is a long time to sit on
        // a dock icon, and well clear of an ordinary click. Qt cancels the hold
        // if the pointer travels past the drag threshold first, so this cannot
        // fire in the middle of some other gesture.
        pressAndHoldInterval: 450
        onPressAndHold: mouse => {
            if (root.separator || mouse.button !== Qt.LeftButton) return
            // The release that ends a deliberate hold must not also launch the
            // app, whether or not the hold turned into a drag.
            root._suppressClick = true
            root.armRequested()
        }

        onPositionChanged: mouse => {
            if (root.separator || !pressed) return
            if (!root.armed && !root.dragging) return
            const rx = _rowX(mouse.x)
            if (!root.dragging) {
                // A double-click that never travels must not reorder anything,
                // so the drag only begins once the pointer has actually moved.
                if (Math.abs(rx - root._pressRowX) < 6) return
                root._suppressClick = true
                root.dragStartRequested()
            }
            root.dragMoved(rx)
        }

        // Arming lasts exactly as long as the finger is down. There is no
        // rearrange MODE to be in or to get out of: hold, move, let go.
        onReleased: {
            if (root.dragging)   root.dragFinished(true)
            else if (root.armed) root.armCancelled()
        }
        onCanceled: {
            if (root.dragging)   root.dragFinished(false)
            else if (root.armed) root.armCancelled()
        }

        onClicked: mouse => {
            if (root.separator) return
            // The release that ends a drag also produces a click.
            if (root._suppressClick) {
                root._suppressClick = false
                return
            }

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
