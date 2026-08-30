import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io

// 1:1 visual port of hypr/hyprlock.conf. Instantiated once per screen (by
// WlSessionLock, see shell.qml) with `context` shared across all of them.
//
// Position math: hyprlock's `position = X, Y` is an offset added on top of
// halign/valign in hyprlock's own renderer coordinate space, which — per
// hyprlock's actual source (src/renderer/widgets/IWidget.cpp,
// posFromHVAlign()) — is Y-up (like OpenGL/bottom-left-origin), the opposite
// of QML's Y-down/top-left-origin. Verified by reading that function
// directly rather than guessing: halign="left"→baseX=0, "right"→baseX=
// viewport.x-size.x (offset added directly, no flip — X is NOT flipped);
// valign="top"→baseY=viewport.y-size.y, "bottom"→baseY=0 (Y IS flipped
// relative to screen space). Net effect used below: positive X always
// moves an element right (use directly), positive Y always moves an
// element up (negate it for any QML top-down anchor/offset).
Item {
    id: root
    required property var context

    // Home directory, resolved at runtime rather than hardcoded, so this
    // config is portable to any user/machine. Quickshell.env is synchronous
    // (same reason finder/Sys.qml uses it), so it is safe to read from a
    // property binding evaluated during initial construction.
    readonly property string home: Quickshell.env("HOME") || ""

    // Skip the ~1s entrance animation (blur ramp, dim ramp, content fade)
    // when this lock is being raised because the machine is about to sleep or
    // hibernate — set by lockscreen-launch.sh --instant, which hypridle's
    // before_sleep_cmd/after_sleep_cmd use.
    //
    // Why: the compositor confirms the lock as soon as the surface covers the
    // screens (~250ms measured), which is when hypridle's inhibit_sleep=3
    // releases the sleep inhibitor — correctly, since that is the instant the
    // desktop stops being visible. systemd then freezes user.slice ~100-200ms
    // later, which halts these animations 10-20% of the way through. They
    // resume mid-flight on wake, so the lock appeared to "load in two halves":
    // a bare blur before sleep, then the clock and password field fading in a
    // second after opening the lid.
    //
    // The fix has to be to paint the final state instantly, NOT to delay the
    // lock until the UI is ready — during any such delay the desktop would be
    // visible and interactive again, which is the far worse bug.
    // The idle-timeout lock (lock_cmd, no flag) keeps the full animation.
    readonly property bool instantIntro: Quickshell.env("LOCKSCREEN_INSTANT") === "1"

    readonly property real vw: root.width
    readonly property real vh: root.height

    // hyprlock.conf's absolute pixel values (position offsets, font_size)
    // are specified against the monitor's PHYSICAL resolution (2880x1620
    // here — hyprlock renders in physical pixels, not compositor-scaled
    // logical ones), while this Wayland surface receives LOGICAL
    // coordinates (1440x810 — physical / the monitor's scale of 2.0, the
    // standard Wayland HiDPI model). Confirmed empirically: rendering the
    // raw .conf numbers unscaled (font.pixelSize: 200 etc.) produced clock
    // digits roughly twice the size of the reference photo of the real
    // hyprlock screen. Halving every absolute pixel value below (NOT the
    // percentage-based input-field size, which is already resolution-
    // independent) matches the photo.
    readonly property real uiScale: 0.5

    // general.hide_cursor = true. Item itself has no cursorShape property in
    // this Qt version (confirmed against QtQuick's qmltypes — only
    // MouseArea/pointer handlers expose it), so a click-through MouseArea
    // (acceptedButtons: NoButton lets press/click events fall through to
    // the real interactive items below, e.g. passwordField) is the way to
    // apply a cursor shape over the whole surface.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: Qt.BlankCursor
    }

    // Fallback base in case the Image below ever fails to load (bad path,
    // corrupt file) — normally invisible, since bg now decodes synchronously
    // (see below) and covers it on the very first frame.
    Rectangle {
        anchors.fill: parent
        color: "black"
    }

    // ── username (for the greeting label) ───────────────────────────
    property string username: "user"
    Process {
        id: userProc
        running: true
        command: ["bash", "-c", "echo -n $USER"]
        stdout: StdioCollector {
            onStreamFinished: root.username = text
        }
    }

    // ── wallpaper path — read live from hyprpaper.conf, the same file
    // set_wallpaper.sh rewrites on every wallpaper change, so this and the
    // desktop wallpaper never drift out of sync with each other. ─────────
    // The previous approach (a Process spawning bash -> grep -> sed) and
    // even a first attempt at FileView using its reactive onLoaded signal
    // both left a real, measurable gap (confirmed live via a timestamped
    // console.log: ~108ms between the two) where wallpaperPath still held
    // its hardcoded literal default — a real, different image. Since bg's
    // Image is synchronous (see below, fixed for the black-flash issue
    // separately), that first frame fully committed the WRONG photo before
    // the real path ever arrived and swapped it — that gap was "wrong
    // wallpaper". onLoaded fires as a queued signal even when the
    // underlying read itself is blocking, so it still lands a tick late.
    // Calling hyprpaperFile.text() directly inside the property binding
    // below instead forces the read (and QML's dependency tracking follows
    // property reads through the function call, so this still re-evaluates
    // on future reloads) synchronously as part of evaluating wallpaperPath
    // itself — confirmed live: the second console.log line disappeared
    // entirely, only the correct path is ever set.
    property string wallpaperPath: {
        const m = /^path\s*=\s*(.+)$/m.exec(hyprpaperFile.text())
        return m ? m[1].trim() : (root.home + "/Pictures/wallpapers/dune.jpg")
    }
    FileView {
        id: hyprpaperFile
        path: root.home + "/.config/hypr/hyprpaper.conf"
        blockLoading: true
        blockAllReads: true
        watchChanges: true
        onFileChanged: reload()
    }

    // ── background { path, blur_size=7, blur_passes=2, brightness=.4 } ──
    // No opacity fade on the Image itself — it shows at full opacity the
    // instant it's decoded, exactly like the desktop wallpaper it mirrors.
    //
    // asynchronous: false (not true) is deliberate: a fresh quickshell
    // process spawns per-lock (shell.qml is not a persistent daemon — see
    // its own comment), so WlSessionLockSurface's very first committed
    // frame previously landed *before* an async decode finished, showing
    // the black fallback Rectangle above for a beat before the wallpaper
    // popped in — a black flash. Decoding synchronously means the first
    // frame Quickshell ever submits already has the image in it, so there's
    // nothing to flash to; the only remaining visible transition is the
    // blur/dim ramp below.
    Image {
        id: bg
        anchors.fill: parent
        source: "file://" + root.wallpaperPath
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
        cache: false
    }
    MultiEffect {
        id: bgBlur
        anchors.fill: bg
        source: bg
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 0           // ramps up below — starts sharp, like the photo
                           // is still in the middle of coming into focus.
        blurMax: 64        // standard/full MultiEffect blur range, so the
                            // 0.5 target below reads as a real, visible 50%
                            // blur instead of a barely-there one (blurMax:24,
                            // tried previously, made 0.5 too subtle to
                            // register)
        NumberAnimation on blur {
            to: 0.5          // "blur to 50%" — MultiEffect's `blur` is
                              // already a 0-1 normalized amount, so 0.5 is
                              // literally that.
            duration: root.instantIntro ? 0 : 1000
            easing.type: Easing.OutQuad
        }
    }
    // brightness = .4 in hyprlock.conf, but the reference photo reads as a
    // fairly bright/vivid image, not one dimmed to 40% — a straight 0.6
    // black overlay (tried first) looked far too dark next to it. Kept a
    // light overlay for *some* dimming (matches general dim-for-legibility
    // intent) but calibrated the opacity down to match the photo rather
    // than the literal multiply-by-0.4 math. Ramps in the same way as the
    // blur above, both settling together ~1s after lock.
    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0
        NumberAnimation on opacity {
            to: 0.15
            duration: root.instantIntro ? 0 : 1000
            easing.type: Easing.OutQuad
        }
    }

    // Clock/date/greeting/pill content still fades in on its own — this is
    // just the "content appearing" transition, independent of the
    // wallpaper's dim/blur ramp above.
    Item {
        id: foreground
        anchors.fill: parent
        opacity: 0
        Component.onCompleted: fadeIn.start()
        NumberAnimation {
            id: fadeIn
            target: foreground
            property: "opacity"
            from: 0
            to: 1
            duration: root.instantIntro ? 0 : 450
            easing.type: Easing.OutQuad
        }

    // ── label: HH (font_size=200, color=$color9, pos=(-120,410), center/center) ──
    // Per the reference photo, the hour digits render solid/bright (near-
    // white), not the muted wal color9 — WalColors.foreground is the closer
    // match visually, so used here instead of color9.
    //
    // Sizing/spacing below is now hand-tuned rather than a literal uiScale
    // conversion of the .conf's numbers — bumped larger and pulled closer
    // together per explicit request, deliberately diverging from strict
    // 1:1 fidelity here.
    Text {
        id: hourLabel
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: -75
        anchors.verticalCenterOffset: -175
        color: WalColors.foreground
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 127
        font.bold: true
        text: clockTick.hourText
        renderType: Text.NativeRendering
    }

    // ── label: MM (font_size=200, color=rgba(150,150,150,.4), pos=(120,230)) ──
    Text {
        id: minuteLabel
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: 75
        anchors.verticalCenterOffset: -90
        color: Qt.rgba(150 / 255, 150 / 255, 150 / 255, 0.6)
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 127
        font.bold: true
        text: clockTick.minuteText
        renderType: Text.NativeRendering
    }

    // cmd[update:1000] — recompute once a second, same as hyprlock's labels.
    QtObject {
        id: clockTick
        property string hourText: "12"
        property string minuteText: "00"
        property string dateText: ""

        function refresh() {
            const d = new Date()
            let h = d.getHours() % 12
            if (h === 0) h = 12
            clockTick.hourText = String(h).padStart(2, "0")
            clockTick.minuteText = String(d.getMinutes()).padStart(2, "0")
            clockTick.dateText = Qt.formatDateTime(d, "dddd, MMMM dd, yyyy")
        }

        Component.onCompleted: refresh()
    }
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: clockTick.refresh()
    }

    // ── label: date (font_size=40, color=$color4, pos=(-40,-20), right/top) ──
    // Reference photo shows this near-white/bright too, not the muted
    // wal color4 — WalColors.foreground used here for the same reason as
    // the hour label above.
    Text {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 20 * root.uiScale
        anchors.rightMargin: 40 * root.uiScale
        color: WalColors.foreground
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 24
        text: clockTick.dateText
        renderType: Text.NativeRendering
    }

    // ── label: greeting "<i>Hello</i> <b>$USER</b>" (font_size=40, color=$color5,
    // pos=(40,-20), left/top) ──────────────────────────────────────────
    Text {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: 20 * root.uiScale
        anchors.leftMargin: 40 * root.uiScale
        color: WalColors.foreground
        font.family: "JetBrainsMono Nerd Font Propo"
        font.pixelSize: 24
        textFormat: Text.StyledText
        text: "<i>Hello</i> <b>" + root.username + "</b>"
        renderType: Text.NativeRendering
    }

    // ── input-field: size=6%,4%, pos=(0,-100), center/center ───────────
    // First pass read `inner_color`/`outer_color`/etc all referencing the
    // undefined `$backgroundCol` variable and assumed that meant a fully
    // invisible box. The reference photo of the real hyprlock screen
    // proves that reading wrong — there's a clearly visible small solid
    // rounded pill. (hyprlock evidently falls back to some default fill
    // for an undefined color variable rather than literal transparency.)
    // Corrected to match the photo: a solid rounded pill, sized/positioned
    // per the .conf's size=6%,4% / position=(0,-100), with the actual
    // TextInput layered transparently on top of it for real keyboard focus.
    Rectangle {
        id: passwordPill
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: 0
        anchors.verticalCenterOffset: 100 * root.uiScale   // position=(0,-100) → -(-100)
        width: root.vw * 0.085   // widened from the .conf's literal 6% —
                                  // explicit request, no longer strict 1:1
                                  // (0.11 tried first, too wide — dialed back)
        height: root.vh * 0.04
        radius: height / 2   // dots_rounding=4 in the .conf, but the photo
                              // shows a full capsule, not a barely-rounded
                              // rect — matched to the photo.
        color: "#f5f5fa"
    }

    // Typed-character feedback (dots_spacing from the .conf) — not visible
    // in the reference photo since that was shot with an empty field, but
    // dots_rounding/dots_spacing being configured at all implies *some*
    // visible typing feedback is expected, so a minimal dot row is shown
    // only once there's text, in a color that reads against the light pill.
    // Bolder/larger fill per explicit request.
    //
    // The Repeater below deliberately does NOT bind `model` directly to
    // `Math.min(root.context.currentText.length, 24)`. Confirmed by direct
    // probing (a temporary delegate logging Component.onCompleted while
    // simulated keystrokes drove currentText): binding `model` to a
    // re-evaluated JS expression like that made THIS Quickshell/Qt version
    // destroy and recreate every existing delegate on every single
    // keystroke, not just append the new one — e.g. typing "abc" logged
    // dot 0 created 3 times, dot 1 created twice. That's exactly why every
    // dot appeared to "blink" while typing: they were all silently
    // replaying their pop-in opacity/scale animation from scratch each
    // time, not just the newest one. A ListModel that's only ever
    // appended to or trimmed from the end (never reset/reassigned) doesn't
    // have this problem — existing delegates are left completely alone,
    // and only the newly appended (or about-to-be-removed) one is touched.
    ListModel { id: dotsModel }
    QtObject {
        id: dotsSync
        function sync() {
            // Comfortably more than the pill can show at once: the row scrolls,
            // so this only needs to outlast any realistic password. If it were
            // set to roughly what fits, typing past that point would add no dot
            // and the row would stop moving — no feedback at all.
            const len = Math.min(root.context.currentText.length, 64)
            while (dotsModel.count < len) dotsModel.append({})
            while (dotsModel.count > len) dotsModel.remove(dotsModel.count - 1)
        }
        Component.onCompleted: sync()
    }
    Connections {
        target: root.context
        function onCurrentTextChanged() { dotsSync.sync() }
    }

    // The dot row is clipped to the pill and scrolls. At a fixed 9px + 5px
    // spacing the model's 24-dot cap came to ~331px of row against a pill only
    // vw*0.085 (~122px) wide, so a long password spilled the dots straight out
    // over the blurred wallpaper.
    Item {
        id: dotsClip
        anchors.centerIn: passwordPill
        width: passwordPill.width - 12 * root.uiScale
        height: passwordPill.height
        clip: true                     // hard backstop, whatever the maths does
        visible: dotsModel.count > 0

        Row {
            id: dotsRow
            spacing: 5
            y: (dotsClip.height - height) / 2

            // Centred while the dots still fit; once they do not, the row is
            // pinned to the right edge so the newest dot is always visible and
            // the oldest ones slide out under the left edge of the pill. The
            // dots keep their size — they disappear into the box rather than
            // shrinking to make room.
            x: dotsRow.width <= dotsClip.width
               ? (dotsClip.width - dotsRow.width) / 2
               : dotsClip.width - dotsRow.width
            Behavior on x { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

            Repeater {
                model: dotsModel
                Rectangle {
                    width: 9
                    height: 9
                    radius: 4.5
                    color: "#1a1d29"
                    opacity: 0
                    scale: 0.4
                // A Behavior armed via Component.onCompleted (tried first)
                // has a known QML timing gotcha: the very first property
                // change right after an item is created can land before
                // the Behavior is fully wired up, so it jumps instead of
                // animating — which is exactly what "still snappy" was.
                // A self-starting `NumberAnimation on <property>` doesn't
                // have that gotcha; it runs from the declared initial value
                // the moment the delegate exists, every time. And since
                // this delegate is now only ever created once per
                // character (see the ListModel note above), this animation
                // now genuinely only plays once per dot, on the dot that
                // was just typed — not on every dot, every keystroke.
                    NumberAnimation on opacity { to: 1; duration: 220; easing.type: Easing.OutQuad }
                    NumberAnimation on scale   { to: 1; duration: 220; easing.type: Easing.OutBack }
                }
            }
        }
    }

    TextInput {
        id: passwordField
        anchors.fill: passwordPill
        color: "transparent"
        cursorVisible: false   // the blinking caret renders regardless of
                                // `color` (that only affects text glyphs).
        // cursorVisible alone wasn't enough — TextInput's internal focus
        // handling re-enables it as a plain C++-side write, which silently
        // overrides a one-time QML literal like the one above once the
        // field gains focus (confirmed still blinking after the
        // cursorVisible-only fix). Swapping the cursor's delegate for an
        // empty Item sidesteps that entirely: there's nothing to draw
        // regardless of the visible/blink state underneath.
        cursorDelegate: Item {}
        echoMode: TextInput.Password
        focus: true
        clip: true
        // No `enabled` gating on an in-flight auth attempt anymore — see
        // LockContext.tryUnlock(): currentText is cleared synchronously at
        // submit time, before PAM is even asked to start, so the field
        // never needs to be disabled/re-enabled (and never loses focus)
        // while a background attempt is still resolving. Retyping after a
        // wrong password is just... continuing to type.

        onTextChanged: root.context.currentText = text
        onAccepted: root.context.tryUnlock()

        // Keeps every screen's field in sync with the shared context
        // (matters when there's more than one monitor).
        Connections {
            target: root.context
            function onCurrentTextChanged() {
                if (passwordField.text !== root.context.currentText)
                    passwordField.text = root.context.currentText
            }
        }
    }
    } // foreground
}
