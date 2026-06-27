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

            exclusiveZone: dockController.dockVisible ? 56 : 0
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
                property bool mouseOnDock:     false
                property bool windowOverlaps:  false

                readonly property bool dockVisible: mouseNearBottom || mouseOnDock || !windowOverlaps

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
                            // Show dock when cursor is within 2px of screen bottom
                            dockController.mouseNearBottom = pos.y >= (sh - 40)
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

                // Hide speed: second number (currently 150ms)
                // Show speed: first number  (currently 220ms)
                anchors.bottomMargin: dockController.dockVisible ? 0 : -(height + 16)
                Behavior on anchors.bottomMargin {
                    NumberAnimation {
                        duration:    dockController.dockVisible ? 300 : 200
                        easing.type: dockController.dockVisible ? Easing.OutCubic : Easing.InCubic
                    }
                }
                opacity: dockController.dockVisible ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: dockController.dockVisible ? 300 : 200 }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    propagateComposedEvents: true
                    z: -1
                    onEntered: dockController.mouseOnDock = true
                    onExited:  dockController.mouseOnDock = false
                }
            }
        }
    }
}
