pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

// The settings menu.
//
// ── 2026-09-12: rebuilt against omarchy's menu ────────────────────────────
// Ahaan sent a screen recording of it and asked for this to match — "the
// snappyness and design … so clean … minimal and simple like the reminders
// thing". What it is now is the result of frame-stepping that recording rather
// than of reading a description of it; the two measurements are written down
// in Theme.qml, which is where the numbers they produced live.
//
// The whole card is now four things:
//
//   a search line        placeholder text and a caret, no icon, no box, no
//                        rule under it. It is also the breadcrumb: it reads
//                        "Search settings…" at the root and "Search setup…"
//                        inside Setup, which is what omarchy's prompt does
//                        when it changes from "Go…" to "Install…".
//   rows                 icon, label, and a › if the row goes somewhere. No
//                        second line under any of them.
//   one band             a 10% wash on the selected row. No outline, no
//                        accent, no travel.
//   the card's own edge  2px of alpha(col7, 0.8) at radius 20, which is the
//                        taskbar's, and the one thing Ahaan asked to leave
//                        exactly as it was.
//
// What was removed, all of it on Ahaan's instruction: the header (page icon,
// page title, breadcrumb), the subtitle under every menu row, and the footer
// of keybind hints. The keys the footer documented are listed where it used to
// be, at the bottom of this file, since nothing on screen says them now.
//
// ── No animation, anywhere in the navigation ─────────────────────────────
// This file used to be mostly animation, and mostly FIXES for animation: a
// selection band whose two edges moved at different speeds, a flag to suppress
// it across a page change, a page slide, a one-frame size pin so the card's
// resize did not aim at a contentHeight that was still settling, a gate so
// that resize did not fire per keystroke, and a morph between this card and
// the launcher box. Every one of those was a real fix for a real artefact, and
// every artefact was caused by the animation it fixed. omarchy has none of it:
// one frame without the menu, the next frame with it, complete. So this has
// none of it either, and the file went from 711 lines of code to 556 for it —
// counted with the comments stripped, because the comments grew.
//
// `Theme.motion` survives for things that are state rather than navigation —
// the switch's knob, the notice banner's fade. Nothing about where the
// selection is or which page is showing may use it.
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
    // No crumbParts any more. It fed the header's "where you are" text, and
    // the header is gone — see the card's layout. Settings.crumb still exists
    // and is still what pageTitle is built from.

    // One height for every row on the page, taken from the tallest kind the
    // page actually contains. Height per ROW made a mixed page ragged; height
    // per PAGE keeps a listing of 276 font families dense while making a menu
    // read as one block.
    //
    // Only rows that are NOT menus can ask for the taller measure now. A menu
    // row draws no subtitle at all after this pass (see the delegate), so a
    // page of nothing but menu rows — which is every page you navigate
    // THROUGH — is always the dense 44. The tall 58 survives for the two
    // listings that genuinely have a second line to draw: keybindings, where
    // the sub is what the bind does, and the font groups, where it is the
    // variant count.
    readonly property int rowH: panel.rows.some(r => r.kind !== "menu" && (r.sub || "") !== "")
                                ? Theme.rowTall : Theme.rowHeight

    // What used to live here: `jumping`, a flag set for the one frame of a page
    // change to suppress the selection band's travel, and `dir`, the direction
    // of the last step, which decided which of the band's two edges led and
    // which lagged. Both existed only to make a 180ms glide behave; nothing
    // glides now, so neither has anything to suppress or to lean.

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

    // ── the page transition, which no longer exists ───────────────────────
    // Deleted here, in full, and recorded because it was a lot of machinery and
    // someone will wonder whether it was removed by accident:
    //
    //   slide / slideOpacity / slideIn   the new page translated in by ±18px
    //                                    and faded up, one animator driving
    //                                    both, leaning the way you travelled
    //   heldW / heldH / slideStart       the card pinned to the OUTGOING size
    //                                    for exactly one frame, so the resize
    //                                    started from a known size towards a
    //                                    settled one — swapping the model
    //                                    rebuilds every delegate, and
    //                                    contentHeight is only final once they
    //                                    exist, so an animation begun in that
    //                                    frame aimed at a moving goalpost
    //   pageAnim / pageAnimClear         a gate so the card resized on a PAGE
    //                                    change but stayed rigid per keystroke
    //
    // Every one of those was a real fix for a real artefact, and every one of
    // the artefacts was caused by the animation it was fixing. Removing the
    // animation removes all four at once. A page change is now what it is in
    // omarchy: the next frame shows the next page.
    //
    // The card's width and height still CHANGE per page — Settings.pageWidth is
    // per page and the row count differs — they just change instantly, which
    // also settles the per-keystroke problem the gate existed for.

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
        // sel BEFORE pageKey, and the order is still load-bearing even with
        // nothing animating. `rows` is bound to pageKey, so assigning pageKey
        // swaps the model on the spot while sel still holds the index of the
        // row selected on the page being left — entering Remove from row 1
        // would render Remove with ITS row 1 selected for a frame. What used to
        // be the OTHER half of that fix, the `jumping` flag, is gone with the
        // animation it suppressed.
        panel.sel = 0
        panel.query = ""
        searchInput.text = ""
        panel.pageKey = key
    }

    // `into` is now unused — it chose which way the outgoing page slid. Kept in
    // the signature because both callers pass it and it is the one word at each
    // call site that says which direction the navigation goes; a reader of
    // enter()/back() should not have to work that out.

    // enterFrom() is gone. It pinned this card to the size of the launcher box
    // it was replacing for one frame so the two morphed into each other rather
    // than swapping — Ahaan, at the time: "settings is snappy and like its own
    // standalone thing". The card now simply appears, which is what omarchy
    // does and what "standalone" was reaching for; Finder.qml drops the
    // launcher box in the same frame rather than fading it out behind this one.

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
        // One fill, lit or not. It used to brighten to 0.14 under the pointer;
        // no control in finder reacts to hover any more.
        color: Theme.alpha(Theme.text, 0.06)
        // Disabled means "the range ends here", and it dims rather than
        // vanishing: a + that disappears at the maximum reads as a glitch,
        // where a dim one reads as a limit.
        opacity: sb.shown ? (sb.enabled ? 1 : 0.3) : 0
        // No Behaviors. `shown` is row.isSel, so this fades in and out with the
        // selection, and the selection no longer fades.

        Text {
            anchors.centerIn: parent
            text: sb.glyph
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 15
        }

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
    // combo and is unreadable at the default width.
    //
    // Straight bindings, no Behaviors and no pin. Both numbers are exact the
    // moment the layout settles, and settling takes the one frame the model
    // swap costs anyway — the elaborate hold that used to wrap these existed
    // purely so an ANIMATION did not start against a contentHeight that had not
    // finished being computed. With nothing animating there is no goalpost to
    // move.
    width:          Settings.pageWidth(panel.pageKey)
    implicitHeight: col.implicitHeight + Theme.pad * 2
    radius: Theme.cardRadius
    color: Theme.bg
    border.width: Theme.cardBorder
    border.color: Theme.line

    // It appears. It does not arrive.
    //
    // This was a fade plus a scale from 0.97 over 190ms, matched against the
    // launcher box's own fade so the two crossfaded into one another. Stepping
    // omarchy's recording frame by frame at 60fps: frame 230 is wallpaper,
    // frame 231 is the complete menu at full opacity and full size, and closing
    // is the same single frame in reverse. There is no in-between frame to find
    // — and that, not any easing curve, is what reads as instant.
    //
    // `scale` is not set at all now rather than being bound to 1: a scale
    // binding on a Rectangle this size is a transform Qt applies every frame
    // for no visual effect.
    visible: panel.shown

    MouseArea { anchors.fill: parent }   // swallow clicks; the scrim is behind

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: Theme.pad
        spacing: 0

        // ── there is no header ────────────────────────────────────────────
        // A page icon, the page title, and a breadcrumb of where you were. All
        // three are gone, on Ahaan's instruction and for the reason the rest of
        // this pass exists: omarchy's menu has no title, and the thing a title
        // would say is already said one line below it. The placeholder in the
        // search field reads "Search settings…" at the root and "Search
        // setup…" inside Setup, so the field IS the breadcrumb — which is
        // exactly what omarchy does with its own prompt ("Go…", then
        // "Install…" once you are inside Install).
        //
        // Settings.pageTitle and Settings.pageIcon still exist and pageTitle is
        // still read, by that placeholder. Nothing else on this card draws a
        // title.

        // ── search: a line, not a box, and now not an icon either ─────────
        // The 󰍉 glyph went with the header. It was the only mark left on the
        // card that named a control rather than being one, and a search field
        // whose placeholder starts with the word "Search" does not need a
        // second thing saying so.
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 16
            spacing: 10
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

        // No rule under the search line. It was the last divider on the card
        // once the footer's went, and a single hairline with nothing to pair
        // with reads as a leftover. The 16px under the search row does the
        // separating; omarchy's prompt sits over its list with nothing but
        // space between them.

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

            // No transform and no opacity. The list used to be translated by
            // panel.slide and faded by a value derived from it, which is the
            // page transition described (and buried) up at jumpTo.
            //
            // Removing them also removes a cost the clip comment below is all
            // about: a clipped item that is ALSO translated and ALSO below full
            // opacity cannot be drawn with a scissor rect, so Qt rendered this
            // subtree to an offscreen texture. That only ever happened during
            // the slide, but it happened on every page change, at 430x460, on a
            // GPU that is downclocked on the balanced profile.
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

            // The band, and it no longer travels.
            //
            // What was here was the most elaborate thing in this file: a top
            // edge and a bottom edge chasing the current row at two DIFFERENT
            // speeds, so the band stretched toward where it was going and was
            // pulled back into shape as it arrived, with both Behaviors
            // suppressed for the one frame of a page change so it did not
            // stretch across a list that had just been replaced. It worked. It
            // was also 180ms of waiting per arrow key, and frame-stepping
            // omarchy's menu at 60fps shows its selection on one row in one
            // frame and on the next row in the very next — no travel at all.
            // That is the whole of what Ahaan meant by snappy, so the band is
            // a plain rectangle that is simply WHERE the selection is.
            //
            // Everything below survives from that version and still matters:
            //
            // COMPUTED FROM THE INDEX, never read off the current delegate.
            // Reassigning a ListView's model resets it, and a rebuilt delegate
            // EXISTS before it has been positioned — currentItem is non-null
            // and its y is still 0. So a guard on `currentItem !== null` does
            // not help: the band read that 0 as a real position and jumped to
            // the top of the list. Every row on a page is the same height (see
            // panel.rowH), so row i sits at i * (rowH + spacing) in content
            // coordinates — which is the space the highlight is placed in.
            // That is exact, it is available before any delegate exists, and it
            // cannot be disturbed by the model being rebuilt underneath it.
            //
            // Note that with no animation this is no longer load-bearing for
            // CORRECTNESS the way it was — a band that snaps to a wrong 0 and
            // snaps back within one frame would never be seen. It is kept
            // because it is still the right answer and costs nothing, and
            // because anything that reintroduces motion here would need it
            // again immediately.
            highlight: Rectangle {
                id: band
                z: 0
                width: list.width

                readonly property real rowPitch: panel.rowH + list.spacing

                y: panel.sel * band.rowPitch
                height: panel.rowH

                radius: Theme.rowRadius
                // A fill and nothing else — see Theme.rowSel. No border: the
                // outline that used to sit around this was the loudest mark on
                // a card that now has no other marks on it.
                color: Theme.rowSel
            }

            delegate: Item {
                id: row
                required property var modelData
                required property int index

                readonly property bool isSel:  row.index === panel.sel
                readonly property bool isOn:   row.modelData.active === true
                readonly property bool nests:  row.modelData.kind === "menu"
                // A menu row never draws one, whatever the model carries — the
                // gate is here rather than in the data so that Settings.qml's
                // page definitions stay readable as descriptions of the menu.
                // Must agree with panel.rowH, which decides the page's height
                // from the same test.
                readonly property bool hasSub: row.modelData.kind !== "menu"
                                               && (row.modelData.sub || "") !== ""

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
                        panel.sel = row.index
                        panel.activate(row.index)
                    }
                }

                // No hover wash, and no HoverHandler to drive one: Ahaan does not
                // want the pointer painting the list. The MouseArea above stays,
                // so clicking a row still selects and activates it — "the mouse
                // should still work" was the other half of the ask. The only
                // fill on this list is the selection.

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
                            //
                            // ONE value, the same on every row. It used to come
                            // up to full strength on the selected row, fading
                            // over Theme.motion so it moved with the band. With
                            // the band no longer moving that fade is a 180ms
                            // flicker chasing an instant step, and omarchy's
                            // icons do not change on selection at all — the
                            // wash is the entire mark. Two things saying
                            // "this row" is one more than is needed, and the
                            // second one arriving late is worse than not
                            // arriving.
                            color: Theme.alpha(Theme.text, 0.65)
                            // Almost always Theme.font, which carries every
                            // glyph in this menu. The exception is a row whose
                            // mark lives somewhere else — the browsers draw
                            // from Font Awesome Brands, because Brave's lion is
                            // only there and its codepoint is a DIFFERENT icon
                            // in the Nerd Font. Settings.qml's _glyphs names the
                            // family; an empty string means the usual one.
                            font.family: row.modelData.iconFont ? row.modelData.iconFont : Theme.font
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
                        // The subtitle, and it is now gone from every MENU row.
                        //
                        // That is the removal Ahaan asked for — "the subtext in
                        // each category" — and the categories are exactly the
                        // menu rows: Install's "packages, AUR, web apps",
                        // Setup's "monitors, keys, window rules, defaults", and
                        // fourteen more like them. Every one of those restates
                        // its own label at greater length. omarchy's rows are a
                        // word each.
                        //
                        // It survives on rows that are NOT menus, because on
                        // those the second line is not a description of the
                        // label — it is the only place the information exists:
                        // a keybind's row says what the bind DOES under the
                        // action's name, and a font group says how many
                        // variants it has. Deleting those would delete the page.
                        //
                        // The menu rows whose subtitle was live STATE rather
                        // than description — the firewall's zone, how many
                        // fingerprints are enrolled — did not lose it. It moved
                        // to the right-hand slot below; see Settings._decorate,
                        // which now writes those into `trail`.
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

                    // The right-hand slot. Two things land here and they are the
                    // same KIND of thing — something about the row that is not a
                    // description of it:
                    //
                    //   on a search hit   the page the row actually lives on
                    //   on a menu row     live state, e.g. "3 enrolled"
                    //
                    // Right-aligned and dim, so it reads as an annotation rather
                    // than as a second label, and so it never adds a line to the
                    // row's height the way a subtitle does.
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
                                // Selected only. It used to appear on hover too,
                                // and hover is gone from this file entirely.
                                shown: row.isSel
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
                                // No Behaviors. Both colours above depend on
                                // row.isSel, and the selection is instant now —
                                // a 180ms tint chasing a band that has already
                                // arrived is the mismatch the old Theme.motion
                                // comment was written to prevent, just with the
                                // two halves swapped round.

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
                                        panel.sel = row.index
                                        panel.beginEdit(row.modelData.id)
                                    }
                                }
                            }

                            StepButton {
                                glyph: "+"
                                shown: row.isSel
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
                                // No Behavior, for the same reason as the value
                                // box above: this tint tracks the selection.

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

        // ── there is no footer ────────────────────────────────────────────
        // A hairline and up to eight keybind hints — "↑↓ navigate", "↵ select",
        // "← back", "esc close", and four more that appeared only on the two
        // pages that need them. Removed on Ahaan's instruction.
        //
        // Worth writing down what goes with it, because none of these keys
        // changed and there is now nothing on screen that says so. Read off the
        // Keys handler above rather than off the footer that used to be here —
        // the footer never mentioned →, and never mentioned the caret
        // conditions that decide whether ← and Backspace edit or navigate:
        //
        //   ↑ ↓          move
        //   ↵            select, or enter a page
        //   Esc          close, at any depth
        //   ←            back one page, but only with the caret at position 0
        //   Backspace    back one page, but only with the field empty
        //   →            enter a page, but only with the caret at the end
        //   − + =        step a window rule   (setup/windowrules)
        //   ⇧E           reassign a keybind   (setup/keybindings)
        //   ⇧R           restore one bind, or reset every window rule
        //
        // The three "but only" clauses are what lets the same keys edit the
        // search text and navigate the list without a mode: a key is the
        // list's only when the caret has nothing left to do with it. There is
        // no Tab binding — → is the only key that descends other than ↵.
        //
        // The same trade the reminder prompt made yesterday, and the same
        // reasoning: its Backspace-walks-back step is undiscoverable now that
        // its hint line is gone, and it was kept because it costs nothing to
        // have. This footer was eight lines of chrome on every page to document
        // four keys most people find by pressing them.
    }
}
