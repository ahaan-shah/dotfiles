pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

// The settings menu.
//
// ── What changed, and why ─────────────────────────────────────────────────
// The first version of this was a literal copy of the taskbar's dropdown
// chrome: a 1.5px outline around every row, a fill on every row, a subtitle
// under most of them. That is right for a panel that hangs off a bar icon — it
// is dense because it is a glance — and wrong here, because it made a list of
// eight things read as a spreadsheet.
//
// The rule now: one drawn edge around the card, and nothing around a row
// EXCEPT the selected one. That last clause is a revision of what this comment
// used to say, and the distinction it turns on is worth keeping: an outline on
// EVERY row is what made eight items read as a spreadsheet, and an outline on
// exactly ONE row is the opposite — it is the cursor. It replaces the short
// accent bar that used to sit on the leading edge, which said the same thing
// in a corner of the row instead of around it. State that used to be a
// subtitle — which value is currently in effect — is a single accent check on
// the right, so it never competes with the selection for the same pixels.
//
// Rows are also one height per page rather than one height per row: a row with
// a subtitle is 58 and one without is 44, and a page mixing the two (the root
// menu, where Update and About carry no subtitle) looked like a list with
// pieces missing. The page takes the taller measure if ANY of its rows needs
// it — see rowH. Listing pages, where no row has a subtitle, stay dense.
//
// Everything else is spacing: a borderless search line under a hairline, and
// generous card padding. The palette is unchanged; the tokens live in
// Theme.qml so this, the password box and the fingerprint box cannot drift.
//
// ── Still no geometry animation ──────────────────────────────────────────
// finder's box animates its width and height, so it re-animated on every
// keystroke. Frames on this machine alternate 8ms/16ms (see the risks section
// of the system map), and an animation at that cadence is what "choppy" looks
// like. Fixed width, height bound straight to the layout, no Behavior.
Rectangle {
    id: panel

    property bool shown: false
    signal requestClose()

    // ── navigation state ──────────────────────────────────────────────────
    property string pageKey: ""
    property string query: ""
    property int sel: 0

    readonly property bool searching: panel.query.trim().length > 0
    readonly property var rows: panel.searching ? Settings.search(panel.pageKey, panel.query)
                                                : Settings.rowsFor(panel.pageKey)
    readonly property var crumbParts: Settings.crumb(panel.pageKey)

    // One height for every row on the page, taken from the tallest kind the
    // page actually contains. Height per ROW made the root menu ragged, because
    // Update and About have nothing to say under their labels and every other
    // row does; height per PAGE keeps a listing of 276 font families dense
    // while making a mixed menu read as one block.
    readonly property int rowH: panel.rows.some(r => (r.sub || "") !== "")
                                ? Theme.rowTall : Theme.rowHeight

    // Set for the one frame in which the page changes, and it suppresses the
    // highlight's travel for exactly that frame.
    //
    // Ordering sel before pageKey (see enter) stops the NEW page rendering with
    // the OLD index, but on its own it still leaves motion: assigning sel starts
    // the highlight gliding from the row you were on up to row 0, and the model
    // swaps underneath it while it is still travelling. Arriving at a page is
    // not navigation within one — it should already be at the top, not be seen
    // getting there — so a page change is the one case that does not animate.
    property bool jumping: false
    Timer { id: jumpClear; interval: 40; onTriggered: panel.jumping = false }

    // Which way the selection last moved, +1 down and -1 up. The band's two
    // edges swap roles on it — see the highlight — so it has to be set BEFORE
    // sel, or the first frame of the stretch leans the wrong way.
    property int dir: 1

    // ── editing a value row ───────────────────────────────────────────────
    // The id of the row whose box has the keyboard, or "". Only the Window
    // rules page has these; everywhere else it stays empty and nothing below
    // costs anything.
    //
    // It has to be panel state rather than delegate state because the SEARCH
    // FIELD owns the keyboard for this whole panel — every key for the list
    // goes through its Keys handler. Handing focus to a box inside a row is
    // therefore a mode, and the panel is what knows it is in one: while a box
    // has focus, Up and Down are the box's (they do nothing), and Escape means
    // "stop editing" rather than "close the settings menu".
    property string editingKey: ""

    // ── the notice under the list ─────────────────────────────────────────
    // Two kinds, one banner. A REFUSAL is a thing that did not happen and it is
    // red; a WARNING is a thing that did happen and cost something else, and it
    // is amber. Wearing the same colour would make "your bind was taken" look
    // like a failure, which is the opposite of what it is.
    readonly property string notice: Settings.kbWarn !== "" ? Settings.kbWarn
                                   : Settings.kbError !== "" ? Settings.kbError
                                   : Settings.winError
    readonly property bool noticeIsWarning: Settings.kbWarn !== ""

    // Held after the live value clears so the banner has something to say while
    // it fades out — binding the text straight to the source blanks the words
    // on frame one of the fade and animates an empty box away.
    property string lastNotice: ""
    property bool lastNoticeWarn: false
    onNoticeChanged: {
        if (panel.notice === "") return
        panel.lastNotice = panel.notice
        panel.lastNoticeWarn = panel.noticeIsWarning
    }

    function beginEdit(id) { panel.editingKey = id }

    // Handed up to Finder, which owns the capture box — it has to sit ABOVE
    // this card and take the keyboard off it, and a child of the thing it
    // covers cannot do either cleanly.
    signal requestRebind(string declared, string label, string inForce)

    function beginRebind(i) {
        const r = panel.rows[i]
        if (!r || r.kind !== "keybind") return
        // The DECLARED combo is r.id; r.value is whatever is in force.
        panel.requestRebind(r.id, r.title, r.value || "")
    }
    function endEdit() {
        panel.editingKey = ""
        searchInput.forceActiveFocus()
    }
    function commitValue(id, text) {
        list.rememberScroll()
        panel.endEdit()
        Settings.setWindowRule(id, String(text).trim())
    }
    // The steppers. Rounded to three places because 0.85 + 0.05 is
    // 0.8999999999999999 in IEEE754 and the box would show it.
    function bumpValue(r, direction) {
        const step = parseFloat(r.step) || 1
        const lo = parseFloat(r.min), hi = parseFloat(r.max)
        // From the REQUESTED value. Counting from the model meant a second
        // press that arrived before the listing had caught up computed the
        // step it had just taken, and asked for a number it was already on —
        // which the guard below then dropped. Three presses moved by two.
        let v = (parseFloat(r.value) || 0) + direction * step
        if (!isNaN(lo)) v = Math.max(lo, v)
        if (!isNaN(hi)) v = Math.min(hi, v)
        v = Math.round(v * 1000) / 1000
        if (String(v) === String(r.value)) return      // already at the end of the range
        list.rememberScroll()
        Settings.setWindowRule(r.id, String(v))
    }

    // ── the page transition ───────────────────────────────────────────────
    // `slide` is the whole thing: the list is translated by it and its opacity
    // is derived from it, so one animator drives both. Set to ±18 at the moment
    // the page changes and animated back to zero, which reads as the new page
    // arriving from the side you are travelling towards — right when you
    // descend into a submenu, left when you come back out.
    //
    // 18px and not more because the card's padding is 20: the translate happens
    // inside a card that does not clip, so a larger offset would put the list
    // over the rounded corner for a few frames.
    property real slide: 0
    readonly property real slideOpacity: 1 - Math.min(1, Math.abs(panel.slide) / 18) * 0.7
    NumberAnimation {
        id: slideIn
        target: panel; property: "slide"; to: 0
        duration: Theme.motionPage; easing.type: Easing.OutCubic
    }
    Timer { id: slideStart; interval: 16; onTriggered: panel.releaseHold() }

    // The card's own width and height animate ONLY across a page change. This
    // is the exception to the no-geometry-animation rule at the top of this
    // file, and it is narrow on purpose: that rule exists because finder's box
    // re-animated its size on every KEYSTROKE, and search still changes the row
    // count per keystroke. Gating on this flag keeps the box rigid while typing
    // and lets it grow into the next page when you enter one.
    property bool pageAnim: false
    Timer {
        id: pageAnimClear
        interval: Theme.motionPage + 40
        onTriggered: { panel.pageAnim = false; panel.heldW = 0; panel.heldH = 0 }
    }

    // The card's size across the frame in which the page changes. Zero means
    // "not holding", which is why nothing here can legitimately be 0.
    //
    // This is what makes the resize smooth, and the reason it was not is that
    // the card was animating towards a target that had not finished moving.
    // Swapping the model rebuilds every delegate, and contentHeight — which is
    // what the card's height is ultimately summed from — only reaches its final
    // value once they exist. Starting the animation in that same frame aimed it
    // at an intermediate number and then re-aimed it, which is the choppiness:
    // not a slow animation, a moving goalpost. Holding the old size for that one
    // frame means the animation starts from a known size, towards a settled one,
    // on the same frame the slide starts.
    property real heldW: 0
    property real heldH: 0

    function jumpTo(key, into) {
        // Leaving the page takes the keyboard back, or the search field on the
        // NEXT page comes up dead while a box that no longer exists holds focus.
        panel.editingKey = ""
        // A new page starts at the top; the position being kept above is only
        // meant to survive a rebuild of the SAME list.
        list.savedContentY = 0
        // And a refusal is about a box on the page being left.
        Settings.winError = ""
        Settings.kbError = ""
        Settings.kbWarn = ""
        // Captured BEFORE anything else, while they still describe the page
        // being left.
        panel.heldW = panel.width
        panel.heldH = panel.implicitHeight
        panel.jumping = true
        // Off until releaseHold, so the pin itself cannot animate.
        panel.pageAnim = false
        panel.sel = 0
        panel.query = ""
        searchInput.text = ""
        panel.pageKey = key

        // The offset is applied NOW and the animation starts on the NEXT frame,
        // deliberately. Assigning pageKey swaps the model, which destroys every
        // delegate on the old page and builds every delegate on the new one —
        // one genuinely expensive frame. Starting the animation in that same
        // frame means its first step is the one that gets stretched, and a
        // stutter at the start of a movement is the part the eye actually
        // catches. So the heavy frame renders the new page already offset and
        // faded, and the travel begins after it.
        panel.slide = into ? 18 : -18
        slideStart.restart()
        jumpClear.restart()
        pageAnimClear.restart()
    }

    // One frame later: the new page's delegates exist, so col.implicitHeight is
    // final. Release the hold and let both Behaviors run to it.
    function releaseHold() {
        panel.pageAnim = true
        panel.heldW = 0
        panel.heldH = 0
        slideIn.restart()
    }

    function reset() {
        panel.pageKey = ""
        panel.query = ""
        panel.sel = 0
        searchInput.text = ""
    }

    function focusInput() { searchInput.forceActiveFocus() }

    function enter(row) {
        // A search hit carries the page it lives on. Descending into it has to
        // start from THERE — building the key from the page the search was
        // typed on would aim at a page that does not exist.
        const base = (row.pageKey !== undefined) ? row.pageKey : panel.pageKey

        // jumpTo assigns sel BEFORE pageKey, and that order is half the fix:
        // `rows` is bound to pageKey, so assigning pageKey swaps the model on
        // the spot while sel still holds the index of the row selected on the
        // page you just left. Entering Remove from row 1 therefore rendered
        // Remove with ITS row 1 (Web App) selected, and only the next statement
        // moved it to 0 — one frame late. Setup was the same thing from row 3,
        // Defaults sliding up to Monitors. The other half is `jumping`.
        panel.jumpTo((base === "") ? row.id : base + "/" + row.id, true)
        Settings.ensure(panel.pageKey)
    }

    function back() {
        // Clearing a search is a step of its own: it is what the user did last,
        // so it is what going back should undo.
        if (panel.searching) { searchInput.text = ""; panel.sel = 0; return }
        if (panel.pageKey === "") { panel.requestClose(); return }
        const cut = panel.pageKey.lastIndexOf("/")
        // Through jumpTo for the same reason as enter().
        panel.jumpTo((cut < 0) ? "" : panel.pageKey.substring(0, cut), false)
    }

    function activate(i) {
        const r = panel.rows[i]
        if (!r) return
        if (r.kind === "menu") { panel.enter(r); return }
        if (r.kind === "value") { panel.beginEdit(r.id); return }
        if (r.kind === "keybind") { panel.beginRebind(i); return }
        // Everything past here can change the listing under the view — a
        // toggle, a choice moving its "current" mark — and all of it patches
        // the model in place, which resets the scroll.
        list.rememberScroll()
        // A search hit carries the page it came from, so it runs exactly what it
        // would have run had the user walked there by hand.
        if (Settings.activate(r.pageKey !== undefined ? r.pageKey : panel.pageKey, r))
            panel.requestClose()
    }

    function move(d) {
        if (panel.rows.length === 0) return
        // No positionViewAtIndex: highlightRangeMode scrolls the view itself,
        // with easing. Calling it here as well jumped the content out from under
        // that animation on the step that crossed the viewport edge.
        panel.dir = d
        panel.sel = Math.max(0, Math.min(panel.rows.length - 1, panel.sel + d))
    }

    onRowsChanged: if (panel.sel >= panel.rows.length) panel.sel = Math.max(0, panel.rows.length - 1)

    // ── a stepper ─────────────────────────────────────────────────────────
    // Its slot is always laid out; `shown` only fades the button itself. See
    // the value row for why.
    component StepButton: Rectangle {
        id: sb
        property string glyph: "+"
        property bool shown: false
        signal tapped()

        width: 24; height: 24; radius: 8
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        color: sbHover.hovered && sb.enabled ? Theme.alpha(Theme.text, 0.14)
                                             : Theme.alpha(Theme.text, 0.06)
        // Disabled means "the range ends here", and it dims rather than
        // vanishing: a + that disappears at the maximum reads as a glitch,
        // where a dim one reads as a limit.
        opacity: sb.shown ? (sb.enabled ? 1 : 0.3) : 0
        Behavior on opacity { NumberAnimation { duration: Theme.motion } }
        Behavior on color   { ColorAnimation  { duration: Theme.motion } }

        Text {
            anchors.centerIn: parent
            text: sb.glyph
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 15
        }

        HoverHandler { id: sbHover }
        MouseArea {
            anchors.fill: parent
            enabled: sb.shown && sb.enabled
            onClicked: sb.tapped()
        }
    }

    // ── the switch ────────────────────────────────────────────────────────
    component ThemedToggle: Rectangle {
        id: tog
        property bool checked: false
        property bool pending: false
        signal toggled(bool value)

        implicitWidth: 40
        implicitHeight: 22
        radius: height / 2
        color: tog.checked ? Theme.accent : Theme.alpha(Theme.col7, 0.16)
        // Dimmed until whatever owns the state has actually answered — the
        // firewall's own status read, today. A switch showing a confident "off"
        // it does not yet know is worse than one that shows it does not know.
        opacity: tog.pending ? 0.4 : 1
        Behavior on color { ColorAnimation { duration: 160 } }

        Rectangle {
            width: 16; height: 16; radius: 8
            y: 3
            x: tog.checked ? tog.width - width - 3 : 3
            color: tog.checked ? Theme.contrast(Theme.accent) : Theme.alpha(Theme.text, 0.75)
            Behavior on x { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 160 } }
        }
        MouseArea { anchors.fill: parent; onClicked: tog.toggled(!tog.checked) }
    }

    // ── card ──────────────────────────────────────────────────────────────
    // Per page: the keybindings listing carries a description as well as a
    // combo and is unreadable at the default width. Changed only on navigation,
    // never per keystroke, so it is not the kind of geometry change that made
    // the old box feel choppy.
    // Pinned to the OUTGOING size while heldW/heldH are set, which is for
    // exactly one frame — see jumpTo. Then they go to zero, these fall back to
    // the real bindings, and the Behaviors animate the difference.
    width:          panel.heldW > 0 ? panel.heldW : Settings.pageWidth(panel.pageKey)
    implicitHeight: panel.heldH > 0 ? panel.heldH : col.implicitHeight + Theme.pad * 2
    // Same duration and same easing as the list's slide, and now started on the
    // same frame as it, so the card resizing and the content arriving are one
    // movement rather than two that overlap.
    Behavior on width {
        enabled: panel.pageAnim
        NumberAnimation { duration: Theme.motionPage; easing.type: Easing.OutCubic }
    }
    Behavior on implicitHeight {
        enabled: panel.pageAnim
        NumberAnimation { duration: Theme.motionPage; easing.type: Easing.OutCubic }
    }
    radius: Theme.cardRadius
    color: Theme.bg
    border.width: Theme.cardBorder
    border.color: Theme.line

    opacity: panel.shown ? 1 : 0
    scale:   panel.shown ? 1 : 0.97
    visible: opacity > 0.001
    Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
    Behavior on scale   { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

    MouseArea { anchors.fill: parent }   // swallow clicks; the scrim is behind

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: Theme.pad
        spacing: 0

        // ── header ────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 14
            spacing: 10

            Text {
                text: Settings.pageIcon(panel.pageKey)
                color: Theme.alpha(Theme.text, 0.8)
                font.family: Theme.font
                font.pixelSize: 18
            }
            Text {
                text: Settings.pageTitle(panel.pageKey)
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: Theme.fsTitle
                font.weight: Font.Medium
            }
            Item { Layout.fillWidth: true }
            // Where you are, only when that is not already obvious from the
            // title. At the root the title says "Settings" and a crumb
            // repeating it is exactly the redundancy this pass removed.
            Text {
                visible: panel.crumbParts.length > 1
                text: panel.crumbParts.slice(0, -1).join("  ›  ")
                color: Theme.dimmer
                font.family: Theme.font
                font.pixelSize: Theme.fsSub
                elide: Text.ElideLeft
                Layout.maximumWidth: 170
            }
        }

        // ── search: a line, not a box ─────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: "󰍉"
                color: searchInput.text.length > 0 ? Theme.alpha(Theme.text, 0.7) : Theme.dimmer
                font.family: Theme.font
                font.pixelSize: 15
            }
            TextInput {
                id: searchInput
                Layout.fillWidth: true
                Layout.preferredHeight: 26
                verticalAlignment: TextInput.AlignVCenter
                font.family: Theme.font
                font.pixelSize: Theme.fsInput
                color: Theme.text
                clip: true
                selectionColor: Theme.alpha(Theme.accent, 0.45)
                onTextChanged: {
                    panel.query = text
                    panel.sel = 0
                    // Same reasoning as a page change: a different set of rows
                    // is a different list, and it starts at the top.
                    list.savedContentY = 0
                }

                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: searchInput.text.length === 0
                    text: panel.pageKey === "" ? "Search settings…"
                                               : "Search " + Settings.pageTitle(panel.pageKey).toLowerCase() + "…"
                    color: Theme.dimmer
                    font: searchInput.font
                }

                // Every key for the panel is handled here, in one place. The
                // Keys attached property defaults to Keys.BeforeItem, so this
                // sees them before the text field does; each is guarded so it
                // only takes a key the cursor has nothing left to do with. And
                // Return is handled here rather than via onAccepted so that
                // there is exactly ONE Return handler — finder had two, and
                // every Return fired twice.
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Down) {
                        panel.move(1); event.accepted = true
                    } else if (event.key === Qt.Key_Up) {
                        panel.move(-1); event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        panel.activate(panel.sel); event.accepted = true
                    } else if (event.key === Qt.Key_Escape) {
                        // Closes outright, at any depth. Left already walks back
                        // up, so Escape doing it too meant getting out of a
                        // nested page took as many presses as it took to get in.
                        panel.requestClose(); event.accepted = true
                    } else if (event.key === Qt.Key_Left && searchInput.cursorPosition === 0) {
                        panel.back(); event.accepted = true
                    } else if (event.key === Qt.Key_Backspace && searchInput.text.length === 0) {
                        panel.back(); event.accepted = true
                    } else if ((event.key === Qt.Key_Minus || event.key === Qt.Key_Plus
                                || event.key === Qt.Key_Equal)
                               && panel.editingKey === ""
                               && panel.rows[panel.sel]
                               && panel.rows[panel.sel].kind === "value") {
                        // The keys as well as the buttons. This page is driven
                        // from the keyboard like every other one here, and
                        // reaching for the pointer to nudge a number by one is
                        // the thing the steppers were meant to save.
                        //
                        // Equal is the unshifted key that carries +, so it
                        // steps up too — otherwise "+" needs Shift on this
                        // layout and only the shifted form would work.
                        // Accepted either way, so neither ever reaches the
                        // search field as a character.
                        panel.bumpValue(panel.rows[panel.sel],
                                        event.key === Qt.Key_Minus ? -1 : 1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_E
                               && (event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))
                               && panel.pageKey === "setup/keybindings") {
                        panel.beginRebind(panel.sel)
                        event.accepted = true
                    } else if (event.key === Qt.Key_R
                               && (event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))
                               && panel.pageKey === "setup/keybindings") {
                        // Back to what hyprland.lua declares, for this bind only.
                        const r = panel.rows[panel.sel]
                        if (r && r.kind === "keybind") {
                            list.rememberScroll()
                            Settings.resetKeybind(r.id)
                        }
                        event.accepted = true
                    } else if (event.key === Qt.Key_R
                               && (event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))
                               && panel.pageKey === "setup/windowrules") {
                        // Everything back to what hyprland.lua hardcodes. The
                        // one escape hatch the page needs: a rule set to
                        // something unusable — opacity 0.1, animations off —
                        // is still reachable by keyboard, but finding it again
                        // in a list of thirteen is not the moment for that.
                        Settings.resetWindowRules()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Right && searchInput.cursorPosition === searchInput.text.length) {
                        const r = panel.rows[panel.sel]
                        if (r && r.kind === "menu") { panel.enter(r); event.accepted = true }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 12
            Layout.bottomMargin: 8
            implicitHeight: 1
            color: Theme.hairline
        }

        // ── rows ──────────────────────────────────────────────────────────
        ListView {
            id: list
            Layout.fillWidth: true
            // Capped and scrolled rather than grown: a 276-family font list
            // would otherwise make a card taller than the screen.
            Layout.preferredHeight: Math.min(contentHeight, 460)
            visible: panel.rows.length > 0

            // Clipped ONLY when there is something to clip, and this is the
            // balanced-profile fix. A clipped item that is also translated and
            // also below full opacity cannot be drawn with a scissor rect: Qt
            // renders that subtree to an offscreen texture instead, every frame,
            // and allocating and blitting one of those at 430x460 is exactly the
            // work a downclocked GPU has no headroom for. It ran fine on the
            // performance profile, which is what made it look like a rendering
            // problem rather than a budget one.
            //
            // Every page you actually descend into — Install, Remove, Setup,
            // Security, Theme — is shorter than the cap, so on those the clip is
            // a no-op that was costing a render target purely to exist. The long
            // listings still clip, because there it is load-bearing.
            clip: list.contentHeight > list.height + 0.5

            // The page transition, driven entirely by panel.slide. A transform
            // rather than an x: this is a ColumnLayout child, and the layout
            // owns x.
            transform: Translate { x: panel.slide }
            opacity: panel.slideOpacity
            spacing: 2
            model: panel.rows
            currentIndex: panel.sel
            boundsBehavior: Flickable.StopAtBounds

            // ── keep the scroll position across a model rebuild ────────────
            // Changing one row means reassigning the model, which resets the
            // view to the top — and then highlightRangeMode scrolls the least
            // it can to bring the current row back into the viewport, which
            // parks it against the BOTTOM edge. So toggling a rule you had
            // scrolled to the middle threw the list down to it.
            //
            // The position is remembered continuously and put back after the
            // rebuild. `restoringY` is what stops the transient 0 the reset
            // writes from being remembered as the place to go back to.
            //
            // Clamped on restore because the new content may be shorter than
            // the old — a search narrowing the list, say — and a contentY past
            // the end leaves the view blank below the last row.
            property real savedContentY: 0
            property bool restoringY: false

            // Snapshotted by the caller, BEFORE it changes anything — see
            // rememberScroll. Tracking contentY reactively and reading it in
            // onModelChanged does not work, and the order is the reason.
            // Instrumented, on a list scrolled to 261.8:
            //
            //     contentY -> 261.8      where it was
            //     contentY -> 0.0        the reset
            //     contentY -> 138.0      highlightRangeMode scrolling back
            //     modelChanged           ...only now
            //
            // Both the reset and the re-scroll land before the signal, so by
            // the time a handler on it runs there is nothing left to restore —
            // the "saved" value has already been overwritten twice, and the
            // second time by the very scroll that has to be undone.
            function rememberScroll() {
                list.savedContentY = list.contentY
                list.restoringY = true
            }
            onContentYChanged: if (!list.restoringY) list.savedContentY = list.contentY
            onModelChanged: {
                if (!list.restoringY) return
                const max = Math.max(0, list.contentHeight - list.height)
                list.contentY = Math.max(0, Math.min(list.savedContentY, max))
                list.restoringY = false
            }

            // The selection is ONE item that moves, not a fill that switches on
            // in one delegate and off in another. Painting it per-delegate meant
            // every step was a cross-fade between two rows a whole row apart,
            // which reads as a blink rather than as movement — the eye gets no
            // path between where the selection was and where it went.
            //
            // But ListView is NOT allowed to place it: highlightFollowsCurrentItem
            // moves a fixed-size rectangle from A to B, which is the plain slide
            // this is replacing. The band positions its own two edges instead —
            // see below — so ListView only decides which row is current.
            highlightFollowsCurrentItem: false
            highlightRangeMode: ListView.ApplyRange
            // The range is the whole viewport, so this behaves like the
            // positionViewAtIndex(Contain) it replaces — except ApplyRange
            // scrolls the view with the same easing the highlight moves under,
            // where positionViewAtIndex jumped the content instantly.
            preferredHighlightBegin: 0
            preferredHighlightEnd: list.height

            // The band. It is defined by a TOP EDGE and a BOTTOM EDGE that
            // chase the current row at two different speeds, rather than by a
            // position and a fixed height:
            //
            //   moving down   bottom edge leaves on motion, top edge on
            //                 motionLag  ->  the band reaches ahead, then the
            //                 back of it is pulled along after
            //   moving up     the roles swap
            //
            // So it stretches into the step and settles out of it, and the two
            // rows involved are briefly connected by the thing travelling
            // between them. A rectangle that only slides covers the same
            // distance in the same time and shows none of that.
            //
            // Both Behaviors are off while `jumping`, because a page change is
            // not a step: there is nothing to travel between, and stretching
            // across a list that has just been replaced would draw a band
            // between two rows that were never both on screen.
            highlight: Rectangle {
                id: band
                z: 0
                width: list.width

                // COMPUTED FROM THE INDEX, never read off the current delegate.
                //
                // Reassigning a ListView's model resets it, and a rebuilt
                // delegate EXISTS before it has been positioned — currentItem
                // is non-null and its y is still 0. So a guard on
                // `currentItem !== null` does not help: the band read that 0 as
                // a real position, travelled to the top of the list and back,
                // and a previous attempt that cached the last good value cached
                // the 0 as well. The selection itself never moved, which is why
                // the next arrow key carried on from the right row and sent the
                // band all the way there again.
                //
                // Every row on a page is the same height (see panel.rowH), so
                // row i sits at i * (rowH + spacing) in content coordinates —
                // which is the space the highlight is placed in. That is exact,
                // it is available before any delegate exists, and it cannot be
                // disturbed by the model being rebuilt underneath it.
                readonly property real rowPitch: panel.rowH + list.spacing
                readonly property real tgtTop: panel.sel * band.rowPitch
                readonly property real tgtBot: band.tgtTop + panel.rowH

                readonly property bool down: panel.dir >= 0

                property real edgeTop: band.tgtTop
                property real edgeBot: band.tgtBot
                Behavior on edgeTop {
                    enabled: !panel.jumping
                    NumberAnimation {
                        duration: band.down ? Theme.motionLag : Theme.motion
                        easing.type: Easing.OutCubic
                    }
                }
                Behavior on edgeBot {
                    enabled: !panel.jumping
                    NumberAnimation {
                        duration: band.down ? Theme.motion : Theme.motionLag
                        easing.type: Easing.OutCubic
                    }
                }

                y: band.edgeTop
                height: Math.max(0, band.edgeBot - band.edgeTop)

                radius: Theme.rowRadius
                color: Theme.rowSel
                border.width: Theme.rowBorder
                border.color: Theme.rowSelLine
            }

            delegate: Item {
                id: row
                required property var modelData
                required property int index

                readonly property bool isSel:  row.index === panel.sel
                readonly property bool isOn:   row.modelData.active === true
                readonly property bool nests:  row.modelData.kind === "menu"
                readonly property bool hasSub: (row.modelData.sub || "") !== ""

                width: list.width
                height: panel.rowH

                // DECLARED FIRST, so it sits UNDERNEATH everything else in the
                // row and receives only the clicks nothing above it accepted.
                // Last — which is where it was — put it on top of the whole
                // delegate, and the steppers and the value box never saw a
                // click at all: a MouseArea filling the row swallows them. The
                // labels accept nothing, so clicking the text still lands here
                // and still selects the row.
                MouseArea {
                    anchors.fill: parent
                    // The switch has its own MouseArea; letting this one sit on
                    // top would make the whole row a toggle and fire it twice.
                    enabled: row.modelData.kind !== "toggle"
                    onClicked: {
                        // A click is a step too, and the band leans on panel.dir
                        // — without this every click stretched downward.
                        panel.dir = row.index >= panel.sel ? 1 : -1
                        panel.sel = row.index
                        panel.activate(row.index)
                    }
                }

                // Hover only. The selected row's fill and outline are the
                // ListView's travelling highlight, above — a hovered row still
                // gets fill alone, because an outline on hover would read as a
                // second selection.
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.rowRadius
                    color: rowHover.hovered && !row.isSel ? Theme.rowHover : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.motion } }
                }

                HoverHandler { id: rowHover }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    spacing: 12

                    Item {
                        Layout.preferredWidth: Theme.iconSlot
                        Layout.preferredHeight: Theme.iconSlot
                        Text {
                            anchors.centerIn: parent
                            text: row.modelData.icon || ""
                            // Dimmer than the label: the icon locates the row,
                            // the label is what is being read.
                            color: row.isSel ? Theme.text : Theme.alpha(Theme.text, 0.65)
                            // Theme.motion, like everything else the selection
                            // does: the icon coming up to full strength is part
                            // of the same movement, and a hard switch under a
                            // gliding highlight is the snap the glide was meant
                            // to remove.
                            Behavior on color { ColorAnimation { duration: Theme.motion } }
                            font.family: Theme.font
                            font.pixelSize: 17
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: row.modelData.title
                            color: Theme.text
                            // The Fonts page sets `font` per row, so each family
                            // name is drawn in the family it names — the list is
                            // the preview. A shade larger there, because judging
                            // a typeface at 14px is judging a smudge.
                            font.family: row.modelData.font ? row.modelData.font : Theme.font
                            font.pixelSize: row.modelData.font ? Theme.fsRow + 2 : Theme.fsRow
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: row.hasSub
                            elide: Text.ElideRight
                            text: row.modelData.sub || ""
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: Theme.fsSub
                        }
                    }

                    // Where a search hit lives. Not a subtitle — a right-aligned
                    // path reads as location rather than as description, and it
                    // keeps the no-redundant-subtext rule intact.
                    Text {
                        visible: (row.modelData.trail || "") !== ""
                        text: row.modelData.trail || ""
                        color: Theme.dimmer
                        font.family: Theme.font
                        font.pixelSize: Theme.fsSub
                        elide: Text.ElideLeft
                        Layout.maximumWidth: 130
                    }

                    // ── a value row: two steppers, a box, and its unit ──────
                    // Behind a Loader, not merely `visible: false`. A row on
                    // any OTHER settings page has no value to show, and an
                    // invisible Row plus two StepButtons plus a box and a unit
                    // is five items per row that still get built, laid out and
                    // kept alive — on a listing of 276 font families that is
                    // real memory for something that can never be seen. The
                    // Loader builds them only on the page that has them.
                    Loader {
                        active: row.modelData.kind === "value"
                        visible: active
                        Layout.alignment: Qt.AlignVCenter
                        sourceComponent: Component {
                        // ── a value row: two steppers, a box, and its unit ──────
                        // Laid out for EVERY row on the page whether or not it is
                        // the selected one, and the steppers only fade in — same
                        // reserved-slot rule as the tick below, and the same reason.
                        // A control that appears on the selected row and takes space
                        // when it does would shove that row's label sideways the
                        // moment the selection landed on it.
                        Row {
                            spacing: 4

                            // Steppers, because eleven of the thirteen rules are a
                            // small integer and nobody wants to type "3" to find out
                            // what 3 looks like. The box is still there for the
                            // cases where you know the number you want.
                            StepButton {
                                glyph: "−"
                                shown: row.isSel || rowHover.hovered
                                enabled: row.modelData.value !== row.modelData.min
                                onTapped: panel.bumpValue(row.modelData, -1)
                            }

                            Rectangle {
                                id: valueBox
                                width: 66
                                height: 30
                                radius: 9
                                anchors.verticalCenter: parent.verticalCenter

                                readonly property bool editing: panel.editingKey === row.modelData.id

                                color: valueBox.editing ? Theme.alpha(Theme.accent, 0.18)
                                       : row.isSel       ? Theme.alpha(Theme.text, 0.10)
                                                         : Theme.alpha(Theme.text, 0.055)
                                border.width: 1
                                border.color: valueBox.editing ? Theme.accent
                                            : row.isSel ? Theme.alpha(Theme.text, 0.22)
                                                        : "transparent"
                                Behavior on color { ColorAnimation { duration: Theme.motion } }
                                Behavior on border.color { ColorAnimation { duration: Theme.motion } }

                                TextInput {
                                    id: valueInput
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    horizontalAlignment: TextInput.AlignHCenter
                                    verticalAlignment: TextInput.AlignVCenter
                                    // Bound, and the binding is what restores the
                                    // box after an edit: committing refreshes the
                                    // listing, the model is reassigned, the delegate
                                    // is rebuilt and this reads the value the script
                                    // reported back. So a refused edit snaps to what
                                    // is actually in force without anything here
                                    // having to undo it.
                                    // `|| ""` because a delegate's bindings are
                                    // evaluated even when its Row is invisible, and
                                    // on every OTHER page in this menu a row has no
                                    // `value` at all — assigning undefined to a
                                    // QString warns on each one.
                                    // Straight off the model, which Settings
                                    // patches in place the instant a change is
                                    // asked for — so this is already the
                                    // instant-feedback path, with no second source
                                    // of truth and no function call per row per
                                    // frame.
                                    text: row.modelData.value || ""
                                    color: Theme.text
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fsRow
                                    selectByMouse: true
                                    selectionColor: Theme.alpha(Theme.accent, 0.45)
                                    // readOnly, NOT enabled:false. A disabled item
                                    // cannot take focus at all, and the binding
                                    // that would have re-enabled it is evaluated on
                                    // the same signal as the handler below — with
                                    // no guaranteed order between them, so
                                    // forceActiveFocus ran against an item that was
                                    // still disabled, failed silently, and left the
                                    // keystrokes going to the search field. readOnly
                                    // gates typing without gating focus.
                                    readOnly: !valueBox.editing

                                    Keys.onPressed: event => {
                                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                            const typed = valueInput.text
                                            // Re-establish the binding BEFORE the
                                            // commit. Typing broke it, and a
                                            // refused value would otherwise sit in
                                            // the box looking applied — the refusal
                                            // caption says no while the number says
                                            // yes. Restoring it snaps to the live
                                            // figure immediately, and the refresh
                                            // that follows an ACCEPTED value moves
                                            // it on to the new one.
                                            valueInput.text = Qt.binding(() => row.modelData.value || "")
                                            panel.commitValue(row.modelData.id, typed)
                                            event.accepted = true
                                        } else if (event.key === Qt.Key_Escape) {
                                            // Escape closes the whole thing, here as
                                            // everywhere else in finder. It used to
                                            // only back out of the box, which made
                                            // this the one place in the launcher
                                            // where Escape did not do what Escape
                                            // does. Nothing is lost: an edit is not
                                            // applied until Enter, so leaving IS the
                                            // cancel.
                                            panel.editingKey = ""
                                            panel.requestClose()
                                            event.accepted = true
                                        }
                                    }
                                }

                                // Focus follows the panel's mode rather than the
                                // other way round, so there is one owner of "which
                                // box has the keyboard" and clicking, Enter and
                                // leaving the page all go through it.
                                function grabIfEditing() {
                                    if (!valueBox.editing) return
                                    // callLater so every binding that depends on
                                    // editingKey — readOnly here, the box's own
                                    // colours — has settled before focus moves.
                                    Qt.callLater(function() {
                                        if (!valueBox.editing) return
                                        valueInput.forceActiveFocus()
                                        valueInput.selectAll()
                                    })
                                }
                                Connections {
                                    target: panel
                                    function onEditingKeyChanged() { valueBox.grabIfEditing() }
                                }
                                // And on creation, because patching a row reassigns
                                // the model and every delegate is rebuilt. Without
                                // this, clicking a stepper while a box was open
                                // destroyed the focused box and left the panel in
                                // editing mode with nothing holding the keyboard.
                                Component.onCompleted: valueBox.grabIfEditing()

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !valueBox.editing
                                    onClicked: {
                                        panel.dir = row.index >= panel.sel ? 1 : -1
                                        panel.sel = row.index
                                        panel.beginEdit(row.modelData.id)
                                    }
                                }
                            }

                            StepButton {
                                glyph: "+"
                                shown: row.isSel || rowHover.hovered
                                enabled: row.modelData.value !== row.modelData.max
                                onTapped: panel.bumpValue(row.modelData, 1)
                            }

                            // The unit sits outside the box rather than inside it,
                            // so every box on the page is the same width and the
                            // numbers line up in a column. Fixed width for the same
                            // reason — "px", "×" and "" must not move the box.
                            Item {
                                width: 20
                                height: 30
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: row.modelData.unit || ""
                                    color: Theme.dimmer
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fsSub
                                }
                            }
                        }
                        }
                    }

                    // ── a keybind row: the combo, on the right ─────────────
                    // Same shape as a window rule's value box and deliberately
                    // so — both are "here is the setting, and here is what it
                    // is". Read-only, because a combo is not something you type
                    // one character at a time; Enter opens the capture box.
                    Loader {
                        active: row.modelData.kind === "keybind"
                        visible: active
                        Layout.alignment: Qt.AlignVCenter
                        sourceComponent: Component {
                            Rectangle {
                                implicitWidth: Math.max(96, comboText.implicitWidth + 22)
                                implicitHeight: 30
                                radius: 9
                                // A reassigned bind is tinted rather than
                                // badged: it is the only state this row has, and
                                // a word saying "changed" beside a combo that is
                                // visibly not the default is the redundancy this
                                // menu keeps removing.
                                color: (row.modelData.value || "") === ""
                                           ? Theme.alpha(Theme.warn, 0.16)
                                       : row.modelData.rebound ? Theme.alpha(Theme.accent, 0.30)
                                       : row.isSel             ? Theme.alpha(Theme.text, 0.10)
                                                               : Theme.alpha(Theme.text, 0.055)
                                border.width: 1
                                border.color: (row.modelData.value || "") === ""
                                                  ? Theme.alpha(Theme.warn, 0.45)
                                              : row.modelData.rebound
                                                  ? Theme.alpha(Theme.accent, 0.55)
                                              : row.isSel ? Theme.alpha(Theme.text, 0.22) : "transparent"
                                Behavior on color { ColorAnimation { duration: Theme.motion } }

                                Text {
                                    id: comboText
                                    anchors.centerIn: parent
                                    // An empty combo is a bind whose key was
                                    // taken by something else. It says so
                                    // rather than showing an empty box, which
                                    // would read as the page having failed to
                                    // load that row.
                                    text: (row.modelData.value || "") !== ""
                                          ? row.modelData.value : "unassigned"
                                    color: (row.modelData.value || "") !== ""
                                           ? Theme.text : Theme.dimmer
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fsSub
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        panel.dir = row.index >= panel.sel ? 1 : -1
                                        panel.sel = row.index
                                        panel.beginRebind(row.index)
                                    }
                                }
                            }
                        }
                    }

                    // "This is the one in effect." A mark rather than a filled
                    // row: filling it fought with the selection highlight, so
                    // sitting on the current value made both illegible.
                    //
                    // The SLOT is always laid out, mark or no mark. A RowLayout
                    // drops a `visible: false` child entirely, so a tick
                    // appearing on one row pushed that row's text left while its
                    // neighbours stayed put — every trailing column jittered by
                    // one glyph. Reserving the space fixes the alignment for
                    // good; only the glyph inside it comes and goes.
                    Item {
                        Layout.preferredWidth: 15
                        Layout.preferredHeight: 15
                        Text {
                            anchors.centerIn: parent
                            visible: row.isOn && (row.modelData.kind === "choice"
                                                  || row.modelData.kind === "multi")
                            text: "󰄬"
                            color: Theme.accent
                            font.family: Theme.font
                            font.pixelSize: 15
                        }
                    }

                    ThemedToggle {
                        visible: row.modelData.kind === "toggle"
                        checked: row.isOn
                        pending: row.modelData.pending === true
                        onToggled: panel.activate(row.index)   // which remembers the scroll
                    }

                    // Reserved for the same reason as the tick slot above.
                    Item {
                        Layout.preferredWidth: 8
                        Layout.preferredHeight: 16
                        Text {
                            anchors.centerIn: parent
                            visible: row.nests
                            text: "›"
                            color: Theme.dimmer
                            font.family: Theme.font
                            font.pixelSize: 16
                        }
                    }
                }

            }
        }

        // What window-rules.sh said when it refused. A BANNER and not a toast,
        // for the same reason the battery panel's unenforced-cap warning is a
        // caption: it is about the box you are looking at, and it should be
        // gone the moment you type something it accepts. Cleared by the next
        // set and by leaving the page.
        //
        // A bare red line between the list and the footer read as an error the
        // window had failed to lay out rather than as a message — it sat in the
        // gap between two rules with nothing holding it. It is a surface now,
        // with the same radius and padding as everything else on this card.
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 12
            implicitHeight: errRow.implicitHeight + 18
            radius: Theme.rowRadius
            readonly property color tone: panel.lastNoticeWarn ? Theme.warn : Theme.danger
            color: Theme.alpha(tone, 0.12)
            border.width: 1
            border.color: Theme.alpha(tone, 0.35)
            Behavior on color { ColorAnimation { duration: Theme.motion } }
            Behavior on border.color { ColorAnimation { duration: Theme.motion } }

            visible: opacity > 0.01
            opacity: panel.notice !== "" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.motion } }

            RowLayout {
                id: errRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                spacing: 10

                Text {
                    text: "󰀦"
                    color: panel.lastNoticeWarn ? Theme.warn : Theme.danger
                    font.family: Theme.font
                    font.pixelSize: 15
                    Layout.alignment: Qt.AlignTop
                }
                Text {
                    Layout.fillWidth: true
                    text: panel.lastNotice
                    wrapMode: Text.WordWrap
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: Theme.fsSub
                }
            }
        }

        // Searching a page whose listing has not landed yet is the common case
        // for Fonts on the first open — say so rather than showing an empty box.
        Text {
            Layout.fillWidth: true
            Layout.topMargin: 10
            Layout.bottomMargin: 6
            visible: panel.rows.length === 0
            text: panel.searching ? "No matches" : "Loading…"
            horizontalAlignment: Text.AlignHCenter
            color: Theme.dimmer
            font.family: Theme.font
            font.pixelSize: Theme.fsSub
        }

        // ── footer ────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 10
            implicitHeight: 1
            color: Theme.hairline
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 10
            spacing: 16
            readonly property bool nested: panel.pageKey !== "" || panel.searching

            Text { text: "↑↓ navigate"; color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint }
            Text { color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint
                   text: panel.editingKey !== "" ? "↵ apply  ·  esc cancel"
                       : panel.pageKey === "setup/windowrules" ? "↵ edit" : "↵ select" }
            Text { text: "← back";      color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint
                   visible: parent.nested }
            Text { text: "− +  adjust"; color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint
                   visible: panel.pageKey === "setup/windowrules" && panel.editingKey === "" }
            Text { text: "⇧E reassign"; color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint
                   visible: panel.pageKey === "setup/keybindings" }
            Text { text: "⇧R restore"; color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint
                   visible: panel.pageKey === "setup/keybindings" }
            Text { text: "⇧R reset all"; color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint
                   visible: panel.pageKey === "setup/windowrules" }
            Item { Layout.fillWidth: true }
            Text { text: "esc close"
                   color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint }
        }
    }
}
