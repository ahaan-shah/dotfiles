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

            WlrLayershell.layer:     WlrLayer.Overlay
            WlrLayershell.namespace: "macswitcher"
            WlrLayershell.keyboardFocus: switcher.shown
                                         ? WlrKeyboardFocus.Exclusive
                                         : WlrKeyboardFocus.None
            color:         "transparent"
            implicitWidth:  screen.width
            implicitHeight: screen.height

            mask: Region { item: switcher.shown ? null : emptyRegion }
            Item { id: emptyRegion; width: 0; height: 0 }

            AppSwitcher {
                id: switcher
                anchors.fill: parent
                screenWidth:  win.screen.width
                screenHeight: win.screen.height
            }
        }
    }
}
