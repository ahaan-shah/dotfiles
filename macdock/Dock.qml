pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects

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

    // ── Stable insertion-order list for unpinned app classes ──────
    // We only ever append to this; never reorder. This prevents unpinned
    // icons from jumping around when WindowTracker re-polls.
    property var _unpinnedOrder: []

    // ── Merged app list: pinned + any unpinned open windows ───────
    //
    // We take the static DockModel, then append any window class that is
    // currently open but has NO match in the pinned list. Unpinned entries
    // are kept in stable insertion order via _unpinnedOrder so re-polls
    // from WindowTracker never cause icons to jump or reorder.
    readonly property var dynamicApps: {
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

        // Collect classes already covered by pinned entries
        const coveredClasses = new Set()
        pinned.forEach(p => {
            if (p.windowClass && p.windowClass !== "")
                coveredClasses.add(p.windowClass.toLowerCase())
        })

        // Build a map of currently-open unpinned classes → their window object
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

        // Append any newly-seen class to _unpinnedOrder (append-only, never reorder)
        const order = root._unpinnedOrder.slice()
        currentlyOpen.forEach(cls => {
            if (!order.includes(cls)) order.push(cls)
        })
        // Prune classes that are no longer open
        const pruned = order.filter(cls => currentlyOpen.has(cls))
        root._unpinnedOrder = pruned

        // Build extra list in stable insertion order
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

        return pinned.concat(extra)
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
    readonly property real pillHeight: maxIconSize + dockPadV * 2 + 12

    // Total height this item occupies (pill + float gap)
    width:  pillWidth
    height: pillHeight + floatMargin + 10   // extra 10 for shadow room

    // ── Frosted glass background ──────────────────────────────────
    Rectangle {
        id: pill
        anchors.bottom:           parent.bottom
        anchors.bottomMargin:     root.floatMargin
        anchors.horizontalCenter: parent.horizontalCenter

        width:  root.pillWidth
        height: root.pillHeight
        radius: root.pillHeight / 2

        color:        Qt.rgba(1, 1, 1, 0.14)
        border.color: Qt.rgba(1, 1, 1, 0.22)
        border.width: 1

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

    // ── Mouse tracking ────────────────────────────────────────────
    MouseArea {
        id: dockMouseArea
        anchors.fill: parent
        hoverEnabled: true
        propagateComposedEvents: true
        acceptedButtons: Qt.NoButton

        onPositionChanged: mouse => {
            root.hoverX = iconRow.mapFromItem(dockMouseArea, mouse.x, 0).x
        }
        onExited:  { root.hoverX = -1 }
        onEntered: { root.hoverX = iconRow.mapFromItem(dockMouseArea, mouseX, 0).x }
    }
}
