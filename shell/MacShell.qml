pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

// macshell - the dock and the Alt+Tab switcher in one Quickshell instance.
//
// These were `macdock` and `macswitcher`, two processes. Each carried its own
// QML engine, scenegraph and GPU context (~72 MB PSS of pure per-process
// overhead, measured), and on top of that duplicated the two genuinely shared
// things they both depend on: Hyprland's window list and the desktop-entry /
// icon-theme cache. Merging removes one process and one copy of each.
//
// Windows remain fully independent surfaces - the dock is a masked Top-layer
// strip that never takes keyboard focus, the switcher is a full-screen Overlay
// that takes it exclusively while shown.
Scope {
    // ── the desktop wallpaper ─────────────────────────────────────────────
    // Added 2026-09-14, replacing hyprpaper — see Wallpaper.qml for what that
    // deleted and why. It lives in THIS shell of the three because macshell is
    // the first one hyprland.lua starts, and the wallpaper is the surface it
    // costs most to be late with: everything else on this desktop appears over
    // the top of it.
    //
    // A Variants of its own rather than another window inside the dock's:
    // Variants takes one delegate, and these are two unrelated surfaces that
    // merely happen to be per-screen.
    Variants {
        model: Quickshell.screens
        Wallpaper {}
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: dockWindow
            required property ShellScreen modelData
            screen: modelData

            // Settings -> Setup -> Dock -> Position.
            //
            // The surface is the WHOLE usable area on every edge, and it never
            // changes size; the mask below cuts input down to the dock itself,
            // so the rest is transparent to clicks. That is what makes the
            // edge switch animatable. It was a strip along the dock's edge
            // (130 deep at the bottom, 360 wide at a side), and switching edge
            // resized the layer surface — which Hyprland animates by stretching
            // the last frame, so the icons smeared into long coloured bars
            // across the screen (Ahaan's recording, 2026-09-26). A fade-out,
            // move, fade-in hid that and cost the fly to the new edge, which
            // he wanted kept. A surface that never resizes gives the
            // compositor nothing to stretch, and the dock flies inside it.
            //
            // ── The flight ──────────────────────────────────────────
            // One animated number, `flyT`, 0 -> 1, and the dock's centre, its
            // angle and its side are all straight interpolations on it — so
            // the turn and the arrival end on the same frame by construction,
            // which is what Ahaan asked for. The first version flew the
            // position with x/y Behaviors and re-laid the row out at the new
            // angle on the first frame, which read as a cut from 0 to 90
            // degrees followed by a smooth move.
            //
            // `edge` is the committed edge, and a plain value rather than a
            // binding on the setting: the flight has to read where the dock
            // IS before anything is re-evaluated for where it is going.
            readonly property string wantEdge: UiConfig.dockEdge
            property string edge: "bottom"
            readonly property bool vertical: edge !== "bottom"

            property real flyT: 1
            property real fromCx: 0
            property real fromCy: 0
            property real fromAngle: 0
            property real fromSide: 1
            readonly property real toAngle: vertical ? 90 : 0
            readonly property real toSide:  edge === "right" ? -1 : 1
            readonly property real curAngle: fromAngle + (toAngle - fromAngle) * flyT
            readonly property real curSide:  fromSide  + (toSide  - fromSide)  * flyT

            onWantEdgeChanged: {
                if (wantEdge === edge) return
                // The first read of ui.conf is where the dock starts, not a
                // move: nothing has been seen yet, so there is nothing to fly.
                if (!UiConfig.loaded) {
                    edge = wantEdge
                    fromAngle = toAngle
                    fromSide  = toSide
                    return
                }
                // From wherever it is right now — mid-flight included.
                fromCx    = dockPanel.x + dockPanel.width  / 2
                fromCy    = dockPanel.y + dockPanel.height / 2
                fromAngle = curAngle
                fromSide  = curSide
                edge      = wantEdge
                flyT      = 0
                flyAnim.restart()
            }
            Component.onCompleted: {
                edge = wantEdge
                fromAngle = toAngle
                fromSide  = toSide
            }
            NumberAnimation {
                id: flyAnim
                target: dockWindow
                property: "flyT"
                from: 0; to: 1
                duration: 450
                easing.type: Easing.InOutCubic
            }

            anchors { top: true; bottom: true; left: true; right: true }

            // Never reserve layout space. Reserving any non-zero zone makes
            // Hyprland's own tiling engine shrink windows to avoid it *before*
            // they can ever reach the dock's strip — so windowOverlaps would
            // almost never observe a real overlap, the zone would stay
            // reserved forever, and tiled windows would never get the full
            // screen. A pure overlay (always 0) is the only way an auto-hide
            // dock and full-height tiling can coexist.
            exclusiveZone: 0
            WlrLayershell.layer:     WlrLayer.Top
            WlrLayershell.namespace: "macdock"
            color:         "transparent"
            implicitHeight: screen.height
            implicitWidth:  screen.width

            mask: Region { item: dockPanel }

            // ── Controller ────────────────────────────────────────
            QtObject {
                id: dockController

                // Whether the pointer is pressed against the dock's edge, inside
                // the dock's span along it. Named for the bottom dock it was
                // written for; it means whichever edge the dock is on.
                property bool mouseNearBottom: false
                // Bound (not set imperatively via a second MouseArea) — see the
                // note on Dock.qml's `hovered` property for why a separate
                // overlapping MouseArea here never actually received hover events.
                readonly property bool mouseOnDock: dockPanel.hovered
                property bool windowOverlaps:  false

                // Raw "mouse wants the dock revealed" condition. A drag in
                // progress counts: carrying an icon can take the pointer off
                // the dock's own footprint, and the dock sliding away from
                // under a held icon would strand the gesture.
                readonly property bool hovering: mouseNearBottom || mouseOnDock
                                                 || dockPanel.dragActive
                                                 || previewOpenHere
                // The hover preview is its own window, so moving onto it
                // leaves the dock and started the 1s hide: the dock slid away
                // from under the popup it had just opened. Ahaan, 2026-09-30:
                // stay "until decision is made". The popup closes itself on a
                // tile click (hideNow) or 250ms after the pointer leaves it,
                // and the normal grace below then runs from that moment.
                readonly property bool previewOpenHere: DockPreview.visible
                                                        && DockPreview.activeScreen === dockPanel.screen

                // Grace period: after the mouse leaves the reveal region, keep the
                // dock up for a moment so a brief/accidental exit doesn't instantly
                // re-hide it. Re-entering cancels the pending hide.
                property bool _grace: false
                onHoveringChanged: {
                    if (hovering) {
                        hideDelay.stop()
                        _grace = false
                    } else {
                        _grace = true          // stay visible during the buffer
                        hideDelay.restart()
                    }
                }
                property var _hideDelay: Timer {
                    id: hideDelay
                    interval: 1000             // ← buffer before the dock hides (ms)
                    onTriggered: dockController._grace = false
                }

                // Settings -> Setup -> Dock -> Always hide. "overlap" (switch
                // off) is what this has always done: out of the way only while
                // a window reaches the dock's edge. "always" drops that last
                // term, so the pointer is the only thing that brings it up.
                readonly property bool alwaysHide: UiConfig.dockHide === "always"
                readonly property bool dockVisible: hovering || _grace
                                                    || (!alwaysHide && !windowOverlaps)

                // ── Poll cursor position ──────────────────────────
                property string _cursorBuf: ""
                property var _cursorProc: Process {
                    id: cursorProc
                    command: ["hyprctl", "cursorpos", "-j"]
                    running: false
                    stdout: SplitParser {
                        splitMarker: ""
                        onRead: data => dockController._cursorBuf += data
                    }
                }
                property var _cursorConn: Connections {
                    target: cursorProc
                    function onRunningChanged() {
                        if (cursorProc.running) return
                        try {
                            const pos = JSON.parse(dockController._cursorBuf)
                            const sh  = dockWindow.screen.height
                            // hyprctl cursorpos is in global (multi-monitor) coordinates;
                            // translate the dock's span into that space.
                            const sx       = dockWindow.screen.x
                            const sy       = dockWindow.screen.y
                            const sw       = dockWindow.screen.width
                            const edge     = dockWindow.edge
                            let near = false, within = false
                            if (edge === "bottom") {
                                const halfDock = dockPanel.width / 2
                                const centerX  = sx + sw / 2
                                near   = pos.y >= (sy + sh - 10)
                                within = pos.x >= (centerX - halfDock) && pos.x <= (centerX + halfDock)
                            } else {
                                // A side strip is anchored top-to-bottom but the
                                // compositor lays it out BELOW the bar's exclusive
                                // zone, so its centre is not the screen's. Its
                                // own height is the usable height; the part of
                                // the screen it does not cover is the bar.
                                const top      = sy + (sh - dockWindow.height)
                                const centerY  = top + dockWindow.height / 2
                                const halfDock = dockPanel.height / 2
                                near   = edge === "left" ? pos.x <= (sx + 10)
                                                         : pos.x >= (sx + sw - 10)
                                within = pos.y >= (centerY - halfDock) && pos.y <= (centerY + halfDock)
                            }
                            dockController.mouseNearBottom = near && within
                        } catch(e) {}
                        dockController._cursorBuf = ""
                    }
                }
                property var _cursorTimer: Timer {
                    interval: 50   // poll every 50ms — snappy without hammering
                    running:  true
                    repeat:   true
                    onTriggered: {
                        dockController._cursorBuf = ""
                        cursorProc.running = true
                    }
                }

                // ── Active workspace tracking ─────────────────────
                property int    activeWorkspaceId:   -1
                property string _wsBuf: ""
                property var _wsProc: Process {
                    id: wsProc
                    command: ["hyprctl", "activeworkspace", "-j"]
                    running: true
                    stdout: SplitParser {
                        splitMarker: ""
                        onRead: data => dockController._wsBuf += data
                    }
                }
                property var _wsConn: Connections {
                    target: wsProc
                    function onRunningChanged() {
                        if (wsProc.running) return
                        try {
                            const ws = JSON.parse(dockController._wsBuf)
                            dockController.activeWorkspaceId = ws.id ?? -1
                        } catch(e) {}
                        dockController._wsBuf = ""
                    }
                }
                property var _wsTimer: Timer {
                    interval: 200
                    running:  true
                    repeat:   true
                    onTriggered: {
                        dockController._wsBuf = ""
                        wsProc.running = true
                    }
                }

                // ── Overlap detection — only current workspace ────
                property var _overlapConn: Connections {
                    target: WindowTracker
                    function onWindowListChanged() {
                        dockController._checkOverlap()
                    }
                }
                // Also recheck when active workspace changes
                onActiveWorkspaceIdChanged: _checkOverlap()
                // …and when the dock moves to another edge, or the answer is
                // about the edge it just left.
                property var _edgeConn: Connections {
                    target: dockWindow
                    function onEdgeChanged() { dockController._checkOverlap() }
                }

                // A window "overlaps" when it reaches within 60px of the
                // dock's edge anywhere along that edge — the same strip the
                // bottom dock has always measured, turned for a side dock.
                function _checkOverlap() {
                    const sx      = dockWindow.screen.x
                    const sy      = dockWindow.screen.y
                    const sh      = dockWindow.screen.height
                    const sw      = dockWindow.screen.width
                    const edge    = dockWindow.edge
                    let overlaps  = false
                    WindowTracker.windowList.forEach(w => {
                        if (w.workspaceName.startsWith("special:")) return
                        if (w.workspaceId <= 0) return
                        if (w.ww <= 0 || w.wh <= 0) return
                        // Only check windows on the currently active workspace
                        if (w.workspaceId !== dockController.activeWorkspaceId) return
                        // On this screen at all
                        if (w.x >= sx + sw || (w.x + w.ww) <= sx) return
                        if (w.y >= sy + sh || (w.y + w.wh) <= sy) return
                        if (edge === "left"  && w.x < sx + 60)             overlaps = true
                        if (edge === "right" && (w.x + w.ww) > sx + sw - 60) overlaps = true
                        if (edge === "bottom" && (w.y + w.wh) > sy + sh - 60) overlaps = true
                    })
                    dockController.windowOverlaps = overlaps
                }
            }

            // ── Dock panel ────────────────────────────────────────
            Dock {
                id: dockPanel
                screen: modelData
                angle:  dockWindow.curAngle
                side:   dockWindow.curSide

                // 0 shown, 1 hidden: slid off its own edge by its own depth
                // plus 16. Matches Finder's box animation: uniform ~150ms
                // OutCubic both ways.
                property real hiddenT: dockController.dockVisible ? 0 : 1
                Behavior on hiddenT {
                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }
                // Where the centre belongs at the committed edge — the rest
                // position, and the far end of a flight.
                readonly property real _hide: hiddenT * (thickness + 16)
                readonly property real _toCx:
                    dockWindow.edge === "left"  ? thickness / 2 - _hide
                  : dockWindow.edge === "right" ? parent.width - thickness / 2 + _hide
                  : parent.width / 2
                readonly property real _toCy:
                    dockWindow.edge === "bottom" ? parent.height - thickness / 2 + _hide
                                                 : parent.height / 2
                readonly property real _cx: dockWindow.fromCx + (_toCx - dockWindow.fromCx) * dockWindow.flyT
                readonly property real _cy: dockWindow.fromCy + (_toCy - dockWindow.fromCy) * dockWindow.flyT
                x: _cx - width  / 2
                y: _cy - height / 2
                opacity: dockController.dockVisible ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }
            }
        }
    }

    // ── Multi-instance hover preview ───────────────────────────────
    // A separate PanelWindow (own Variants block, one per screen) rather
    // than a child of dockWindow above. That was because dockWindow was once
    // a 130px strip, the dock's own footprint, and content above y=0 would
    // have been clipped; it is the whole usable area now, but the popup keeps
    // its own window so it can sit on the Top layer above everything the
    // dock's mask excludes. Sized to
    // its own content (like the OSD pill below, not the calendar dropdown's
    // full-screen catcher — see DockPreview.qml/WindowPreviewPopup.qml for
    // why full-screen was wrong here), so it only ever intercepts input
    // over the area it's actually visibly occupying.
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: previewWindow
            required property ShellScreen modelData
            screen: modelData

            visible: DockPreview.visible && DockPreview.activeScreen === modelData

            color: "transparent"
            exclusiveZone: 0
            WlrLayershell.layer:     WlrLayer.Top
            WlrLayershell.namespace: "macdock-preview"

            // Bottom dock: a window the popup's own size, pinned bottom-left
            // and pushed into place by margins, as it always was. Side dock: a
            // full-height strip on the dock's edge, with the popup placed at
            // the hovered icon's y inside it and the mask cutting input down
            // to the popup — see DockPreview.localY for why a strip.
            readonly property string edge: UiConfig.dockEdge
            readonly property bool vertical: edge !== "bottom"

            anchors {
                bottom: true
                top:    previewWindow.vertical
                left:   previewWindow.edge !== "right"
                right:  previewWindow.edge === "right"
            }

            implicitWidth:  previewPopup.implicitWidth
            implicitHeight: vertical ? modelData.height : previewPopup.implicitHeight
            mask: Region { item: previewPopup }

            // Center the popup over the hovered icon's global x, clamped so
            // it can't slide off either edge of this screen. globalX is in
            // Quickshell's global (multi-monitor) coordinate space, same as
            // dockController's cursor-tracking above — subtract this
            // screen's own x offset to land in this window's local space.
            // PanelWindow.anchors is a plain 4-bool struct (edges only) —
            // offsets from those edges are a separate `margins` property.
            margins.left: {
                if (vertical) return DockPreview.dockHeight - 3 - previewPopup.shadowMargin
                const half = previewPopup.implicitWidth / 2
                const raw  = (DockPreview.globalX - modelData.x) - half
                return Math.max(0, Math.min(raw, modelData.width - previewPopup.implicitWidth))
            }
            // Sit just above the dock pill. Subtract the popup's own
            // shadowMargin padding (see WindowPreviewPopup.qml) so the
            // *visible* card sits this close, not the padded window edge.
            //
            // "- 3" was "+ 2" until 2026-09-30: Ahaan found the card floated
            // too far off the dock, asked for half the gap, then settled on
            // 7px after trying 9. Measured by scanning a grim capture column by column for
            // the card's outer ring and the pill's top edge: "- 3" leaves
            // 7px, "- 1" leaves 9px — one unit here is one pixel of gap, so
            // "+ 2" was 12px. (Eyeballed readings of 14 and 7 before that
            // were 2px generous each; trust the column scan.)
            // All three edges use it.
            margins.bottom: vertical ? 0 : DockPreview.dockHeight - 3 - previewPopup.shadowMargin
            margins.right:  vertical ? DockPreview.dockHeight - 3 - previewPopup.shadowMargin : 0

            WindowPreviewPopup {
                id: previewPopup
                // Beside the icon on a side dock, clamped to the strip.
                y: previewWindow.vertical
                   ? Math.max(0, Math.min(DockPreview.localY - implicitHeight / 2,
                                          previewWindow.height - implicitHeight))
                   : 0
                windows:       DockPreview.windows
                iconPath:      DockPreview.iconPath
                cancelClose:   DockPreview.cancelClose
                scheduleClose: DockPreview.scheduleClose
                closeNow:      DockPreview.hideNow
            }
        }
    }

    // ── App switcher (Alt+Tab) ─────────────────────────────────────
    // Merged in from what used to be a separate `macswitcher` Quickshell
    // process. It lives here because it needs exactly the same Hyprland window
    // list and icon cache the dock does: as two processes they each ran their
    // own `hyprctl clients -j` / `activewindow -j` poll loop and their own full
    // .desktop + icon-theme scan, against the same data. One process does that
    // once (see WindowTracker and DesktopEntryCache).
    //
    // Its surface stays independent of the dock's: Overlay layer (above the
    // dock's Top), full-screen, and it takes exclusive keyboard focus while
    // shown, which the dock must never do.
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: switcherWindow
            required property ShellScreen modelData
            screen: modelData

            anchors { top: true; left: true; right: true; bottom: true }

            WlrLayershell.layer:     WlrLayer.Overlay
            WlrLayershell.namespace: "macswitcher"
            WlrLayershell.keyboardFocus: switcher.shown
                                         ? WlrKeyboardFocus.Exclusive
                                         : WlrKeyboardFocus.None
            color:          "transparent"
            implicitWidth:  screen.width
            implicitHeight: screen.height

            // Input passes straight through unless the switcher is up.
            mask: Region { item: switcher.shown ? null : emptyRegion }
            Item { id: emptyRegion; width: 0; height: 0 }

            AppSwitcher {
                id: switcher
                anchors.fill: parent
                screenWidth:  switcherWindow.screen.width
                screenHeight: switcherWindow.screen.height
            }
        }
    }
}
