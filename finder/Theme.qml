pragma Singleton

import QtQuick

// The settings surface's design tokens, in one place so the panel and the
// password box cannot drift apart.
//
// The palette names are the taskbar's (colBg / col7 / col9 / col15 →
// text / accent / border), so the two read as one system — but the *metrics*
// deliberately are not the taskbar's. A dropdown that hangs off a bar icon is
// dense on purpose: it is a glance. A settings menu is a place you stop and
// read.
//
// ── 2026-09-12: measured against omarchy's menu ───────────────────────────
// Ahaan's ask was to match it: "minimal and simple like the reminders thing".
// Two of its properties are what this pass is, and both were MEASURED off a
// screen recording of it rather than guessed at:
//
//   The selection is a wash, not a colour. Sampled from a text-free column of
//   the recording: card 33,33,45 and the selected row 45,45,57 — a flat +12
//   on every channel, which is roughly 5% white laid over the card. No
//   outline, no accent, no gradient. What used to be here was the accent at
//   0.95 plus a 1.5px outline, which is a button, and a list of eight buttons
//   is the same mistake as the 1.5px-outline-on-every-row pass before it:
//   loud repeated down a column reads as chrome.
//
//   Nothing moves. Frame-stepping the recording at 60fps: the menu is absent
//   in one frame and complete in the next, the selection is on one row in one
//   frame and the next row in the next, and closing is the same single frame
//   in reverse. There is no fade, no travel, no page slide. That is the whole
//   of what "snappy" turned out to mean, and it is cheaper than what it
//   replaces rather than more expensive.
//
// So the tokens below carry no motion for anything the selection or a page
// change does. `motion` survives only for state that is not navigation — a
// switch flipping, a notice appearing — where an instant cut reads as a
// glitch rather than as speed.
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
    // The selection, and it is now a WASH rather than a colour. See the
    // measurement at the top of this file: omarchy's is +12/255 on every
    // channel over its card, which is about 5% white.
    //
    // 0.10 of the text colour rather than the measured 0.047 of white, and the
    // difference is deliberate on both axes. A fraction of pywal's `text` keeps
    // the wash in the palette's own hue instead of introducing a grey the rest
    // of the card does not have. And it is roughly twice omarchy's strength
    // because omarchy's card is a fixed near-black, where this one is whatever
    // pywal made the wallpaper's background — a wash tuned to the darkest case
    // is the one that vanishes on every lighter one. NOT measured across
    // wallpapers; if it turns out to be too quiet on a pale palette this single
    // number is the whole fix.
    //
    // This replaces the accent at 0.95 with a 1.5px text outline, which Ahaan
    // had tuned up twice (0.55 → 0.80 → 0.95) back when the selection was the
    // only thing marking a row on a page full of other chrome. There is no
    // other chrome now, so it does not have to shout over any.
    readonly property color rowSel:    root.alpha(root.text, 0.10)

    // "subtitles, crumbs" and "footer hints, chevrons" is what these two used to
    // say, and half of each is gone: there are no crumbs and no footer hints on
    // the settings card any more. What is left of `dim` is the subtitle on the
    // rows that still have one (keybind descriptions, window-rule
    // documentation) and the prompts' caption text; `dimmer` is the chevron,
    // the placeholder, and the right-hand trailing slot.
    readonly property color dim:    root.alpha(root.text, 0.45)
    readonly property color dimmer: root.alpha(root.text, 0.30)

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
    // There is no rowBorder any more. The selected row carried a 1.5px outline
    // as well as a fill; omarchy's carries a fill and nothing else, and with
    // the fill down at 0.10 an outline is no longer the junior partner in the
    // mark — it IS the mark, and a hard line around one row in a list with no
    // other lines in it is the loudest thing on the card.
    readonly property int rowRadius:  12
    readonly property int iconSlot:   26

    // ── motion ────────────────────────────────────────────────────────────
    // What is NOT here any more is the point of this section.
    //
    // There was a `motionLag` — the selection band's two edges left at
    // different speeds so it stretched into a step — and the band itself, and a
    // page slide, and a card that resized into the page it was entering, and a
    // morph between the launcher box and this card. All of it is gone. omarchy
    // does none of it and is the thing Ahaan pointed at; frame-stepping its
    // recording, a step of the selection is one frame and a page change is one
    // frame. The band that stretched was the single most-worked-on thing in
    // this file and it was work spent making a 180ms delay pleasant instead of
    // removing it.
    //
    // `motion` survives at 180 for the things that are NOT navigation: a switch
    // moving its knob, a notice banner arriving or leaving. Those are state
    // changing rather than the cursor moving, and cutting them reads as a
    // glitch rather than as speed. Nothing in the list or the card's geometry
    // may use it — if a Behavior is about where the selection is or which page
    // is shown, it does not belong here at all.
    readonly property int motion: 180

    // Kept only for the launcher box's own fade, in Finder.qml — the settings
    // card no longer animates its size, its position or its arrival, so
    // nothing in SettingsPanel reads this any more.
    readonly property int motionPage: 190

    readonly property int fsInput: 15
    readonly property int fsRow:   14
    readonly property int fsSub:   11
    readonly property int fsHint:  11
}
