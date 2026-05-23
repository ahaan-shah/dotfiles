pragma Singleton

import QtQuick
import Quickshell.Io

// Fetches the full window list from Hyprland and exposes it.
// Also tracks the active window address.
QtObject {
    id: root

    property var   windows:       []
    property string activeAddress: ""

    readonly property var skipClasses: new Set([
        "", "xdg-desktop-portal", "xdg-desktop-portal-gnome",
        "xdg-desktop-portal-gtk", "xdg-desktop-portal-kde",
        "gcr-prompter", "polkit-gnome-authentication-agent-1"
    ])

    // ── Clients poll ──────────────────────────────────────────────
    property string _clientsBuf: ""

    property var _clientsProc: Process {
        id: clientsProc
        command: ["hyprctl", "clients", "-j"]
        running: true
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._clientsBuf += data
        }
    }

    property var _clientsConn: Connections {
        target: clientsProc
        function onRunningChanged() {
            if (clientsProc.running) return
            try {
                const arr = JSON.parse(root._clientsBuf)
                root.windows = arr
                    .filter(w => !root.skipClasses.has((w.class ?? "").toLowerCase()))
                    .map(w => ({
                        class:          (w.class        ?? "").toLowerCase(),
                        initialClass:   (w.initialClass ?? w.class ?? "").toLowerCase(),
                        address:        w.address  ?? "",
                        title:          w.title    ?? "",
                        initialTitle:   w.initialTitle ?? w.title ?? "",
                        pid:            w.pid      ?? 0,
                        workspace:      w.workspace?.id ?? 0,
                        workspaceName:  (w.workspace?.name ?? "").toLowerCase(),
                        floating:       w.floating ?? false,
                        focusHistoryID: w.focusHistoryID ?? 9999
                    }))
                    .sort((a, b) => a.focusHistoryID - b.focusHistoryID)
            } catch(e) {}
            root._clientsBuf = ""
        }
    }

    // ── Active window poll ────────────────────────────────────────
    property string _activeBuf: ""

    property var _activeProc: Process {
        id: activeProc
        command: ["hyprctl", "activewindow", "-j"]
        running: true
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._activeBuf += data
        }
    }

    property var _activeConn: Connections {
        target: activeProc
        function onRunningChanged() {
            if (activeProc.running) return
            try {
                const w = JSON.parse(root._activeBuf)
                root.activeAddress = w.address ?? ""
            } catch(e) {}
            root._activeBuf = ""
        }
    }

    // Poll clients on demand (called by AppSwitcher when it opens)
    function refresh() {
        root._clientsBuf = ""
        clientsProc.running = true
    }

    function refreshActive() {
        root._activeBuf = ""
        activeProc.running = true
    }
}
