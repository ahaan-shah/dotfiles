pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property ShellScreen modelData
            screen: modelData

            anchors { top: true; left: true; right: true; bottom: true }

            // Mapped only while the launcher is actually up.
            //
            // Without this the window is a FULL-SCREEN layer surface on the
            // OVERLAY level for the entire life of the session — measured with
            // `hyprctl layers`, finder sat there at 1440x766 with nothing on
            // screen. Every frame the compositor ever draws then blends one more
            // full-screen layer over the top of everything, for a launcher that
            // is visible for a few seconds a day. Every one of the taskbar's own
            // full-screen click-catchers is bound to its panel's visibility for
            // exactly this reason (`visible: root.dispVisible`, and five more
            // like it); finder was the one that never was.
            //
            // The `mask` below stays as well. It is what makes clicks fall
            // through during the frame either side of a map/unmap, and it costs
            // nothing.
            visible: finder.shown

            WlrLayershell.layer:     WlrLayer.Overlay
            WlrLayershell.namespace: "finder"
            WlrLayershell.keyboardFocus: finder.shown
                                         ? WlrKeyboardFocus.Exclusive
                                         : WlrKeyboardFocus.None
            color:         "transparent"
            implicitWidth:  screen.width
            implicitHeight: screen.height

            mask: Region { item: finder.shown ? null : emptyRegion }
            Item { id: emptyRegion; width: 0; height: 0 }

            Finder {
                id: finder
                anchors.fill: parent
                screenWidth:  win.screen.width
                screenHeight: win.screen.height
            }
        }
    }
}
