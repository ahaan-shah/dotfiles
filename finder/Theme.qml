pragma Singleton

import QtQuick

// The settings surface's design tokens, in one place so the panel and the
// password box cannot drift apart.
//
// The palette names are the taskbar's (colBg / col7 / col9 / col15 →
// text / accent / border), so the two read as one system — but the *metrics*
// deliberately are not the taskbar's. A dropdown that hangs off a bar icon is
// dense on purpose: it is a glance. A settings menu is a place you stop and
// read, and the first pass at it — a literal copy of the panel chrome, a 1.5px
// outline around every single row — made a list of eight things look like a
// spreadsheet.
//
// So: one hairline around the card and nothing around the rows. The selected
// row is the only thing with a fill, and state that used to be spelled out in
// a subtitle is a mark on the right instead. Everything the eye does not need
// gets out of the way.
QtObject {
    id: root

    // ── palette ───────────────────────────────────────────────────────────
    readonly property color bg:     WalColors.background
    readonly property color col7:   WalColors.color7
    readonly property color accent: WalColors.color9
    readonly property color text:   WalColors.color15
    // The one hardcoded colour here. pywal makes no promise about any slot
    // being red, and "authentication failed" has to read as a failure on every
    // wallpaper.
    readonly property color danger: "#e0796f"
    // Likewise hardcoded: "it worked" has to read as success on every wallpaper,
    // and pywal promises no green slot either.
    readonly property color good:   "#7fca97"

    readonly property string font: UiConfig.fontFamily

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    function contrast(c) { return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? "black" : "white" }

    // ── surfaces ──────────────────────────────────────────────────────────
    readonly property color line:      root.alpha(root.col7, 0.20)   // the card hairline
    readonly property color hairline:  root.alpha(root.text, 0.10)   // dividers inside it
    // Deliberately far below rowSel: at 0.07 a hovered row read as a second
    // selection, so the pointer resting anywhere made the list ambiguous.
    readonly property color rowHover:  root.alpha(root.col7, 0.035)
    readonly property color rowSel:    root.alpha(root.accent, 0.22)

    readonly property color dim:    root.alpha(root.text, 0.45)   // subtitles, crumbs
    readonly property color dimmer: root.alpha(root.text, 0.30)   // footer hints, chevrons

    // ── metrics ───────────────────────────────────────────────────────────
    readonly property int cardWidth:  430
    readonly property int cardRadius: 20
    readonly property int pad:        20
    readonly property int rowHeight:  44
    readonly property int rowTall:    58   // with a subtitle
    readonly property int rowRadius:  12
    readonly property int iconSlot:   26

    readonly property int fsTitle: 17
    readonly property int fsInput: 15
    readonly property int fsRow:   14
    readonly property int fsSub:   11
    readonly property int fsHint:  11
}
