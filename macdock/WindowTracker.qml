pragma Singleton

import QtQuick
import Quickshell.Io

// Polls hyprctl clients every 1.5 s and exposes:
//   WindowTracker.runningClasses  – Set<string>  (all window classes currently open)
//   WindowTracker.activeClass     – string        (class of the focused window)
//   WindowTracker.windowsFor(cls) – [{address,title}]  (windows matching a class)
QtObject {
    id: root

    // ── public API ────────────────────────────────────────────────
    property var runningClasses: ({})   // object used as Set: { "firefox": true, … }
    property string activeClass: ""
    property string activeAddress: ""
    property var windowList: []         // raw array of {class, address, title}

    function windowsFor(cls, titleHint) {
        if ((!cls || cls === "") && (!titleHint || titleHint === "")) return []
        const lc  = cls ? cls.toLowerCase() : ""
        const th  = titleHint ? titleHint.toLowerCase() : ""
        return root.windowList.filter(w => {
            // 1. Exact class match
            if (lc && w.class === lc) return true
            // 2. Class contains the pattern (handles chromium webapp classes)
            if (lc && lc !== "" && w.class.includes(lc)) return true
            // 3. Pattern contains the class
            if (lc && lc !== "" && lc.includes(w.class) && w.class !== "") return true
            // 4. Same checks against initialClass
            if (lc && w.initialClass && w.initialClass.includes(lc)) return true
            if (lc && w.initialClass && lc.includes(w.initialClass) && w.initialClass !== "") return true
            // 5. Title fallback — window title contains the app name hint
            if (th && th !== "" && w.title.toLowerCase().includes(th)) return true
            return false
        })
    }

    function isRunning(cls, titleHint) {
        return windowsFor(cls, titleHint).length > 0
    }

    // ── internal ──────────────────────────────────────────────────
    property var _clientsProcess: Process {
        id: clientsProc
        command: ["bash", "-c", "hyprctl clients -j"]
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._clientsBuf += data
        }
    }

    property var _activeProcess: Process {
        id: activeProc
        command: ["bash", "-c", "hyprctl activewindow -j"]
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._activeBuf += data
        }
    }

    property string _clientsBuf: ""
    property string _activeBuf: ""

    property var _pollTimer: Timer {
        interval: 350
        running: true
        repeat: true
        onTriggered: {
            root._clientsBuf = ""
            clientsProc.running = true
        }
    }

    // Fast timer just for active window — drives dot highlight responsiveness
    property var _activePollTimer: Timer {
        interval: 150
        running: true
        repeat: true
        onTriggered: {
            root._activeBuf = ""
            activeProc.running = true
        }
    }

    // Parse clients JSON when process exits
    property var _clientsConn: Connections {
        target: clientsProc
        function onRunningChanged() {
            if (clientsProc.running) return
            try {
                const arr = JSON.parse(root._clientsBuf)

                // Skip dialog/portal windows — they should never appear in the dock
                const skipClasses = new Set([
                    "", "xdg-desktop-portal", "xdg-desktop-portal-gnome",
                    "xdg-desktop-portal-gtk", "xdg-desktop-portal-kde",
                    "gcr-prompter", "polkit-gnome-authentication-agent-1"
                ])
                const filtered = arr.filter(w => !skipClasses.has((w.class ?? "").toLowerCase()))

                root.windowList = filtered.map(w => ({
                    class:         (w.class        ?? "").toLowerCase(),
                    initialClass:  (w.initialClass ?? w.class ?? "").toLowerCase(),
                    address:       w.address       ?? "",
                    title:         w.title         ?? "",
                    initialTitle:  w.initialTitle  ?? w.title ?? "",
                    pid:           w.pid           ?? 0,
                    workspaceId:   w.workspace?.id   ?? 0,
                    workspaceName: (w.workspace?.name ?? "").toLowerCase(),
                    x:             w.at?.[0]   ?? 0,
                    y:             w.at?.[1]   ?? 0,
                    ww:            w.size?.[0] ?? 0,
                    wh:            w.size?.[1] ?? 0
                }))
                const cls = {}
                filtered.forEach(w => { if (w.class) cls[w.class.toLowerCase()] = true })
                root.runningClasses = cls
            } catch (e) {}
        }
    }

    // Parse activewindow JSON when process exits
    property var _activeConn: Connections {
        target: activeProc
        function onRunningChanged() {
            if (activeProc.running) return
            try {
                const obj = JSON.parse(root._activeBuf)
                root.activeClass   = (obj.class   ?? "").toLowerCase()
                root.activeAddress = (obj.address ?? "").toLowerCase()
            } catch (e) {
                root.activeClass = ""
            }
        }
    }

    Component.onCompleted: {
        root._clientsBuf = ""
        root._activeBuf  = ""
        clientsProc.running = true
        activeProc.running  = true
    }
}
