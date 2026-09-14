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
        // Decode bounded to the output. A wallpaper is usually larger than the
        // screen and decoding it at native size costs real memory for pixels
        // that cannot be drawn — the same trap finder's preview pane documents,
        // where a 6000x4000 photo is ~96 MB as a pixmap. At 2880x1620 this is
        // ~18 MB, and two of them exist only across a fade.
        //
        // The trade, stated: Qt fits the decode INSIDE this box preserving
        // aspect, so an image far wider than the screen (a panorama) decodes
        // shorter than the screen and is then upscaled by the crop. Soft, not
        // broken, and not the shape of anything in ~/Pictures/wallpapers.
        sourceSize.width:  win.screen.width
        sourceSize.height: win.screen.height
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
        sourceSize.width:  win.screen.width
        sourceSize.height: win.screen.height
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
