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

    // Left-click on an icon with two or more windows open. Also handled by the
    // parent Dock, for the same reason: the multi-instance popup lives in the
    // DockPreview singleton and needs this Dock's height and ShellScreen to
    // place itself, neither of which a delegate knows. See Dock.qml's
    // showPreviewFor().
    signal previewRequested()

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

    // ── The frame the parent Dock lays this cell out in ───────────
    // Not an edge name: a direction. (dx, dy) is the unit vector the row runs
    // along, (nx, ny) points from the row towards the screen edge, and
    // (ox, oy) is where the row starts, in the parent's coordinates. The Dock
    // animates these continuously while it flies from one edge to another, so
    // the row turns through every angle in between rather than jumping from
    // horizontal to vertical — see Dock.qml's `angle`. At rest they are the
    // four exact cases: row right/normal down at the bottom, row down/normal
    // left or right at a side.
    //
    // targetX, dragX and dockHoverX are all measured ALONG the row; the names
    // are the bottom dock's.
    property real dx: 1
    property real dy: 0
    property real nx: 0
    property real ny: 1
    property real ox: 0
    property real oy: 0
    property real angle: 0          // the row's angle in degrees, for rotated parts
    readonly property bool vertical: Math.abs(root.dy) > Math.abs(root.dx)

    // The cell follows the layout, except while it is being carried, when it
    // follows the pointer. Everything else slides because its targetX changed
    // underneath this same Behavior. It animates the distance along the row,
    // not x or y, so a reorder slides the same way at any angle.
    property real alongPos: root.dragging ? root.dragX - root.cellLen / 2 : root.targetX
    Behavior on alongPos {
        enabled: !root.dragging     // the carried icon must not lag the pointer
        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
    }
    // The cell's centre, and its box: the bounding box of a cellLen x
    // cellThick rectangle turned to the row's angle. Only the two rest angles
    // matter for hit testing; in between, the box is just somewhere to draw.
    readonly property real _cx: root.ox + root.dx * (root.alongPos + root.cellLen / 2)
    readonly property real _cy: root.oy + root.dy * (root.alongPos + root.cellLen / 2)
    x: root._cx - width / 2
    y: root._cy - height / 2

    // The carried icon passes over its neighbours, not under them.
    z: root.dragging ? 2 : (root.armed ? 1 : 0)

    // magnification state fed by parent Dock
    property real dockHoverX: -1          // mouse X in dock-row coords, –1 = no hover
    property int  baseSize:   48
    property int  maxSize:    72
    property int  magnRadius: 140

    // ── Running / active state (queried from WindowTracker) ───────
    readonly property var   matchedWindows: WindowTracker.windowsFor(windowClass, "")
    // ── what the running dots and the row separator are drawn with ────────
    // The palette's FOREGROUND, not white. The dots were hardcoded white, which
    // is invisible on a light palette: the pill under them is color0 at 0.82
    // alpha (see Dock.qml), and on Catppuccin Latte or White that is a
    // near-white ground with white dots on it — Ahaan sent a screenshot of
    // exactly that.
    //
    // foreground is the right answer rather than a nicer-looking one, because
    // background-against-foreground is the ONE pair pywal actually guarantees is
    // legible: every palette here is built so that text on the ground can be
    // read, and the pill IS the ground. The accent (color9) was the tempting
    // alternative — it is what marks "active" everywhere else in this desktop —
    // but nothing promises it contrasts with color0, and a dot nobody can see is
    // the bug being fixed.
    //
    // 2026-09-18: the separator bar below was the same bug, left behind by the
    // dot pass, so it now reads this too — hence the rename from `dotColor`.
    // Measured on the flexoki-light palette in use that day (color0 #FFFCF0,
    // foreground #100F0F): white on the pill is 1.03:1, foreground is 18.62:1.
    //
    // Declared as a `color` rather than read inline: WalColors exposes strings,
    // and .r/.g/.b below need the coerced type.
    readonly property color fg: WalColors.foreground

    readonly property bool  isRunning:      matchedWindows.length > 0
    readonly property bool  isActive:       matchedWindows.length > 0 &&
                                            matchedWindows.some(w => w.address === WindowTracker.activeAddress)

    // ── Geometry ──────────────────────────────────────────────────
    // Centre of this icon in the row (used by parent to feed dockHoverX back)
    readonly property real iconCenterX: root.alongPos + root.cellLen / 2

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
    readonly property real _effRadius: Math.min(magnRadius, root.cellLen / 2)

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
    // cellLen along the row, cellThick away from the screen edge.
    readonly property real cellLen:   separator ? 18 : baseSize + 8
    readonly property real cellThick: maxSize + 24     // constant: icon bottom + dot clearance
    width:  Math.abs(root.dx) * root.cellLen + Math.abs(root.dy) * root.cellThick
    height: Math.abs(root.dy) * root.cellLen + Math.abs(root.dx) * root.cellThick

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
        // Across the row, so it turns with the dock.
        width:  1
        height: root.baseSize * 0.65
        rotation: root.angle
        // Same foreground as the dots, same reason: a white hairline on a
        // near-white pill is not a hairline, it is nothing.
        color:  Theme.dimmer
    }

    // ── Icon container ────────────────────────────────────────────
    Item {
        id: iconItem
        visible: !root.separator

        width:  root.baseSize
        height: root.baseSize

        // Sits on the screen-edge side of the cell; leaves room for the
        // running dot. Lifts off the row while armed or carried, which together
        // with the jiggle below is the whole of the "you can move me now"
        // affordance.
        property real edgeGap: 11 + ((root.armed || root.dragging) ? 7 : 0)
        Behavior on edgeGap {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }
        // Offset from the cell's centre towards the edge. The icon itself is
        // never turned: it stays upright at every angle, and only where it
        // sits moves with the row.
        readonly property real off: root.cellThick / 2 - edgeGap - root.baseSize / 2
        x: root.width  / 2 + root.nx * off - width  / 2
        y: root.height / 2 + root.ny * off - height / 2

        // Magnification is a pure visual transform (not a layout resize),
        // scaled from the screen-edge side so it grows away from the edge in
        // place and can overlap neighboring cells the way real dock
        // magnification does, without ever changing this item's actual
        // width/height/x. The origin is the point of the icon nearest the
        // edge, taken from the normal, so it follows the row as it turns.
        property real mag: (root.currentSize / root.baseSize)
                           * ((mouseArea.pressed && !root.dragging) ? 0.88 : 1.0)
                           * (root.dragging ? 1.18 : (root.armed ? 1.08 : 1.0))
        Behavior on mag { NumberAnimation { duration: 70 } }
        transform: Scale {
            origin.x: iconItem.width  / 2 * (1 + root.nx)
            origin.y: iconItem.height / 2 * (1 + root.ny)
            xScale: iconItem.mag
            yScale: iconItem.mag
        }

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

            // Until the icon index (DesktopEntryCache, one ~3s scan at shell
            // start) has landed, an icon NAME cannot be mapped to a file and
            // falls through to Quickshell's image://icon provider — which
            // draws a magenta/black checkerboard for anything the Qt theme
            // lacks, rather than failing. Ahaan saw that on launch, in the dock
            // and in the switcher; the switcher got this first (2026-09-30).
            // The icon re-resolves on its own when the scan finishes, so all
            // that is needed is to show the letter tile, not the checkerboard,
            // for those seconds. Only image://icon sources are held back: a
            // pin with an absolute path (the webapps) draws correctly at once.
            readonly property bool _premature: !DesktopEntryCache.ready
                                               && String(source).startsWith("image://icon/")
            visible: !_premature
        }

        // Fallback coloured tile with initial letter. A sibling of the Image,
        // not its child, since 2026-09-30: it has to show while the Image is
        // hidden, and a child of an invisible item is invisible too.
        Rectangle {
            visible: iconImg._premature
                     || iconImg.status === Image.Error
                     || iconImg.status === Image.Null
                     || (iconImg.status === Image.Ready && iconImg.paintedWidth <= 0)
            anchors.fill: parent
            radius: parent.width * 0.22
            // Deliberately NOT palette-driven, and so is the letter on it:
            // this tile is its own fixed ground, so white is legible on it
            // whatever pywal is doing. Left alone by the 2026-09-18 sweep.
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

    // ── Running indicator ─────────────────────────────────────────
    // A short bar on the edge side of the icon, turned with the row. These
    // were dots — one to three, then a line for four or more — and Ahaan's
    // verdict after the side docks landed was that they "look a little odd
    // in the new positions": three 4px circles read as punctuation next to
    // an icon, and more so standing in a column. One bar reads as a mark.
    //
    //   running           Theme.dimmer, the settings card's quiet ink
    //   focused           Theme.accent. The focused app also had the
    //                     settings card's selection wash behind its icon
    //                     for a day; Ahaan had it removed (2026-09-27), so
    //                     the bar alone says which app is current.
    //   more than one     longer: 8 / 14 / 20px for 1 / 2 / 3+ windows,
    //                     which keeps the count the dots used to carry
    //
    // The accent is safe here where it was not for text (see Theme.qml and
    // the map's note on ncAccent): this is a fill, not a glyph that has to be
    // read. It sits 1px past the icon cell's edge-side boundary — measured on
    // screen at 4px it sat on the pill's bright 2px border and read as part of
    // it; icons carry a few px of transparent padding, so 1px still leaves a
    // visible gap under the artwork. Faded by the normal's length, for the reason the dots were:
    // flying between the two sides the normal swings through zero, and the
    // bar would otherwise cross the icon.
    Rectangle {
        id: runBar
        visible: root.isRunning && !root.separator
        readonly property int n: root.matchedWindows.length
        width:  n >= 3 ? 20 : (n === 2 ? 14 : 8)
        height: 3
        radius: 1.5
        rotation: root.angle
        opacity: Math.min(1, Math.sqrt(root.nx * root.nx + root.ny * root.ny))
        color: root.isActive ? Theme.accent : Theme.dimmer
        readonly property real off: root.cellThick / 2 - 11 + 1 + height / 2
        x: root.width  / 2 + root.nx * off - width  / 2
        y: root.height / 2 + root.ny * off - height / 2
        Behavior on width { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
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

        // alongPos is this cell's position along the row and the mouse is
        // measured from the cell, so the sum is the pointer in row coordinates
        // — and it stays true once the cell starts following the pointer,
        // because the two move by equal and opposite amounts. The mouse is
        // projected onto the row direction, so this holds at either rest angle.
        function _rowX(mx, my) {
            return root.alongPos + root.cellLen / 2
                 + (mx - root.width / 2) * root.dx + (my - root.height / 2) * root.dy
        }

        onPressed: mouse => {
            root._pressRowX     = _rowX(mouse.x, mouse.y)
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
            const rx = _rowX(mouse.x, mouse.y)
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
                // Two or more windows: show the same instance picker a
                // sustained hover shows, and let the user say WHICH one.
                //
                // This was `focus({ window = 'class:<cls>' })`, sold as a
                // cycle and not one: that dispatch focuses whichever window
                // Hyprland matches on the class first, which does not advance
                // between clicks, so from the pointer's side one arbitrary
                // window of the app comes up and clicking again brings up the
                // same one. Ahaan's words for it were "randomly seems to open
                // one of the windows".
                //
                // Deliberately show-only and not a toggle. The hover gate is
                // 500ms (Dock.qml's _previewIntentTimer), so by the time a
                // deliberate click lands on the icon the popup is usually
                // ALREADY up — a toggle would close the picker that the click
                // was asking for. Re-showing an open popup is a no-op apart
                // from cancelling its close timer, which is what is wanted.
                root.previewRequested()
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
}
