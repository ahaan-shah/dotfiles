pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// The reassign-a-keybind box. Raised over the settings menu by the Keybindings
// page, it takes the keyboard, shows what is being held, and commits the combo
// when the key comes back up.
//
// ── Why it commits on RELEASE ─────────────────────────────────────────────
// Because a combination is not known until then. Pressing SUPER and then W is
// two press events, and committing on the second would take SUPER+W — but so
// would committing on SUPER alone if the user is slow, and there is no way to
// tell "still going" from "done" while a key is down. Release is the one
// unambiguous moment, and it also lets the box show the combo building up
// rather than closing the instant it can guess.
//
// ── Modifiers are tracked, not inferred ──────────────────────────────────
// event.modifiers describes the state the event was DELIVERED in, and for the
// press of a modifier key itself that state may or may not already include it
// depending on the backend. So each modifier key is tracked by its own press
// and release, and event.modifiers is folded in as a second source when the
// main key arrives — either alone would miss a case.
Rectangle {
    id: cap

    property bool shown: false
    // The combo hyprland.lua DECLARES, which is the identity the override is
    // keyed on — never the one currently in force.
    property string target: ""
    property string label: ""
    property string current: ""

    signal committed(string combo)
    signal cancelled()

    // ── the compositor's own binds, switched off ──────────────────────────
    // Hyprland matches binds BEFORE forwarding a key to any client, and
    // exclusive keyboard focus does not change that — so without this, pressing
    // a combo that is already bound fires that bind instead of arriving here.
    // Measured: rebinding onto a SUPER combo opened a window behind this card.
    //
    // `capture` is a submap defined at the end of hyprland.lua holding a single
    // emergency-exit bind, so while it is active everything else reaches this
    // box — including the combos this page exists to reassign.
    //
    // finish() is paired with begin() on EVERY exit path. Leaving the submap
    // behind would leave the whole keyboard dead except SUPER+SHIFT+Escape.
    property var _submapProc: Process { id: submapProc; running: false }
    function _submap(name) {
        submapProc.running = false
        submapProc.command = ["hyprctl", "dispatch", "hl.dsp.submap('" + name + "')"]
        submapProc.running = true
    }
    function finish() { cap._submap("reset") }

    function begin(declared, describedAs, inForce) {
        cap.target = declared
        cap.label = describedAs
        cap.current = inForce
        cap._reset()
        // NOT forceActiveFocus() here. `visible` is `opacity > 0.001` and the
        // opacity animates up from zero, so at this instant the card is still
        // invisible — and an invisible item cannot take focus. The call
        // succeeded silently, the keyboard stayed with the search field behind,
        // and the box sat there showing "Press a combination" while every key
        // went somewhere else. Focus is taken when it is actually on screen.
        cap._submap("capture")
        focusGrab.restart()
    }

    onVisibleChanged: if (cap.visible && cap.target !== "") focusGrab.restart()

    // Same shape as Finder's own inputFocusTimer, and for the same reason: one
    // retry costs nothing and the alternative is a box that cannot be typed in.
    Timer {
        id: focusGrab
        interval: 16
        repeat: true
        triggeredOnStart: true
        property int tries: 0
        onTriggered: {
            if (cap.target === "") { running = false; tries = 0; return }
            if (cap.visible) cap.forceActiveFocus()
            if (cap.activeFocus || ++tries > 12) { running = false; tries = 0 }
        }
    }

    function _reset() {
        cap.heldMods = []
        cap.capturedMods = []
        cap.capturedKey = ""
    }

    // ── state ─────────────────────────────────────────────────────────────
    property var heldMods: []
    property var capturedMods: []
    property string capturedKey: ""

    // What the boxes show: the finished combo once a key has landed, otherwise
    // whatever is being held right now.
    readonly property var parts: cap.capturedKey !== ""
                                 ? cap.capturedMods.concat([cap.capturedKey])
                                 : cap.heldMods

    readonly property string combo: cap.capturedKey === "" ? ""
                                  : cap.capturedMods.concat([cap.capturedKey]).join(" + ")

    // ── keys ──────────────────────────────────────────────────────────────
    function _modName(k) {
        if (k === Qt.Key_Super_L || k === Qt.Key_Super_R || k === Qt.Key_Meta) return "SUPER"
        if (k === Qt.Key_Control) return "CTRL"
        if (k === Qt.Key_Alt || k === Qt.Key_AltGr) return "ALT"
        if (k === Qt.Key_Shift) return "SHIFT"
        return ""
    }

    // Ordered SUPER, CTRL, ALT, SHIFT, which is the order hyprland.lua already
    // writes them in — "SUPER + SHIFT + 1", "ALT + SHIFT + Tab". A combo that
    // reads differently from the ones around it in the list looks like a
    // different kind of thing.
    function _ordered(list) {
        const order = ["SUPER", "CTRL", "ALT", "SHIFT"]
        return order.filter(m => list.indexOf(m) >= 0)
    }

    function _modsFrom(modifiers) {
        const out = []
        if (modifiers & Qt.MetaModifier)    out.push("SUPER")
        if (modifiers & Qt.ControlModifier) out.push("CTRL")
        if (modifiers & Qt.AltModifier)     out.push("ALT")
        if (modifiers & Qt.ShiftModifier)   out.push("SHIFT")
        return out
    }

    // Qt key code -> the name Hyprland wants, which is an XKB keysym. Letters
    // and digits are their own name; everything else that this desktop actually
    // binds is listed. Anything unlisted returns "" and is refused rather than
    // guessed — a wrong keysym binds silently to nothing, and a bind that does
    // nothing is worse than a box that says it did not understand.
    readonly property var _named: ({
        [Qt.Key_Left]: "Left", [Qt.Key_Right]: "Right",
        [Qt.Key_Up]: "Up", [Qt.Key_Down]: "Down",
        [Qt.Key_Return]: "Return", [Qt.Key_Enter]: "Return",
        [Qt.Key_Escape]: "Escape", [Qt.Key_Tab]: "Tab",
        [Qt.Key_Space]: "space", [Qt.Key_Backspace]: "BackSpace",
        [Qt.Key_Delete]: "Delete", [Qt.Key_Insert]: "Insert",
        [Qt.Key_Home]: "Home", [Qt.Key_End]: "End",
        [Qt.Key_PageUp]: "Prior", [Qt.Key_PageDown]: "Next",
        [Qt.Key_Print]: "Print", [Qt.Key_Pause]: "Pause",
        [Qt.Key_Period]: "period", [Qt.Key_Comma]: "comma",
        [Qt.Key_Minus]: "minus", [Qt.Key_Equal]: "equal",
        [Qt.Key_Slash]: "slash", [Qt.Key_Backslash]: "backslash",
        [Qt.Key_Semicolon]: "semicolon", [Qt.Key_Apostrophe]: "apostrophe",
        [Qt.Key_BracketLeft]: "bracketleft", [Qt.Key_BracketRight]: "bracketright",
        [Qt.Key_QuoteLeft]: "grave"
    })

    function _keyName(k) {
        if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k)
        if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(k)
        if (k >= Qt.Key_F1 && k <= Qt.Key_F12) return "F" + (k - Qt.Key_F1 + 1)
        return cap._named[k] !== undefined ? cap._named[k] : ""
    }

    property string error: ""

    // A key that may stand alone. Everything else needs a modifier: binding a
    // bare Q means the letter stops being typeable everywhere, and it is the
    // kind of mistake you notice later in another window wondering why a key
    // does nothing. Function and media keys carry no character, so nothing is
    // lost by claiming one — and this config already binds F1 to F12 and Print
    // bare. keybinds.sh refuses the same shapes; this is the half that can
    // explain it without a round trip, and without closing the box on you.
    function _standalone(name) {
        return /^F([1-9]|1[0-9]|2[0-4])$/.test(name)
            || name === "Print" || name === "Pause"
            || name.indexOf("XF86") === 0
    }

    Keys.onPressed: event => {
        event.accepted = true
        // Auto-repeat is NOT filtered here, and that is deliberate. Re-capturing
        // the same combo is idempotent, so a repeat costs nothing — while
        // dropping one costs a press. Synthetic input arrives flagged as repeat
        // on this setup (every event wtype generates is), and a capture box that
        // ignores it is a capture box that cannot be tested or scripted.
        const m = cap._modName(event.key)
        if (m !== "") {
            if (cap.capturedKey !== "") cap._reset()   // a new attempt
            if (cap.heldMods.indexOf(m) < 0) cap.heldMods = cap._ordered(cap.heldMods.concat([m]))
            return
        }

        // Escape ALONE gets out. With a modifier it is a perfectly good bind —
        // SUPER+Escape is one this desktop already ships — so only the bare
        // press can mean cancel.
        const mods = cap._ordered(cap.heldMods.concat(cap._modsFrom(event.modifiers)))
        if (event.key === Qt.Key_Escape && mods.length === 0) { cap.finish(); cap.cancelled(); return }

        const name = cap._keyName(event.key)
        if (name === "") { cap.error = "That key is not one this can name"; return }
        cap.error = ""
        cap.capturedMods = mods
        cap.capturedKey = name
    }

    Keys.onReleased: event => {
        event.accepted = true
        if (event.isAutoRepeat) return

        const m = cap._modName(event.key)
        if (m !== "") {
            cap.heldMods = cap.heldMods.filter(x => x !== m)
            return
        }
        // The main key coming back up is the commit. Nothing else ends it.
        if (cap.capturedKey !== "" && cap._keyName(event.key) === cap.capturedKey) {
            if (cap.capturedMods.length === 0 && !cap._standalone(cap.capturedKey)) {
                // Stays OPEN and stays in the submap: the next attempt is the
                // point, and closing would make the user reopen the box to make
                // the same mistake differently.
                cap.error = cap.capturedKey + " alone would stop that key working everywhere. Add SUPER, CTRL, ALT or SHIFT."
                cap._reset()
                return
            }
            cap.finish()
            cap.committed(cap.combo)
        }
    }

    // ── the card ──────────────────────────────────────────────────────────
    width: 420
    implicitHeight: col.implicitHeight + Theme.pad * 2
    radius: Theme.cardRadius
    color: Theme.bg
    border.width: Theme.cardBorder
    // Theme.line like every other card in finder, not the accent it used to
    // draw: "finder entirely wears the taskbar's edge" is the rule now, and
    // this box already says it is capturing with its title and its live combo.
    border.color: Theme.line

    opacity: cap.shown ? 1 : 0
    scale:   cap.shown ? 1 : 0.97
    visible: opacity > 0.001
    focus: cap.shown
    Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
    Behavior on scale   { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

    MouseArea { anchors.fill: parent }   // swallow clicks

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: Theme.pad
        spacing: 14

        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Rectangle {
                implicitWidth: 38; implicitHeight: 38
                radius: 12
                color: Theme.alpha(Theme.accent, 0.20)
                Text {
                    anchors.centerIn: parent
                    text: "\u{f030c}"                  // md-keyboard
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: 18
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: cap.label === "" ? "Reassign keybind" : cap.label
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: Theme.fsRow + 1
                    font.weight: Font.Medium
                }
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: cap.current === "" ? "" : "currently " + cap.current
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fsSub
                }
            }
        }

        // ── the keys, as boxes ────────────────────────────────────────────
        // Fixed height whether or not anything is held, so the card does not
        // resize under the hand that is pressing keys into it.
        Item {
            Layout.fillWidth: true
            implicitHeight: 54

            Text {
                anchors.centerIn: parent
                visible: cap.parts.length === 0
                text: "Press a combination"
                color: Theme.dimmer
                font.family: Theme.font
                font.pixelSize: Theme.fsInput
            }

            Row {
                anchors.centerIn: parent
                spacing: 8
                Repeater {
                    model: cap.parts
                    Rectangle {
                        required property var modelData
                        // Sized to its label rather than fixed: SUPER and W are
                        // very different widths and a uniform box would make one
                        // of them look padded out.
                        implicitWidth: Math.max(44, keyLabel.implicitWidth + 22)
                        implicitHeight: 38
                        radius: 10
                        color: Theme.accent
                        border.width: 1
                        border.color: Theme.alpha(Theme.text, 0.25)
                        Text {
                            id: keyLabel
                            anchors.centerIn: parent
                            text: String(parent.modelData).toUpperCase()
                            // Against the accent, not against the card: pywal
                            // hands out a light accent on some wallpapers and a
                            // dark one on others, and Theme.contrast is what
                            // keeps the label readable on both.
                            color: Theme.contrast(Theme.accent)
                            font.family: Theme.font
                            font.pixelSize: Theme.fsRow
                            font.weight: Font.Medium
                        }
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: cap.error === ""
            text: "Every key reaches this box. A combination already in use will be taken from whatever has it."
            color: Theme.dimmer
            font.family: Theme.font
            font.pixelSize: Theme.fsHint
        }

        Text {
            Layout.fillWidth: true
            visible: cap.error !== ""
            text: cap.error
            horizontalAlignment: Text.AlignHCenter
            // Wraps. Without it the message ran off both edges of the card —
            // fillWidth gives a Text its width, not permission to use more than
            // one line.
            wrapMode: Text.WordWrap
            color: Theme.danger
            font.family: Theme.font
            font.pixelSize: Theme.fsSub
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.hairline }

        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Text {
                text: "release to save"
                color: Theme.dimmer
                font.family: Theme.font
                font.pixelSize: Theme.fsHint
            }
            Item { Layout.fillWidth: true }
            Text {
                text: "esc cancel"
                color: Theme.dimmer
                font.family: Theme.font
                font.pixelSize: Theme.fsHint
            }
        }
    }
}
