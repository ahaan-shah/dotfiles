pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

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
}
