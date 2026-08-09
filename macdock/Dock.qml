pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import "."

Item {
    id: root

    // ── Sizing knobs ──────────────────────────────────────────────
    readonly property int baseIconSize: 34
    readonly property int maxIconSize:  40
    readonly property int magnRadius:   45
    readonly property int dockPadH:     5   // left/right padding inside pill
    readonly property int dockPadV:     0   // top/bottom padding inside pill
    readonly property int iconSpacing:  0
    readonly property int floatMargin:  4   // gap between pill bottom and screen edge

    // ── Mouse X in row coordinates (–1 = outside) ─────────────────
    property real hoverX: -1

    // Whether the pointer is anywhere over the dock's own footprint.
    // Read by shell.qml — must be set from dockMouseArea below, not a second
    // overlapping MouseArea, since QtQuick only delivers hover (entered/
    // exited) to the topmost hoverEnabled MouseArea at a given point; an
    // externally-added MouseArea sitting behind this one in z-order never
    // sees these events at all.
    property bool hovered: false

    // ── Multi-instance hover preview ────────────────────────────────
    // Detection is driven centrally off dockMouseArea/hoverX below (NOT off
    // DockIcon's own nested MouseArea — per the note on `hovered` above, a
    // topmost MouseArea like dockMouseArea is the only one that reliably
    // receives hover in this layout; DockIcon's own MouseArea only gets
    // clicks, via NoButton + propagateComposedEvents fallthrough, which
    // doesn't extend to raw hover/entered/exited).
    //
    // Actual show/hide state lives in the DockPreview singleton, not here —
    // shell.qml's preview popup is a separate per-screen PanelWindow in its
    // own Variants block, and ids declared in this Dock instance aren't
    // visible there. See DockPreview.qml for why.
    property var screen: null   // set by shell.qml to this Dock's ShellScreen

    // Which icon (by windowClass) is the current hover-intent candidate —
    // "" means none. Used purely to detect "did the hovered icon change".
    property string _hoverCandidateClass: ""

    function _updateHoverCandidate() {
        if (root.hoverX < 0) {
            _setHoverCandidate("", null)
            return
        }
        const item = iconRow.childAt(root.hoverX, iconRow.height / 2)
        if (!item || item.separator || !item.windowClass || item.windowClass === "") {
            _setHoverCandidate("", null)
            return
        }
        _setHoverCandidate(item.windowClass, item)
    }

    function _setHoverCandidate(cls, item) {
        if (cls === root._hoverCandidateClass) return
        root._hoverCandidateClass = cls
        _previewIntentTimer.stop()

        const isActiveScreen = DockPreview.activeScreen === root.screen
        if (cls === "") {
            if (DockPreview.visible && isActiveScreen) DockPreview.scheduleClose()
            return
        }

        if (WindowTracker.windowsFor(cls, "").length >= 2) {
            _previewIntentTimer.item = item
            _previewIntentTimer.restart()
        } else if (DockPreview.visible && isActiveScreen) {
            DockPreview.scheduleClose()
        }
    }

    // Sustained-hover gate — only shows the popup after 500ms of continuous
    // hover over the same multi-instance icon.
    property var _previewIntentTimer: Timer {
        property var item: null
        interval: 500
        repeat:   false
        onTriggered: {
            if (!item) return
            const p = item.mapToGlobal(item.width / 2, 0)
            DockPreview.show(
                WindowTracker.windowsFor(item.windowClass, ""),
                item.iconPath,
                p.x, p.y,
                root.height,
                root.screen)
        }
    }

    // ── Stable state ──────────────────────────────────────────────
    property var _unpinnedOrder: []
    property var dynamicApps:    []  // written atomically by _rebuild(), never a binding

    // ── Rebuild the model ─────────────────────────────────────────
    // Called by Connections whenever windowList changes.
    // Keeping all mutation here (never inside a binding expression)
    // prevents QML's binding engine from cascading re-evaluations that
    // corrupt the Repeater model and terminate open apps.
    function _rebuild() {
        const pinned = []
        for (let i = 0; i < dockModel.count; i++) {
            pinned.push({
                name:        dockModel.get(i).name,
                icon:        dockModel.get(i).icon,
                command:     dockModel.get(i).command,
                windowClass: dockModel.get(i).windowClass,
                separator:   dockModel.get(i).separator,
                isPinned:    true
            })
        }

        const coveredClasses = new Set()
        pinned.forEach(p => {
            if (p.windowClass && p.windowClass !== "")
                coveredClasses.add(p.windowClass.toLowerCase())
        })

        const currentlyOpen = new Set()
        const windowByClass = {}
        WindowTracker.windowList.forEach(w => {
            if (!w.class || w.class === "") return
            let covered = false
            coveredClasses.forEach(c => {
                if (w.class.includes(c) || c.includes(w.class)) covered = true
            })
            if (!covered) {
                currentlyOpen.add(w.class)
                if (!windowByClass[w.class]) windowByClass[w.class] = w
            }
        })

        const order = root._unpinnedOrder.slice()
        currentlyOpen.forEach(cls => {
            if (!order.includes(cls)) order.push(cls)
        })
        const pruned = order.filter(cls => currentlyOpen.has(cls))
        root._unpinnedOrder = pruned

        const extra = pruned.map(cls => {
            const w = windowByClass[cls]
            return {
                name:        w.initialTitle || w.title || cls,
                icon:        root.resolveIcon(w),
                command:     "",
                windowClass: cls,
                separator:   false,
                isPinned:    false
            }
        })

        root.dynamicApps = pinned.concat(extra)
    }

    // Trigger rebuild whenever the window list changes
    property var _trackerConn: Connections {
        target: WindowTracker
        function onWindowListChanged() { root._rebuild() }
    }

    // Re-resolve icons once DesktopEntryCache's async index actually lands —
    // a window already open when macdock starts can race the singleton's
    // own first-load Process, see DesktopEntryCache.qml's `ready` comment.
    property var _cacheConn: Connections {
        target: DesktopEntryCache
        function onReadyChanged() { root._rebuild() }
    }

    // ── Icon resolution for dynamic (unpinned) windows ───────────
    function resolveIcon(w) {
        const cls  = w.class        ?? ""
        const icls = w.initialClass ?? cls

        // 1. Look up the .desktop file by StartupWMClass — most reliable for webapps
        const desktopIcon = DesktopEntryCache.iconForClass(cls)
        if (desktopIcon !== "") return desktopIcon

        // Also try initialClass in case it differs
        if (icls !== cls) {
            const desktopIcon2 = DesktopEntryCache.iconForClass(icls)
            if (desktopIcon2 !== "") return desktopIcon2
        }

        // 2. Try system icon theme with stripped class name
        const prefixes = ["brave-", "chrome-", "chromium-", "msedge-", "firefox-"]
        for (let i = 0; i < prefixes.length; i++) {
            const p = prefixes[i]
            if (cls.startsWith(p)) {
                let s = cls.slice(p.length)
                s = s.replace(/[_-]+default$/i, "").replace(/__.*$/, "")
                const domainRoot = s.split(".")[0]
                if (domainRoot) return "image://icon/" + domainRoot
            }
        }

        // 3. Last dot-segment (e.g. "org.gnome.Nautilus" → "nautilus")
        const segments = cls.split(".")
        if (segments.length > 1) return "image://icon/" + segments[segments.length - 1].toLowerCase()

        // 4. Raw class — DockIcon's letter-tile fallback handles total failure
        return "image://icon/" + cls
    }

    // ── Pill dimensions ───────────────────────────────────────────
    readonly property real pillWidth:  iconRow.implicitWidth + dockPadH * 2
    readonly property real pillHeight: maxIconSize + dockPadV * 2 + 14

    // Total height this item occupies (pill + float gap)
    width:  pillWidth
    height: pillHeight + floatMargin + 10   // extra 10 for shadow room
    Behavior on width  { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    // ── Frosted glass background ──────────────────────────────────
    Rectangle {
        id: pill
        anchors.bottom:           parent.bottom
        anchors.bottomMargin:     root.floatMargin
        anchors.horizontalCenter: parent.horizontalCenter

        width:  root.pillWidth
        height: root.pillHeight
        radius: root.pillHeight / 2

        // Pywal: color0 (darkest bg tone) at 0.82 alpha for the fill;
        // color1 (first accent) at 0.55 alpha for the border.
        color:        Qt.rgba(
                          parseInt(WalColors.color0.slice(1,3), 16) / 255,
                          parseInt(WalColors.color0.slice(3,5), 16) / 255,
                          parseInt(WalColors.color0.slice(5,7), 16) / 255,
                          0.82)
        border.color: Qt.rgba(
                          parseInt(WalColors.color1.slice(1,3), 16) / 255,
                          parseInt(WalColors.color1.slice(3,5), 16) / 255,
                          parseInt(WalColors.color1.slice(5,7), 16) / 255,
                          0.55)
        border.width: 2

        Behavior on color        { ColorAnimation { duration: 600; easing.type: Easing.InOutCubic } }
        Behavior on border.color { ColorAnimation { duration: 600; easing.type: Easing.InOutCubic } }
        Behavior on width        { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on height       { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled:          true
            shadowColor:            Qt.rgba(0, 0, 0, 0.45)
            shadowBlur:             0.7
            shadowHorizontalOffset: 0
            shadowVerticalOffset:   4
        }
    }

    // ── Icon row ──────────────────────────────────────────────────
    Row {
        id: iconRow
        anchors.bottom:           parent.bottom
        anchors.bottomMargin:     root.floatMargin
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: root.iconSpacing

        leftPadding:  root.dockPadH
        rightPadding: root.dockPadH

        DockModel { id: dockModel }

        Repeater {
            model: root.dynamicApps

            DockIcon {
                required property var  modelData
                required property int  index

                appName:     modelData.name
                iconPath:    modelData.icon
                command:     modelData.command
                separator:   modelData.separator
                windowClass: modelData.windowClass

                baseSize:   root.baseIconSize
                maxSize:    root.maxIconSize
                magnRadius: root.magnRadius
                dockHoverX: root.hoverX
            }
        }
    }

    Component.onCompleted: root._rebuild()

    // ── Mouse tracking ────────────────────────────────────────────
    MouseArea {
        id: dockMouseArea
        anchors.fill: parent
        hoverEnabled: true
        propagateComposedEvents: true
        acceptedButtons: Qt.NoButton

        onPositionChanged: mouse => {
            root.hoverX = iconRow.mapFromItem(dockMouseArea, mouse.x, 0).x
            root._updateHoverCandidate()
        }
        onExited: {
            root.hoverX = -1
            root.hovered = false
            root._updateHoverCandidate()
        }
        onEntered: {
            root.hoverX = iconRow.mapFromItem(dockMouseArea, mouseX, 0).x
            root.hovered = true
            root._updateHoverCandidate()
        }
    }
}
