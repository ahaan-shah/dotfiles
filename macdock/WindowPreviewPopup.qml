pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell.Io
import "."

// Multi-instance hover preview: one tile per open window of the app whose
// dock icon is being hovered, so a specific instance can be picked instead
// of cycling through them with repeated clicks. Chrome (rounded card,
// wal-colored semi-opaque fill/border) is modeled on taskbar/shell.qml's
// calendar dropdown, per the user's explicit visual reference — but unlike
// that dropdown, this Item is hosted in a content-sized PanelWindow (see
// shell.qml), not a full-screen one, so it never intercepts input outside
// its own visible bounds.
//
// Deliberately a single MouseArea covering the whole popup (hover-bridging
// AND click dispatch, hit-testing which tile via tileRow.childAt) rather
// than one MouseArea per tile — Dock.qml's own dockMouseArea/DockIcon
// relationship demonstrates overlapping MouseAreas in this layout don't
// reliably both receive events, so this mirrors the one-MouseArea-plus-
// childAt pattern already proven to work there instead of risking the same
// pitfall here.
Item {
    id: root

    property var    windows:  []   // WindowTracker window objects for this class
    property string iconPath: ""

    // Injected by shell.qml: bridges hover here back into Dock.qml's
    // close-grace timer so moving the mouse from the dock icon up into
    // this popup doesn't flicker-close it.
    property var cancelClose:   function() {}
    property var scheduleClose: function() {}
    property var closeNow:      function() {}

    // Room around the card for its drop shadow to fade out in. Without
    // this, the card filled the whole PanelWindow surface exactly, so the
    // shadow (shadowBlur/shadowVerticalOffset below) got hard-clipped at
    // the surface's own rectangular bounds instead of fading to nothing —
    // visible as a faint rectangular halo poking out past the rounded
    // corners, worst at the bottom edge where the offset pushes it. See
    // Dock.qml's own pill, which reserves similar space ("extra 10 for
    // shadow room") for the same reason. shell.qml compensates its bottom
    // margin by this amount so the *visible* gap above the dock is
    // unaffected by this padding.
    readonly property int shadowMargin: 12

    implicitWidth:  card.width  + shadowMargin * 2
    implicitHeight: card.height + shadowMargin * 2

    property int _hoverIndex: -1

    Rectangle {
        id: card
        anchors.centerIn: parent
        width:  Math.max(tileRow.implicitWidth + 24, 40)
        height: tileRow.implicitHeight + 20
        radius: 16

        // Same WalColors Qt.rgba idiom as Dock.qml's pill (lines 200-212),
        // just more opaque — this is a transient popup, not a persistent
        // bar, so it can afford to read more clearly against any window
        // behind it.
        color: Qt.rgba(
                  parseInt(WalColors.color0.slice(1, 3), 16) / 255,
                  parseInt(WalColors.color0.slice(3, 5), 16) / 255,
                  parseInt(WalColors.color0.slice(5, 7), 16) / 255,
                  0.92)
        border.color: Qt.rgba(
                  parseInt(WalColors.color1.slice(1, 3), 16) / 255,
                  parseInt(WalColors.color1.slice(3, 5), 16) / 255,
                  parseInt(WalColors.color1.slice(5, 7), 16) / 255,
                  0.55)
        border.width: 3

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled:          true
            shadowColor:            Qt.rgba(0, 0, 0, 0.45)
            shadowBlur:             0.7
            shadowHorizontalOffset: 0
            shadowVerticalOffset:   4
        }

        Row {
            id: tileRow
            anchors.centerIn: parent
            spacing: 10

            Repeater {
                model: root.windows

                Rectangle {
                    id: tile
                    required property var modelData
                    required property int index

                    width:  140
                    height: 92
                    radius: 10
                    color: root._hoverIndex === index
                        ? Qt.rgba(1, 1, 1, 0.16)
                        : Qt.rgba(1, 1, 1, 0.07)
                    Behavior on color { ColorAnimation { duration: 120 } }

                    // Grey per-window border, matching macswitcher's own
                    // card chrome (AppSwitcher.qml's panel border: color7,
                    // 2px, 0.55 alpha) rather than macdock's own accent-
                    // colored (color1) chrome used on the popup's outer card.
                    border.width: 2
                    border.color: Qt.rgba(
                              parseInt(WalColors.color7.slice(1, 3), 16) / 255,
                              parseInt(WalColors.color7.slice(3, 5), 16) / 255,
                              parseInt(WalColors.color7.slice(5, 7), 16) / 255,
                              0.55)

                    Column {
                        anchors.centerIn: parent
                        spacing: 6
                        width: parent.width - 12

                        Image {
                            anchors.horizontalCenter: parent.horizontalCenter
                            source:            root.iconPath
                            width:             40
                            height:            40
                            sourceSize.width:  80
                            sourceSize.height: 80
                            fillMode:          Image.PreserveAspectFit
                            smooth:            true
                            mipmap:            true
                        }

                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            elide:            Text.ElideRight
                            maximumLineCount: 2
                            wrapMode:         Text.WordWrap
                            text:  tile.modelData.title || tile.modelData.initialTitle
                                   || tile.modelData.class
                            color: "white"
                            font.pixelSize: 12
                        }
                    }
                }
            }
        }
    }

    MouseArea {
        id: popupMouse
        anchors.fill: parent
        hoverEnabled: true

        onEntered: root.cancelClose()
        onExited: {
            root._hoverIndex = -1
            root.scheduleClose()
        }
        onPositionChanged: mouse => {
            const p = tileRow.mapFromItem(popupMouse, mouse.x, mouse.y)
            const item = tileRow.childAt(p.x, p.y)
            root._hoverIndex = item ? item.index : -1
        }
        onClicked: mouse => {
            const p = tileRow.mapFromItem(popupMouse, mouse.x, mouse.y)
            const item = tileRow.childAt(p.x, p.y)
            if (!item) return
            const w = item.modelData
            focusAddr.addr        = w.address
            focusAddr.isSpecial   = (w.workspaceName ?? "").startsWith("special:")
            focusAddr.workspaceId = w.workspaceId ?? 0
            focusAddr.running     = true
            // Close immediately rather than waiting for the mouse to leave
            // the popup first (it usually doesn't move on click) — a click
            // is a definite choice, no need for the close-grace timer.
            root.closeNow()
        }
    }

    // Mirrors DockIcon.qml's own focusAddr Process exactly (same 0.55
    // hl.dsp.* dispatch chain) — see the note there on why hyprctl dispatch
    // takes a Lua-expression string rather than the old positional form.
    Process {
        id: focusAddr
        property string addr:        ""
        property bool   isSpecial:   false
        property int    workspaceId: 0
        command: ["bash", "-c",
            isSpecial
                ? "hyprctl dispatch \"hl.dsp.window.move({ workspace = 'e+0', window = 'address:" + addr + "' })\""
                  + " && hyprctl dispatch \"hl.dsp.focus({ window = 'address:" + addr + "' })\""
                  + " && hyprctl dispatch \"hl.dsp.window.bring_to_top()\""
                : "hyprctl dispatch \"hl.dsp.focus({ workspace = " + workspaceId + " })\""
                  + " && hyprctl dispatch \"hl.dsp.focus({ window = 'address:" + addr + "' })\""
                  + " && hyprctl dispatch \"hl.dsp.window.bring_to_top()\""]
        running: false
    }
}
