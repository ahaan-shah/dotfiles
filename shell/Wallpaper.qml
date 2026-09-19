pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// The desktop wallpaper, one surface per output.
//
// ── What this replaces, and why ───────────────────────────────────────────
// hyprpaper, and the ~80 lines of finder/apply-wallpaper.sh that existed to
// keep it alive. Three failure modes lived in that arrangement and all three
// came from the same fact — the wallpaper was a separate process:
//
//   * it inherited Quickshell's stdout pipe through `& disown` and died of
//     SIGPIPE on its next log line, mid-session, leaving a grey desktop;
//   * `pkill` returns when the signal is sent, so a new instance starting
//     inside the old one's socket-release window exited with "couldn't open
//     a socket (1)";
//   * it came up perfectly healthy and drew NOTHING when `monitor =` named an
//     output that did not exist, which is one stale hardware.env or one
//     docked display away at any time.
//
// None of the three is expressible here. There is no process to die, no socket
// to race, and no monitor name to get wrong: `Variants` over
// `Quickshell.screens` means every output that exists gets a surface, and one
// that appears later gets one then. The generated hyprpaper.conf is gone with
// them, so the wallpaper is no longer a file this repo has to keep in sync
// with itself.
//
// Ahaan's call on the one cost: SUPER+K restarts all three shells, so the
// wallpaper now blinks with them. "That bind is a universal shell reload."
PanelWindow {
    id: win

    required property ShellScreen modelData
    screen: modelData

    // The image to draw. Empty is a valid state — a machine with no wallpaper
    // recorded yet shows the ground colour below rather than a guess.
    property string path: ""

    readonly property string url: win.path === "" ? "" : "file://" + win.path

    // How long a change takes. hyprpaper could only cut; this is the one thing
    // the move ADDS rather than deletes, and it is state changing rather than
    // navigation — the distinction Theme.qml draws for the settings card, on
    // the other side of which a fade is right.
    readonly property int fadeMs: 420

    anchors { top: true; left: true; right: true; bottom: true }

    WlrLayershell.layer:     WlrLayer.Background
    WlrLayershell.namespace: "wallpaper"
    // Nothing here is ever typed into, and a background that takes focus would
    // take it FROM whatever the user is using.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // exclusionMode, NOT exclusiveZone: 0. The two are different questions and
    // the taskbar's reminder prompt already paid for the distinction — a
    // surface with exclusiveZone 0 reserves nothing and is still SHRUNK out of
    // everything else's reserved space, which for the bar's 44px zone would
    // leave a 44px strip of bare compositor across the top of the desktop.
    // ExclusionMode.Ignore maps to layer-shell's exclusive_zone -1, "give me
    // the whole output", which is the only correct answer for a wallpaper.
    exclusionMode: ExclusionMode.Ignore

    // The ground under the image: black, and visible only while there is no
    // wallpaper to draw or during the first decode. Not the palette's
    // background — a wallpaper that has not loaded yet is not a themed
    // surface, and matching the bar would make a missing image look deliberate.
    color: "black"

    // Click-through, permanently. A 0x0 item and not an empty `Region {}`:
    // Quickshell reads a Region with no item as the WHOLE window, which is the
    // opposite of what is wanted here and is why finder's own scrim is written
    // the same way round. Without this the desktop swallows every click that
    // is not on a window.
    mask: Region { item: nothing }
    Item { id: nothing; width: 0; height: 0 }

    // ── the two images ────────────────────────────────────────────────────
    // A double buffer, so a change never shows a half-decoded image. The
    // incoming one loads underneath at opacity 0 and the pair crossfade only
    // once it reports Ready; whichever ends up behind is then freed.
    //
    // `_frontIsA` is the whole state machine: both opacities are bound to it,
    // so flipping it IS the crossfade and there is no animation to drive by
    // hand, nothing to cancel when a second change arrives mid-fade, and no
    // way for the two images to end up both visible or both hidden.
    property bool _frontIsA: true

    Image {
        id: imgA
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        // Decode bounded to the output, in PHYSICAL pixels.
        //
        // ── The * devicePixelRatio is the whole of this, and it was missing ──
        // `screen.width` is LOGICAL — 1440 on this 2880x1620 panel at scale 2 —
        // and Qt honours sourceSize verbatim. So the wallpaper decoded at half
        // the panel's resolution and the surface then stretched it 2x, on every
        // image, since the move off hyprpaper on 2026-09-14. Reported as "all my
        // wallpapers appear blur now, even the ones that looked perfectly fine
        // before", and measured rather than reasoned about: a grim capture of a
        // window-free strip of the live desktop matched a 1440x810-then-upscaled
        // render at RMSE 0.0024 against 0.0131 for a true 2880x1620 render, with
        // edge energy 43 against 102. It was drawing half the pixels it had.
        //
        // The comment that used to sit here said "at 2880x1620 this is ~18 MB",
        // which is the arithmetic for the PHYSICAL size — so the intent was
        // always this and only the expression was wrong. Worth knowing: every
        // other Image in this repo that needs the same correction hardcodes
        // `* 2` (DockIcon, SettingsPanel, Bar's SVG glyphs). This asks the
        // screen instead, because a hardcoded 2 is exactly the machine-specific
        // constant the rest of the repo keeps out of configs.
        //
        // devicePixelRatio carries no change signal of its own, but width and
        // height notify through geometryChanged and the binding reads all
        // three — so a scale change re-evaluates this and picks up the new
        // ratio with it.
        //
        // Memory is unchanged from what that comment claimed: 2880x1620 RGBA is
        // ~18 MB, and two exist only across a fade. Decoding at native size
        // instead would be ~74 MB each for the 5760x3240 images here.
        //
        // The trade that remains, now with numbers: Qt fits the decode INSIDE
        // this box preserving aspect, so an image whose aspect is not the
        // screen's decodes short on one axis and is upscaled by the crop.
        // Measured over the 17 wallpapers here, 15 are exactly 16:9 and need no
        // upscale at all; lunar-tides (5120x4266) needs 1.48x and space-arc
        // (1893x4096, a portrait) needs 3.85x. Fixing that properly means
        // decoding to COVER rather than to fit, which needs the image's aspect
        // before the decode — deliberately not done here.
        sourceSize.width:  Math.round(win.screen.width  * win.screen.devicePixelRatio)
        sourceSize.height: Math.round(win.screen.height * win.screen.devicePixelRatio)
        // Synchronous, and only this one: it holds the FIRST wallpaper, and a
        // session that comes up showing black for a beat before the desktop
        // appears is the one moment this is visible. The lock screen's own
        // background is synchronous for exactly this reason and records the
        // measurement. Every later change goes through imgB, which is async so
        // that decoding a new wallpaper never blocks the dock.
        asynchronous: false
        // Neither image is cached: they are the two largest pixmaps this
        // process ever holds, and a cache would keep every wallpaper tried
        // during a session resident for the life of the shell.
        cache: false
        opacity: win._frontIsA ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: win.fadeMs; easing.type: Easing.InOutQuad } }
        onStatusChanged: win._arrived(imgA)
    }

    Image {
        id: imgB
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        // Physical pixels, for the reason spelled out on imgA above.
        sourceSize.width:  Math.round(win.screen.width  * win.screen.devicePixelRatio)
        sourceSize.height: Math.round(win.screen.height * win.screen.devicePixelRatio)
        asynchronous: true
        cache: false
        opacity: win._frontIsA ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: win.fadeMs; easing.type: Easing.InOutQuad } }
        onStatusChanged: win._arrived(imgB)
    }

    readonly property Image _back: win._frontIsA ? imgB : imgA

    onUrlChanged: win._load()

    function _load() {
        if (win.url === "") return
        // Already showing it — a re-save of the state file with the same path
        // must not cost a decode and a fade. This is not hypothetical: every
        // palette change under "pywal" rewrites nothing here, but a wallpaper
        // re-applied from finder (choosing the one already up) writes the same
        // path back.
        const front = win._frontIsA ? imgA : imgB
        if (front.source == win.url) return
        win._back.source = win.url
    }

    // Ready on the image that is currently BEHIND means the incoming wallpaper
    // is fully decoded, which is the only moment it is safe to show. Flipping
    // the flag crossfades both images at once.
    function _arrived(img) {
        if (img.status !== Image.Ready) return
        if (img !== win._back || img.source != win.url) return
        win._frontIsA = !win._frontIsA
        freeTimer.restart()
    }

    // Free the outgoing image once the fade has finished. Clearing `source`
    // with cache:false is what actually releases the pixmap, and it must not
    // happen before the fade ends or the old wallpaper vanishes mid-crossfade,
    // showing the black ground through it.
    Timer {
        id: freeTimer
        interval: win.fadeMs + 80
        onTriggered: win._back.source = ""
    }

    // ── where the path comes from ─────────────────────────────────────────
    // ~/.local/state/hyprahaan/wallpaper, one line, written by
    // finder/apply-wallpaper.sh. It sits beside the dock pins, the night-light
    // temperature and the reminders for the reasons those are there: it is
    // per-machine state rather than design, it must not reach the public
    // mirror, and a deploy copies files INTO ~/.config — a store kept there
    // would be clobbered by the very update that ships a wallpaper change.
    //
    // It also replaces hyprpaper.conf as the one place the desktop and the
    // LOCK SCREEN agree on what the wallpaper is; lockscreen/LockSurface.qml
    // reads this same file.
    readonly property string _home: Quickshell.env("HOME") || ""
    readonly property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || win._home + "/.local/state")
        + "/hyprahaan/wallpaper"

    // blockLoading, for the same reason imgA is synchronous: the path has to be
    // known on the frame the surface is first drawn, not a tick later. The lock
    // screen measured that gap at ~108 ms and committed the WRONG image inside
    // it; here the equivalent is a black desktop that then pops.
    FileView {
        id: stateFile
        path: win.statePath
        blockLoading: true
        blockAllReads: true
        onLoaded:      win.path = String(stateFile.text()).trim()
        onLoadFailed:  win.path = ""
    }

    // watchChanges is NOT used, and that is deliberate. The writer replaces this
    // file with a temp-file `mv` so a reader can never see half a path, and a
    // file watch follows the INODE — it fires once and then never again, which
    // is the exact trap ui.conf and the dock's pin store both document. So the
    // watch is on the DIRECTORY, and it is StateDir's: the dock's pin store
    // watches the same directory, and one shell should not hold two identical
    // inotify watches on it.
    property var _watchConn: Connections {
        target: StateDir
        function onChanged() {
            stateFile.reload()
            win.path = String(stateFile.text()).trim()
        }
    }
}
