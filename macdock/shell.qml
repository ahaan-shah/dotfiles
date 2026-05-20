pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: dockWindow

            required property ShellScreen modelData
            screen: modelData

            anchors {
                bottom: true
                left:   true
                right:  true
            }

            // Reserve space at the bottom so tiled windows don't go under the dock.
            // = pill height (maxIconSize + vertical padding + dot row) + float margin
            // matches the values in Dock.qml: maxIconSize=72, dockPadV=10, dots=14, floatMargin=10
            exclusiveZone: 40 + 16   // = 116

            WlrLayershell.layer:     WlrLayer.Top
            WlrLayershell.namespace: "macdock"
            color: "transparent"

            // Panel height = exclusiveZone + a little extra for shadow/magnification headroom
            implicitHeight: 130
            implicitWidth:  screen.width

            // Input mask: only the pill itself receives mouse events
            mask: Region { item: dockPanel }

            Dock {
                id: dockPanel
                anchors {
                    bottom:           parent.bottom
                    horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }
}
