pragma Singleton

// MusicState.qml — whether the music player is open in the centre island, and
// the player it is showing.
//
// The player used to be the top box of the notification center. Ahaan, 2026-10-25:
// "keep the control centre just for notifications and move the music player
// into the center island" — clicking the mpris chip (or SUPER+SHIFT+M) grows
// the island, cover on the left, controls on the right. Music.qml draws it;
// Bar.qml sizes the island from `amount` / `wantHeight` / `targetWidth` below
// and hands `player` over (the sticky pick it already keeps, mprisPlayer, so
// the island shows the player the old widget did).

import QtQuick
import Quickshell
import Quickshell.Services.Mpris

Singleton {
    id: root

    property bool open: false
    // The island's expansion, 0..1, animated here so the bar and Music.qml
    // read the same number on the same frame (as TodoState does).
    property real amount: open ? 1 : 0
    Behavior on amount { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

    // The centre island Music.qml draws over; set by the bar. With more than
    // one monitor the last bar wins, as for the other tenants.
    property var island: null
    // An MprisPlayer, or null. Set by the bar.
    property var player: null

    // Size of the part of the island under its clock row. Fixed: a cover and
    // a column of controls do not change shape with the track.
    readonly property real targetWidth: 560
    readonly property real wantHeight: 224

    // Tab in the island: the bar walks its player list (mprisCycle).
    property int cycleDir: 1    // direction of the last cycle, for the slide
    signal cyclePlayer(int dir)

    function toggleOpen() { open ? close() : show() }
    function show() {
        // One thing in the island at a time: a jarvis card that is up goes.
        if (JarvisState.expanded) JarvisState.dismiss()
        open = true
    }
    function close() { open = false }

    // ── transport, shared by the keys, the buttons and `ipc call music` ───
    function playPause() { if (player && player.canTogglePlaying) player.togglePlaying() }
    function next() { if (player && player.canGoNext) player.next() }
    function previous() { if (player && player.canGoPrevious) player.previous() }
    function toggleShuffle() { if (player && player.shuffleSupported) player.shuffle = !player.shuffle }
    // What the repeat button shows. Optimistic, then confirmed: clicking
    // Playlist -> Track made the icon drop to "off" and then come back
    // ringed (Ahaan). Measured with `ipc call music state` polled right after
    // the click: Spotsie reports Track, then None for ~0.5 s, then Track
    // again — it resets and re-sets its loop status — and the button drew
    // every step of it. So a click is shown at once and held for holdMs
    // before the player's own reading is trusted again; a click inside that
    // window steps from what is shown, not from the blip. (Spotsie does
    // support repeat-track; the blip only looked like it did not.)
    readonly property int holdMs: 1500
    property int pendingLoop: -1
    readonly property int loopShown: pendingLoop >= 0 ? pendingLoop
                                   : (player ? player.loopState : MprisLoopState.None)
    Timer { id: loopHold; interval: root.holdMs; onTriggered: root.pendingLoop = -1 }
    onPlayerChanged: { pendingLoop = -1; loopHold.stop() }

    // None -> Playlist -> Track -> None, as the notification center's button did.
    function cycleRepeat() {
        if (!player || !player.loopSupported) return
        const s = loopShown
        const n = s === MprisLoopState.None ? MprisLoopState.Playlist
                : s === MprisLoopState.Playlist ? MprisLoopState.Track
                : MprisLoopState.None
        pendingLoop = n
        loopHold.restart()
        player.loopState = n
    }
}
