pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
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

    // ── Home-relative paths ──────────────────────────────
    // A pin's icon living under the user's home is stored with a leading "~/"
    // and expanded here — DockModel.qml's ListElements cannot evaluate JS, so
    // the seed could never spell out a real path, and the store inherits the
    // same convention so a hand-edit reads the same in both files. Only a
    // leading "~/" is treated specially; absolute paths pass through untouched.
    readonly property string homeDir: Quickshell.env("HOME") || ""
    // A pin's `icon` is a name, a ~/-relative file, an absolute file, or an
    // already-resolved URL — see the header of DockPins.qml. A NAME goes
    // through the shared theme index, so pinned icons follow Settings -> Icons
    // instead of being frozen to whatever theme was current when they were
    // pinned.
    function _resolveDockIcon(v) {
        if (typeof v !== "string" || v === "") return v
        if (v.substring(0, 2) === "~/") return root.homeDir + v.substring(1)
        if (v.charAt(0) === "/")        return v
        // Already a URL — "file://…" or "image://icon/…". A pin created by
        // right-clicking a window whose class has no .desktop entry carries one
        // of these, and feeding it back through resolveIconPath() below would
        // produce "image://icon/image://icon/foo" and a blank tile.
        if (v.indexOf("://") > 0)       return v
        // resolveIconPath falls back to image://icon/<name> when the theme has
        // no such icon, which is a working last resort rather than a blank tile.
        return DesktopEntryCache.resolveIconPath(v)
    }

    // ── Stable state ──────────────────────────────────────────────
    // ONE ordered list of dock slots, pinned and unpinned together, keyed by
    // window class. This was two lists — the pinned block from DockModel, then
    // whatever was open — which was fine while the pinned block could not
    // change, and is exactly wrong now that it can: promoting a running app out
    // of the second list would land it at the END of the first, hopping the
    // icon left over every unpinned one before it, at the moment the user is
    // pointing at it. With one list a right-click only flips `isPinned` on a
    // slot that is already in place, so an app pins where the pointer is.
    // Order survives a restart because the store is written back in this same
    // order — see DockPins.setPins().
    property var _slotOrder: []
    property var dynamicApps:    []  // written atomically by _rebuild(), never a binding

    // ── Rebuild the model ─────────────────────────────────────────
    // Called by Connections whenever the window list, the pin store or the
    // icon index changes.
    // Keeping all mutation here (never inside a binding expression)
    // prevents QML's binding engine from cascading re-evaluations that
    // corrupt the Repeater model and terminate open apps.
    function _rebuild() {
        // Nothing until the pin store has actually been read. Both sources here
        // are async, and whichever lands first sets the slot order: with the
        // window list arriving first, every open app took a slot BEFORE the
        // pins existed and the pinned block came up shuffled into compositor
        // order — measured, on a dock that should have opened kitty-first and
        // opened Files-first instead. An empty dock for the few ms a `cat`
        // takes is the correct thing to draw.
        if (!DockPins.ready) return

        // A rebuild reassigns dynamicApps, which regenerates every Repeater
        // delegate — under a drag that destroys the item the pointer is
        // holding. The window list is polled every 350ms, so this is not a
        // rare collision; it is one app opening away at any moment. Deferred
        // and replayed by endDrag().
        if (root._dragKey !== "") {
            root._rebuildPending = true
            return
        }

        const byKey = ({})

        // 1. The pinned slots, in the store's order.
        const pinEntries = []
        const pins = DockPins.pins
        for (let i = 0; i < pins.length; i++) {
            const p   = pins[i]
            const key = DockPins.keyFor(p, i)
            if (byKey[key]) continue      // a duplicated class in a hand-edited
                                          // file would otherwise claim two slots
            const e = {
                key:         key,
                name:        p.name,
                icon:        root._resolveDockIcon(p.icon),
                // What goes back to the store when the list is rewritten. The
                // resolved path must not: writing that back would freeze this
                // pin to today's icon theme.
                rawIcon:     p.icon,
                rawCommand:  p.command,
                command:     p.command,
                windowClass: p.windowClass,
                separator:   p.separator === true,
                isPinned:    true
            }
            byKey[key] = e
            pinEntries.push(e)
        }

        const coveredClasses = new Set()
        pinEntries.forEach(p => {
            if (p.windowClass && p.windowClass !== "")
                coveredClasses.add(p.windowClass.toLowerCase())
        })

        // 2. Open windows no pin already accounts for.
        const openEntries = []
        WindowTracker.windowList.forEach(w => {
            if (!w.class || w.class === "") return
            if (byKey[w.class]) return
            let covered = false
            coveredClasses.forEach(c => {
                if (w.class.includes(c) || c.includes(w.class)) covered = true
            })
            if (covered) return
            // The APP's name, not the window's title. A title is whatever the
            // window happens to say at this instant — an unpinned Nautilus
            // caught mid-load reported "Loading…" — and that string is what
            // the letter-tile fallback takes its initial from and what the pin
            // toast names when this slot is right-clicked.
            const wde = DesktopEntryCache.entryForClass(w.class)
            const e = {
                key:         w.class,
                name:        (wde && wde.name) ? wde.name
                                               : (w.initialTitle || w.title || w.class),
                icon:        root.resolveIcon(w),
                rawIcon:     "",
                rawCommand:  "",
                command:     "",
                windowClass: w.class,
                separator:   false,
                isPinned:    false
            }
            byKey[w.class] = e
            openEntries.push(e)
        })

        // 3. Order: keep every slot exactly where it already was, drop the ones
        //    that are gone, append what is new — pins first (they carry their
        //    own stored order into an empty list at startup), then windows in
        //    the order the compositor reports them.
        const seen  = new Set()
        const order = []
        const take  = k => {
            if (!byKey[k] || seen.has(k)) return
            seen.add(k)
            order.push(k)
        }
        root._slotOrder.forEach(take)
        pinEntries.forEach(e  => take(e.key))
        openEntries.forEach(e => take(e.key))

        const apps = order.map(k => byKey[k])
        root._slotOrder = order
        // Positions first, model second. Assigning dynamicApps regenerates the
        // Repeater synchronously, and a delegate created while cellX still
        // describes the OLD list is born at the wrong x — then slides there
        // from it, because by then its Behavior is live.
        root._relayout(apps)
        root.dynamicApps = apps
    }

    // ── Layout ────────────────────────────────────────────────────
    // x per slot, indexed by MODEL index but computed in VISUAL order, which
    // are the same thing except while a drag is shuffling icons around. The Row
    // this replaced could not do that: a Row positions by child order, and the
    // child order comes from a JS-array model that is wholesale-replaced on
    // every rebuild, so a reorder was a pop rather than a slide. Positioning
    // each cell by an animated x is what makes the neighbours slide out of the
    // way — see the Behavior in DockIcon.qml.
    property var  cellX:    []
    property real rowWidth: root.dockPadH * 2

    function _cellW(e) { return (e && e.separator) ? 18 : root.baseIconSize + 8 }

    function _relayout(apps) {
        const n     = apps.length
        const order = []
        for (let i = 0; i < n; i++) order.push(i)

        // The dragged icon is lifted out of the flow and re-inserted at the
        // slot the pointer is over; everything between closes up behind it.
        const from = root._dragIndex
        const to   = root._dragTo
        if (from >= 0 && to >= 0 && from !== to && from < n && to < n) {
            order.splice(from, 1)
            order.splice(to, 0, from)
        }

        const xs = new Array(n)
        let content = 0
        for (let v = 0; v < n; v++) {
            const mi = order[v]
            xs[mi] = root.dockPadH + content
            content += root._cellW(apps[mi])
            if (v < n - 1) content += root.iconSpacing
        }
        root.cellX    = xs
        root.rowWidth = root.dockPadH * 2 + content
    }

    // ── Reorder by drag ───────────────────────────────────────────
    // Press and hold an icon to pick it up, then drag it. The arming step is
    // what keeps a dock icon a button: a plain press-and-move would make every
    // slightly sloppy click a potential reorder, on a control whose whole job
    // is to be clicked. It is a hold and not a double-click because a
    // double-click's FIRST click cannot be suppressed without delaying every
    // ordinary click by the double-click interval — see DockIcon.qml.
    property string _armedKey: ""       // double-clicked, ready to be moved
    property string _dragKey:  ""       // actually being dragged right now
    property int    _dragIndex: -1      // its index in dynamicApps
    property int    _dragTo:    -1      // the index it would land on
    property real   _dragX:     0       // pointer x, in iconRow coordinates
    property bool   _rebuildPending: false

    // Read by shell.qml: the dock must not auto-hide out from under a drag.
    readonly property bool dragActive: root._dragKey !== ""

    // A backstop only: arming normally ends with the release that ends the
    // hold. This covers the case where that release never arrives because the
    // grab was taken away.
    property var _disarmTimer: Timer {
        id: disarmTimer
        interval: 3000
        repeat:   false
        onTriggered: root._armedKey = ""
    }

    function armSlot(key) {
        root._armedKey = key
        disarmTimer.restart()
        if (DockPreview.visible) DockPreview.hideNow()
    }

    function beginDrag(key, index) {
        if (index < 0 || index >= root.dynamicApps.length) return
        root._dragKey   = key
        root._dragIndex = index
        root._dragTo    = index
        disarmTimer.stop()
        // Magnification and the multi-instance preview both key off the
        // pointer, and both are noise while an icon is being carried.
        root.hoverX = -1
        root._setHoverCandidate("", null)
    }

    function updateDrag(rowX) {
        if (root._dragKey === "") return
        root._dragX = rowX
        const to = root._dropIndexAt(rowX)
        if (to !== root._dragTo) {
            root._dragTo = to
            root._relayout(root.dynamicApps)
        }
    }

    // Which slot the pointer is over, measured against the layout the list had
    // BEFORE the drag started. Hit-testing the shuffled layout instead would
    // feed the shuffle back into itself and make the icons oscillate around
    // every boundary.
    function _dropIndexAt(px) {
        const apps = root.dynamicApps
        const n    = apps.length
        if (n === 0) return -1
        let x = root.dockPadH
        for (let i = 0; i < n; i++) {
            const w = root._cellW(apps[i])
            if (px < x + w) return i
            x += w + root.iconSpacing
        }
        return n - 1
    }

    function endDrag(commit) {
        const from = root._dragIndex
        const to   = root._dragTo

        root._dragKey   = ""
        root._dragIndex = -1
        root._dragTo    = -1
        root._armedKey  = ""        // one move per double-click

        if (commit && from >= 0 && to >= 0 && from !== to) {
            const apps  = root.dynamicApps.slice()
            const moved = apps.splice(from, 1)[0]
            apps.splice(to, 0, moved)
            root._slotOrder = apps.map(e => e.key)
            root._relayout(apps)
            root.dynamicApps = apps
            root._persistOrder(apps)
        } else {
            root._relayout(root.dynamicApps)
        }

        if (root._rebuildPending) {
            root._rebuildPending = false
            root._rebuild()
        }
    }

    // The store holds the pinned slots in dock order, so a drag that moved one
    // of them has to rewrite it — and a drag that only moved a running,
    // unpinned icon has nothing to say to it. Comparing before writing keeps a
    // session-only rearrangement off the disk entirely.
    function _persistOrder(apps) {
        const next = []
        apps.forEach(e => { if (e.isPinned) next.push(root._pinRecord(e)) })

        const now = DockPins.pins
        let same = (now.length === next.length)
        for (let i = 0; same && i < next.length; i++) {
            if (DockPins.keyFor(now[i], i) !== String(next[i].windowClass).toLowerCase())
                same = false
        }
        if (!same) DockPins.setPins(next)
    }

    // ── Pinning ───────────────────────────────────────────────────
    // Right-click toggles. The whole pin list is rewritten from the CURRENT
    // dock order rather than patched, because that order is the only record of
    // where the pins sit relative to each other — see _slotOrder above.
    function togglePin(key) {
        const slots = root.dynamicApps
        let target = null
        for (let i = 0; i < slots.length; i++)
            if (slots[i].key === key) target = slots[i]
        if (!target || target.separator) return

        const next = []
        let added = null
        slots.forEach(e => {
            if (e.key === key) {
                if (!target.isPinned) {
                    added = root._pinRecord(e)
                    next.push(added)
                }
                return                       // pinned + right-clicked = unpin,
                                             // so it is simply not carried over
            }
            if (e.isPinned) next.push(root._pinRecord(e))
        })
        DockPins.setPins(next)

        // The name the DOCK will show from now on, which for a newly pinned app
        // is the .desktop entry's ("Spotify") and not the window title it was
        // carrying a moment ago ("Spotify Premium").
        root._toast(added ? "Pinned " + added.name + " to the dock"
                          : "Removed " + target.name + " from the dock")
    }

    // A slot as it is stored. Pinned slots round-trip what they came in with;
    // an unpinned one has to be turned into something that can still be
    // launched after the app is quit, which is what the .desktop entry is for.
    function _pinRecord(e) {
        if (e.isPinned) {
            return {
                name:        e.name,
                icon:        e.rawIcon,
                command:     e.rawCommand,
                windowClass: e.windowClass,
                separator:   e.separator
            }
        }
        const de    = DesktopEntryCache.entryForClass(e.windowClass)
        // This desktop's own preference outranks the .desktop file's Icon=, or
        // pinning Files by right-click would swap Dolphin's icon for Nautilus's.
        const alias = IconResolver.aliasFor(e.windowClass)
        return {
            name:        (de && de.name) ? de.name : e.name,
            // A NAME, so this pin follows Settings -> Icons like every other
            // one. Only when there is no alias and no entry at all does the
            // already-resolved URL get stored — _resolveDockIcon() passes those
            // through untouched.
            icon:        alias !== ""      ? alias
                       : (de && de.icon)   ? de.icon
                       : e.icon,
            command:     (de && de.exec) ? de.exec : root._guessCommand(e.windowClass),
            windowClass: e.windowClass,
            separator:   false
        }
    }

    // Last resort for a window with no .desktop file behind it. The reverse-DNS
    // class of a well-behaved app is its binary ("org.gnome.nautilus" ->
    // "nautilus"), and a plain class usually IS the binary ("kitty"). It is a
    // guess, and a wrong one costs a dock icon that does nothing when clicked
    // while the app is closed — not a crash.
    function _guessCommand(cls) {
        if (!cls || cls === "") return ""
        const segs = cls.split(".")
        return segs.length > 1 ? segs[segs.length - 1].toLowerCase() : cls
    }

    // ── Pin confirmation ──────────────────────────────────────────
    // A right-click changes something with no visible effect at the moment it
    // happens: whether the icon is still there tomorrow. Hence a word about it.
    // It lives HERE and not in DockIcon because pinning rewrites dynamicApps,
    // and the Repeater destroys and recreates every delegate when that array's
    // contents change — an animation started inside an icon dies instantly.
    property string _toastText: ""
    function _toast(msg) {
        root._toastText = msg
        pinToast.opacity = 1
        toastTimer.restart()
    }

    // Trigger rebuild whenever the window list changes
    property var _trackerConn: Connections {
        target: WindowTracker
        function onWindowListChanged() { root._rebuild() }
    }

    // The pin store is read asynchronously and can be written by a hand-edit or
    // by a second macshell instance, so the dock follows it rather than
    // sampling it once at startup.
    property var _pinsConn: Connections {
        target: DockPins
        function onPinsChanged() { root._rebuild() }
        // Not the same signal: a store holding an empty pin list assigns the
        // same [] it started with, which emits nothing at all, and the dock
        // would then never draw its running apps either.
        function onReadyChanged() { root._rebuild() }
    }

    // Re-resolve icons once DesktopEntryCache's async index actually lands —
    // a window already open when macdock starts can race the singleton's
    // own first-load Process, see DesktopEntryCache.qml's `ready` comment.
    property var _cacheConn: Connections {
        target: DesktopEntryCache
        function onReadyChanged() { root._rebuild() }
        // …and again whenever the index is rebuilt, which is how a pinned icon
        // picks up a new icon theme without restarting the shell.
        function onRevisionChanged() { root._rebuild() }
    }

    // ── Icon resolution for dynamic (unpinned) windows ───────────
    function resolveIcon(w) {
        const cls  = w.class        ?? ""
        const icls = w.initialClass ?? cls

        // 0. A class this desktop has an opinion about — Dolphin's icon for
        // Nautilus, and Papirus's zen-browser for zen. The table lives in
        // IconResolver; the switcher has always read it and the dock never did,
        // which is why an unpinned window could draw a different icon from the
        // pinned entry for the same app.
        const alias = IconResolver.aliasFor(cls)
        if (alias !== "") return DesktopEntryCache.resolveIconPath(alias)

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
    readonly property real pillWidth:  root.rowWidth + dockPadH * 2
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
    // A plain Item, not a Row: cells are placed by an animated x so a reorder
    // can slide. implicitWidth reproduces what the Row reported (its own
    // left/right padding included), because pillWidth is built from it.
    Item {
        id: iconRow
        anchors.bottom:           parent.bottom
        anchors.bottomMargin:     root.floatMargin
        anchors.horizontalCenter: parent.horizontalCenter

        implicitWidth:  root.rowWidth
        implicitHeight: root.maxIconSize + 24

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
                isPinned:    modelData.isPinned

                baseSize:   root.baseIconSize
                maxSize:    root.maxIconSize
                magnRadius: root.magnRadius
                // Frozen while carrying an icon — a cell that grows under the
                // pointer mid-drag fights the drag for the same pixels.
                dockHoverX:  root.dragActive ? -1 : root.hoverX

                targetX:  root.cellX[index] ?? 0
                armed:    root._armedKey === modelData.key
                dragging: root._dragKey  === modelData.key
                dragX:    root._dragX

                onPinToggleRequested: root.togglePin(modelData.key)
                onArmRequested:       root.armSlot(modelData.key)
                onArmCancelled:       root._armedKey = ""
                onDragStartRequested: root.beginDrag(modelData.key, index)
                onDragMoved:          rowX => root.updateDrag(rowX)
                onDragFinished:       committed => root.endDrag(committed)
            }
        }
    }

    // Sits above the pill, inside the panel window's 130px height (the pill
    // itself only occupies the bottom ~68 of that) and outside the input mask,
    // so it is never in the way of a click.
    Rectangle {
        id: pinToast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom:           pill.top
        anchors.bottomMargin:     8

        width:  toastLabel.implicitWidth  + 26
        height: toastLabel.implicitHeight + 12
        radius: height / 2

        color:        pill.color
        border.color: pill.border.color
        border.width: 1

        opacity: 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        Text {
            id: toastLabel
            anchors.centerIn: parent
            text:            root._toastText
            color:           WalColors.foreground
            font.family:     UiConfig.fontFamily
            font.pixelSize:  13
        }

        Timer {
            id: toastTimer
            interval: 1600
            repeat:   false
            onTriggered: pinToast.opacity = 0
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
