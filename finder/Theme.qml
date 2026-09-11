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
    // The card edge, and it is the TASKBAR's edge: alpha(color7, 0.8) at 2px is
    // exactly what every dropdown panel in taskbar/shell.qml draws (its
    // `ncBorder`), and Ahaan's call is that finder wear the same one. It was
    // col7 at 0.30, which against a bright wallpaper was barely an edge at all.
    readonly property color line:      root.alpha(root.col7, 0.80)   // the card edge
    readonly property color hairline:  root.alpha(root.text, 0.10)   // dividers inside it
    // There is no rowHover any more. It was alpha(col7, 0.035) — deliberately
    // far below rowSel, because at 0.07 a hovered row read as a second
    // selection — and Ahaan's call is that the pointer should not paint the
    // list at all. The mouse still SELECTS and still activates; it just leaves
    // no trail. Anything tempted to add a hover wash back belongs here, and
    // should ask first.
    // ONE value across the whole row. It was a left-to-right gradient for a
    // while and the falloff is gone: on a row 430px wide it made the right-hand
    // end look unfinished rather than shaped, and the page now has a box and a
    // unit sitting in exactly that end. A selection is one thing, so it is one
    // colour.
    //
    // 0.95, and it is Ahaan's number twice over: he asked for 0.80, tried it on
    // the running desktop and turned it up here. Before that it was 0.55, and
    // before that a fifth of the accent, which over a near-black card
    // desaturated to mud rather than reading as a colour at all. At 0.95 the
    // selection is the accent, near enough, and the row it marks is
    // unmistakable from across the screen.
    readonly property color rowSel:    root.alpha(root.accent, 0.95)
    // The selected row's outline, and it can no longer BE the accent. At a 0.55
    // fill a full-strength accent outline stood clear of it; at 0.80 the two
    // are the same colour four-fifths of the way and the outline vanished into
    // its own fill — thickening it only made a thicker nothing. So the outline
    // is drawn in the text colour instead, which is what the taskbar's own
    // active rows do (`alpha(ncText, 0.85)` in shell.qml) and keeps the mark
    // legible whatever pywal makes the accent.
    readonly property color rowSelLine: root.alpha(root.text, 0.85)

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
    // On the SELECTED row only, and 1.5 is not a guess: it is the weight the
    // battery panel's charge-limit buttons carry (taskbar/shell.qml, 1.5px of
    // alpha(ncText, 0.9) around a solid-accent active button), which is the
    // same shape doing the same job. Ahaan asked for the two to match. A 2.5px
    // pass sat between them and read as heavier than anything on the bar.
    readonly property real rowBorder: 1.5
    readonly property int rowRadius:  12
    readonly property int iconSlot:   26

    // ── motion ────────────────────────────────────────────────────────────
    // ONE number for everything the selection does, because the complaint that
    // produced it was that the parts did not match: the highlight slid over
    // 190ms while the row's own state — the icon coming up to full strength —
    // switched on its own shorter timing, so a single step looked like two
    // separate events, one of them slow.
    //
    // 180, set by Ahaan on the running desktop. The note this replaces argued
    // for 120 — "past roughly 150ms the eye stops reading it as the selection
    // moving and starts waiting for it to arrive" — and that was written when
    // the launcher's selection did not travel at all. Now that it does, and
    // over a whole card rather than a 430px column, the slower step is the one
    // that reads as movement. It drives the settings band, the launcher's
    // highlight (move AND resize) and every colour fade on a row, which is the
    // point: they cannot disagree.
    readonly property int motion: 180

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
