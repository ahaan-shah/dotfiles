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
// So: a drawn edge around the card and nothing around the rows EXCEPT the
// selected one, which carries both a fill and an accent outline. That outline
// is a later revision and it overrides what this file used to say — the
// original pass put a 1.5px line around every row, which is what made eight
// items read as a spreadsheet. One row is not eight: the outline is what marks
// the selection, so it never repeats down the list. State that used to be
// spelled out in a subtitle is a mark on the right instead.
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
    // And the third of the same kind. "This worked, but something else changed
    // because of it" is neither a failure nor a success, and it must not borrow
    // the accent — the accent is the SELECTION on every page here, so a notice
    // wearing it reads as something chosen rather than something to act on.
    readonly property color warn:   "#e0b96f"

    readonly property string font: UiConfig.fontFamily

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    function contrast(c) { return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? "black" : "white" }

    // ── surfaces ──────────────────────────────────────────────────────────
    readonly property color line:      root.alpha(root.col7, 0.30)   // the card edge
    readonly property color hairline:  root.alpha(root.text, 0.10)   // dividers inside it
    // Deliberately far below rowSel: at 0.07 a hovered row read as a second
    // selection, so the pointer resting anywhere made the list ambiguous.
    readonly property color rowHover:  root.alpha(root.col7, 0.035)
    // ONE value across the whole row. It was a left-to-right gradient for a
    // while and the falloff is gone: on a row 430px wide it made the right-hand
    // end look unfinished rather than shaped, and the page now has a box and a
    // unit sitting in exactly that end. A selection is one thing, so it is one
    // colour.
    //
    // 0.55 and not less: pywal's accent is a light warm orange, and a fifth of
    // it over a near-black card desaturates to mud rather than reading as a
    // colour at all.
    readonly property color rowSel:    root.alpha(root.accent, 0.55)
    // The selected row's outline. Full-strength accent: it is the same mark the
    // old 3px leading bar was, wrapped around the row instead of stacked beside
    // it, so it has to read as that mark and not as a divider.
    readonly property color rowSelLine: root.accent

    readonly property color dim:    root.alpha(root.text, 0.45)   // subtitles, crumbs
    readonly property color dimmer: root.alpha(root.text, 0.30)   // footer hints, chevrons

    // ── metrics ───────────────────────────────────────────────────────────
    readonly property int cardWidth:  430
    readonly property int cardRadius: 20
    readonly property int pad:        20
    // The card edge. Shared by the settings panel, the password box and the
    // fingerprint box, which is the whole reason this file exists — at 1px the
    // card had no edge against a busy wallpaper, and three cards drifting apart
    // on it would be worse than none of them having one.
    readonly property int cardBorder: 2
    readonly property int rowHeight:  44
    readonly property int rowTall:    58   // with a subtitle
    readonly property real rowBorder: 1.5  // on the SELECTED row only
    readonly property int rowRadius:  12
    readonly property int iconSlot:   26

    // ── motion ────────────────────────────────────────────────────────────
    // ONE number for everything the selection does, because the complaint that
    // produced it was that the parts did not match: the highlight slid over
    // 190ms while the row's own state — the icon coming up to full strength,
    // the hover fill — switched on its own shorter timing, so a single step
    // looked like two separate events, one of them slow.
    //
    // 120 rather than 190: a step of one row is a small distance, and past
    // roughly 150ms the eye stops reading it as the selection moving and starts
    // waiting for it to arrive.
    readonly property int motion: 120

    // The selection band's two edges do not move together: the one facing the
    // direction of travel leaves on `motion`, the one behind it on `motionLag`,
    // so the band stretches toward where it is going and is pulled back into
    // shape as it arrives. A rectangle that merely slides is the same distance
    // in the same time with none of that, and it is what "flowing" looked like.
    //
    // 1.55x rather than 2x: past about that the trailing edge is still visibly
    // catching up after the leading edge has stopped, which reads as lag rather
    // than as weight.
    readonly property int motionLag: Math.round(root.motion * 1.55)

    // A page change is not movement within a page — see SettingsPanel's
    // jumpTo. The card resizes and the new list slides in over this.
    readonly property int motionPage: 190

    readonly property int fsTitle: 17
    readonly property int fsInput: 15
    readonly property int fsRow:   14
    readonly property int fsSub:   11
    readonly property int fsHint:  11
}
