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
ShellRoot {
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: dockWindow
            required property ShellScreen modelData
            screen: modelData

            anchors { bottom: true; left: true; right: true }

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
            implicitHeight: 130
            implicitWidth:  screen.width

            mask: Region { item: dockPanel }

            // ── Controller ────────────────────────────────────────
            QtObject {
                id: dockController

                property bool mouseNearBottom: false
                // Bound (not set imperatively via a second MouseArea) — see the
                // note on Dock.qml's `hovered` property for why a separate
                // overlapping MouseArea here never actually received hover events.
                readonly property bool mouseOnDock: dockPanel.hovered
                property bool windowOverlaps:  false

                // Raw "mouse wants the dock revealed" condition.
                readonly property bool hovering: mouseNearBottom || mouseOnDock

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

                readonly property bool dockVisible: hovering || _grace || !windowOverlaps

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
                            // translate the dock's horizontal span into that space.
                            const sx       = dockWindow.screen.x
                            const sw       = dockWindow.screen.width
                            const halfDock = dockPanel.width / 2
                            const centerX  = sx + sw / 2
                            const nearBottom = pos.y >= (sh - 10)
                            const withinDockSpan =
                                pos.x >= (centerX - halfDock) && pos.x <= (centerX + halfDock)
                            dockController.mouseNearBottom = nearBottom && withinDockSpan
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

                function _checkOverlap() {
                    const sh      = dockWindow.screen.height
                    const sw      = dockWindow.screen.width
                    const dockTop = sh - 60
                    let overlaps  = false
                    WindowTracker.windowList.forEach(w => {
                        if (w.workspaceName.startsWith("special:")) return
                        if (w.workspaceId <= 0) return
                        if (w.ww <= 0 || w.wh <= 0) return
                        // Only check windows on the currently active workspace
                        if (w.workspaceId !== dockController.activeWorkspaceId) return
                        if ((w.y + w.wh) > dockTop && w.y < sh &&
                             w.x < sw && (w.x + w.ww) > 0)
                            overlaps = true
                    })
                    dockController.windowOverlaps = overlaps
                }
            }

            // ── Dock panel ────────────────────────────────────────
            Dock {
                id: dockPanel
                screen: modelData
                anchors.bottom:           parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter

                // Matches Finder's box animation: uniform ~150ms OutCubic both ways.
                anchors.bottomMargin: dockController.dockVisible ? 0 : -(height + 16)
                Behavior on anchors.bottomMargin {
                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }
                opacity: dockController.dockVisible ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }
            }
        }
    }

    // ── Multi-instance hover preview ───────────────────────────────
    // A separate PanelWindow (own Variants block, one per screen) rather
    // than a child of dockWindow above — dockWindow's implicitHeight (130)
    // is exactly the dock's own footprint, and content positioned above y=0
    // there would just be clipped by that surface's own bounds. Sized to
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

            anchors { bottom: true; left: true }

            implicitWidth:  previewPopup.implicitWidth
            implicitHeight: previewPopup.implicitHeight

            // Center the popup over the hovered icon's global x, clamped so
            // it can't slide off either edge of this screen. globalX is in
            // Quickshell's global (multi-monitor) coordinate space, same as
            // dockController's cursor-tracking above — subtract this
            // screen's own x offset to land in this window's local space.
            // PanelWindow.anchors is a plain 4-bool struct (edges only) —
            // offsets from those edges are a separate `margins` property.
            margins.left: {
                const half = previewPopup.implicitWidth / 2
                const raw  = (DockPreview.globalX - modelData.x) - half
                return Math.max(0, Math.min(raw, modelData.width - previewPopup.implicitWidth))
            }
            // Sit just above the dock pill. Subtract the popup's own
            // shadowMargin padding (see WindowPreviewPopup.qml) so the
            // *visible* card sits this close, not the padded window edge.
            margins.bottom: DockPreview.dockHeight + 2 - previewPopup.shadowMargin

            WindowPreviewPopup {
                id: previewPopup
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
