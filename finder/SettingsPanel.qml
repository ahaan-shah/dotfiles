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
// The rule now: ONE hairline, around the card. Nothing around a row. The
// selected row is the only thing with a fill, and it also carries a short
// accent bar on its left edge, so the eye finds it without needing an outline
// to separate it from its neighbours. State that used to be a subtitle — which
// value is currently in effect — is a single accent check on the right, so it
// never competes with the selection highlight for the same pixels.
//
// Everything else is spacing. 44px rows, a borderless search line under a
// hairline, and generous card padding. The palette is unchanged; the tokens
// live in Theme.qml so this and the password box cannot drift.
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
        panel.pageKey = (base === "") ? row.id : base + "/" + row.id
        panel.query = ""
        searchInput.text = ""
        panel.sel = 0
        Settings.ensure(panel.pageKey)
    }

    function back() {
        // Clearing a search is a step of its own: it is what the user did last,
        // so it is what going back should undo.
        if (panel.searching) { searchInput.text = ""; panel.sel = 0; return }
        if (panel.pageKey === "") { panel.requestClose(); return }
        const cut = panel.pageKey.lastIndexOf("/")
        panel.pageKey = (cut < 0) ? "" : panel.pageKey.substring(0, cut)
        panel.sel = 0
    }

    function activate(i) {
        const r = panel.rows[i]
        if (!r) return
        if (r.kind === "menu") { panel.enter(r); return }
        // A search hit carries the page it came from, so it runs exactly what it
        // would have run had the user walked there by hand.
        if (Settings.activate(r.pageKey !== undefined ? r.pageKey : panel.pageKey, r))
            panel.requestClose()
    }

    function move(d) {
        if (panel.rows.length === 0) return
        panel.sel = Math.max(0, Math.min(panel.rows.length - 1, panel.sel + d))
        list.positionViewAtIndex(panel.sel, ListView.Contain)
    }

    onRowsChanged: if (panel.sel >= panel.rows.length) panel.sel = Math.max(0, panel.rows.length - 1)

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
        // Dimmed until the compositor has actually answered "is hyprbars
        // loaded" — a switch showing a confident "off" it does not yet know is
        // worse than one that shows it does not know.
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
    width: Settings.pageWidth(panel.pageKey)
    implicitHeight: col.implicitHeight + Theme.pad * 2
    radius: Theme.cardRadius
    color: Theme.bg
    border.width: 1
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
                onTextChanged: { panel.query = text; panel.sel = 0 }

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
            clip: true
            spacing: 2
            model: panel.rows
            currentIndex: panel.sel
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: row
                required property var modelData
                required property int index

                readonly property bool isSel:  row.index === panel.sel
                readonly property bool isOn:   row.modelData.active === true
                readonly property bool nests:  row.modelData.kind === "menu"
                readonly property bool hasSub: (row.modelData.sub || "") !== ""

                width: list.width
                height: row.hasSub ? Theme.rowTall : Theme.rowHeight

                // The only fill in the list. No border on any row, ever — that
                // is the whole point of this pass.
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.rowRadius
                    color: row.isSel ? Theme.rowSel
                           : rowHover.hovered ? Theme.rowHover
                           : "transparent"
                    Behavior on color { ColorAnimation { duration: 110 } }
                }

                // A short accent bar on the leading edge of the selected row —
                // it reads as a cursor, which an outline does not.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 0
                    width: 3
                    height: row.isSel ? 18 : 0
                    radius: 1.5
                    color: Theme.accent
                    Behavior on height { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
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
                        onToggled: panel.activate(row.index)
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

                MouseArea {
                    anchors.fill: parent
                    // The switch has its own MouseArea; letting this one sit on
                    // top would make the whole row a toggle and fire it twice.
                    enabled: row.modelData.kind !== "toggle"
                    onClicked: { panel.sel = row.index; panel.activate(row.index) }
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
            Text { text: "↵ select";    color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint }
            Text { text: "← back";      color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint
                   visible: parent.nested }
            Item { Layout.fillWidth: true }
            Text { text: "esc close"
                   color: Theme.dimmer; font.family: Theme.font; font.pixelSize: Theme.fsHint }
        }
    }
}
