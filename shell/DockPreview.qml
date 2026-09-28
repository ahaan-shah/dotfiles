pragma Singleton

import QtQuick

// Shared hover-preview state, written by Dock.qml (one instance per screen,
// via shell.qml's Variants) and read by shell.qml's separate per-screen
// preview PanelWindow. A singleton (rather than a property on Dock.qml
// directly) because those two live in independent Variants blocks — QML
// ids declared inside one Variants delegate aren't visible from another,
// and Variants.delegate is a single component, not a list, so the popup
// can't just be a second child of the dock's own PanelWindow either. Only
// one screen's dock can plausibly be hovered at a time, so a single shared
// instance (rather than one per screen) is fine — `activeScreen` records
// which screen's popup should actually render.
QtObject {
    id: root

    property bool   visible:     false
    property var    windows:     []      // WindowTracker window objects
    property string iconPath:    ""
    property real   globalX:     0       // hovered icon's mapToGlobal anchor
    property real   globalY:     0
    property real   dockHeight:  0       // that screen's dock thickness away from its edge
    // The hovered icon's centre, as a y in the dock WINDOW's own coordinates.
    // Only a side dock uses it: there the popup sits beside the icon, and the
    // dock and popup windows both span the same full-height strip, so a
    // window-local y is already right for the popup's window.
    property real   localY:      0
    property var    activeScreen: null   // the ShellScreen the hover originated on

    function show(windows, iconPath, globalX, globalY, dockHeight, screen, localY) {
        _closeTimer.stop()
        root.windows      = windows
        root.iconPath     = iconPath
        root.globalX      = globalX
        root.globalY      = globalY
        root.dockHeight   = dockHeight
        root.localY       = localY ?? 0
        root.activeScreen = screen
        root.visible      = true
    }

    function cancelClose()   { _closeTimer.stop() }
    function scheduleClose() { _closeTimer.restart() }

    // Bypasses the close-grace timer entirely — used when a tile is
    // clicked, so the popup doesn't linger over the now-focused window
    // waiting for the mouse to move away first.
    function hideNow() {
        _closeTimer.stop()
        root.visible = false
    }

    property var _closeTimer: Timer {
        interval: 250
        repeat:   false
        onTriggered: root.visible = false
    }
}
