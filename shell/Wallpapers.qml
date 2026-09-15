pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Setting the wallpaper. One call, and it is a shell-out.
//
// The apply pipeline (record the path, then pywal, the cava gradient sync and
// `hyprctl reload` through palette.sh) lives in apply-wallpaper.sh alongside
// this file — it is a shell pipeline with a lot of independent side effects,
// not worth reimplementing inline in QML piece by piece, and it has to stay
// runnable from a terminal because install.sh calls it on a fresh machine.
//
// ── This file used to do the LISTING too ──────────────────────────────────
// It held the directory walk (`ls -1 ~/Pictures/wallpapers`), the cached list
// and a substring search over it, because finder had a wallpaper MODE — ALT+W,
// its own result list — and that mode was its only caller. On 2026-09-15 the
// picker became a settings page instead (Settings.qml, Theme → Wallpapers) and
// the keybind went with it. A settings listing comes from a script, like every
// other listing on that card, so the directory walk moved to
// scripts/wallpapers.sh — which also has to answer a question this file never
// could: which of those images goes with the palette in force.
//
// What is left is the half nothing replaced. Settings.activate() calls it with
// the absolute path the listing carried.
QtObject {
    id: root

    function apply(path) {
        applyProc.command = [Quickshell.shellPath("apply-wallpaper.sh"), path]
        applyProc.running = true
    }

    property var applyProc: Process { id: applyProc; running: false }
}
